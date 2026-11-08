<!--
SPDX-FileCopyrightText: The OpenArtifact Authors

SPDX-License-Identifier: MPL-2.0
-->

# ecs-service

Runs one [OpenArtifact](https://github.com/openartifact/openartifact) process role (`all`, `web` or `worker`) as an **ECS service** on Fargate (default) or on EC2 capacity providers: task definition, service, task security group, execution and task IAM roles, CloudWatch log group, optional Application Auto Scaling and an optional secret-rotation redeployer.

The root module of this repository calls it twice (`module.web`, and `module.worker` when enabled). You can also use it on its own, against your own cluster, load balancer, database and bucket.

## EC2 capacity providers and EFS volumes

- **Fargate (default).** With `capacity_provider_strategy = []` the service uses the `FARGATE` launch type, a Fargate-only task definition and `ephemeral_storage_gib` for `/tmp`.
- **EC2.** Pass a `capacity_provider_strategy` (for example the names from `modules/ecs-ec2-capacity`) and the service is placed by those capacity providers: no launch type, a task definition that requires `EC2`, `awsvpc` networking unchanged, no `ephemeral_storage` (Fargate-only) and `/tmp` as a task-scoped local Docker volume on the instance disk. `assign_public_ip` must stay `false`.
- **EFS.** Each entry of `efs_volumes` becomes an EFS volume mounted at its `container_path`, always through its access point, with TLS (`transit_encryption = "ENABLED"`) and IAM authorization, and the task role gets `elasticfilesystem:ClientMount` and `ClientWrite` on that file system restricted to that access point. The container still runs as uid/gid 10001 on a read-only root filesystem; the access point decides ownership of the mounted directory. The file system, its access points and its mount targets (see `modules/efs`) must exist before the service starts: pass the ids from `modules/efs` outputs, which only resolve once the mount targets are available.

## Usage

```hcl
module "openartifact_web" {
  source  = "openartifact/openartifact/aws//modules/ecs-service"
  version = "~> 0.1"

  name         = "openartifact"
  cluster_arn  = aws_ecs_cluster.this.arn
  cluster_name = aws_ecs_cluster.this.name
  vpc_id       = var.vpc_id
  subnet_ids   = var.private_subnet_ids

  image         = "ghcr.io/openartifact/openartifact:0.19.2" # or "...@sha256:<digest>"
  role          = "web"
  desired_count = 2
  cpu           = 1024
  memory        = 2048

  target_group_arn           = aws_lb_target_group.web.arn
  ingress_security_group_ids = [aws_security_group.alb.id]

  environment = {
    STORAGE_BACKEND = "s3"
    STORAGE_BUCKET  = module.storage.bucket_id
    STORAGE_REGION  = module.storage.bucket_region
    DB_HOST         = module.database.endpoint
    DB_PORT         = tostring(module.database.port)
    DB_NAME         = module.database.database_name
    DB_USER         = module.database.master_username
    DB_SSLMODE      = "require"
    LOG_FORMAT      = "json"
  }

  secrets = {
    DB_PASSWORD             = "${module.database.master_user_secret_arn}:password::"
    OPENARTIFACT_SECRET_KEY = module.secrets.secret_key_arn
    AUTH_HMAC_KEY           = module.secrets.hmac_key_arn
  }
  execution_secret_arns  = [module.database.master_user_secret_arn, module.secrets.secret_key_arn, module.secrets.hmac_key_arn]
  execution_kms_key_arns = [module.database.kms_key_arn]

  task_role_policy_json = module.storage.access_policy_json

  egress_security_group_rules = [
    { security_group_id = module.database.security_group_id, port = 5432, description = "PostgreSQL" },
  ]

  autoscaling = {
    enabled      = true
    min_capacity = 2
    max_capacity = 6
  }

  # RDS rotates its master password: restart the tasks so they read the new one.
  redeploy_on_secret_rotation_arns = [module.database.master_user_secret_arn]
}
```

To run straight from Git before a release is published, use `source = "git::https://github.com/openartifact/terraform-aws-openartifact.git//modules/ecs-service?ref=vX.Y.Z"`.

For a `worker` service leave `target_group_arn` unset (it is rejected for `role = "worker"`) and `ingress_security_group_ids` empty.

## Container and runtime facts

| Aspect | Value | Source |
|---|---|---|
| Entrypoint / health check | `/app/openartifact` and `["CMD", "/app/openartifact", "-healthcheck"]` (exec form: the image is shell-less) | `docker/Dockerfile` (`COPY ... /app/openartifact`, `HEALTHCHECK CMD ["/app/openartifact", "-healthcheck"]`), `docker/docker-compose.yml`; `cmd/server/healthcheck.go` GETs `/health` on `SERVER_PORT` |
| User | `10001:10001`, no privilege, all Linux capabilities dropped, init process enabled | Dockerfile `USER 10001:10001` |
| Root filesystem | read-only | see below |
| Writable path | `/tmp` only, a task-scoped ephemeral volume (`ephemeral_storage_gib`, 21-200 GiB) | see below |

### Writable paths with `readonlyRootFilesystem`

Checked against the OpenArtifact source (`internal/storage`, `internal/format/base`, `internal/proxy`, `internal/vuln`, `internal/backup`):

- **S3 upload spool.** The S3 backend spools every `Put` to disk before it uploads. With `STORAGE_SPOOL_PATH` unset it uses `os.TempDir()` (`/tmp`), which is neither created nor swept by the server (`prepareSpoolDir` returns early for an empty path). The module therefore does **not** set `STORAGE_SPOOL_PATH`: `/tmp` is mounted from the task volume, already exists, and the image's temp files (upload spools, proxy downloads, conda/npm/backup-restore temp files) all land there. If you set `STORAGE_SPOOL_PATH=/tmp/<dir>` yourself the server creates it (0700) and removes stale spool files at start.
- **Sizing.** Large uploads and proxied blobs (for example OCI layers) are spooled to `/tmp`, so `ephemeral_storage_gib` bounds the largest blob times the concurrent transfers per task.
- **Not writable, not needed by default.** The in-application backup feature writes to `OPENARTIFACT_BACKUP_DIR` (default `/var/lib/openartifact/backups`) and runtime install of the Trivy/Grype scanners writes to `OPENARTIFACT_SCANNER_CACHE_DIR` (`/var/cache/openartifact/scanners`). Neither is available on a read-only root filesystem; on ECS rely on RDS snapshots and S3 versioning for recovery and use a pre-built scanner image or the default OSV-based scanning. Pointing them at `/tmp` works but is ephemeral and, for the scanner cache, is refused by the server (a shared temp directory is not accepted for downloaded binaries).
- **Home directory.** The image sets no `$HOME`; nothing else in the server runtime path uses it.
- **Volume permissions.** [INFERENCE] The `tmp` volume replaces `/tmp` of the image, whose mode is `1777` in the distroless/static base, so uid 10001 can write. This was derived from the image and Dockerfile, not observed on a running Fargate task.

## Security notes

- **No static credentials.** S3 access comes from the task role (`task_role_policy_json`, normally the storage module's least-privilege policy). `STORAGE_ACCESS_KEY`, `STORAGE_SECRET_KEY` and `AWS_*` credentials are rejected in `environment`.
- **Secrets never touch Terraform state or the task definition as values.** Pass them through `secrets` as `valueFrom` references; the execution role reads them. `environment` is plain text in the task definition: never put secrets in it.
- **Execution role** is limited to `logs:CreateLogStream/PutLogEvents` on this log group, `secretsmanager:GetSecretValue` on `execution_secret_arns` and `kms:Decrypt` on `execution_kms_key_arns` (only when non-empty). Its trust policy is scoped with `aws:SourceAccount` and `aws:SourceArn`. The default image is public (`ghcr.io`), so no registry permissions are added; for a private ECR mirror attach an ECR pull policy to the `execution_role_arn` role yourself.
- **Task role** carries only `task_role_policy_json`. ECS Exec is **off** by default (`enable_execute_command`); enabling it adds the `ssmmessages:*Channel` actions (resource `*`, the only form IAM supports for them). Because the image is shell-less, ECS Exec is only useful with a debug image or sidecar.
- **Network.** The task security group allows ingress only from `ingress_security_group_ids` on `container_port`. Egress is TCP 443 to `egress_https_cidr_blocks` (default `0.0.0.0/0`, deliberately: proxy repositories fetch from arbitrary upstream registries, plus ghcr.io image pulls and the AWS APIs) and explicit security-group rules such as PostgreSQL to the database. Narrow the CIDRs only together with VPC endpoints for the AWS APIs and, for S3, `egress_https_prefix_list_ids` (a gateway endpoint is reached through its managed prefix list). The `0.0.0.0/0` rule carries an inline, justified Trivy/Checkov suppression. DNS to the VPC resolver is not subject to security groups.
- **Log encryption.** Pass `log_kms_key_arn` to encrypt the log groups with a customer-managed key. Its key policy must allow the `logs.<region>.amazonaws.com` service principal, otherwise log group creation fails.
- **Lifecycle.** `desired_count` is only the initial value (`ignore_changes`); Application Auto Scaling or an operator owns the count afterwards. The deployment circuit breaker is on with rollback.
- **Admin bootstrap token.** `OPENARTIFACT_BOOTSTRAP_ADMIN_TOKEN_FILE` is file-only and not supported on ECS (no file mounts); use the bootstrap admin password secret.

## Redeploy on secret rotation

The container reads its environment, including `DB_PASSWORD`, only at start. The RDS-managed master secret rotates by default every 7 days, so tasks must be restarted after a rotation. When `redeploy_on_secret_rotation_arns` is non-empty the module creates:

1. An EventBridge rule on the **default event bus** matching `source = aws.secretsmanager`, `detail-type = "Secret Label Updated"`, `detail.labelUpdated = ["AWSCURRENT"]` and `resources` = the given secret ARNs.
2. An IAM role letting that rule start exactly one state machine.
3. A Step Functions `STANDARD` state machine (X-Ray tracing off, error-level logging to its own log group under `/aws/vendedlogs/states/`) with a single `arn:aws:states:::aws-sdk:ecs:updateService` task: `ForceNewDeployment = true` on this cluster and service, retried three times.
4. A state machine role limited to `ecs:UpdateService` on this service's ARN plus the CloudWatch Logs delivery actions Step Functions logging needs (these only support `*`).

The native `Secret Label Updated` event is published by Secrets Manager itself whenever a staging label moves, is on by default for every secret and **needs no CloudTrail trail**. AWS recommends it for detecting a changed secret value (including automatic rotation) in the Secrets Manager User Guide, *Match events when a secret value rotates*. The alternative CloudTrail-derived pattern (`detail-type = "AWS Service Event via CloudTrail"`, `eventName = RotationSucceeded`) is not used: it depends on CloudTrail management events and is not needed.

**Verification status: UNVERIFIED against a live account.** The event shape (source, detail-type, `detail.labelUpdated`, `resources` containing the secret ARN) is copied from the AWS documentation (*Secret event notifications* and *Secret Label Updated event*); the module's tests check the generated rule, state machine and policies, but this module has not been applied and no real rotation has been observed. Check the first rotation in your account in the state machine's execution history.

Notes: the event also fires when `AWSCURRENT` moves for any other reason (for example a manual `PutSecretValue`), which simply causes one extra rolling deployment. The `AWSCURRENT` label moves after the new password is set in the database, so the restarted tasks read the new value. A `valueFrom` without an explicit version suffix always resolves `AWSCURRENT` at task start.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.72 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 6.72 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_appautoscaling_policy.cpu](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy) | resource |
| [aws_appautoscaling_policy.memory](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy) | resource |
| [aws_appautoscaling_policy.requests](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy) | resource |
| [aws_appautoscaling_target.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_target) | resource |
| [aws_cloudwatch_event_rule.redeploy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.redeploy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_log_group.redeploy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_ecs_service.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service) | resource |
| [aws_ecs_task_definition.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition) | resource |
| [aws_iam_role.execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.redeploy_events](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.redeploy_sfn](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.task](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.redeploy_events](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.redeploy_sfn](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.task_efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.task_execute_command](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.task_storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_sfn_state_machine.redeploy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sfn_state_machine) | resource |
| [aws_vpc_security_group_egress_rule.https_cidr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.https_prefix_list](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.to_security_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.container_port](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_assign_public_ip"></a> [assign\_public\_ip](#input\_assign\_public\_ip) | Whether the tasks get a public IPv4 address. Keep false and place the tasks in private subnets; only enable it for Fargate tasks in public subnets without a NAT gateway. Must be false with capacity\_provider\_strategy: tasks on EC2 instances cannot get a public address. | `bool` | `false` | no |
| <a name="input_autoscaling"></a> [autoscaling](#input\_autoscaling) | Application Auto Scaling target tracking for the service desired count. When enabled, CPU tracking (cpu\_target\_percent) is always created; memory tracking when memory\_target\_percent is set; ALB request count per target when requests\_per\_target is set, which also requires alb\_resource\_label (app/<lb name>/<lb id>/targetgroup/<tg name>/<tg id>, the ALB arn\_suffix and target group arn\_suffix joined as <alb arn\_suffix>/<tg arn\_suffix>). Once enabled, autoscaling owns the task count and desired\_count is ignored after creation. | <pre>object({<br/>    enabled               = optional(bool, false)<br/>    min_capacity          = optional(number, 1)<br/>    max_capacity          = optional(number, 4)<br/>    cpu_target_percent    = optional(number, 60)<br/>    memory_target_percent = optional(number)<br/>    requests_per_target   = optional(number)<br/>    alb_resource_label    = optional(string)<br/>    scale_in_cooldown     = optional(number, 300)<br/>    scale_out_cooldown    = optional(number, 60)<br/>  })</pre> | `{}` | no |
| <a name="input_capacity_provider_strategy"></a> [capacity\_provider\_strategy](#input\_capacity\_provider\_strategy) | ECS capacity providers the service places its tasks with (EC2 container instances, for example from modules/ecs-ec2-capacity or the root module). Empty (the default) runs the tasks on Fargate. With a strategy the task definition is EC2-only: the same CPU/memory combinations apply, ephemeral\_storage\_gib is ignored, /tmp becomes a task-scoped Docker volume on the instance disk, and the network mode stays awsvpc. weight is the relative share of tasks (0 sends none beyond base), base the number of tasks that always run on the provider; only one provider may set a base. | <pre>list(object({<br/>    capacity_provider = string<br/>    weight            = optional(number, 1)<br/>    base              = optional(number, 0)<br/>  }))</pre> | `[]` | no |
| <a name="input_cluster_arn"></a> [cluster\_arn](#input\_cluster\_arn) | ARN of the ECS cluster the service runs in. | `string` | n/a | yes |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name of the ECS cluster the service runs in. Used for the Application Auto Scaling resource ID (service/<cluster\_name>/<service name>). | `string` | n/a | yes |
| <a name="input_container_health_check_start_period"></a> [container\_health\_check\_start\_period](#input\_container\_health\_check\_start\_period) | Seconds the container health check (openartifact -healthcheck, GET /health) is not counted as failed after the container starts, to cover database connection and migrations on startup (0-300). | `number` | `60` | no |
| <a name="input_container_port"></a> [container\_port](#input\_container\_port) | Port the OpenArtifact server listens on, injected as SERVER\_PORT and used for the container port mapping, the security group ingress rules and the load balancer registration. | `number` | `8080` | no |
| <a name="input_cpu"></a> [cpu](#input\_cpu) | Task CPU units: 256, 512, 1024, 2048, 4096, 8192 or 16384. Must form a valid Fargate combination with memory. | `number` | `1024` | no |
| <a name="input_cpu_architecture"></a> [cpu\_architecture](#input\_cpu\_architecture) | CPU architecture of the tasks: ARM64 (cheaper, the default) or X86\_64. The OpenArtifact image is published for both. With capacity\_provider\_strategy the container instances must have the same architecture. | `string` | `"ARM64"` | no |
| <a name="input_deployment_maximum_percent"></a> [deployment\_maximum\_percent](#input\_deployment\_maximum\_percent) | Upper limit, in percent of desired\_count, of tasks that may run during a deployment. | `number` | `200` | no |
| <a name="input_deployment_minimum_healthy_percent"></a> [deployment\_minimum\_healthy\_percent](#input\_deployment\_minimum\_healthy\_percent) | Lower limit, in percent of desired\_count, of tasks that must stay running and healthy during a deployment. | `number` | `100` | no |
| <a name="input_desired_count"></a> [desired\_count](#input\_desired\_count) | Initial number of tasks. Changes after creation are ignored (lifecycle ignore\_changes) so Application Auto Scaling and manual scaling are not reverted; scale with the autoscaling variable or `aws ecs update-service`. | `number` | n/a | yes |
| <a name="input_efs_volumes"></a> [efs\_volumes](#input\_efs\_volumes) | EFS access points to mount into the container, one entry per volume (for example the outputs of modules/efs). Each volume is mounted writable at container\_path, encrypted in transit and authorized with the task role, which is granted elasticfilesystem:ClientMount and ClientWrite on file\_system\_arn restricted to access\_point\_arn. Only the list length and the names must be known at plan time. Security groups, mount targets and the access point itself are the caller's concern. | <pre>list(object({<br/>    name             = string<br/>    container_path   = string<br/>    file_system_id   = string<br/>    file_system_arn  = string<br/>    access_point_id  = string<br/>    access_point_arn = string<br/>  }))</pre> | `[]` | no |
| <a name="input_egress_https_cidr_blocks"></a> [egress\_https\_cidr\_blocks](#input\_egress\_https\_cidr\_blocks) | IPv4 CIDR blocks the tasks may reach on TCP 443. The default 0.0.0.0/0 is needed because OpenArtifact proxy repositories fetch from arbitrary upstream registries, plus ghcr.io image pulls and the AWS APIs (S3, Secrets Manager, CloudWatch Logs, ECS). Narrow it only if you use VPC endpoints and an allow-listed set of upstreams; the S3 gateway endpoint is reached through egress\_https\_prefix\_list\_ids. | `list(string)` | <pre>[<br/>  "0.0.0.0/0"<br/>]</pre> | no |
| <a name="input_egress_https_prefix_list_ids"></a> [egress\_https\_prefix\_list\_ids](#input\_egress\_https\_prefix\_list\_ids) | IDs of the managed prefix lists the tasks may reach on TCP 443, for example the S3 gateway endpoint prefix list when egress\_https\_cidr\_blocks is narrowed. | `list(string)` | `[]` | no |
| <a name="input_egress_security_group_rules"></a> [egress\_security\_group\_rules](#input\_egress\_security\_group\_rules) | Additional egress rules towards other security groups, one per entry (for example the database security group on port 5432). | <pre>list(object({<br/>    security_group_id = string<br/>    port              = number<br/>    description       = string<br/>  }))</pre> | `[]` | no |
| <a name="input_enable_execute_command"></a> [enable\_execute\_command](#input\_enable\_execute\_command) | Enable ECS Exec (aws ecs execute-command) on the service. The image is shell-less, so the session has nothing to run; leave disabled unless you use a debug sidecar or image. Enabling adds the ssmmessages permissions to the task role. | `bool` | `false` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Plain environment variables for the container (map of name to value). OPENARTIFACT\_ROLE, SERVER\_PORT, SERVER\_SHUTDOWN\_DELAY and SERVER\_SHUTDOWN\_TIMEOUT are set by the module and override the same keys here. Static credentials (STORAGE\_ACCESS\_KEY, STORAGE\_SECRET\_KEY, AWS\_ACCESS\_KEY\_ID, AWS\_SECRET\_ACCESS\_KEY) are rejected: the task role provides S3 access. | `map(string)` | `{}` | no |
| <a name="input_ephemeral_storage_gib"></a> [ephemeral\_storage\_gib](#input\_ephemeral\_storage\_gib) | Size of the task ephemeral storage in GiB (21-200; Fargate includes 20 GiB); ignored with capacity\_provider\_strategy, where /tmp is a Docker volume on the container instance disk. The volume holds the writable /tmp where OpenArtifact spools uploads and downloads before they are sent to S3, so size it for the largest blob you expect to proxy or upload. | `number` | `21` | no |
| <a name="input_execution_kms_key_arns"></a> [execution\_kms\_key\_arns](#input\_execution\_kms\_key\_arns) | ARNs of the customer-managed KMS keys that encrypt the secrets in execution\_secret\_arns; the execution role is granted kms:Decrypt on them. Leave empty when the secrets use the aws/secretsmanager key. | `list(string)` | `[]` | no |
| <a name="input_execution_secret_arns"></a> [execution\_secret\_arns](#input\_execution\_secret\_arns) | ARNs of the Secrets Manager secrets the task execution role may read with secretsmanager:GetSecretValue (the secrets referenced in the secrets variable, without the json key suffix). When empty, no secret access is granted. | `list(string)` | `[]` | no |
| <a name="input_health_check_grace_period_seconds"></a> [health\_check\_grace\_period\_seconds](#input\_health\_check\_grace\_period\_seconds) | Seconds ECS ignores failing load balancer health checks after a task starts. Applied only when target\_group\_arn is set. | `number` | `60` | no |
| <a name="input_image"></a> [image](#input\_image) | Full container image reference including the tag or digest, for example ghcr.io/openartifact/openartifact:0.19.2 or ghcr.io/openartifact/openartifact@sha256:<64 hex>. A digest is passed through unchanged. The image must be multi-arch or match cpu\_architecture. | `string` | n/a | yes |
| <a name="input_ingress_security_group_ids"></a> [ingress\_security\_group\_ids](#input\_ingress\_security\_group\_ids) | IDs of the security groups allowed to reach container\_port on the tasks (normally the ALB security group). One ingress rule is created per entry. | `list(string)` | `[]` | no |
| <a name="input_log_kms_key_arn"></a> [log\_kms\_key\_arn](#input\_log\_kms\_key\_arn) | ARN of a customer-managed KMS key to encrypt the CloudWatch log groups, or null for the default CloudWatch Logs encryption. The key policy must allow the logs.<region>.amazonaws.com service principal (kms:Encrypt*, kms:Decrypt*, kms:ReEncrypt*, kms:GenerateDataKey*, kms:Describe*) with the encryption context aws:logs:arn matching the log group ARNs, otherwise log group creation fails. | `string` | `null` | no |
| <a name="input_log_retention_days"></a> [log\_retention\_days](#input\_log\_retention\_days) | Retention of the CloudWatch log group /ecs/<name> (and of the redeploy state machine log group) in days. Must be a value CloudWatch Logs accepts; never-expire (0) is deliberately not allowed. | `number` | `90` | no |
| <a name="input_memory"></a> [memory](#input\_memory) | Task memory in MiB. Must be a valid Fargate combination with cpu: 256 CPU 512/1024/2048; 512 CPU 1024-4096 step 1024; 1024 CPU 2048-8192 step 1024; 2048 CPU 4096-16384 step 1024; 4096 CPU 8192-30720 step 1024; 8192 CPU 16384-61440 step 4096; 16384 CPU 32768-122880 step 8192. | `number` | `2048` | no |
| <a name="input_name"></a> [name](#input\_name) | Name of the ECS service and task definition family, and the prefix of every resource created by this module (IAM roles, security group, log group). Must be 3-24 characters, lowercase letters, digits and hyphens. Must be unique per cluster; IAM roles use a name prefix so the same name may be reused in another region. | `string` | n/a | yes |
| <a name="input_redeploy_on_secret_rotation_arns"></a> [redeploy\_on\_secret\_rotation\_arns](#input\_redeploy\_on\_secret\_rotation\_arns) | ARNs of Secrets Manager secrets whose rotation must restart the tasks (the container reads its environment only at start), typically the RDS-managed master user secret. Non-empty creates an EventBridge rule on the native `Secret Label Updated` event (AWSCURRENT moved) that starts a small Step Functions state machine calling ecs:UpdateService with forceNewDeployment on this service. Only the list length must be known at plan time, the ARNs may be unknown. | `list(string)` | `[]` | no |
| <a name="input_role"></a> [role](#input\_role) | Process role of the OpenArtifact server, injected as OPENARTIFACT\_ROLE: "all" (HTTP API and background jobs), "web" (HTTP API only) or "worker" (background jobs only, no load balancer). | `string` | `"all"` | no |
| <a name="input_secrets"></a> [secrets](#input\_secrets) | Secret environment variables (map of environment variable name to the Secrets Manager valueFrom reference: a secret ARN, or "<secret ARN>:<json key>::" for one key of a JSON secret such as the RDS-managed master secret). The execution role must be allowed to read them: list the secret ARNs (without the json key suffix) in execution\_secret\_arns. Names must not also appear in environment. | `map(string)` | `{}` | no |
| <a name="input_shutdown_delay_seconds"></a> [shutdown\_delay\_seconds](#input\_shutdown\_delay\_seconds) | Seconds the server keeps serving after SIGTERM before it stops accepting connections (SERVER\_SHUTDOWN\_DELAY), so the load balancer deregisters the task first. | `number` | `15` | no |
| <a name="input_shutdown_timeout_seconds"></a> [shutdown\_timeout\_seconds](#input\_shutdown\_timeout\_seconds) | Seconds in-flight requests get to finish during shutdown (SERVER\_SHUTDOWN\_TIMEOUT). shutdown\_delay\_seconds + shutdown\_timeout\_seconds + 5 must not exceed 120, the Fargate stop timeout limit. | `number` | `60` | no |
| <a name="input_stop_timeout_seconds"></a> [stop\_timeout\_seconds](#input\_stop\_timeout\_seconds) | Container stopTimeout in seconds (2-120). Null computes min(120, shutdown\_delay\_seconds + shutdown\_timeout\_seconds + 5) so ECS sends SIGKILL only after the graceful shutdown completed. | `number` | `null` | no |
| <a name="input_subnet_ids"></a> [subnet\_ids](#input\_subnet\_ids) | IDs of the subnets the tasks run in (private subnets with a NAT gateway or the VPC endpoints for ECR/S3/Secrets Manager/CloudWatch Logs, unless assign\_public\_ip is set). | `list(string)` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource of the module that supports tags. | `map(string)` | `{}` | no |
| <a name="input_target_group_arn"></a> [target\_group\_arn](#input\_target\_group\_arn) | ARN of the ALB target group the service registers its tasks with. Null attaches no load balancer, which is required for role = worker. | `string` | `null` | no |
| <a name="input_task_role_policy_json"></a> [task\_role\_policy\_json](#input\_task\_role\_policy\_json) | IAM policy document (JSON) attached inline to the task role, normally the S3/KMS access policy from the storage module (access\_policy\_json). Required and non-empty so the plan does not depend on a value that is unknown until apply; the task role has no other permissions except the SSM channel actions added when enable\_execute\_command is true. | `string` | n/a | yes |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | ID of the VPC the task security group is created in. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_capacity_provider_strategy"></a> [capacity\_provider\_strategy](#output\_capacity\_provider\_strategy) | Capacity provider strategy of the service as ECS holds it, empty on Fargate. |
| <a name="output_container_definitions"></a> [container\_definitions](#output\_container\_definitions) | Rendered container definitions JSON of the task definition (read-only/user/health check/environment/secrets), exposed for tests and review. |
| <a name="output_execution_role_arn"></a> [execution\_role\_arn](#output\_execution\_role\_arn) | ARN of the task execution role used by the ECS agent (logs, secrets). |
| <a name="output_log_group_arn"></a> [log\_group\_arn](#output\_log\_group\_arn) | ARN of the CloudWatch log group of the container. |
| <a name="output_log_group_name"></a> [log\_group\_name](#output\_log\_group\_name) | Name of the CloudWatch log group of the container. |
| <a name="output_redeploy_state_machine_arn"></a> [redeploy\_state\_machine\_arn](#output\_redeploy\_state\_machine\_arn) | ARN of the Step Functions state machine that force-redeploys the service on secret rotation, or null when redeploy\_on\_secret\_rotation\_arns is empty. |
| <a name="output_security_group_id"></a> [security\_group\_id](#output\_security\_group\_id) | ID of the task security group, for example to allow it on the database security group. |
| <a name="output_service_arn"></a> [service\_arn](#output\_service\_arn) | ARN of the ECS service. |
| <a name="output_service_name"></a> [service\_name](#output\_service\_name) | Name of the ECS service. |
| <a name="output_task_definition_arn"></a> [task\_definition\_arn](#output\_task\_definition\_arn) | ARN of the task definition revision the service runs. |
| <a name="output_task_role_arn"></a> [task\_role\_arn](#output\_task\_role\_arn) | ARN of the task role assumed by the OpenArtifact process. |
<!-- END_TF_DOCS -->
