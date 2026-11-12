mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-west-2a", "us-west-2b"] }
  }
  mock_data "aws_region" {
    defaults = { region = "us-west-2", name = "us-west-2" }
  }
}

variables {
  irc_port = 6697
}

run "ipv6_only_with_no_inbound_path" {
  command = plan

  assert {
    condition     = aws_subnet.this.map_public_ip_on_launch == false && aws_subnet.this.assign_ipv6_address_on_creation == true
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
