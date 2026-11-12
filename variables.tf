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
  description = "IRC server the bot connects to over TLS and IPv6. It must have an AAAA record: the subnet has no IPv4 path."
  type = object({
    host = string
    port = optional(number, 6697)
  })
}

variable "channels" {
  description = "Channels the bot joins. SiteUp is 1 only while it has ops in every one."
  type        = list(string)

  validation {
    condition     = length(var.channels) > 0 && alltrue([for channel in var.channels : can(regex("^#[A-Za-z0-9_.-]+$", channel))])
    error_message = "channels must list at least one channel, each # followed by letters, digits, dots, hyphens and underscores. Channel names are written into Tcl, so other characters are not accepted."
  }
}

variable "ops" {
  description = "Handle to hostmask patterns (nick!ident@host, with * and ?) of the users the bot ops on join. Use the ident and the VPC's IPv6 /56 of the client that connects, so the mask survives the client's own replacement."
  type        = map(list(string))

  validation {
    condition     = alltrue([for handle in keys(var.ops) : can(regex("^[a-z][a-z0-9_-]*$", handle))])
    error_message = "Each handle in ops must start with a lowercase letter and hold only lowercase letters, digits, hyphens and underscores."
  }

  validation {
    condition = alltrue([
      for masks in values(var.ops) : length(masks) > 0 && alltrue([for mask in masks : can(regex("^[^\\s{}\\\\]+![^\\s{}\\\\]+@[^\\s{}\\\\]*[^\\s{}\\\\*?][^\\s{}\\\\]*$", mask))])
    ])
    error_message = "Each handle in ops needs at least one mask of the form nick!ident@host, with no whitespace, brace or backslash, and a host part with something other than wildcards: a mask is the only proof the bot has that a user may be opped or may mint a status link."
  }
}

variable "owner" {
  description = "Handle in ops that may ask the bot for a status page link with /msg <nick> status."
  type        = string

  validation {
    condition     = contains(keys(var.ops), var.owner)
    error_message = "owner must be a key of ops, because the bot recognises the owner by that handle's hostmasks."
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
