data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

locals {
  az = var.az != null ? var.az : data.aws_availability_zones.available.names[0]
}

# The IPv4 block is required by the VPC API and never routed: the subnet has no
# IPv4 default route, so no instance can send or receive IPv4 beyond the VPC.
resource "aws_vpc" "this" {
  cidr_block                       = "10.30.0.0/24"
  assign_generated_ipv6_cidr_block = true
  enable_dns_support               = true
  enable_dns_hostnames             = true

  tags = {
    Name = "naju"
  }
}

# cidrsubnet(..., 8, 0) carves the first /64 out of the VPC's amazon-provided
# /56. Operator masks match the /56, not this /64, so they survive a subnet move.
resource "aws_subnet" "this" {
  vpc_id                          = aws_vpc.this.id
  cidr_block                      = aws_vpc.this.cidr_block
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.this.ipv6_cidr_block, 8, 0)
  availability_zone               = local.az
  assign_ipv6_address_on_creation = true
  map_public_ip_on_launch         = false

  tags = {
    Name = "naju"
  }
}

# Outbound IPv6 only (IRC, dual-stack AWS APIs); no inbound, no hourly or
# per-GB charge.
resource "aws_egress_only_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "naju"
  }
}

resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "naju"
  }
}

resource "aws_route_table_association" "this" {
  subnet_id      = aws_subnet.this.id
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
    Name = "naju-s3"
  }
}
