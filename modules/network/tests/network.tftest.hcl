mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-west-2a", "us-west-2b"] }
  }
  mock_data "aws_region" {
    defaults = { region = "us-west-2", name = "us-west-2" }
  }
}

mock_provider "dns" {
  mock_data "dns_aaaa_record_set" {
    defaults = { addrs = ["2001:db8::1"] }
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
  irc_ports = [6697]
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

  assert {
    condition     = output.subnet_ipv6_cidr_blocks == [for az in ["us-west-2a", "us-west-2b"] : aws_subnet.this[az].ipv6_cidr_block] && alltrue([for cidr in output.subnet_ipv6_cidr_blocks : can(regex("^([0-9a-f]{1,4}:){3}[0-9a-f]{1,4}::/64$", cidr))])
    error_message = "Each subnet's /64 is output in zone order, with all four prefix groups printed."
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
    error_message = "Without ident the only inbound rule is SSH from the instance connect endpoint."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.app_irc_ipv6["6697"].from_port == 6697 && aws_vpc_security_group_egress_rule.app_irc_ipv6["6697"].to_port == 6697
    error_message = "IRC egress must follow irc_ports."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.app_https_ipv6.cidr_ipv6 == "::/0" && aws_vpc_security_group_egress_rule.app_irc_ipv6["6697"].cidr_ipv6 == "::/0"
    error_message = "Egress is IPv6 only: HTTPS for the AWS APIs and the IRC port."
  }
}

run "no_ipv4_path_by_default" {
  command = plan

  assert {
    condition     = length(aws_internet_gateway.this) == 0 && length(aws_route.ipv4_egress) == 0 && length(aws_vpc_security_group_egress_rule.app_irc_ipv4) == 0 && length(aws_route.ident_ipv6) == 0 && length(aws_vpc_security_group_ingress_rule.app_ident) == 0
    error_message = "With ipv4_enabled and ident off there is no internet gateway, IPv4 route, IPv4 egress rule, ident route or ident rule."
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
    condition     = aws_vpc_security_group_egress_rule.app_irc_ipv4["6697"].from_port == 6697 && aws_vpc_security_group_egress_rule.app_irc_ipv4["6697"].to_port == 6697 && aws_vpc_security_group_egress_rule.app_irc_ipv4["6697"].cidr_ipv4 == "0.0.0.0/0"
    error_message = "IPv4 egress is the IRC port only."
  }
}

run "one_egress_rule_per_port" {
  command = plan
  variables {
    irc_ports    = [6697, 7000]
    ipv4_enabled = true
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_egress_rule.app_irc_ipv6)) == toset(["6697", "7000"]) && toset(keys(aws_vpc_security_group_egress_rule.app_irc_ipv4)) == toset(["6697", "7000"]) && aws_vpc_security_group_egress_rule.app_irc_ipv6["7000"].to_port == 7000 && aws_vpc_security_group_egress_rule.app_irc_ipv4["7000"].from_port == 7000
    error_message = "Every distinct port gets one IPv6 rule and, with ipv4_enabled, one IPv4 rule."
  }
}

run "ident_routes_each_server_address_through_the_internet_gateway" {
  command = plan
  variables {
    ident     = true
    irc_hosts = ["a.example.net", "b.example.net"]
  }

  override_data {
    target = data.dns_aaaa_record_set.irc["a.example.net"]
    values = { addrs = ["2001:db8::a"] }
  }

  override_data {
    target = data.dns_aaaa_record_set.irc["b.example.net"]
    values = { addrs = ["2001:db8::b", "2001:db8::c"] }
  }

  assert {
    condition     = length(aws_internet_gateway.this) == 1 && length(aws_route.ipv4_egress) == 0
    error_message = "ident adds an internet gateway and no IPv4 route."
  }

  assert {
    condition     = toset(keys(aws_route.ident_ipv6)) == toset(["2001:db8::a", "2001:db8::b", "2001:db8::c"]) && alltrue([for route in values(aws_route.ident_ipv6) : endswith(route.destination_ipv6_cidr_block, "/128")])
    error_message = "Each IRC server address gets one /128 route."
  }

  assert {
    condition     = aws_route.ipv6_egress.destination_ipv6_cidr_block == "::/0"
    error_message = "Every other IPv6 destination still leaves through the egress-only gateway."
  }

  assert {
    condition     = toset([for rule in values(aws_vpc_security_group_ingress_rule.app_ident) : rule.cidr_ipv6]) == toset(["2001:db8::a/128", "2001:db8::b/128", "2001:db8::c/128"]) && alltrue([for rule in values(aws_vpc_security_group_ingress_rule.app_ident) : rule.from_port == 113 && rule.to_port == 113 && rule.ip_protocol == "tcp"])
    error_message = "One tcp/113 rule per server address, from that /128 only."
  }

  assert {
    condition     = alltrue([for rule in values(aws_vpc_security_group_ingress_rule.app_ident) : endswith(rule.cidr_ipv6, "/128")]) && length(aws_vpc_security_group_ingress_rule.app_ident) == 3
    error_message = "No ident source may be wider than a /128."
  }
}

run "ident_with_ipv4_keeps_one_internet_gateway" {
  command = plan
  variables {
    ident        = true
    ipv4_enabled = true
    irc_hosts    = ["irc.example.net"]
  }

  assert {
    condition     = length(aws_internet_gateway.this) == 1 && length(aws_route.ipv4_egress) == 1 && length(aws_route.ident_ipv6) == 1
    error_message = "ident and ipv4_enabled share the internet gateway."
  }
}

run "ident_needs_an_aaaa_record_per_host" {
  command = plan
  variables {
    ident     = true
    irc_hosts = ["v4only.example.net"]
  }

  override_data {
    target = data.dns_aaaa_record_set.irc["v4only.example.net"]
    values = { addrs = [] }
  }

  expect_failures = [data.dns_aaaa_record_set.irc["v4only.example.net"]]
}
