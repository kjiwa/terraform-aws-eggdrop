resource "aws_autoscaling_group" "this" {
  name = local.name

  # The instance role's policy must be current before the first launch;
  # Terraform infers no ordering from the launch template to the policy.
  depends_on = [aws_iam_role_policy.instance, aws_s3_object.config, aws_s3_object.status_key]

  min_size            = var.active ? 1 : 0
  max_size            = var.active ? 1 : 0
  desired_capacity    = var.active ? 1 : 0
  vpc_zone_identifier = [var.subnet_id]
  capacity_rebalance  = false

  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.this.id
        version            = aws_launch_template.this.latest_version
      }

      dynamic "override" {
        for_each = local.instance_types
        content {
          instance_type = override.value
        }
      }
    }

    instances_distribution {
      spot_allocation_strategy                 = "price-capacity-optimized"
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = var.spot_enabled ? 0 : 100
    }
  }

  tag {
    key                 = "Name"
    value               = local.name
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = local.name
    propagate_at_launch = true
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
    }
  }
}
