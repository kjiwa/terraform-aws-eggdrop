resource "aws_route53_zone" "this" {
  name = var.domain_name
}

module "eggdrop" {
  source = "../.."
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  domain_name = var.domain_name
  zone_id     = aws_route53_zone.this.zone_id
  alert_email = var.alert_email

  irc_server = { host = "irc.example.net" }
  channels   = ["#example"]
  ops        = { alice = ["*!*alice@2001:db8:1:2??:*"] }
  owner      = "alice"

  # sha256 of eggdrop-<version>.tar.gz; upload it with scripts/upload.sh.
  eggdrop = {
    version = "1.10.2"
    sha256  = "d6646b630879e1acd9b053ffa12f46667f907145f29af1df0f82749ef3032a94"
  }
}
