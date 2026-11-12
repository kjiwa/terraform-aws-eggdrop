variable "az" {
  description = "Availability zone for the subnet. Null derives the first available AZ in the region."
  type        = string
  default     = null
}

variable "irc_port" {
  description = "TCP port the IRC server listens on for TLS. The app security group allows egress to it over IPv6."
  type        = number
}
