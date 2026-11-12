variable "subnet_ids" {
  description = "Subnets the ASG launches into, one per availability zone."
  type        = list(string)
}

variable "app_sg_id" {
  description = "Security group attached to the instance."
  type        = string
}

variable "active" {
  description = "If false the ASG is scaled to zero; the bucket and config stay."
  type        = bool
}

variable "spot_enabled" {
  description = "If false the ASG runs On-Demand instead of Spot."
  type        = bool
}

variable "nick" {
  description = "IRC nick the bot registers with. The alternate nick is this plus a random character."
  type        = string
}

variable "irc_server" {
  description = "IRC server the bot connects to over TLS and IPv6."
  type = object({
    host = string
    port = number
  })
}

variable "channels" {
  description = "Channels the bot joins, keyed by name. ops lists the handles in users that the bot ops on join in that channel. SiteUp is 1 only while the bot has ops in every one."
  type = map(object({
    ops = list(string)
  }))
}

variable "users" {
  description = "Handle to hostmasks (nick!ident@host patterns) of the people the bot recognises."
  type        = map(list(string))
}

variable "owner" {
  description = "Handle in users that may ask the bot for a status page link."
  type        = string
}

variable "eggdrop" {
  description = "Eggdrop release the instance compiles: version and the SHA-256 of eggdrop-<version>.tar.gz."
  type = object({
    version = string
    sha256  = string
  })
}

variable "image_ids" {
  description = "AMI ID per architecture (arm64 and x86_64) to launch instead of the latest Amazon Linux 2023. Null tracks the latest, which replaces the instance whenever AWS publishes a release. A plan warns when a pinned image is stale."
  type        = map(string)
  default     = null

  validation {
    condition     = var.image_ids == null || toset(keys(var.image_ids)) == toset(["arm64", "x86_64"])
    error_message = "image_ids must have exactly the keys arm64 and x86_64."
  }
}

variable "domain_name" {
  description = "Domain the status page link points at."
  type        = string
}

variable "metric_namespace" {
  description = "CloudWatch namespace the bot publishes SiteUp to."
  type        = string
}

variable "status_key" {
  description = "HMAC key that signs status page tokens. Written to the bot bucket for the instance to read."
  type        = string
  sensitive   = true
}
