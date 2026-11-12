# Local Zones and Wavelength Zones are opt-in and lack some instance types.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_region" "current" {}

locals {
  azs = sort(data.aws_availability_zones.available.names)
}

# The IPv4 block is required by the VPC API. It is routed beyond the VPC only
# when var.ipv4_enabled adds a default route and a public address.
resource "aws_vpc" "this" {
  cidr_block                       = "10.30.0.0/24"
  assign_generated_ipv6_cidr_block = true
  enable_dns_support               = true
  enable_dns_hostnames             = true

  tags = {
    Name = "eggdrop"
  }
}

# One subnet per zone: Spot capacity is a pool per type and zone, so every zone
# is another pool for the ASG to draw from. cidrsubnet(..., 8, n) carves the
# nth /64 out of the VPC's amazon-provided /56. Operator masks match the /56,
# not a /64, so they survive a move between zones.
resource "aws_subnet" "this" {
  for_each = { for index, az in local.azs : az => index }

  vpc_id                          = aws_vpc.this.id
  cidr_block                      = cidrsubnet(aws_vpc.this.cidr_block, 4, each.value)
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.this.ipv6_cidr_block, 8, each.value)
  availability_zone               = each.key
  assign_ipv6_address_on_creation = true
  map_public_ip_on_launch         = var.ipv4_enabled

  tags = {
    Name = "eggdrop-${each.key}"
  }
}

# Outbound IPv6 only (IRC, dual-stack AWS APIs); no inbound, no hourly or
# per-GB charge.
resource "aws_egress_only_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "eggdrop"
  }
}

resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "eggdrop"
  }
}

resource "aws_route_table_association" "this" {
  for_each = aws_subnet.this

  subnet_id      = each.value.id
  route_table_id = aws_route_table.this.id
}

resource "aws_route" "ipv6_egress" {
  route_table_id              = aws_route_table.this.id
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = aws_egress_only_internet_gateway.this.id
}

# With no IPv4 path, this is how the instance reaches S3 (the Eggdrop tarball,
# config) and the S3-hosted dnf mirrors.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.this.id]

  tags = {
    Name = "eggdrop-s3"
  }
}

resource "aws_internet_gateway" "this" {
  count  = var.ipv4_enabled ? 1 : 0
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "eggdrop"
  }
}

resource "aws_route" "ipv4_egress" {
  count                  = var.ipv4_enabled ? 1 : 0
  route_table_id         = aws_route_table.this.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}
