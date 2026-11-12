# Stock AL2023, not a baked image: patching is dnf-automatic (user_data) plus
# the instance refresh that a launch template change triggers. The SSM public
# parameters resolve to the latest AL2023 release; image_ids pins a release so
# that AWS publishing one does not replace the instance.
data "aws_ssm_parameter" "al2023" {
  for_each = local.architectures

  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${each.key}"
}

# insecure_value is the non-sensitive twin of value: an AMI ID is not a secret.
check "image_is_latest" {
  assert {
    condition = var.image_ids == null ? true : alltrue([
      for architecture in local.architectures : var.image_ids[architecture] == data.aws_ssm_parameter.al2023[architecture].insecure_value
    ])
    error_message = var.image_ids == null ? "" : "image_ids is behind the latest AL2023: ${join(", ", [for architecture in sort(tolist(local.architectures)) : "${architecture} ${var.image_ids[architecture]} -> ${data.aws_ssm_parameter.al2023[architecture].insecure_value}" if var.image_ids[architecture] != data.aws_ssm_parameter.al2023[architecture].insecure_value])}."
  }
}
