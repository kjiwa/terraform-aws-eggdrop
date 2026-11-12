# terraform-aws-eggdrop

Terraform module for a stateless [Eggdrop](https://www.eggheads.org/) IRC bot on an IPv6-only AWS Spot instance, with a status page.

The bot holds ops in your channels and ops the users you list when they join. It exists for networks without ChanServ, where a channel keeps its ops only while someone with ops stays in it: run it next to a client that fails independently (a different region, instance family and server), and each re-ops the other when it reconnects.

Nothing persists. The instance rebuilds its userfile from the module's inputs on every boot, so there is no data volume and no backup. A replacement compiles the pinned Eggdrop release from an S3 bucket the module owns.

## What it builds

| Module | Resources |
| --- | --- |
| `modules/network` | IPv6-only VPC with a subnet in every availability zone, egress-only internet gateway, S3 gateway endpoint, EC2 Instance Connect Endpoint. No public IPv4 unless `ipv4_enabled`, and no inbound path. |
| `modules/compute` | Spot Auto Scaling group of one across every zone and six burstable types (`t3a`, `t3` and `t4g` nano and micro, x86_64 and arm64), stock Amazon Linux 2023 with unattended security updates, the bot bucket, and the rendered Eggdrop config. |
| `modules/monitoring` | The [status page](https://github.com/kjiwa/terraform-aws-status-page) availability and alarm modules, with the canary off. |
| `modules/status` | The status page core plus a plugin that checks an HMAC token. |
| `modules/edge` | CloudFront and an ACM certificate at the apex of your domain. `/` redirects to `/status`. |

## Usage

```hcl
module "eggdrop" {
  source = "git::https://github.com/kjiwa/terraform-aws-eggdrop.git?ref=vX.Y.Z"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  domain_name = "bot.example.com"
  zone_id     = aws_route53_zone.this.zone_id
  alert_email = "ops@example.com"

  irc_server = { host = "irc.example.net" }
  channels   = { "#example" = { ops = ["alice"] } }
  users      = { alice = ["*!*alice@2001:db8:1:2??:*"] }
  owner      = "alice"

  eggdrop = { version = "1.10.2", sha256 = "<sha256 of eggdrop-1.10.2.tar.gz>" }
}
```

See `examples/minimal`. Pin a literal `?ref=vX.Y.Z`; before 1.0 a minor release may break.

| Input | Meaning |
| --- | --- |
| `domain_name`, `zone_id` | Apex domain for the status page and its Route 53 zone. |
| `alert_email` | Receives the DOWN and RECOVERED emails. |
| `irc_server` | `{ host, port = 6697 }`. TLS over IPv6, so the host needs an AAAA record unless `ipv4_enabled`. |
| `channels` | Channels to join, each with `ops`: the handles in `users` the bot ops there. |
| `users` | Handle to hostmask patterns of the people the bot recognises. |
| `owner` | The handle in `users` that may request a status page link. It gets no ops unless a channel lists it. |
| `eggdrop` | `{ version, sha256 }` of the release to compile. |
| `nick`, `spot_enabled`, `active` | Optional: bot nick (`eggdrop`), Spot or On-Demand (`true`), sleep switch (`true`). |
| `ipv4_enabled` | Optional, `false`. Gives the instance a public IPv4 address, about 3.65 USD a month, and opens the IRC port over IPv4, for servers with no AAAA record. |

### Masks

The bot's address changes with every replacement, but a client's does not leave its VPC's `/56`. Match the ident and the `/56` rather than a full address. For the `/56` `2001:db8:1:200::/56`, the fourth group runs `2??`:

```
*!*alice@2001:db8:1:2??:*
```

## Operating

1. Apply. The instance waits for the Eggdrop tarball, up to 30 minutes. In an account that has never launched a Spot instance, the first launch fails with "Authentication Failure" while AWS creates its Spot service-linked role. Apply again: the failed Auto Scaling group is replaced.
2. Upload it. The script checks the hash before the bucket sees it, and the instance checks it again:

   ```sh
   scripts/upload.sh --version 1.10.2 --sha256 <hash> --bucket "$(terraform output -raw bucket_name)"
   ```

3. Op the bot once from a client that has ops. A bot that rejoins an occupied channel is not opped until someone ops it.
4. Message the bot `status` from a client whose hostmask matches `owner`. It replies with a link that signs you in for 12 hours.

To upgrade from v0.1.0, apply with `active = false` first, then apply the new version with `active = true`: the subnets are replaced, which cannot happen while an instance is running in the old one.

To roll out a new Eggdrop version, upload the new tarball, then change `eggdrop`. Any change to the rendered config replaces the instance the same way. `terraform output asg_name` names the group for a manual `aws autoscaling start-instance-refresh`.

## Availability

The bot publishes the `SiteUp` metric every minute: 1 while it holds ops in every channel, 0 while connected without them. A down bot publishes nothing, and the alarm treats missing data as down. DOWN and RECOVERED emails, the episode record and the Spot capture of the status page all work from that one metric.

The status page gate verifies the token in a Lambda with a key in SSM, so it works while the bot is down.

## Cost

About 2 USD a month at Spot prices in us-west-2: the instance (about 0.0007 USD an hour at the last check for a `t3.nano`, and at most 0.0024 for a `t4g.micro`), an 8 GB root volume, and metrics and logs. CloudFront and Lambda stay inside the free tier. A Route 53 zone is yours to add.

## Verification

```sh
terraform init -backend=false && terraform test
terraform -chdir=modules/<name> init -backend=false && terraform -chdir=modules/<name> test
pip install -r requirements-dev.txt && pytest
sh scripts/tests/run.sh
pre-commit run --all-files
```

Unit tests cannot start a bot. Before a release, build Eggdrop on Amazon Linux 2023, point the rendered config at a throwaway IRC server, and check that it joins, ops a listed mask only in the channels that list it, ignores a stranger, ignores a non-owner's `status`, publishes `SiteUp` and answers `status`.

## Limits

- One bot, one instance, in whichever zone has Spot capacity. Any replacement, whether a Spot reclaim or a config change, takes minutes and the bot is off IRC for that time: the compile is the longest step.
- Nick collisions after a replacement: the old nick lingers on the server until it times out. The bot takes its alternate nick and reclaims the primary.
- The status page lists only what the status-page core can see from AWS. The bot reports no host metrics.
