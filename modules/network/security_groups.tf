resource "aws_security_group" "app" {
  name        = "naju-app"
  description = "The Eggdrop instance."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "naju-app"
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

resource "aws_vpc_security_group_egress_rule" "app_irc_ipv6" {
  security_group_id = aws_security_group.app.id
  description       = "IRC over TLS over IPv6."
  ip_protocol       = "tcp"
  from_port         = var.irc_port
  to_port           = var.irc_port
  cidr_ipv6         = "::/0"
}

resource "aws_security_group" "eice" {
  name        = "naju-eice"
  description = "EC2 Instance Connect Endpoint."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "naju-eice"
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
