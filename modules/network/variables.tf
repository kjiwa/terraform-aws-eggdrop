variable "irc_port" {
  description = "TCP port the IRC server listens on for TLS. The app security group allows egress to it over IPv6."
  type        = number
}

variable "ipv4_enabled" {
  description = "If true the subnet routes IPv4 to an internet gateway and instances get a public IPv4 address, billed hourly, so the bot can reach IRC servers that have no AAAA record. Egress stays limited to the IRC port."
  type        = bool
  default     = false
}
