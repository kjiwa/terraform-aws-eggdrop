resource "random_password" "status_key" {
  length  = 48
  special = false
}

module "network" {
  source = "./modules/network"

  irc_port = var.irc_server.port
}

module "compute" {
  source = "./modules/compute"

  subnet_id        = module.network.subnet_id
  app_sg_id        = module.network.app_sg_id
  active           = var.active
  spot_enabled     = var.spot_enabled
  nick             = var.nick
  irc_server       = var.irc_server
  channels         = var.channels
  ops              = var.ops
  owner            = var.owner
  eggdrop          = var.eggdrop
  domain_name      = var.domain_name
  metric_namespace = local.metric_namespace
  status_key       = random_password.status_key.result
}

module "monitoring" {
  source = "./modules/monitoring"

  domain_name      = var.domain_name
  asg_name         = module.compute.asg_name
  alert_email      = var.alert_email
  metric_namespace = local.metric_namespace
  active           = var.active
}

module "status" {
  source = "./modules/status"

  domain_name                  = var.domain_name
  distribution_arn             = module.edge.distribution_arn
  asg_name                     = module.compute.asg_name
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
