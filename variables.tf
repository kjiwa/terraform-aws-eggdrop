variable "domain_name" {
  description = "Apex domain the status page is served from: https://<domain_name>/status."
  type        = string
}

variable "zone_id" {
  description = "Route 53 hosted zone ID for domain_name."
  type        = string
}

variable "alert_email" {
  description = "Address that receives the DOWN and RECOVERED emails."
  type        = string
}

variable "nick" {
  description = "IRC nick the bot registers with."
  type        = string
  default     = "eggdrop"

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_-]{0,29}$", var.nick))
    error_message = "The nick must start with a letter and hold at most 30 letters, digits, hyphens and underscores. It is written into a Tcl string, so IRC's other nick characters are not accepted."
  }
}

variable "irc_server" {
  description = "IRC server the bot connects to over TLS. It must have an AAAA record unless ipv4_enabled is set."
  type = object({
    host = string
    port = optional(number, 6697)
  })
}

variable "users" {
  description = "Handle to hostmask patterns (nick!ident@host, with * and ?) of the people the bot recognises. Use the ident and the VPC's IPv6 /56 of the client that connects, so the mask survives the client's own replacement. A user gets ops only in the channels that list their handle."
  type        = map(list(string))

  validation {
    condition     = alltrue([for handle in keys(var.users) : can(regex("^[a-z][a-z0-9_-]*$", handle))])
    error_message = "Each handle in users must start with a lowercase letter and hold only lowercase letters, digits, hyphens and underscores."
  }

  validation {
    condition = alltrue([
      for masks in values(var.users) : length(masks) > 0 && alltrue([for mask in masks : can(regex("^[^\\s{}\\\\]+![^\\s{}\\\\]+@[^\\s{}\\\\]*[^\\s{}\\\\*?][^\\s{}\\\\]*$", mask))])
    ])
    error_message = "Each handle in users needs at least one mask of the form nick!ident@host, with no whitespace, brace or backslash, and a host part with something other than wildcards: a mask is the only proof the bot has that a user may be opped or may mint a status link."
  }
}

variable "channels" {
  description = "Channels the bot joins, keyed by name. ops lists the handles in users that the bot ops on join in that channel. SiteUp is 1 only while the bot has ops in every channel."
  type = map(object({
    ops = optional(list(string), [])
  }))

  validation {
    condition     = length(var.channels) > 0 && alltrue([for channel in keys(var.channels) : can(regex("^#[A-Za-z0-9_.-]+$", channel))])
    error_message = "channels must list at least one channel, each # followed by letters, digits, dots, hyphens and underscores. Channel names are written into Tcl, so other characters are not accepted."
  }

  validation {
    condition     = alltrue([for channel in values(var.channels) : alltrue([for handle in channel.ops : contains(keys(var.users), handle)])])
    error_message = "Every handle in a channel's ops must be a key of users."
  }
}

variable "owner" {
  description = "Handle in users that may ask the bot for a status page link with /msg <nick> status. The owner needs no ops."
  type        = string

  validation {
    condition     = contains(keys(var.users), var.owner)
    error_message = "owner must be a key of users, because the bot recognises the owner by that handle's hostmasks."
  }
}

variable "eggdrop" {
  description = "Eggdrop release the instance compiles: its version and the SHA-256 of eggdrop-<version>.tar.gz. Upload the tarball with scripts/upload.sh."
  type = object({
    version = string
    sha256  = string
  })

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.eggdrop.version)) && can(regex("^[0-9a-f]{64}$", var.eggdrop.sha256))
    error_message = "eggdrop.version must be a plain x.y.z release and eggdrop.sha256 must be 64 lowercase hex digits."
  }
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

variable "ipv4_enabled" {
  description = "If true instances get a public IPv4 address (about 3.65 USD per month) and may reach IRC servers over IPv4. Leave false for servers with AAAA records."
  type        = bool
  default     = false
}

variable "spot_enabled" {
  description = "If false the instance runs On-Demand instead of Spot."
  type        = bool
  default     = true
}

variable "active" {
  description = "If false the environment is asleep: the ASG is scaled to zero and alarm notifications are disabled."
  type        = bool
  default     = true
}
