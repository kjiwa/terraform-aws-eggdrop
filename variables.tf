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

variable "nicks" {
  description = "IRC nicks the bots take. A booting bot takes the first free one (README, Slot assignment)."
  type        = list(string)
  default     = ["eggdrop"]

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
  description = "Number of bots the ASG runs, at most 10. Up to len(nicks) of them wear a listed nick; any more keep a default name."
  type        = number
  default     = 1

  validation {
    condition     = var.bots >= length(var.nicks)
    error_message = "bots must be at least the number of nicks, so every nick has a bot."
  }

  validation {
    condition     = var.bots <= 10
    error_message = "bots must be at most 10: the nick slots, snapshot reads and refresh headroom are sized for a handful of bots."
  }
}

variable "irc_servers" {
  description = "Servers of one IRC network, tried over TLS. The bot wearing nicks[i] starts at irc_servers[i mod length] (README, Slot assignment). Every host needs an AAAA record unless ipv4_enabled is set."
  type = list(object({
    host = string
    port = optional(number, 6697)
  }))

  validation {
    condition     = length(var.irc_servers) >= 1 && length(var.irc_servers) <= 50
    error_message = "irc_servers must list between 1 and 50 servers."
  }

  validation {
    condition     = alltrue([for server in var.irc_servers : server.port >= 1 && server.port <= 65535])
    error_message = "Each port in irc_servers must be between 1 and 65535."
  }

  validation {
    condition     = alltrue([for server in var.irc_servers : can(regex("^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$", server.host))])
    error_message = "Each host in irc_servers must be a non-empty hostname or IPv4 address of letters, digits, dots and hyphens; IPv6 literals are not supported."
  }

  validation {
    condition     = length(distinct([for server in var.irc_servers : "${lower(server.host)}:${server.port}"])) == length(var.irc_servers)
    error_message = "Each host:port pair in irc_servers must be unique, ignoring the case of the host."
  }
}

variable "net_type" {
  description = "Eggdrop's net-type for the network of irc_servers."
  type        = string

  validation {
    condition     = contains(["EFnet", "IRCnet", "Undernet", "DALnet", "Libera", "freenode", "QuakeNet", "Rizon", "Other"], var.net_type)
    error_message = "net_type must be one of EFnet, IRCnet, Undernet, DALnet, Libera, freenode, QuakeNet, Rizon or Other, because Eggdrop accepts only those names (Twitch needs a module this bot does not load)."
  }
}

variable "users" {
  description = "Handle to hostmask patterns (nick!ident@host, with * and ?) of the people the bot recognises. Use the ident and the VPC's IPv6 /56 of the client that connects, so the mask survives the client's own replacement. A user gets ops only in the channels that list their handle."
  type        = map(list(string))

  validation {
    condition     = !contains(keys(var.users), "peers")
    error_message = "users must not contain the handle peers, which the bots use to recognise each other."
  }

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
  description = "Channels the bot joins, keyed by name. ops lists the handles in users that the bot ops on join in that channel. Every channel is joined, and the bots op each other and the listed users there. bitch deops anyone opped without being listed, unless a bot or the owner opped them. revenge punishes whoever deops or kicks a listed op, short of the owner and the bots: it deops, removes their ops, kicks and bans for 120 minutes."
  type = map(object({
    ops     = optional(list(string), [])
    bitch   = optional(bool, false)
    revenge = optional(bool, false)
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
  description = "AMI ID per architecture (arm64 and x86_64) to launch instead of the latest Amazon Linux 2023. Null lets the ami-updater follow AWS releases; a pin is never moved, and changing it replaces the bots in a make-before-break refresh."
  type        = map(string)
  default     = null

  validation {
    condition     = var.image_ids == null || toset(keys(var.image_ids)) == toset(["arm64", "x86_64"])
    error_message = "image_ids must have exactly the keys arm64 and x86_64."
  }
}

variable "ami_max_age_days" {
  description = "Age in days past which a running bot's AMI makes the ami-updater replace the bots in a make-before-break refresh, when a newer AMI is targeted. A refresh replaces the bots one at a time; unused when image_ids is set."
  type        = number
  default     = 14
}

variable "ipv4_enabled" {
  description = "If true instances get a public IPv4 address (about 3.65 USD per month) and may reach IRC servers over IPv4. Leave false for servers with AAAA records."
  type        = bool
  default     = false
}

variable "ident" {
  description = "If true the bots answer RFC 1413 ident queries (Eggdrop's built-in server on tcp/113), so IRC servers show the nick as the username, without the \"~\". Free: an internet gateway has no charge; switches the IPv6 default route from the egress-only gateway to the internet gateway, and opens inbound tcp/113 to the IRC servers' IPv6 addresses only, resolved at plan time (an address that changes shows as a diff on the next plan; a host that rotates among several AAAA records is not supported, because the bot may connect to an address the plan did not open). Every irc_servers host needs an AAAA record. Changing it replaces the instances."
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
