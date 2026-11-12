variable "domain_name" {
  description = "Apex domain the status page is served from. Point its registrar at the name servers this stack outputs."
  type        = string
}

variable "alert_email" {
  description = "Address for outage and cost alerts."
  type        = string
}
