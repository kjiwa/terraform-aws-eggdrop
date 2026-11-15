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
  group_size       = 2
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

run "group_size_alarm_needs_every_bot_for_twenty_minutes" {
  command = plan

  assert {
    condition     = aws_cloudwatch_metric_alarm.group_size[0].namespace == "Eggdrop" && aws_cloudwatch_metric_alarm.group_size[0].metric_name == "GroupSize" && aws_cloudwatch_metric_alarm.group_size[0].statistic == "Minimum" && aws_cloudwatch_metric_alarm.group_size[0].comparison_operator == "LessThanThreshold" && aws_cloudwatch_metric_alarm.group_size[0].threshold == 2
    error_message = "The alarm must watch the minimum GroupSize and fire below group_size."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.group_size[0].period == 60 && aws_cloudwatch_metric_alarm.group_size[0].evaluation_periods == 20 && aws_cloudwatch_metric_alarm.group_size[0].datapoints_to_alarm == 20 && aws_cloudwatch_metric_alarm.group_size[0].treat_missing_data == "breaching"
    error_message = "The alarm needs 20 consecutive one-minute breaches, and silence breaches."
  }
}

run "group_size_threshold_follows_the_variable" {
  command = plan
  variables {
    group_size = 3
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.group_size[0].threshold == 3
    error_message = "The threshold must equal group_size."
  }
}

run "group_size_alarm_sleeps_with_the_environment" {
  command = plan
  variables {
    active = false
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.group_size) == 0
    error_message = "An inactive environment has no group size alarm."
  }
}
