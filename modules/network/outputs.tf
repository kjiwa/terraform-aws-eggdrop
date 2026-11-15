output "subnet_ids" {
  description = "One subnet ID per availability zone, for the ASG to launch into."
  value       = [for az in local.azs : aws_subnet.this[az].id]
}

output "subnet_ipv6_cidr_blocks" {
  description = "Each subnet's /64, ordered like subnet_ids."
  value       = [for az in local.azs : aws_subnet.this[az].ipv6_cidr_block]
}

output "app_sg_id" {
  description = "Security group attached to the instance."
  value       = aws_security_group.app.id
}

output "ipv6_cidr_block" {
  description = "The VPC's /56. Every instance address falls inside it, so operator hostmasks match this range."
  value       = aws_vpc.this.ipv6_cidr_block
}
