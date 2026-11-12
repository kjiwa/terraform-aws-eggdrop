# Stock AL2023, not a baked image: patching is dnf-automatic (user_data) plus
# the instance refresh that every launch template change triggers. The SSM
# public parameters resolve to the latest AL2023 release.
data "aws_ssm_parameter" "al2023" {
  for_each = local.architectures

  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${each.key}"
}
