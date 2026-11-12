# Stock AL2023, not a baked image: patching is dnf-automatic (user_data) plus
# the instance refresh that every launch template change triggers. The SSM
# public parameter resolves to the latest AL2023 release.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
