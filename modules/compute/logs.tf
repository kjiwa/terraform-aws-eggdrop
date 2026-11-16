# Server events (connects, refusals and their reasons) from every bot, one
# stream per instance. Channel traffic is never sent.
resource "aws_cloudwatch_log_group" "irc" {
  name              = local.log_group_name
  retention_in_days = 30
}
