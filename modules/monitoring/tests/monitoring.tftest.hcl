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
  domain_name      = "example.com"
  asg_name         = "eggdrop"
  alert_email      = "ops@example.com"
  metric_namespace = "Eggdrop"
  active           = true
}

# The absence of the canary rule is asserted where the resource lives: the
# status-page repo's availability test heartbeat_drops_canary.
run "plans_with_the_heartbeat_wiring" {
  command = plan

  assert {
    condition     = output.episodes_log_group_name != null && output.spot_interruptions_log_group_name != null
    error_message = "The status module needs both log groups."
  }
}
