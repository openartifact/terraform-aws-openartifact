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

# Every directory that is a Terraform root, module or example.
DIRS := . $(wildcard modules/*/) $(wildcard examples/*/)
export TF_PLUGIN_CACHE_DIR ?= $(HOME)/.terraform.d/plugin-cache

.PHONY: all fmt fmt-check lint validate tofu-validate test tofu-test docs docs-check security trivy checkov reuse actionlint clean

all: fmt-check validate lint test docs-check security reuse actionlint ## everything CI runs (terraform only)

fmt: ## rewrite formatting
	$(TERRAFORM) fmt -recursive

fmt-check: ## fail on unformatted files
	$(TERRAFORM) fmt -check -recursive -diff

define validate_all
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"
	@for d in $(DIRS); do \
	  ls "$$d"/*.tf >/dev/null 2>&1 || continue; \
	  echo "==> $(1) validate $$d"; \
	  ( cd "$$d" && $(1) init -backend=false -input=false -no-color >/dev/null && $(1) validate -no-color ); \
	done
endef

validate: ## init -backend=false + validate for root, modules/*, examples/*
	$(call validate_all,$(TERRAFORM))

tofu-validate: ## same with OpenTofu
	$(call validate_all,$(TOFU))

lint: ## tflint (terraform + aws rulesets), recursive
	tflint --init --config="$(CURDIR)/.tflint.hcl"
	tflint --recursive --config="$(CURDIR)/.tflint.hcl"

test: ## native plan-only tests (tests/*.tftest.hcl)
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"
	$(TERRAFORM) init -backend=false -input=false >/dev/null
	$(TERRAFORM) test

tofu-test: ## same with OpenTofu
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"
	$(TOFU) init -backend=false -input=false >/dev/null
	$(TOFU) test

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
	find . -type d -name .terraform -prune -exec rm -rf {} +
