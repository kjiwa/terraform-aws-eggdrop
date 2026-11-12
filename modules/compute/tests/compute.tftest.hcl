mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-west-2", name = "us-west-2" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

# The bucket name is generated at apply; user_data embeds it.
override_resource {
  target          = aws_s3_bucket.this
  override_during = plan
  values = {
    id  = "naju-bot-test"
    arn = "arn:aws:s3:::naju-bot-test"
  }
}

variables {
  subnet_id        = "subnet-0123456789abcdef0"
  app_sg_id        = "sg-0123456789abcdef0"
  active           = true
  spot_enabled     = true
  nick             = "naju"
  irc_server       = { host = "irc.example.net", port = 6697 }
  channels         = ["#example", "#second"]
  ops              = { alice = ["*!*alice@2001:db8:1:2??:*", "*!*alice@host.example"], bob = ["*!*bob@host.example"] }
  owner            = "alice"
  eggdrop          = { version = "1.10.2", sha256 = "d6646b630879e1acd9b053ffa12f46667f907145f29af1df0f82749ef3032a94" }
  domain_name      = "example.com"
  metric_namespace = "Naju"
  status_key       = "0123456789"
}

run "instance_contract" {
  command = plan

  assert {
    condition     = one(aws_launch_template.this.metadata_options).http_tokens == "required"
    error_message = "IMDSv2 must be required."
  }

  assert {
    condition     = one(aws_launch_template.this.credit_specification).cpu_credits == "standard"
    error_message = "Burst credits must not go into surplus billing."
  }

  assert {
    condition     = length(aws_launch_template.this.block_device_mappings) == 1 && one(one(aws_launch_template.this.block_device_mappings).ebs).encrypted == "true"
    error_message = "The root volume is the only volume and it is encrypted: the bot is stateless."
  }

  assert {
    condition     = length(aws_launch_template.this.network_interfaces) == 0
    error_message = "No network interface block may request a public IPv4 address."
  }

  assert {
    condition     = toset([for override in one(aws_autoscaling_group.this.mixed_instances_policy).launch_template[0].override : override.instance_type]) == toset(["t3a.nano", "t3.nano"])
    error_message = "Only x86_64 nano types are allowed."
  }

  assert {
    condition     = one(one(aws_autoscaling_group.this.mixed_instances_policy).instances_distribution).on_demand_percentage_above_base_capacity == 0
    error_message = "spot_enabled must request Spot."
  }

  assert {
    condition     = aws_autoscaling_group.this.min_size == 1 && aws_autoscaling_group.this.max_size == 1
    error_message = "One instance when active."
  }
}

run "on_demand_when_spot_is_off" {
  command = plan
  variables {
    spot_enabled = false
  }

  assert {
    condition     = one(one(aws_autoscaling_group.this.mixed_instances_policy).instances_distribution).on_demand_percentage_above_base_capacity == 100
    error_message = "spot_enabled = false must request On-Demand."
  }
}

run "asleep_scales_to_zero" {
  command = plan
  variables {
    active = false
  }

  assert {
    condition     = aws_autoscaling_group.this.min_size == 0 && aws_autoscaling_group.this.max_size == 0 && aws_autoscaling_group.this.desired_capacity == 0
    error_message = "active = false must scale the ASG to zero."
  }
}

run "boot_script_pins_the_release" {
  command = plan

  assert {
    condition     = strcontains(base64decode(aws_launch_template.this.user_data), "d6646b630879e1acd9b053ffa12f46667f907145f29af1df0f82749ef3032a94") && strcontains(base64decode(aws_launch_template.this.user_data), "EGGDROP_VERSION=\"1.10.2\"")
    error_message = "user_data must carry the pinned version and hash."
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.this.user_data), local.config_hash)
    error_message = "user_data must carry the config hash so a config change replaces the instance."
  }
}

run "rendered_config" {
  command = plan

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "server add irc.example.net +6697") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set prefer-ipv6 1")
    error_message = "The server must be reached over TLS and IPv6."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/naju.tcl"].content, "{alice} +nafo {*!*alice@2001:db8:1:2??:* *!*alice@host.example}") && strcontains(aws_s3_object.config["config/naju.tcl"].content, "{bob} +afo {*!*bob@host.example}")
    error_message = "Only the owner gets +n; every op is auto-opped with the masks given."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/naju.tcl"].content, "channel add #example") && strcontains(aws_s3_object.config["config/naju.tcl"].content, "channel add #second")
    error_message = "Every channel must be added."
  }
}

run "bot_bucket_is_private" {
  command = plan

  assert {
    condition     = aws_s3_bucket_public_access_block.this.block_public_acls && aws_s3_bucket_public_access_block.this.block_public_policy && aws_s3_bucket_public_access_block.this.ignore_public_acls && aws_s3_bucket_public_access_block.this.restrict_public_buckets
    error_message = "The bot bucket must block all public access."
  }

  assert {
    condition     = aws_s3_object.status_key.key == "secret/status.key" && aws_s3_object.status_key.server_side_encryption == "AES256"
    error_message = "The status key must be stored encrypted."
  }
}
