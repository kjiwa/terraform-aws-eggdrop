data "aws_region" "current" {}

locals {
  name = "eggdrop"

  # Burstable nano and micro types only: the bot needs megabytes, and any
  # larger family costs many times a nano. The ASG draws from every type in
  # every zone, each type with its architecture's image.
  instance_types = {
    x86_64 = ["t3a.nano", "t3.nano", "t3a.micro", "t3.micro"]
    arm64  = ["t4g.nano", "t4g.micro"]
  }
  architectures = toset(keys(local.instance_types))

  type_architectures = merge([
    for architecture, types in local.instance_types : {
      for type in types : type => architecture
    }
  ]...)

  channel_ops = flatten([
    for channel, settings in var.channels : [
      for handle in settings.ops : { channel = channel, handle = handle }
    ]
  ])

  boot_files = {
    "config/eggdrop.conf" = templatefile("${path.module}/files/eggdrop.conf.tftpl", {
      nick       = var.nick
      irc_server = var.irc_server
    })
    "config/eggdrop-token"       = file("${path.module}/files/eggdrop-token.py")
    "config/eggdrop-spot-drain"  = file("${path.module}/files/spot-drain.sh")
    "config/eggdrop-config-sync" = file("${path.module}/files/config-sync.sh")
  }

  # The roster: channels, users and owner. The running bot picks changes up
  # through config-sync, so they stay out of config_hash.
  roster_files = {
    "config/eggdrop.tcl" = templatefile("${path.module}/files/eggdrop.tcl.tftpl", {
      region           = data.aws_region.current.region
      metric_namespace = var.metric_namespace
      domain_name      = var.domain_name
      channels         = sort(keys(var.channels))
      channel_ops      = local.channel_ops
      users            = var.users
      owner            = var.owner
    })
  }

  config_files = merge(local.boot_files, local.roster_files)

  # Part of user_data, so a change to a boot file, or a new status key, is a
  # launch template change and the ASG replaces the instance. The instance
  # reads the key once at boot; a stale key would mint tokens the Lambda rejects.
  config_hash = sha256(join("", concat([for key in sort(keys(local.boot_files)) : local.boot_files[key]], [var.status_key])))
}
