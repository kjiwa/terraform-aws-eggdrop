data "aws_region" "current" {}

locals {
  name = "naju"

  # Spot capacity decorrelated from The Lounge's t4g.nano by architecture and family.
  instance_types = ["t3a.nano", "t3.nano"]

  users = {
    for handle, masks in var.ops : handle => {
      flags = handle == var.owner ? "+nafo" : "+afo"
      masks = masks
    }
  }

  config_files = {
    "config/eggdrop.conf" = templatefile("${path.module}/files/eggdrop.conf.tftpl", {
      nick       = var.nick
      irc_server = var.irc_server
    })
    "config/naju.tcl" = templatefile("${path.module}/files/naju.tcl.tftpl", {
      region           = data.aws_region.current.region
      metric_namespace = var.metric_namespace
      domain_name      = var.domain_name
      channels         = var.channels
      users            = local.users
    })
    "config/naju-token"         = file("${path.module}/files/naju-token.py")
    "config/eggdrop-spot-drain" = file("${path.module}/files/spot-drain.sh")
  }

  # Part of user_data, so any config change, or a new status key, is a launch
  # template change and the ASG replaces the instance. The instance reads the
  # key once at boot; a stale key would mint tokens the Lambda rejects.
  config_hash = sha256(join("", concat([for key in sort(keys(local.config_files)) : local.config_files[key]], [var.status_key])))
}
