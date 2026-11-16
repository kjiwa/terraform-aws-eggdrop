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
  domain_name       = "example.com"
  asg_name          = "eggdrop"
  alert_email       = "ops@example.com"
  metric_namespace  = "Eggdrop"
  group_size        = 2
  slot_gate_seconds = 1800
  active            = true
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

run "on_slot_alarm_waits_two_jump_gates_and_ignores_silence" {
  command = plan

  assert {
    condition     = aws_cloudwatch_metric_alarm.on_slot_server[0].namespace == "Eggdrop" && aws_cloudwatch_metric_alarm.on_slot_server[0].metric_name == "OnSlotServer" && aws_cloudwatch_metric_alarm.on_slot_server[0].statistic == "Minimum" && aws_cloudwatch_metric_alarm.on_slot_server[0].comparison_operator == "LessThanThreshold" && aws_cloudwatch_metric_alarm.on_slot_server[0].threshold == 1
    error_message = "The alarm must fire when the minimum OnSlotServer drops below 1."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.on_slot_server[0].period == 60 && aws_cloudwatch_metric_alarm.on_slot_server[0].evaluation_periods == 60 && aws_cloudwatch_metric_alarm.on_slot_server[0].datapoints_to_alarm == 60 && aws_cloudwatch_metric_alarm.on_slot_server[0].treat_missing_data == "notBreaching"
    error_message = "The alarm needs 60 consecutive one-minute breaches, and silence is not one."
  }
}

run "on_slot_alarm_is_off_while_inactive" {
  command = plan
  variables {
    active = false
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.on_slot_server) == 0
    error_message = "No alarm while the group is scaled to zero."
  }
}

run "on_slot_alarm_window_is_two_gates" {
  command = plan
  variables {
    slot_gate_seconds = 900
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.on_slot_server[0].evaluation_periods == 30 && aws_cloudwatch_metric_alarm.on_slot_server[0].datapoints_to_alarm == 30
    error_message = "The alarm must need two jump gates of one-minute breaches."
  }
}
