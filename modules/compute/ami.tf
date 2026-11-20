# Seeds image_id when the launch templates are created. The ami-updater
# module then advances it through new template versions, and image_id is
# ignored so that Terraform does not revert them.
data "aws_ssm_parameter" "al2023" {
  for_each = local.architectures

  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${each.key}"
}

# image_id is ignored, so replace_triggered_by is what makes a change of
# image_ids reach the templates.
resource "terraform_data" "image_pin" {
  input = var.image_ids
}
