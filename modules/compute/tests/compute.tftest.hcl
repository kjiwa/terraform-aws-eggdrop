mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-west-2", name = "us-west-2" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0", insecure_value = "ami-0123456789abcdef0" }
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
    id  = "eggdrop-bot-test"
    arn = "arn:aws:s3:::eggdrop-bot-test"
  }
}

override_resource {
  target          = aws_cloudwatch_log_group.irc
  override_during = plan
  values          = { arn = "arn:aws:logs:us-west-2:123456789012:log-group:/eggdrop/irc" }
}

override_resource {
  target          = aws_launch_template.this["x86_64"]
  override_during = plan
  values          = { id = "lt-0123456789abcdef0", latest_version = 1 }
}

override_resource {
  target          = aws_launch_template.this["arm64"]
  override_during = plan
  values          = { id = "lt-0123456789abcdef1", latest_version = 1 }
}

variables {
  subnet_ids              = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  app_sg_id               = "sg-0123456789abcdef0"
  active                  = true
  spot_enabled            = true
  nicks                   = ["naju", "zera"]
  ident                   = false
  bots                    = 2
  subnet_ipv6_cidr_blocks = ["2001:db8:1:0::/64", "2001:db8:1:1::/64"]
  irc_servers             = [{ host = "irc.example.net", port = 6697 }]
  net_type                = "IRCnet"
  channels                = { "#example" = { ops = ["alice", "bob"] }, "#second" = { ops = ["bob"] } }
  users                   = { alice = ["*!*alice@2001:db8:1:2??:*", "*!*alice@host.example"], bob = ["*!*bob@host.example"] }
  owner                   = "alice"
  eggdrop                 = { version = "1.10.2", sha256 = "d6646b630879e1acd9b053ffa12f46667f907145f29af1df0f82749ef3032a94" }
  domain_name             = "example.com"
  metric_namespace        = "Eggdrop"
  status_key              = "0123456789"
}

run "instance_contract" {
  command = plan

  assert {
    condition     = one(aws_launch_template.this["x86_64"].metadata_options).http_tokens == "required"
    error_message = "IMDSv2 must be required."
  }

  assert {
    condition     = one(aws_launch_template.this["x86_64"].credit_specification).cpu_credits == "standard"
    error_message = "Burst credits must not go into surplus billing."
  }

  assert {
    condition     = length(aws_launch_template.this["x86_64"].block_device_mappings) == 1 && one(one(aws_launch_template.this["x86_64"].block_device_mappings).ebs).encrypted == "true"
    error_message = "The root volume is the only volume and it is encrypted: the bot is stateless."
  }

  assert {
    condition     = length(aws_launch_template.this["x86_64"].network_interfaces) == 0
    error_message = "No network interface block may request a public IPv4 address."
  }

  assert {
    condition     = toset([for override in one(aws_autoscaling_group.this.mixed_instances_policy).launch_template[0].override : override.instance_type]) == toset(["t3a.nano", "t3.nano", "t3a.micro", "t3.micro", "t4g.nano", "t4g.micro"])
    error_message = "Only burstable nano and micro types are allowed."
  }

  assert {
    condition     = length(aws_autoscaling_group.this.vpc_zone_identifier) == 2
    error_message = "The ASG must span every subnet it is given."
  }

  assert {
    condition     = one(one(aws_autoscaling_group.this.mixed_instances_policy).instances_distribution).on_demand_percentage_above_base_capacity == 0
    error_message = "spot_enabled must request Spot."
  }

  assert {
    condition     = aws_autoscaling_group.this.min_size == 2 && aws_autoscaling_group.this.desired_capacity == 2 && aws_autoscaling_group.this.max_size == 3
    error_message = "bots instances when active, with one extra allowed for a rebalance or a refresh."
  }

  assert {
    condition     = aws_autoscaling_group.this.capacity_rebalance
    error_message = "A rebalance must start a replacement before the old bot goes."
  }

  assert {
    condition     = one(one(aws_autoscaling_group.this.instance_refresh).preferences).min_healthy_percentage == 100 && one(one(aws_autoscaling_group.this.instance_refresh).preferences).max_healthy_percentage == 150 && one(one(aws_autoscaling_group.this.instance_refresh).preferences).skip_matching
    error_message = "A refresh adds one bot at a time and never drops below the group size."
  }

  assert {
    condition     = aws_autoscaling_lifecycle_hook.launching.lifecycle_transition == "autoscaling:EC2_INSTANCE_LAUNCHING" && aws_autoscaling_lifecycle_hook.launching.default_result == "ABANDON" && aws_autoscaling_lifecycle_hook.launching.name == local.lifecycle_hook_name
    error_message = "A launch waits for the bot to be ready, and an expired wait abandons the instance."
  }
}

run "refresh_headroom_follows_group_size" {
  command = plan
  variables {
    nicks = ["naju"]
    bots  = 1
  }

  assert {
    condition     = one(one(aws_autoscaling_group.this.instance_refresh).preferences).max_healthy_percentage == 200 && aws_autoscaling_group.this.max_size == 2
    error_message = "A single bot is replaced by starting the new one first."
  }
}

run "every_type_launches_its_own_architecture" {
  command = plan

  assert {
    condition = alltrue([
      for override in one(aws_autoscaling_group.this.mixed_instances_policy).launch_template[0].override :
      one(override.launch_template_specification).launch_template_id == aws_launch_template.this[local.type_architectures[override.instance_type]].id
    ])
    error_message = "Graviton types must launch the arm64 template and every other type the x86_64 one."
  }

  assert {
    condition     = data.aws_ssm_parameter.al2023["arm64"].name == "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64" && data.aws_ssm_parameter.al2023["x86_64"].name == "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
    error_message = "Each architecture resolves its own AL2023 image."
  }

  assert {
    condition     = aws_launch_template.this["arm64"].user_data == aws_launch_template.this["x86_64"].user_data
    error_message = "Both templates must boot the same config."
  }
}

run "unpinned_image_tracks_the_latest" {
  command = plan

  assert {
    condition     = aws_launch_template.this["x86_64"].image_id == "ami-0123456789abcdef0" && aws_launch_template.this["arm64"].image_id == "ami-0123456789abcdef0"
    error_message = "Without image_ids both templates use the SSM image."
  }
}

run "pinned_image_reaches_both_templates" {
  command = plan
  variables {
    image_ids = { arm64 = "ami-0aaaaaaaaaaaaaaaa", x86_64 = "ami-0bbbbbbbbbbbbbbbb" }
  }

  assert {
    condition     = aws_launch_template.this["arm64"].image_id == "ami-0aaaaaaaaaaaaaaaa" && aws_launch_template.this["x86_64"].image_id == "ami-0bbbbbbbbbbbbbbbb"
    error_message = "Each template must launch its pinned image."
  }
}

run "pinned_image_reads_no_ssm_parameter" {
  command = plan
  variables {
    image_ids = { arm64 = "ami-0aaaaaaaaaaaaaaaa", x86_64 = "ami-0bbbbbbbbbbbbbbbb" }
  }

  assert {
    condition     = length(data.aws_ssm_parameter.al2023) == 0
    error_message = "A pin must not read the SSM parameters."
  }
}

run "changing_the_pin_replaces_the_templates" {
  command = plan
  variables {
    image_ids = { arm64 = "ami-0aaaaaaaaaaaaaaaa", x86_64 = "ami-0bbbbbbbbbbbbbbbb" }
  }

  assert {
    condition     = terraform_data.image_pin.input == tomap({ arm64 = "ami-0aaaaaaaaaaaaaaaa", x86_64 = "ami-0bbbbbbbbbbbbbbbb" })
    error_message = "image_pin must carry image_ids: replace_triggered_by replaces the templates when it changes, since image_id itself is ignored."
  }
}

run "templates_are_exported_for_the_updater" {
  command = plan

  assert {
    condition     = output.launch_template_ids["arm64"] == "lt-0123456789abcdef1" && output.launch_template_ids["x86_64"] == "lt-0123456789abcdef0"
    error_message = "launch_template_ids must map each architecture to its template."
  }
}

run "pin_must_name_both_architectures" {
  command = plan
  variables {
    image_ids = { arm64 = "ami-0aaaaaaaaaaaaaaaa" }
  }

  expect_failures = [var.image_ids]
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
    condition     = strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "d6646b630879e1acd9b053ffa12f46667f907145f29af1df0f82749ef3032a94") && strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "EGGDROP_VERSION=\"1.10.2\"")
    error_message = "user_data must carry the pinned version and hash."
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), local.config_hash)
    error_message = "user_data must carry the config hash so a config change replaces the instance."
  }
}

run "roster_changes_do_not_replace_the_instance" {
  command = plan
  variables {
    channels = { "#other" = { ops = ["carol"] } }
    users    = { carol = ["*!*carol@host.example"] }
    owner    = "carol"
  }

  assert {
    condition     = !contains(keys(local.boot_files), "config/eggdrop.tcl")
    error_message = "The roster file must not be a boot file: user_data would hash it."
  }

  assert {
    condition     = local.config_hash == sha256(join("", concat([for key in sort(keys(local.boot_files)) : local.boot_files[key]], [var.status_key])))
    error_message = "config_hash covers the boot files and the status key only."
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), local.config_hash) && contains(keys(aws_s3_object.config), "config/eggdrop.tcl")
    error_message = "The roster file is still uploaded, but outside user_data."
  }
}

run "rendered_config" {
  command = plan

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set eggdrop_servers { {irc.example.net +6697} }") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set prefer-ipv6 1")
    error_message = "The server must be reached over TLS, preferring IPv6."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "{alice} {*!*alice@2001:db8:1:2??:* *!*alice@host.example}") && strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "{bob} {*!*bob@host.example}")
    error_message = "Every user is added with the masks given."
  }

  assert {
    condition = alltrue([
      for grant in ["{alice} {#example}", "{bob} {#example}", "{bob} {#second}"] :
      strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, grant)
    ]) && !strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "{alice} {#second}")
    error_message = "A user is opped only in the channels that list them."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "chattr $handle |+fao $channel") && !can(regex("chattr[^\\n]*\\+[a-z]*n", aws_s3_object.config["config/eggdrop.tcl"].content))
    error_message = "Ops are channel flags, and no user holds +n."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "set eggdrop_owner \"alice\"") && strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "bind msg - status")
    error_message = "The status command is gated by the owner's handle."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "channel add #example") && strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "channel add #second")
    error_message = "Every channel must be added."
  }
}

run "ident_is_off_by_default" {
  command = plan

  assert {
    condition     = !strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "loadmodule ident") && strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "CapabilityBoundingSet=\n") && !strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "AmbientCapabilities")
    error_message = "Without ident the config has no ident module and the unit holds no capability."
  }
}

run "ident_loads_the_builtin_server_and_may_bind_113" {
  command = plan
  variables {
    ident = true
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "loadmodule ident\nset ident-method 1\nset ident-port 113")
    error_message = "ident loads the module in built-in server mode on port 113."
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "CapabilityBoundingSet=CAP_NET_BIND_SERVICE\nAmbientCapabilities=CAP_NET_BIND_SERVICE\n")
    error_message = "The unit may bind port 113 as the bot's user and holds nothing else."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set username $nick")
    error_message = "The ident answer is the username, which follows the claimed nick."
  }
}

run "peers_op_each_other" {
  command = plan

  assert {
    condition = alltrue([
      for mask in ["*!*@2001:db8:1:0:*", "*!*@2001:db8:1:1:*"] :
      strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, mask)
    ])
    error_message = "Every subnet's address range is a peer mask."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "chattr peers |+fao $channel")
    error_message = "Peers are opped in every channel."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "proc eggdrop_op_members") && strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "bind evnt - userfile-loaded eggdrop_schedule_op_members")
    error_message = "A roster reload must op members who now match."
  }
}

run "bots_claim_the_listed_nicks" {
  command = plan

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set nick \"naju\"") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set eggdrop_nicks { naju zera }")
    error_message = "Every bot boots as the first nick and knows the whole list."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set nick $botnick")
    error_message = "A rehash must keep the nick the bot has claimed."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "onchan $name $channel") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "eggdrop_ready_failures >= 5")
    error_message = "A bot claims only a name no one wears, and gives up releasing a launch hook that never completes."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "eggdrop-ready ${local.name} ${local.lifecycle_hook_name}")
    error_message = "The bot must release its own launch hook."
  }
}

run "site_up_means_connected" {
  command = plan

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "[set ::server-online]") && strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "if {![eggdrop_up]} {\n    return\n  }") && !strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "--value 0")
    error_message = "A connected bot publishes SiteUp 1 and a disconnected one publishes nothing, so the metric follows the group, not one bot's ops."
  }
}

run "servers_are_listed_in_order" {
  command = plan
  variables {
    irc_servers = [{ host = "a.example.net", port = 6697 }, { host = "b.example.net", port = 7000 }, { host = "c.example.net", port = 6697 }]
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set eggdrop_servers { {a.example.net +6697} {b.example.net +7000} {c.example.net +6697} }") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "server add [lindex $eggdrop_server 0] [lindex $eggdrop_server 1]")
    error_message = "Every server is added, starting at the slot server and keeping the listed order after it; scripts/tests/test_conf.tcl runs the rotation."
  }
}

run "servers_are_taken_by_nick_slot" {
  command = plan
  variables {
    irc_servers = [{ host = "a.example.net", port = 6697 }, { host = "b.example.net", port = 7000 }]
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set eggdrop_servers { {a.example.net +6697} {b.example.net +7000} }")
    error_message = "eggdrop_servers lists the servers in the order given."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "proc eggdrop_take_server") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "[eggdrop_on_slot_server]") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "bind time - \"* * * * *\" eggdrop_take_server") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "[scan $minute %d] % [llength $eggdrop_nicks] != [eggdrop_slot]") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "[llength [channels]] == 0") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "[unixtime] - $eggdrop_moved_at < 1800") && !strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "eggdrop_moved_for")
    error_message = "The slot proc runs each minute, staggers by slot, gates on time and channels, and skips a bot already on its slot server."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "string equal -nocase $::serveraddress \"$host:$port\"") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "proc eggdrop_slot_server")
    error_message = "One proc finds the slot server, and the comparison with serveraddress ignores case."
  }
}

run "one_server_has_no_slot_jump" {
  command = plan

  assert {
    condition     = !strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "eggdrop_take_server") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "proc eggdrop_on_slot_server")
    error_message = "With one server there is nowhere to move, so the jump proc is not rendered; the heartbeat's slot check still resolves."
  }
}

run "bots_connect_as_their_claimed_nick" {
  command = plan

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set net-type \"IRCnet\"") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set username $nick") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set realname $nick")
    error_message = "The network type comes from net_type, and the ident and realname follow the nick."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set ::username $name")
    error_message = "A claimed nick must also set the ident and realname."
  }

  assert {
    condition     = !strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "EFnet") && !strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set admin") && !strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set network")
    error_message = "The config must name no network and set no admin."
  }
}

run "net_type_must_be_an_eggdrop_name" {
  command = plan
  variables {
    net_type = "Efnet2"
  }

  expect_failures = [var.net_type]
}

run "empty_server_list_is_rejected" {
  command = plan
  variables {
    irc_servers = []
  }

  expect_failures = [var.irc_servers]
}

run "duplicate_server_is_rejected" {
  command = plan
  variables {
    irc_servers = [{ host = "a.example.net", port = 6697 }, { host = "a.example.net", port = 6697 }]
  }

  expect_failures = [var.irc_servers]
}

run "irc_servers_reject_port_zero" {
  command = plan
  variables {
    irc_servers = [{ host = "irc.example.net", port = 0 }]
  }

  expect_failures = [var.irc_servers]
}

run "irc_servers_reject_port_above_65535" {
  command = plan
  variables {
    irc_servers = [{ host = "irc.example.net", port = 70000 }]
  }

  expect_failures = [var.irc_servers]
}

run "irc_servers_reject_empty_host" {
  command = plan
  variables {
    irc_servers = [{ host = "", port = 6697 }]
  }

  expect_failures = [var.irc_servers]
}

run "irc_servers_reject_hosts_differing_only_by_case" {
  command = plan
  variables {
    irc_servers = [{ host = "irc.example.net", port = 6697 }, { host = "IRC.Example.net", port = 6697 }]
  }

  expect_failures = [var.irc_servers]
}

run "heartbeat_sends_group_size_with_site_up" {
  command = plan

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "MetricName=SiteUp,Value=1 MetricName=GroupSize,Value=$size") && strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "[onchan $nick $channel]") && strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "foreach nick $eggdrop_nicks")
    error_message = "The heartbeat must send SiteUp and GroupSize in one call, counting the listed nicks on the bot's channels."
  }
}

run "heartbeat_reports_the_slot_server" {
  command = plan

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "MetricName=OnSlotServer,Value=$on_slot") && strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "set on_slot [eggdrop_on_slot_server]")
    error_message = "The heartbeat must publish OnSlotServer from the same lookup the jump uses."
  }
}

run "server_events_go_to_the_log_group" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.irc.name == "/eggdrop/irc" && aws_cloudwatch_log_group.irc.retention_in_days == 30
    error_message = "Server events go to /eggdrop/irc, kept 30 days."
  }

  assert {
    condition = alltrue([
      for bind in [
        "bind evnt - init-server eggdrop_event_accepted",
        "bind evnt - disconnect-server eggdrop_event_disconnected",
        "bind log - {* Trying server *} eggdrop_log_trying",
        "bind log - {* Failed connect to *} eggdrop_log_failed",
        "bind log - {* Timeout: connect *} eggdrop_log_failed",
        "bind log - {* Disconnected from *} eggdrop_log_dropped",
        "bind raw - ERROR* eggdrop_raw_refused",
        "bind raw - 463 eggdrop_raw_refused",
        "bind raw - 465 eggdrop_raw_refused",
      ] : strcontains(aws_s3_object.config["config/eggdrop.conf"].content, bind)
    ])
    error_message = "Every server event and refusal numeric must be bound."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set eggdrop_log_group \"/eggdrop/irc\"") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "--log-stream-name $instance_id") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "> /dev/null 2> /dev/null &")
    error_message = "Each event goes to the instance's stream, in the background."
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "aws logs create-log-stream") && strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "Environment=EGGDROP_INSTANCE_ID=$INSTANCE_ID") && strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "readonly LOG_GROUP=\"/eggdrop/irc\"")
    error_message = "Boot creates the instance's log stream and hands its name to the bot."
  }

  assert {
    condition     = !strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "bind pub") && !strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "bind pubm") && !strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "bind msgm")
    error_message = "No channel or private text may be bound for the log."
  }
}

run "snapshot_compares_stable_fields_and_sends_the_full_body" {
  command = plan

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "set stable [eggdrop_snapshot_body 0]") && strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "$stable eq $eggdrop_snapshot_last") && strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "set eggdrop_snapshot_last $stable")
    error_message = "The change check must compare the form without member counts."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "set json \"\\{[eggdrop_snapshot_body 1],") && strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "if {$with_members} {")
    error_message = "The body sent must carry member counts, and only the full form may."
  }
}

run "boot_survives_a_missing_instance_id" {
  command = plan

  assert {
    condition     = strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "INSTANCE_ID=\"$(retry fetch_instance_id)\" || INSTANCE_ID=\"\"") && strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "if [ -z \"$INSTANCE_ID\" ]; then")
    error_message = "An IMDS failure must leave the instance id empty and skip the log stream, not abort boot."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "proc eggdrop_instance_id") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "if {$instance_id eq \"\"} {") && strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "if {$instance_id eq \"\" ||")
    error_message = "The server event log and the snapshot must skip when the instance id is empty."
  }
}

run "targetless_server_events_carry_a_placeholder" {
  command = plan

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "if {$target eq \"\"} {\n    set target -\n  }")
    error_message = "An event without a target must log \"-\" so the line keeps its fields."
  }
}

run "slot_gate_is_rendered_and_exported" {
  command = plan
  variables {
    irc_servers = [{ host = "a.example.net", port = 6697 }, { host = "b.example.net", port = 7000 }]
  }

  assert {
    condition     = output.slot_gate_seconds == 1800 && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "$eggdrop_moved_at < ${output.slot_gate_seconds}")
    error_message = "The jump gate rendered into the conf must be the value the alarm window derives from."
  }
}

run "bot_snapshot_goes_to_the_bots_prefix" {
  command = plan

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "bots/$instance_id.json") && strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "$now - $eggdrop_snapshot_at < 900") && strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "> /dev/null 2> /dev/null &")
    error_message = "The snapshot goes to bots/<instance-id>.json, when it changes and every 900 s, in the background."
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "Environment=EGGDROP_BUCKET=$BUCKET")
    error_message = "The bot must learn the bucket name at boot."
  }

  assert {
    condition = anytrue([
      for statement in data.aws_iam_policy_document.instance.statement :
      statement.sid == "WriteBotSnapshot" && one(statement.actions) == "s3:PutObject" && one(statement.resources) == "${aws_s3_bucket.this.arn}/bots/*"
    ])
    error_message = "A bot may write only under bots/."
  }

  assert {
    condition = anytrue([
      for statement in data.aws_iam_policy_document.instance.statement :
      statement.sid == "WriteServerEvents" && toset(statement.actions) == toset(["logs:CreateLogStream", "logs:PutLogEvents"]) && one(statement.resources) == "${aws_cloudwatch_log_group.irc.arn}:*"
    ])
    error_message = "A bot may create a stream and put events in its log group only."
  }
}

run "compressed_prefix_is_rejected" {
  command = plan
  variables {
    subnet_ipv6_cidr_blocks = ["2001:db8:1::/64", "2001:db8:1:1::/64"]
  }

  expect_failures = [var.subnet_ipv6_cidr_blocks]
}

run "fewer_bots_than_nicks_is_rejected" {
  command = plan
  variables {
    bots = 1
  }

  expect_failures = [var.bots]
}

run "duplicate_nick_is_rejected" {
  command = plan
  variables {
    nicks = ["naju", "naju"]
  }

  expect_failures = [var.nicks]
}

run "peers_cannot_be_a_nick" {
  command = plan
  variables {
    nicks = ["peers", "zera"]
  }

  expect_failures = [var.nicks]
}

run "peers_cannot_be_a_user" {
  command = plan
  variables {
    users = { peers = ["*!*x@host.example"] }
  }

  expect_failures = [var.users]
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

run "server_probe_is_installed_and_bound" {
  command = plan

  assert {
    condition     = contains(keys(local.boot_files), "config/eggdrop-probe") && strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "config/eggdrop-probe\" \"$HOME_DIR/eggdrop-probe\"")
    error_message = "The probe is a boot file, fetched next to the token minter."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "bind time - \"* * * * *\" eggdrop_probe_servers") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "python3 /opt/eggdrop/eggdrop-probe $eggdrop_probe_file {*}$entries")
    error_message = "A minute bind runs the probe."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "> /dev/null 2> /dev/null &") && !strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "JOIN")
    error_message = "The probe runs in the background, so PING replies are not blocked, and joins nothing."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "$now - [set ::server-online] < 600") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "[file mtime $eggdrop_probe_file] < 86400") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "[scan $minute %d] % [llength $eggdrop_nicks] != [eggdrop_slot]")
    error_message = "A probe starts 10 min after the welcome, on the bot's slot minute, when the last is a day old."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set server-timeout 20")
    error_message = "A dead server entry must cost 20 s, not Eggdrop's default 60."
  }
}

run "bots_set_the_deaf_mode_the_server_advertises" {
  command = plan

  assert {
    condition = alltrue([
      for bind in [
        "bind isupport - DEAF eggdrop_isupport_deaf",
        "bind raw - 221 eggdrop_raw_umode",
      ] : strcontains(aws_s3_object.config["config/eggdrop.conf"].content, bind)
    ])
    error_message = "The deaf letter comes from the DEAF token, and the user modes are read back from 221."
  }

  assert {
    condition     = !strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "+D")
    error_message = "The deaf letter is never guessed: on other ircds D means something else."
  }

  assert {
    condition     = !strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "eggdrop_server_event umode") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "eggdrop_cancel_umode_query") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set eggdrop_deaf $value")
    error_message = "The umode is stored without an event line, one query timer is pending at most, and the snapshot's deaf letter is the cached one."
  }
}

run "the_console_never_prints_channel_text" {
  command = plan

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set console \"jkcobxs\"")
    error_message = "The console mask must keep joins, modes, misc and server notices and drop p (channel text) and m (private text)."
  }

  assert {
    condition     = !strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "set console \"mkcoblxs\"") && !can(regex("set console \"[^\"]*[pm]", aws_s3_object.config["config/eggdrop.conf"].content))
    error_message = "The console mask must not carry p or m."
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "exec $HOME_DIR/eggdrop -t eggdrop.conf 0<>eggdrop.stdin") && strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "mkfifo -m 0600 eggdrop.stdin") && !strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "eggdrop -n eggdrop.conf")
    error_message = "Only the -t terminal console filters stdout by the console mask (-n prints every log line), and -t needs a stdin that never ends."
  }
}

run "roster_script_stubs_what_an_older_conf_lacks" {
  command = plan

  assert {
    condition     = alltrue([for symbol in ["eggdrop_on_slot_server", "eggdrop_instance_id", "eggdrop_json_string", "eggdrop_probes_json"] : strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "  ${symbol} {return")]) && strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "if {![info exists eggdrop_nicks]}") && strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "foreach eggdrop_name {eggdrop_umode eggdrop_deaf}")
    error_message = "The roster script runs on bots whose conf is a release older, so each conf symbol it uses needs a stub."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "![info exists ::env(EGGDROP_BUCKET)]")
    error_message = "A bot launched before the bucket was in its environment writes no snapshot."
  }
}

run "bot_takes_its_slot_before_it_connects" {
  command = plan

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop-slot"].content, "eggdrop_boot_%s") && strcontains(aws_s3_object.config["config/eggdrop-slot"].content, ".slot") && strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "ExecStartPre=-/usr/bin/timeout 60 /usr/local/bin/eggdrop-slot $ASG_NAME $HOME_DIR/slot.tcl $NICKS") && strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "readonly ASG_NAME=\"${local.name}\"") && strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "readonly NICKS=\"naju zera\"")
    error_message = "The unit runs eggdrop-slot before every start, with the group name, the slot file and the nicks, and a failed run must not stop the bot."
  }

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "slot.tcl") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "eggdrop_boot_slot")
    error_message = "The config reads the slot file before it sets the nick and the servers."
  }

  assert {
    condition = anytrue([
      for statement in data.aws_iam_policy_document.instance.statement :
      statement.sid == "ReadBotBucket" && contains(statement.resources, "${aws_s3_bucket.this.arn}/bots/*")
    ])
    error_message = "A booting bot reads its peers' snapshots."
  }

  assert {
    condition = anytrue([
      for statement in data.aws_iam_policy_document.instance.statement :
      statement.sid == "ListGroupInstances" && one(statement.actions) == "autoscaling:DescribeAutoScalingGroups" && one(statement.resources) == "*"
    ])
    error_message = "A booting bot lists the group's instances."
  }
}

run "boot_is_short" {
  command = plan

  assert {
    condition     = strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "fallocate -l 1G /swapfile") && strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "make -j2")
    error_message = "Swap is preallocated and the compile uses both cores."
  }

  assert {
    condition     = length(split("systemctl enable --now eggdrop.service", base64decode(aws_launch_template.this["x86_64"].user_data))[0]) < length(split("\n  enable_security_updates\n", base64decode(aws_launch_template.this["x86_64"].user_data))[0])
    error_message = "Unattended updates are installed after the bot starts."
  }

  assert {
    condition     = local.refresh_preferences.instance_warmup == 30
    error_message = "The launch hook already waits for the bot, so the warmup after it is 30 s."
  }
}

run "boot_script_globals_are_readonly" {
  command = plan

  assert {
    condition     = strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), "readonly INSTANCE_ID")
    error_message = "The instance id is fixed once read."
  }
}

run "unit_is_confined" {
  command = plan

  assert {
    condition = alltrue([
      for line in ["RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK", "CapabilityBoundingSet=\n", "ProtectKernelTunables=true", "ProtectKernelModules=true", "ProtectControlGroups=true"] :
      strcontains(base64decode(aws_launch_template.this["x86_64"].user_data), line)
    ])
    error_message = "The bot needs sockets and nothing else of the kernel."
  }
}

run "status_link_lasts_an_hour" {
  command = plan

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "set eggdrop_token_ttl 3600") && strcontains(aws_s3_object.config["config/eggdrop.tcl"].content, "(valid for 1 hour)")
    error_message = "A status link expires after an hour."
  }
}

run "bots_are_at_most_ten" {
  command = plan
  variables {
    bots = 11
  }

  expect_failures = [var.bots]
}

run "spare_may_name_the_server_of_the_bot_it_replaces" {
  command = plan

  assert {
    condition     = strcontains(aws_s3_object.config["config/eggdrop-slot"].content, "LaunchTemplate.Version") && strcontains(aws_s3_object.config["config/eggdrop.conf"].content, "eggdrop_boot_server")
    error_message = "The slot script compares launch template versions and the config reads the server-only choice."
  }
}
