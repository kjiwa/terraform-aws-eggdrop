mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-west-2a", "us-west-2b"] }
  }
  mock_data "aws_region" {
    defaults = { region = "us-west-2", name = "us-west-2" }
  }
}

# Computed at apply; the subnets carve their blocks out of it.
override_resource {
  target          = aws_vpc.this
  override_during = plan
  values = {
    id              = "vpc-0123456789abcdef0"
    ipv6_cidr_block = "2001:db8:1:200::/56"
  }
}

override_resource {
  target          = aws_subnet.this["us-west-2a"]
  override_during = plan
  values          = { id = "subnet-0123456789abcdef0" }
}

variables {
  irc_port = 6697
}

run "one_subnet_per_zone" {
  command = plan

  assert {
    condition     = toset(keys(aws_subnet.this)) == toset(["us-west-2a", "us-west-2b"]) && length(distinct([for subnet in values(aws_subnet.this) : subnet.cidr_block])) == 2 && length(distinct([for subnet in values(aws_subnet.this) : subnet.ipv6_cidr_block])) == 2
    error_message = "Every zone gets its own subnet with its own IPv4 and IPv6 blocks."
  }

  assert {
    condition     = aws_ec2_instance_connect_endpoint.this.subnet_id == aws_subnet.this["us-west-2a"].id
    error_message = "The single instance connect endpoint sits in the first zone."
  }
}

run "ipv6_only_with_no_inbound_path" {
  command = plan

  assert {
    condition     = alltrue([for subnet in values(aws_subnet.this) : subnet.map_public_ip_on_launch == false && subnet.assign_ipv6_address_on_creation == true])
    error_message = "The subnet must hand out IPv6 addresses and no public IPv4."
  }

  assert {
    condition     = aws_route.ipv6_egress.destination_ipv6_cidr_block == "::/0"
    error_message = "IPv6 must leave through the egress-only gateway."
  }

  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" && aws_vpc_endpoint.s3.service_name == "com.amazonaws.us-west-2.s3"
    error_message = "S3 must be reached through a gateway endpoint."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.app_ssh_from_eice.from_port == 22 && aws_vpc_security_group_ingress_rule.app_ssh_from_eice.to_port == 22
    error_message = "The only inbound rule is SSH from the instance connect endpoint."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.app_irc_ipv6.from_port == 6697 && aws_vpc_security_group_egress_rule.app_irc_ipv6.to_port == 6697
    error_message = "IRC egress must follow irc_port."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.app_https_ipv6.cidr_ipv6 == "::/0" && aws_vpc_security_group_egress_rule.app_irc_ipv6.cidr_ipv6 == "::/0"
    error_message = "Egress is IPv6 only: HTTPS for the AWS APIs and the IRC port."
  }
}

run "no_ipv4_path_by_default" {
  command = plan

  assert {
    condition     = length(aws_internet_gateway.this) == 0 && length(aws_route.ipv4_egress) == 0 && length(aws_vpc_security_group_egress_rule.app_irc_ipv4) == 0
    error_message = "With ipv4_enabled off there is no internet gateway, IPv4 route or IPv4 egress rule."
  }
}

run "ipv4_enabled_opens_only_the_irc_port" {
  command = plan
  variables {
    ipv4_enabled = true
  }

  assert {
    condition     = alltrue([for subnet in values(aws_subnet.this) : subnet.map_public_ip_on_launch == true]) && aws_route.ipv4_egress[0].destination_cidr_block == "0.0.0.0/0"
    error_message = "ipv4_enabled must give instances a public address and a default route."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.app_irc_ipv4[0].from_port == 6697 && aws_vpc_security_group_egress_rule.app_irc_ipv4[0].to_port == 6697 && aws_vpc_security_group_egress_rule.app_irc_ipv4[0].cidr_ipv4 == "0.0.0.0/0"
    error_message = "IPv4 egress is the IRC port only."
  }
}
