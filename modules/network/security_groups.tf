resource "aws_security_group" "app" {
  name        = "eggdrop-app"
  description = "The Eggdrop instance."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "eggdrop-app"
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_ssh_from_eice" {
  security_group_id            = aws_security_group.app.id
  description                  = "SSH from the EC2 Instance Connect Endpoint."
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.eice.id
}

# The S3 gateway endpoint is reached by prefix list over IPv4 addressing inside
# the VPC; this rule is what lets the instance use it.
data "aws_ec2_managed_prefix_list" "s3" {
  name = "com.amazonaws.${data.aws_region.current.region}.s3"
}

resource "aws_vpc_security_group_egress_rule" "app_s3" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to S3 through the gateway endpoint."
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = data.aws_ec2_managed_prefix_list.s3.id
}

resource "aws_vpc_security_group_egress_rule" "app_https_ipv6" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS over IPv6 to the dual-stack AWS API endpoints."
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv6         = "::/0"
}

locals {
  irc_port_rules = { for port in var.irc_ports : tostring(port) => port }
}

# Valid for the default port, which every v0.4.0 caller used unless irc_server.port was set.
moved {
  from = aws_vpc_security_group_egress_rule.app_irc_ipv6
  to   = aws_vpc_security_group_egress_rule.app_irc_ipv6["6697"]
}

moved {
  from = aws_vpc_security_group_egress_rule.app_irc_ipv4[0]
  to   = aws_vpc_security_group_egress_rule.app_irc_ipv4["6697"]
}

resource "aws_vpc_security_group_egress_rule" "app_irc_ipv6" {
  for_each          = local.irc_port_rules
  security_group_id = aws_security_group.app.id
  description       = "IRC over TLS over IPv6."
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  cidr_ipv6         = "::/0"
}

# The AWS APIs stay on IPv6 (above); only IRC needs the IPv4 path.
resource "aws_vpc_security_group_egress_rule" "app_irc_ipv4" {
  for_each          = var.ipv4_enabled ? local.irc_port_rules : {}
  security_group_id = aws_security_group.app.id
  description       = "IRC over TLS over IPv4."
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "eice" {
  name        = "eggdrop-eice"
  description = "EC2 Instance Connect Endpoint."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "eggdrop-eice"
  }
}

resource "aws_vpc_security_group_egress_rule" "eice_ssh_to_app" {
  security_group_id            = aws_security_group.eice.id
  description                  = "SSH to the app instance."
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.app.id
}

data "dns_aaaa_record_set" "irc" {
  for_each = var.ident ? var.irc_hosts : toset([])
  host     = each.value

  lifecycle {
    postcondition {
      condition     = length(self.addrs) > 0
      error_message = "ident needs an AAAA record for every irc_servers host; ${each.value} has none."
    }
  }
}

locals {
  ident_addresses = toset(flatten([for record in data.dns_aaaa_record_set.irc : record.addrs]))
}

resource "aws_vpc_security_group_ingress_rule" "app_ident" {
  for_each          = local.ident_addresses
  security_group_id = aws_security_group.app.id
  description       = "Ident queries from an IRC server."
  ip_protocol       = "tcp"
  from_port         = 113
  to_port           = 113
  cidr_ipv6         = "${each.value}/128"
}
