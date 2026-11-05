# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Mirrors .github/workflows. Never runs apply/plan against AWS: validate and
# `test` (plan-only, mocked provider) are offline.
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

TERRAFORM ?= terraform
TOFU ?= tofu
TF_DOCS ?= terraform-docs
TOFU_WORK ?= $(CURDIR)/.tofu/work
LOCK_PLATFORMS := -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64 -platform=darwin_amd64 -platform=windows_amd64

# Every directory that is a Terraform root, module or example.
DIRS := . $(wildcard modules/*/) $(wildcard examples/*/)
export TF_PLUGIN_CACHE_DIR ?= $(HOME)/.terraform.d/plugin-cache

.PHONY: all fmt fmt-check lint validate tofu-sync tofu-validate test tofu-test lock docs docs-check security trivy checkov reuse actionlint clean

all: fmt-check validate lint test docs-check security reuse actionlint ## everything CI runs (terraform only)

fmt: ## rewrite formatting
	$(TERRAFORM) fmt -recursive

fmt-check: ## fail on unformatted files
	$(TERRAFORM) fmt -check -recursive -diff

# Terraform runs in the tree. Committed lock files (examples/) are never rewritten:
# `-lockfile=readonly` makes init fail on drift instead; refresh them with `make lock`.
validate: ## init -backend=false + validate for root, modules/*, examples/*
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"
	@for d in $(DIRS); do \
	  ls "$$d"/*.tf >/dev/null 2>&1 || continue; \
	  lockflag=""; \
	  case "$$d" in examples/*) [ -f "$$d/.terraform.lock.hcl" ] && lockflag="-lockfile=readonly" ;; esac; \
	  echo "==> terraform validate $$d"; \
	  ( cd "$$d" && $(TERRAFORM) init -backend=false -input=false -no-color $$lockflag >/dev/null && $(TERRAFORM) validate -no-color ); \
	done

# OpenTofu must not share .terraform/ or lock files with Terraform (tofu rewrites the lock
# file with its own registry addresses), so it runs in a throwaway copy of the tree.
tofu-sync:
	@mkdir -p "$(TOFU_WORK)"
	@rsync -a --delete --delete-excluded \
	  --exclude=/.git --exclude=/.tofu --exclude=.terraform --exclude=.terraform.lock.hcl \
	  ./ "$(TOFU_WORK)/"

tofu-validate: tofu-sync ## same with OpenTofu (in .tofu/work, the tree is not touched)
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"
	@for d in $(DIRS); do \
	  ls "$(TOFU_WORK)/$$d"/*.tf >/dev/null 2>&1 || continue; \
	  echo "==> tofu validate $$d"; \
	  ( cd "$(TOFU_WORK)/$$d" && $(TOFU) init -backend=false -input=false -no-color >/dev/null && $(TOFU) validate -no-color ); \
	done

lint: ## tflint (terraform + aws rulesets), recursive
	tflint --init --config="$(CURDIR)/.tflint.hcl"
	tflint --recursive --config="$(CURDIR)/.tflint.hcl"

test: ## native plan-only tests (tests/*.tftest.hcl, run against the root module)
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"
	$(TERRAFORM) init -backend=false -input=false >/dev/null
	$(TERRAFORM) test

tofu-test: tofu-sync ## same with OpenTofu (in .tofu/work)
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"
	cd "$(TOFU_WORK)" && $(TOFU) init -backend=false -input=false >/dev/null && $(TOFU) test

lock: ## refresh examples/*/.terraform.lock.hcl with hashes for all supported platforms
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"
	@for d in $(wildcard examples/*/); do \
	  echo "==> terraform providers lock $$d"; \
	  ( cd "$$d" && $(TERRAFORM) init -backend=false -input=false -no-color >/dev/null && \
	    $(TERRAFORM) providers lock $(LOCK_PLATFORMS) ); \
	done

docs: ## regenerate the terraform-docs sections (root, modules/*, examples/*)
	@for d in $(DIRS); do \
	  echo "==> terraform-docs $$d"; \
	  $(TF_DOCS) --config "$(CURDIR)/.terraform-docs.yml" "$$d"; \
	done

docs-check: ## fail when a README is out of date with the code
	@for d in $(DIRS); do \
	  echo "==> terraform-docs --output-check $$d"; \
	  $(TF_DOCS) --config "$(CURDIR)/.terraform-docs.yml" --output-check "$$d"; \
	done

trivy: ## misconfiguration scan, fails on HIGH/CRITICAL
	trivy config --config trivy.yaml .

checkov: ## checkov, fails on any finding
	checkov --config-file .checkov.yaml

security: trivy checkov ## trivy + checkov

reuse: ## licence/copyright compliance
	reuse lint

actionlint: ## lint GitHub workflows
	actionlint .github/workflows/*.yml

clean: ## remove local working data
	rm -rf .tofu
	find . -type d -name .terraform -prune -exec rm -rf {} +
