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
  asg_name                     = "eggdrop"
  episodes_log_group           = "/eggdrop/episodes"
  spot_interruptions_log_group = "/eggdrop/spot"
  metric_namespace             = "Eggdrop"
  spot_enabled                 = true
  status_key                   = "0123456789"
  token_key                    = "eggdrop-token"
  bot_bucket                   = "eggdrop-bot-test"
  irc_log_group                = "/eggdrop/irc"
  irc_servers                  = [{ host = "a.example.net", port = 6697 }, { host = "b.example.net", port = 7000 }]
}

run "key_lives_in_ssm_and_the_shell_reads_the_same_token_key" {
  command = plan

  assert {
    condition     = aws_ssm_parameter.status_key.type == "SecureString" && aws_ssm_parameter.status_key.name == "/eggdrop/status-key"
    error_message = "The HMAC key must be a SecureString the plugin can name."
  }

  assert {
    condition     = length(output.origins) == 2 && length(output.behaviors) == 5
    error_message = "The core module must supply the shell and Lambda origins and five behaviors."
  }
}

run "plugin_reads_snapshots_and_events_and_nothing_wider" {
  command = plan

  assert {
    condition     = local.irc_server_addresses == ["a.example.net:+6697", "b.example.net:+7000"]
    error_message = "Servers must be spelled as the bot's serveraddress is: host:+port."
  }

  assert {
    condition = alltrue([
      for statement in local.plugin_policy.Statement :
      statement.Resource != "*" || statement.Action == "autoscaling:DescribeAutoScalingGroups"
    ])
    error_message = "Only DescribeAutoScalingGroups, which takes no resource, may use *."
  }

  assert {
    condition     = one([for statement in local.plugin_policy.Statement : statement.Resource if statement.Sid == "ReadBotSnapshots"]) == "arn:aws:s3:::eggdrop-bot-test/bots/*" && one([for statement in local.plugin_policy.Statement : statement.Resource if statement.Sid == "ReadServerEvents"]) == "arn:aws:logs:us-west-2:123456789012:log-group:/eggdrop/irc:*"
    error_message = "The plugin reads only bots/* in the bot bucket and the one log group."
  }
}
