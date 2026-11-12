output "subnet_id" {
  description = "Subnet ID the ASG launches into."
  value       = aws_subnet.this.id
}

output "app_sg_id" {
  description = "Security group attached to the instance."
  value       = aws_security_group.app.id
}

output "ipv6_cidr_block" {
  description = "The VPC's /56. Every instance address falls inside it, so operator hostmasks match this range."
  value       = aws_vpc.this.ipv6_cidr_block
}
