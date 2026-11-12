resource "aws_launch_template" "this" {
  name_prefix   = "${local.name}-"
  image_id      = data.aws_ssm_parameter.al2023.value
  ebs_optimized = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  vpc_security_group_ids = [var.app_sg_id]

  # No key_name: the network module's EICE pushes an ephemeral key per
  # session, so a static key pair would be a standing credential.

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 8
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/files/user_data.sh.tftpl", {
    region          = data.aws_region.current.region
    bucket          = aws_s3_bucket.this.id
    eggdrop_version = var.eggdrop.version
    eggdrop_sha256  = var.eggdrop.sha256
    config_hash     = local.config_hash
  }))

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = false
  }

  # Standard, not unlimited: a bot that idles at a few percent CPU must never
  # run up surplus-credit charges.
  credit_specification {
    cpu_credits = "standard"
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = local.name
      Project = local.name
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${local.name}-root"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
