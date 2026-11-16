# terraform-aws-eggdrop

Terraform module for a stateless [Eggdrop](https://www.eggheads.org/) IRC bot on an AWS Spot instance, IPv6-only by default, with a status page.

The bot holds ops in your channels and ops the users you list when they join. It exists for networks without ChanServ, where a channel keeps its ops only while someone with ops stays in it: it runs several bots that op each other, so one that reconnects is opped by a peer that stayed. A client never re-ops a bot that rejoins an occupied channel.

Nothing persists. The instance rebuilds its userfile from the module's inputs on every boot, so there is no data volume and no backup. A replacement compiles the pinned Eggdrop release from an S3 bucket the module owns.

## What it builds

| Module | Resources |
| --- | --- |
| `modules/network` | IPv6-only VPC with a subnet in every availability zone, egress-only internet gateway, S3 gateway endpoint, EC2 Instance Connect Endpoint. No public IPv4 unless `ipv4_enabled`, and no inbound path. |
| `modules/compute` | Spot Auto Scaling group of `bots` instances across every zone and six burstable types (`t3a`, `t3` and `t4g` nano and micro, x86_64 and arm64), stock Amazon Linux 2023 with unattended security updates, the bot bucket, the rendered Eggdrop config, and a launch hook that holds each new bot in `Pending:Wait` until it is in its channels. |
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

  irc_servers = [{ host = "irc.example.net" }]
  net_type    = "EFnet"
  channels    = { "#example" = { ops = ["alice"] } }
  users       = { alice = ["*!*alice@2001:db8:1:2??:*"] }
  owner       = "alice"

  eggdrop = { version = "1.10.2", sha256 = "<sha256 of eggdrop-1.10.2.tar.gz>" }
}
```

See `examples/minimal`. Pin a literal `?ref=vX.Y.Z`; before 1.0 a minor release may break.

| Input | Meaning |
| --- | --- |
| `domain_name`, `zone_id` | Apex domain for the status page and its Route 53 zone. |
| `alert_email` | Receives the DOWN and RECOVERED emails. |
| `irc_servers` | List of `{ host, port = 6697 }` for one IRC network: 1 to 50 unique pairs, tried in order, wrapping at the end. TLS over IPv6, so each host needs an AAAA record unless `ipv4_enabled`. Egress opens once per distinct port. |
| `net_type` | Eggdrop's `net-type` for the network of `irc_servers`: EFnet, IRCnet, Undernet, DALnet, Libera, freenode, QuakeNet, Rizon or Other. Each bot's ident and realname follow its claimed nick from its next connect. |
| `channels` | Channels to join, each with `ops`: the handles in `users` the bot ops there. |
| `users` | Handle to hostmask patterns of the people the bot recognises. |
| `owner` | The handle in `users` that may request a status page link. It gets no ops unless a channel lists it. |
| `eggdrop` | `{ version, sha256 }` of the release to compile. |
| `nicks`, `bots` | Optional, `["eggdrop"]` and `1`. The names the bots take, and how many run. Every bot boots as the first nick; one that holds no listed name takes the next free one each minute, so a replacement fills the gap. `bots` is at least the number of nicks, and extra bots keep a default name. Use two or more to keep ops through a reclaim. |
| `spot_enabled`, `active` | Optional: Spot or On-Demand (`true`), sleep switch (`true`). |
| `image_ids` | Optional, `null`. `{ arm64, x86_64 }` AMI IDs of an Amazon Linux 2023 release to launch. Null tracks the latest, so each AWS release replaces the instance on the next apply. A pinned image that is stale warns on every plan. |
| `ipv4_enabled` | Optional, `false`. Gives the instance a public IPv4 address, about 3.65 USD a month, and opens the IRC port over IPv4, for servers with no AAAA record. |

### Masks

The bot's address changes with every replacement, but a client's does not leave its VPC's `/56`. Match the ident and the `/56` rather than a full address. For the `/56` `2001:db8:1:200::/56`, the fourth group runs `2??`:

```
*!*alice@2001:db8:1:2??:*
```

The module adds the handle `peers` for the bots' own address ranges (each subnet's `/64`), opped in every channel. `users` and `nicks` may not use that handle.

## Operating

1. Apply. The instance waits for the Eggdrop tarball, up to 30 minutes. In an account that has never launched a Spot instance, the first launch fails with "Authentication Failure" while AWS creates its Spot service-linked role. Apply again: the failed Auto Scaling group is replaced.
2. Upload it. The script checks the hash before the bucket sees it, and the instance checks it again:

   ```sh
   scripts/upload.sh --version 1.10.2 --sha256 <hash> --bucket "$(terraform output -raw bucket_name)"
   ```

3. Op one bot once from a client that has ops. It ops the other, and from then on the bots op each other. A bot that rejoins a channel with no peer in it is not opped until someone ops it.
4. Message the bot `status` from a client whose hostmask matches `owner`. It replies with a link that signs you in for 12 hours.

To upgrade from v0.1.0, apply with `active = false` first, then apply the new version with `active = true`: the subnets are replaced, which cannot happen while an instance is running in the old one.

To roll out a new Eggdrop version, upload the new tarball, then change `eggdrop`. Changes to `channels`, `users` and `owner` do not replace the instance: the bot checks the bucket every minute and, when the roster differs, reloads in place without leaving IRC. A channel removed from `channels` is dropped from the bot's list but not necessarily parted. Any other change to the rendered config, to `nicks`, `irc_servers` or `image_ids`, or a new status key refreshes the instances one at a time: each new bot waits in `Pending:Wait` until it is in its channels, and the old one is retired after. The refresh needs a peer in place to op the new bot, so it keeps ops with two or more bots; `terraform output asg_name` names the group for a manual `aws autoscaling start-instance-refresh`.

The roster script (`config/eggdrop.tcl`) is applied to running bots in place, but the config reaches a bot only when its instance is replaced, so the two must stay compatible for one release: the script stubs every proc and variable it takes from the config (`eggdrop_on_slot_server`, `eggdrop_instance_id`, `eggdrop_json_string`, `eggdrop_probes_json`, `eggdrop_nicks`, `eggdrop_umode`, `eggdrop_deaf`).

To update a pinned image, read the latest IDs with `aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-<arch>`, where `<arch>` is `arm64` or `x86_64`, and set `image_ids`. AWS announces releases on an SNS topic in us-east-1 that takes email subscriptions (AL2023 user guide, "Receive update notifications"). IDs are per region. `dnf-automatic` applies security updates to a running instance, so a pin ages gracefully, but a stale one still warns.

## Availability

Each bot publishes the `SiteUp` metric every minute while it is connected to the IRC server, whether or not it holds ops, and nothing while it is not. The status page's schedule writes a 0 for each minute no bot published, so the site is up while any bot is connected, and the alarm fires on any one bad minute of the last three. DOWN and RECOVERED emails, the episode record and the Spot capture of the status page all work from that one metric. With one bot, any replacement counts as an outage in the uptime figures, because the bot is off IRC until the replacement connects. With two or more, an outage is every bot off IRC at once.

Each bot also publishes `GroupSize` in the same call: how many of the `nicks` are in any of its channels, itself included. The `eggdrop-group-size` alarm fires when the smallest value stays below `min(bots, length(nicks))` for 20 minutes, and treats silence as below. It mails the status page's alert topic, and costs about 0.40 USD a month (one custom metric and one alarm, not measured). It catches a dead bot, a bot that cannot connect, a bot on another network and a split between the bots. It is off while `active` is false.

With more than one `irc_servers` entry, the bots spread over the servers by nick slot, so one server's outage or restart leaves the other bot connected and opped, and the dropped bot cycles on and is re-opped by its peer. A split between their servers leaves an opped bot on each side. The slot rule needs the servers to be one network: on separate networks each bot sees only itself, `GroupSize` reads 1 and the alarm fires.

Each bot also publishes `OnSlotServer` in that call: 0 while it sits off its slot server, 1 otherwise (and always with one server or an unlisted name). `GroupSize` cannot see two bots on one server. The `eggdrop-on-slot-server` alarm fires when the smallest value stays 0 for 60 minutes, two jump gates, so a failover the bots cannot undo is noticed; silence is not a breach, because `SiteUp` covers it. It mails the same topic and costs about 0.40 USD a month (one custom metric and one alarm, not measured).

Each bot sends its server events to the `/eggdrop/irc` log group (30-day retention, one stream per instance): the server it tries, its welcome, every disconnect and failed connect, and the text of an `ERROR` line or a 463 or 465 refusal. Channel and private text is never sent. A bot also writes `bots/<instance-id>.json` to the bot bucket when its state changes (member counts excluded) and at least every 15 minutes, and the status page's Bots section reads those: nick, ident (`$::botname`, which carries the bot's IPv6 address), the server entry and the name the server gives itself, when it connected, whether it is on its slot server, its user modes (marked "not deaf" when the deaf mode is missing), each channel's joined, opped and member count, and the snapshot's age, marked stale past 20 minutes. The Servers section lists each `irc_servers` entry with its last accept in 24 hours, its last failure or refusal and the reason, and its latest probe (below). It reads the log newest first, the last hour, then 1 to 6 hours, then 6 to 24 hours, and stops once every entry has an accept and a failure; a window is read up to 20 pages, keeps its newest 2000 events, and is named as truncated if pages remain (the bots log under 300 an hour). Bots shutting down are not listed, and a snapshot that cannot be read shows as such. Both sections sit behind the token gate, never on `/public`.

Each bot also probes the `irc_servers` once a day, starting 10 minutes after its welcome and on its own slot minute: for each entry in turn it resolves the AAAA record, connects over TLS with a random nick, waits up to 30 seconds for the welcome, sends `QUIT` and records the seconds taken or the failure (`no AAAA`, `tls`, `timeout`, the server's `ERROR` line, or a refusal numeric such as `465` with its text; a nick in use is retried once). A probe joins no channel and runs in the background, so the bot's PING replies are not blocked. The result rides in the bot's snapshot, and the Servers section shows the newest across bots as a caption ("probe ok 1.3 s 2026-01-01 03:10Z"). Each server sees one short connection a day per bot: not a flood. A probe that dies writes its error instead, shown as a `probe` row in Servers, and a failed start is logged as `probe_failed`. The probe reports only; the operator edits `irc_servers` after reading it. List every server that might work, ordered by evidence: the bots take slots from the first entries, so those must be proven, and a dead entry costs one `server-timeout` (20 s), not correctness. A server with no AAAA record cannot be reached from the IPv6-only VPC, and an IPv4 address costs about 3.6 USD a month, so such servers are not worth listing.

The status page gate verifies the token in a Lambda with a key in SSM, so it works while the bot is down.

## Privacy

The bot's console, which the systemd unit sends to the journal, never prints channel text on any server: the unit runs `eggdrop -t` with `console "jkcobxs"`, so public text, actions and channel notices (`p`) and private text (`m`) are left out, and joins, modes, misc, commands, bot and server notices and errors stay. (`-n` would print every log line whatever `console` says.) The bots also log `/msg` and CTCP text sent to them (`logfile` flag `m`) under `logs/` on the instance disk until the instance is replaced. Channel text is never written to the server event log or the snapshots, which hold server names, nicks, channel names and counts.

Deaf additionally stops the server delivering channel text to the bot, where the server advertises `DEAF` in its 005 line: the bot sets the mode from that line on, and a server without the token gets no mode and the Bots section then reads "not deaf". The deaf letter is the one the server advertises, and is trusted as such (`D` on ircd-ratbox); if a server uses the token for something else, the status page still shows the mode string. The bots keep joins, parts, nick changes, modes and the member list, which the op sweep, name claim and slot rules need.

Deaf describes the bots, not the channel. Every channel member, every server operator on the path and every server that carries the channel sees the traffic. TLS protects only the hop between a client and its server. Treat channel text on a public network as public.

## Cost

About 3 USD a month for two bots at Spot prices in us-west-2: each instance (about 0.0008 USD an hour at the last check, and at most 0.0024 for a `t4g.micro`) with an 8 GB root volume, plus metrics, alarms and logs (the snapshots add about 6,000 S3 PUTs a month, a few cents; log ingestion is negligible). The second bot's volume and metrics are estimated, not measured; one bot costs about 1.2 USD less. CloudFront and Lambda stay inside the free tier. A Route 53 zone is yours to add.

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

- Each bot is one Spot instance, in whichever zone has capacity. A replacement takes minutes and the bot is off IRC for that time: the compile is the longest step.
- One reclaim at a time keeps ops: the other bot stays in the channels and ops the replacement. Simultaneous reclaims, or `bots = 1`, drop ops until someone re-ops a bot.
- Bots recognise each other by IPv6 address range. A bot connected over IPv4 (`ipv4_enabled`) is not recognised and is not opped by its peers.
- The launch hook is a separate resource, so on the first apply of a version that adds it the group's first instances can launch before it exists.
- A dead or wrong host in `irc_servers` costs a bot one connection attempt (at most 20 s, `server-timeout`) before it moves on; with six dead entries in a row that is about 2 minutes plus the cycle wait of about a minute. If no host answers, no bot connects and the `SiteUp` alarm fires.
- With several servers, the bot wearing `nicks[i]` moves to `irc_servers[i mod length]` and jumps at most once per 30 minutes, so one server outage leaves the other bot on its own server. A bot whose slot server is down cycles on to the next listed server and tries its slot server again after 30 minutes, so a down slot server costs one reconnect per 30 minutes at most. Bots with no listed name stay where they are. With fewer servers than names the index wraps. While the bots share a server (one entry, or before the jump), an outage moves them to the next listed server together; ops survive only if someone else holds the channel, otherwise the first bot to join the empty channel gets ops and the peers op each other.
- Bots jump on staggered minutes (the minute modulo the bot count equals the slot), so never two at once. A bot jumps only while another listed bot is opped in every channel (at least one channel), so moving never drops the last op. Without one it stays on its current server.
- A server split leaves each side with its bots, and the channel merge deops one side when the split heals. The peers op each other afterwards. `GroupSize` is the only signal.
- A list that mixes networks can land the bots on different networks, each seeing an empty channel and opping itself. `SiteUp` stays 1; only the `GroupSize` alarm notices.
- Nick collisions after a replacement: the old nick lingers on the server until it times out. The bot takes its alternate nick and reclaims the primary.
- The status page lists only what the status-page core can see from AWS. The bot reports no host metrics.
