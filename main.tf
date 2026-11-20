resource "random_password" "status_key" {
  length  = 48
  special = false
}

module "network" {
  source = "./modules/network"

  irc_ports    = toset([for server in var.irc_servers : server.port])
  ipv4_enabled = var.ipv4_enabled
}

module "compute" {
  source = "./modules/compute"

  subnet_ids              = module.network.subnet_ids
  subnet_ipv6_cidr_blocks = module.network.subnet_ipv6_cidr_blocks
  app_sg_id               = module.network.app_sg_id
  active                  = var.active
  spot_enabled            = var.spot_enabled
  nicks                   = var.nicks
  bots                    = var.bots
  irc_servers             = var.irc_servers
  net_type                = var.net_type
  channels                = var.channels
  users                   = var.users
  owner                   = var.owner
  eggdrop                 = var.eggdrop
  image_ids               = var.image_ids
  domain_name             = var.domain_name
  metric_namespace        = local.metric_namespace
  status_key              = random_password.status_key.result
}

module "monitoring" {
  source = "./modules/monitoring"

  domain_name       = var.domain_name
  asg_name          = module.compute.asg_name
  alert_email       = var.alert_email
  metric_namespace  = local.metric_namespace
  group_size        = min(var.bots, length(var.nicks))
  slot_gate_seconds = module.compute.slot_gate_seconds
  active            = var.active
}

# Not with image_ids: a pin is the operator's, so nothing may move it.
module "ami_updater" {
  count  = var.image_ids == null ? 1 : 0
  source = "../terraform-aws-keel/modules/ami-updater"

  name_prefix         = "eggdrop"
  asg_name            = module.compute.asg_name
  launch_template_ids = module.compute.launch_template_ids
  instance_role_arns  = [module.compute.instance_role_arn]
  ami_max_age_days    = var.ami_max_age_days
  alarm_topic_arn     = module.monitoring.alarm_topic_arn

  # The group's instance_refresh, without skip_matching: the updater only
  # refreshes when an instance has to be replaced. The group's launching
  # hook applies to every refresh.
  refresh_preferences = merge(module.compute.refresh_preferences, { alarm_names = module.monitoring.outage_alarm_names })
}

module "status" {
  source = "./modules/status"

  domain_name                  = var.domain_name
  distribution_arn             = module.edge.distribution_arn
  asg_name                     = module.compute.asg_name
  bot_bucket                   = module.compute.bucket_name
  irc_log_group                = module.compute.irc_log_group_name
  irc_servers                  = var.irc_servers
  episodes_log_group           = module.monitoring.episodes_log_group_name
  spot_interruptions_log_group = module.monitoring.spot_interruptions_log_group_name
  metric_namespace             = local.metric_namespace
  spot_enabled                 = var.spot_enabled
  status_key                   = random_password.status_key.result
  token_key                    = local.token_key
}

module "edge" {
  source = "./modules/edge"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  domain_name      = var.domain_name
  zone_id          = var.zone_id
  token_key        = local.token_key
  status_origins   = module.status.origins
  status_behaviors = module.status.behaviors
}
