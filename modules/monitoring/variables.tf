variable "domain_name" {
  description = "Apex domain of the status page; the alarm and emails name it."
  type        = string
}

variable "asg_name" {
  description = "Auto Scaling group the availability Lambda watches for replacements."
  type        = string
}

variable "alert_email" {
  description = "Address that receives the DOWN and RECOVERED emails."
  type        = string
}

variable "metric_namespace" {
  description = "CloudWatch namespace the bot publishes SiteUp to."
  type        = string
}

variable "active" {
  description = "If false the environment is asleep and the alarm-notification rule is disabled."
  type        = bool
}
