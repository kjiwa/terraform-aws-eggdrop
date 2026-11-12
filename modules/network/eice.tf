# Break-glass SSH. The instance has no inbound path and no SSM agent path on an
# IPv6-only subnet, so this is the only out-of-band way in. Billed only for open
# tunnel minutes.
resource "aws_ec2_instance_connect_endpoint" "this" {
  subnet_id          = aws_subnet.this.id
  security_group_ids = [aws_security_group.eice.id]
  preserve_client_ip = false

  tags = {
    Name = "eggdrop-eice"
  }
}
