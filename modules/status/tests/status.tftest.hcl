mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-west-2", name = "us-west-2" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/test" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

mock_provider "archive" {}

variables {
  domain_name                  = "example.com"
  distribution_arn             = "arn:aws:cloudfront::123456789012:distribution/EXAMPLE"
  asg_name                     = "naju"
  episodes_log_group           = "/naju/episodes"
  spot_interruptions_log_group = "/naju/spot"
  metric_namespace             = "Naju"
  spot_enabled                 = true
  status_key                   = "0123456789"
  token_key                    = "naju-token"
}

run "key_lives_in_ssm_and_the_shell_reads_the_same_token_key" {
  command = plan

  assert {
    condition     = aws_ssm_parameter.status_key.type == "SecureString" && aws_ssm_parameter.status_key.name == "/naju/status-key"
    error_message = "The HMAC key must be a SecureString the plugin can name."
  }

  assert {
    condition     = length(output.origins) == 2 && length(output.behaviors) == 5
    error_message = "The core module must supply the shell and Lambda origins and five behaviors."
  }
}
