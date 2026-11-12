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
    defaults = { value = "ami-0123456789abcdef0" }
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
  irc_server  = { host = "irc.example.net" }
  channels    = ["#example"]
  ops         = { alice = ["*!*alice@2001:db8:1:2??:*"] }
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
    condition     = var.nick == "eggdrop" && var.irc_server.port == 6697 && var.spot_enabled && var.active
    error_message = "The nick, TLS port, Spot and active must default to eggdrop, 6697, true and true."
  }

  assert {
    condition     = output.asg_name == "eggdrop" && output.status_url == "https://example.com/status"
    error_message = "The outputs the operator reads must resolve at plan time."
  }
}

run "owner_must_be_an_op" {
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

run "channels_must_not_be_empty" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    channels = []
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
    ops = { alice = ["*!*alice@host} ; die {"] }
  }

  expect_failures = [var.ops]
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
    ops = { alice = ["*!*@*"] }
  }

  expect_failures = [var.ops]
}

run "nick_cannot_carry_tcl_substitution" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    nick = "bot[1]"
  }

  expect_failures = [var.nick]
}

run "channel_cannot_carry_tcl_substitution" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    channels = ["#a[b]"]
  }

  expect_failures = [var.channels]
}
