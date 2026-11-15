variable "subnet_ids" {
  description = "Subnets the ASG launches into, one per availability zone."
  type        = list(string)
}

variable "subnet_ipv6_cidr_blocks" {
  description = "Each subnet's /64 in subnet_ids order. Peer bots are recognised by these ranges."
  type        = list(string)

  validation {
    condition     = alltrue([for cidr in var.subnet_ipv6_cidr_blocks : can(regex("^([0-9a-f]{1,4}:){3}[0-9a-f]{1,4}::/64$", cidr))])
    error_message = "Each subnet_ipv6_cidr_blocks entry must print all four prefix groups followed by ::/64, because the peer mask is built from the printed prefix."
  }
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

variable "nicks" {
  description = "IRC nicks the bots take. Every bot boots as the first and claims the first free name in the list; extra bots keep a default name."
  type        = list(string)

  validation {
    condition     = length(var.nicks) > 0 && length(distinct(var.nicks)) == length(var.nicks) && alltrue([for nick in var.nicks : can(regex("^[A-Za-z][A-Za-z0-9_-]{0,29}$", nick))])
    error_message = "nicks must list at least one unique nick, each starting with a letter and holding at most 30 letters, digits, hyphens and underscores. Nicks are written into a Tcl string, so IRC's other nick characters are not accepted."
  }

  validation {
    condition     = !contains(var.nicks, "peers")
    error_message = "nicks must not contain peers, which is the handle the bots use to recognise each other."
  }
}

variable "bots" {
  description = "Number of bots the ASG runs. The first len(nicks) take the nicks in order; any more keep a default name."
  type        = number

  validation {
    condition     = var.bots >= length(var.nicks)
    error_message = "bots must be at least the number of nicks, so every nick has a bot."
  }
}

variable "irc_server" {
  description = "IRC server the bot connects to over TLS, preferring IPv6."
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

  validation {
    condition     = !contains(keys(var.users), "peers")
    error_message = "users must not contain the handle peers, which the bots use to recognise each other."
  }
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
