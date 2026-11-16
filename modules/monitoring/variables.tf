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

variable "group_size" {
  description = "Expected number of listed nicks present, at most the number of bots; GroupSize below it for 20 minutes alarms."
  type        = number
}

variable "active" {
  description = "If false the environment is asleep and the alarm-notification rule is disabled."
  type        = bool
}

variable "slot_gate_seconds" {
  description = "Minimum seconds between a bot's jumps to its slot server; the OnSlotServer alarm waits two gates."
  type        = number
}
