mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/test" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-west-2", name = "us-west-2" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-west-2a", "us-west-2b"] }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0", insecure_value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

mock_provider "aws" {
  alias = "us_east_1"
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/test" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
}

mock_provider "archive" {}

override_resource {
  target          = module.edge.aws_acm_certificate.this
  override_during = plan
  values = {
    arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    domain_validation_options = [
      { domain_name = "example.com", resource_record_name = "_a.example.com.", resource_record_type = "CNAME", resource_record_value = "a.acm.example." },
    ]
  }
}

variables {
  domain_name = "example.com"
  zone_id     = "Z0000000000000TEST"
  alert_email = "ops@example.com"
  irc_servers = [{ host = "irc.example.net" }]
  net_type    = "EFnet"
  channels    = { "#example" = { ops = ["alice"] } }
  users       = { alice = ["*!*alice@2001:db8:1:2??:*"] }
  owner       = "alice"
  eggdrop     = { version = "1.10.2", sha256 = "d6646b630879e1acd9b053ffa12f46667f907145f29af1df0f82749ef3032a94" }
}

run "defaults_plan_with_the_required_inputs" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition     = join(",", var.nicks) == "eggdrop" && var.irc_servers[0].port == 6697 && var.spot_enabled && var.active
    error_message = "The nick, TLS port, Spot and active must default to eggdrop, 6697, true and true."
  }

  assert {
    condition     = var.bots == 1
    error_message = "One bot by default."
  }

  assert {
    condition     = output.asg_name == "eggdrop" && output.status_url == "https://example.com/status"
    error_message = "The outputs the operator reads must resolve at plan time."
  }
}

run "unpinned_image_runs_the_updater" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition     = length(module.ami_updater) == 1
    error_message = "Without image_ids the AMI updater must exist."
  }
}

run "pinned_image_has_no_updater" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    image_ids = { arm64 = "ami-0aaaaaaaaaaaaaaaa", x86_64 = "ami-0bbbbbbbbbbbbbbbb" }
  }

  assert {
    condition     = length(module.ami_updater) == 0
    error_message = "With image_ids the AMI is pinned, so no updater may move it."
  }
}

run "owner_must_be_a_user" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    owner = "mallory"
  }

  expect_failures = [var.owner]
}

run "net_type_must_be_an_eggdrop_name" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    net_type = "Efnet2"
  }

  expect_failures = [var.net_type]
}

run "irc_servers_must_not_be_empty" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    irc_servers = []
  }

  expect_failures = [var.irc_servers]
}

run "irc_servers_must_be_unique" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    irc_servers = [{ host = "irc.example.net" }, { host = "irc.example.net", port = 6697 }]
  }

  expect_failures = [var.irc_servers]
}

run "irc_servers_reject_port_zero" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    irc_servers = [{ host = "irc.example.net", port = 0 }]
  }

  expect_failures = [var.irc_servers]
}

run "irc_servers_reject_port_above_65535" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    irc_servers = [{ host = "irc.example.net", port = 70000 }]
  }

  expect_failures = [var.irc_servers]
}

run "irc_servers_reject_empty_host" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    irc_servers = [{ host = "" }]
  }

  expect_failures = [var.irc_servers]
}

run "irc_servers_reject_hosts_differing_only_by_case" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    irc_servers = [{ host = "irc.example.net" }, { host = "IRC.Example.net" }]
  }

  expect_failures = [var.irc_servers]
}

run "irc_servers_are_at_most_fifty" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    irc_servers = [for i in range(51) : { host = "irc${i}.example.net" }]
  }

  expect_failures = [var.irc_servers]
}

run "channels_must_not_be_empty" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    channels = {}
  }

  expect_failures = [var.channels]
}

run "mask_cannot_carry_tcl_metacharacters" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    users = { alice = ["*!*alice@host} ; die {"] }
  }

  expect_failures = [var.users]
}

run "pin_must_name_both_architectures" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    image_ids = { x86_64 = "ami-0bbbbbbbbbbbbbbbb" }
  }

  expect_failures = [var.image_ids]
}

run "release_hash_must_be_hex" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    eggdrop = { version = "1.10.2", sha256 = "not-a-hash" }
  }

  expect_failures = [var.eggdrop]
}

run "mask_cannot_be_all_wildcards" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    users = { alice = ["*!*@*"] }
  }

  expect_failures = [var.users]
}

run "nick_cannot_carry_tcl_substitution" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    nicks = ["bot[1]"]
  }

  expect_failures = [var.nicks]
}

run "every_nick_needs_a_bot" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    nicks = ["naju", "zera"]
  }

  expect_failures = [var.bots]
}

run "channel_cannot_carry_tcl_substitution" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    channels = { "#a[b]" = {} }
  }

  expect_failures = [var.channels]
}

run "channel_ops_must_be_users" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    channels = { "#example" = { ops = ["mallory"] } }
  }

  expect_failures = [var.channels]
}

run "channel_ops_may_be_omitted" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    channels = { "#example" = {} }
  }

  assert {
    condition     = output.asg_name == "eggdrop"
    error_message = "A channel with no ops entry must plan: the bot holds the channel and ops nobody."
  }
}
