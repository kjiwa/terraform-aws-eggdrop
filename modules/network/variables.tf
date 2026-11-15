variable "irc_ports" {
  description = "TCP ports the IRC servers listen on for TLS. The app security group allows egress to each over IPv6, and over IPv4 when ipv4_enabled."
  type        = set(number)
}

variable "ipv4_enabled" {
  description = "If true the subnet routes IPv4 to an internet gateway and instances get a public IPv4 address, billed hourly, so the bot can reach IRC servers that have no AAAA record. Egress stays limited to the IRC port."
  type        = bool
  default     = false
}
