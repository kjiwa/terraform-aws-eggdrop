data "aws_region" "current" {}
data "aws_caller_identity" "default" {}

resource "aws_ssm_parameter" "status_key" {
  name  = "/naju/status-key"
  type  = "SecureString"
  value = var.status_key
}

locals {
  auth_header = "X-Naju-Token"

  # Built from known parts, not aws_ssm_parameter.status_key.arn: the core
  # module counts on whether this policy is set, and a count cannot depend on
  # an attribute that is unknown until apply.
  status_key_arn = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.default.account_id}:parameter${aws_ssm_parameter.status_key.name}"
}

module "core" {
  source = "git::https://github.com/kjiwa/terraform-aws-status-page.git//modules/status?ref=v0.4.0"

  name_prefix      = "naju"
  bucket_name      = "${replace(var.domain_name, ".", "-")}-status"
  auth_header      = local.auth_header
  distribution_arn = var.distribution_arn
  asg_name         = var.asg_name

  episodes_log_group           = var.episodes_log_group
  spot_interruptions_log_group = var.spot_interruptions_log_group
  siteup_metric_namespace      = var.metric_namespace

  spot_enabled = var.spot_enabled

  # A new account's concurrency quota can be too low to reserve any.
  reserved_concurrency = -1

  plugin_dir         = "${path.module}/plugin"
  plugin_environment = { STATUS_KEY_PARAMETER = aws_ssm_parameter.status_key.name }
  plugin_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadStatusKey"
      Effect   = "Allow"
      Action   = "ssm:GetParameter"
      Resource = local.status_key_arn
    }]
  })

  config_js = templatefile("${path.module}/config.js.tpl", {
    auth_header = local.auth_header
    token_key   = var.token_key
  })
}
