# Changelog

## v0.11.0

Upgrading: the first plan changes the launch templates, the instance role's policy and the group's refresh warmup, so Terraform starts one make-before-break refresh. The first replacement of that refresh joins as a spare on the first server and moves once; the second joins the server of the bot it replaces.

### Added

- Slot-first join: before each start the bot reads its peers and connects as its slot nick to its slot server, instead of booting as the first nick on the first server and moving later (see "Slot assignment" in the README). A bot that finds every slot held and has exactly one peer on an older launch template connects to that peer's server. The instance role gains `autoscaling:DescribeAutoScalingGroups` and `s3:GetObject` on `bots/*`.
- `bots` must be at most 10.
- Tests: `scripts/tests/test_slot.sh` and `scripts/tests/test_conf.sh` (tclsh, with Eggdrop's commands stubbed; needs `tclsh` and `terraform`).

### Changed

- The launch hook is released when a channel's NAMES list ends after the bot's join, not on the next minute tick; the 300 s fallback stays. `instance_warmup` is 30 s, down from 60.
- Boot is shorter: the swap file is preallocated, Eggdrop compiles with `make -j2`, and `dnf-automatic` is installed after the bot starts.
- Status links last 1 hour, not 12. The token format is unchanged, so the status page verifier accepts it.
- The eggdrop unit sets `CapabilityBoundingSet=` (none), `RestrictAddressFamilies`, `ProtectKernelTunables`, `ProtectKernelModules` and `ProtectControlGroups`.

### Fixed

- Channel or private text such as `Trying server evil:6697` could forge a server event in `/eggdrop/irc`; the log binds now accept only the bot's own server log lines.

## v0.10.0

Upgrading with `image_ids` null: the first plan adds `terraform_data.image_pin`, the updater Lambda, its role and policy, log group, schedule rule and target, and two alarms, and changes no launch template, ASG or instance. Unpinned bots keep their current image until their next replacement.

### Added

- The keel `ami-updater` module (v0.4.0) runs when `image_ids` is null. It writes a launch template version for each new Amazon Linux 2023 release once it is a day old and points the group at it; it starts a make-before-break refresh only when a running bot's AMI is over `ami_max_age_days` (new, default 14) old, and alarms notify the alerts topic when a running AMI is 7 days past that limit and when the updater fails. Compute outputs `launch_template_ids` and `refresh_preferences` (shared by the group's own instance refresh); monitoring outputs `alarm_topic_arn` and `outage_alarm_names`.
- Root output `irc_log_group_name`.

### Changed

- Launch templates ignore changes to `image_id`: AWS releases no longer show in a plan, and unpinned bots adopt a new image at their next replacement instead of at the next apply. A change to `image_ids` replaces the templates.

### Removed

- The `image_is_latest` stale-pin check; a pin is the operator's to keep current.

### Fixed

- The `channels` description says `SiteUp` follows the connection, not ops.

## v0.9.0

### Added

- `net_type` (required): Eggdrop's `net-type` for the network of `irc_servers`, one of EFnet, IRCnet, Undernet, DALnet, Libera, freenode, QuakeNet, Rizon or Other. It was hard-coded to EFnet.
- Each bot's ident (`username`) and realname follow its nick, and a bot that claims a listed nick sets both to it, applied at its next connect. Before, every bot connected as `<nick>!~<first nick>`.

### Removed

- `admin` and `network` from the config. Neither was visible: the module has no `listen` line and no inbound path.

### Upgrade

- `net_type` is required. Set `net_type = "EFnet"` for the old behavior.
- Boot files change, so the apply refreshes the bots one at a time.

## v0.8.1

### Added

- The bot never prints channel text to its console, so none reaches the journal. The cause was `eggdrop -n`: in Eggdrop 1.10.2 the flag is a no-op that runs in the foreground with no terminal, and `putlog` then writes every log line to stdout whatever the `console` setting says. The unit now runs `-t`, the only foreground mode that filters stdout by `console`, with `set console "jkcobxs"` (no `p`, no `m`). `-t` exits on end of file, so stdin is a FIFO the bot opens read-write itself (`eggdrop.stdin`, mode 0600, recreated by `prestart.sh`). Joins, modes, misc, commands, bot and server notices and errors stay in the journal.
- Deaf bots: when the server's `DEAF` token (005) names a letter, the bot sets that user mode, so the server stops delivering channel messages to it. A server without the token gets no mode.
- The bot reads its user modes back (221) and stores them, only when the text has the shape `nick +modes`. The snapshot carries `umode` and `deaf`, both cleared on disconnect; the Bots row shows `mode +iD` and says "not deaf" in its caption when the deaf letter is not among the mode letters or the server has no token. A snapshot without `umode` makes no claim.
- One umode query timer is pending at most: a reconnect cancels the previous one.
- The roster script stubs two more config variables (`eggdrop_deaf`, `eggdrop_umode`), so it still applies in place to a bot whose config is v0.8.0 or older.

### Upgrade

- Boot files change, so the apply refreshes the bots one at a time.
- `logfile` keeps `m`: `/msg` and CTCP text sent to a bot stays in `logs/` on the instance disk until the instance is replaced.
- A running bot keeps `-n` and the old console until its instance is replaced.

## v0.8.0

### Added

- Server probe: once a day, from 10 minutes after its welcome and on its slot minute, each bot resolves the AAAA record of every `irc_servers` entry, connects over TLS with a random nick, waits up to 30 s for the welcome and quits, never joining a channel and in the background. The result is in the bot's snapshot (`probes`), and the status page's Servers section shows the newest probe across bots per entry. The probe is a boot file, `eggdrop-probe`.
- The probe fails fast on a registration refusal (463, 464, 465, 432, 484, `ERROR`) with the numeric and text, retries a nick in use (433) once, keeps the whole entry inside its 30 s, and ignores a failed `QUIT` after a welcome. If it dies it writes `probes.json` with a top-level `error`, and the status page shows a `probe` row in Servers; a failed exec logs a `probe_failed` line to the server event log. A malformed probe block is skipped.
- The Bots and Servers sections share one read of the group and the snapshots per request.
- The roster script stubs each config symbol it uses (`eggdrop_on_slot_server`, `eggdrop_instance_id`, `eggdrop_json_string`, `eggdrop_probes_json`, `eggdrop_nicks`) and skips the snapshot without `EGGDROP_BUCKET`, so it applies in place to a bot whose config is a release older. On v0.7.0 a v0.6.0 config made every heartbeat fail, so `SiteUp` stopped.

### Changed

- `server-timeout` is 20 s (Eggdrop's default is 60): a dead `irc_servers` entry costs 20 s.
- The Servers section reads the log newest first in three windows (1 h, 1 to 6 h, 6 to 24 h) and stops when every entry has an accept and a failure, so a busy log no longer hides the latest accept. A window is read up to 20 pages and keeps its newest 2000 events (the log returns oldest first, so the newest are never the ones dropped); one that still has pages left is named as truncated.

### Upgrade

- Boot files change, so the apply refreshes the bots one at a time.
- Each listed server sees one more short connection a day per bot.

## v0.7.0

### Added

- Server event log: each bot sends its connect attempts, welcomes, disconnects, failed connects and the text of `ERROR`, 463 and 465 refusals to the `/eggdrop/irc` log group (30-day retention, a stream per instance, created at boot). Channel and private text is not sent.
- Bot snapshot: each bot writes `bots/<instance-id>.json` to the bot bucket when its channels, server or connection state change (member counts do not count as a change) and at least every 15 minutes. The status page gains a Bots section (nick, ident, server, connect time, slot, channels, snapshot age) and a Servers section (last accept and last failure or refusal per `irc_servers` entry over 24 hours, reading at most 5 pages or 2000 events and saying "truncated" past that), behind the token gate only.
- `OnSlotServer`, published with `SiteUp` and `GroupSize`: 0 while a bot sits off its slot server. The `eggdrop-on-slot-server` alarm fires after 60 minutes of 0, with silence not a breach, and mails the status page alert topic.
- Instance role: `s3:PutObject` on `bots/*` and `logs:CreateLogStream` and `logs:PutLogEvents` on the log group. Status plugin role: `s3:GetObject` on `bots/*`, `s3:ListBucket`, `autoscaling:DescribeAutoScalingGroups` and `logs:FilterLogEvents` on the log group.
- The status module takes `bot_bucket`, `irc_log_group` and `irc_servers`; the compute module outputs `irc_log_group_name`.

### Changed

- A boot that cannot read its instance id from the metadata service starts the bot anyway, without server events or snapshots.
- The `eggdrop-on-slot-server` window is derived from the jump gate (two gates), not written beside it.
- `eggdrop_servers` is rendered with one server too, and the slot lookup is shared by the jump and the new metric.

### Upgrade

- Boot files change, so the apply refreshes the bots one at a time.
- The new alarm starts clear. It costs about 0.40 USD a month with the metric.

## v0.6.0

### Changed

- With more than one `irc_servers` entry, the bot wearing `nicks[i]` moves to `irc_servers[i mod length]`, so one server's outage leaves the other bot opped. Bots jump on staggered minutes (the minute modulo the bot count equals the slot), at most once per 30 minutes, and only while another listed bot is opped in every channel (at least one); a bot that failed over returns to its slot server after the gate. With one entry the rendered config is unchanged. A bot with no listed name stays where it is.
- Status page modules at v0.8.0.

### Upgrade

- The bots on a list of two or more servers move to their slot servers one minute after they claim a name. The servers must be one network: on separate networks each bot sees only itself, `GroupSize` reads 1 and the `eggdrop-group-size` alarm fires.
- Status page v0.8.0 changes the payload shape; the apply redeploys the status Lambda and web build.

## v0.5.0

### Changed

- `irc_server` is now `irc_servers`, a list of `{ host, port = 6697 }` for one network: 1 to 50 pairs, unique ignoring the case of the host, with ports 1 to 65535 and hostnames or IPv4 addresses only. The bots try them in order and wrap at the end. The network module takes `irc_ports` and opens egress once per distinct port.
- The root `channels` description no longer says `SiteUp` depends on ops.

### Added

- `GroupSize`: each bot publishes how many of the `nicks` share one of its channels, in the same call as `SiteUp`.
- The `eggdrop-group-size` alarm in `modules/monitoring`: minimum `GroupSize` below `min(bots, length(nicks))` for 20 one-minute periods, missing data counted as below, mailed through the status page alert topic. The monitoring module takes `group_size`.

### Upgrade

- Rename `irc_server = { host = "h" }` to `irc_servers = [{ host = "h" }]`.
- The apply refreshes the bots one at a time.
- The IRC egress rules move to per-port addresses in state. A non-default port plans a destroy and create of one rule.
- The alarm needs the group at `min(bots, length(nicks))` for 20 minutes before it clears, so a refresh that takes a bot out for longer than that alarms.

## v0.4.0

### Changed

- `nick` is now `nicks`, a list. Every bot boots as the first and claims the first free name in the list.
- `SiteUp` is 1 while any bot is connected to the IRC server, ops or not. A disconnected bot publishes nothing, where it published 0.
- The `irc_server` and `irc_port` descriptions, the README intro and the network comments now say IPv4 is available with `ipv4_enabled`, and that the instance has no Session Manager access because its role grants none.
- A refresh adds one bot before it retires one, and each new bot waits in `Pending:Wait` until it is in its channels. Capacity rebalancing is on. Status page modules at v0.7.2.

### Added

- `bots`: how many bots the group runs, at least the number of `nicks`.
- A launch hook and the `eggdrop-ready` script that completes it, with the IAM permission to do so.
- The `peers` handle: each subnet's `/64` is opped in every channel, so the bots op each other. `network` outputs `subnet_ipv6_cidr_blocks`.
- After a roster reload, members who now match are opped without rejoining.

### Upgrade

- Rename `nick` to `nicks` (for example `["naju", "zera"]`) and set `bots`.
- The apply refreshes the bots one at a time: the old bot gets the `peers` grant in place, each new bot joins and is opped by it, and the old bot goes last.
- The refresh can start before the hook exists. Create it first with `aws autoscaling put-lifecycle-hook --auto-scaling-group-name eggdrop --lifecycle-hook-name launching --lifecycle-transition autoscaling:EC2_INSTANCE_LAUNCHING --heartbeat-timeout 3600 --default-result ABANDON`, or accept one refresh without the gate.

## v0.3.0

### Changed

- `SiteUp` is 1 while the bot is connected to the IRC server, whether or not it holds ops. Before, a channel where the bot lacked ops counted as down.
- Changes to `channels`, `users` and `owner` apply in place. The instance polls the bot bucket every minute and reloads Eggdrop when the roster differs; the launch template no longer changes, so there is no instance refresh. Status page modules at v0.7.1.

### Added

- `image_ids`: pin the Amazon Linux 2023 image per architecture. A stale pin warns on every plan.

### Upgrade

- Applying replaces the instance once: the launch template gains the sync script and units. A pin set at the same time adds nothing further.

## v0.2.3

### Changed

- Any bad minute of the last three raises the DOWN alarm, so a short disconnect is no longer missed. A minute the bot missed is recorded as a 0 (status page modules at v0.7.0).

### Upgrade

- Applying replaces the status page's schedule rule and Lambda permission; nothing else changes.

## v0.2.2

### Changed

- Every outage counts toward the status page's uptime, including instance refreshes and other deliberate replacements: any replacement drops the bot's ops until someone re-ops it. Status page modules at v0.6.0.

## v0.2.1

### Changed

- Status page modules at v0.5.0: an outage with no heartbeat is recorded for its whole length, the RECOVERED email without a recorded outage no longer claims a sleep, and the Storage card and machine image omit rows with no value.
- Upgrading from v0.1.0: set `active = false` and apply, then upgrade and set it back. A direct upgrade deadlocks: the old subnet cannot be deleted while the instance holds an interface in it, and the instance replacement starts without a route.

## v0.2.0

### Changed

- Breaking: `ops` is now `users` (handle to hostmasks), and `channels` is a map from channel name to `{ ops = [handles] }`. A user is opped only in the channels that list them, through channel flags. Migrate `ops = { alice = [...] }` with `channels = ["#a", "#b"]` to `users = { alice = [...] }` with `channels = { "#a" = { ops = ["alice"] }, "#b" = { ops = ["alice"] } }`.
- The `status` command is gated by the `owner` handle instead of the `+n` flag, so no user holds global flags and the owner gets no ops unless a channel lists them.
- The network module creates a subnet in every availability zone and drops its `az` input, and the ASG draws Spot capacity from every zone. Applying replaces the v0.1.0 subnet and the instance connect endpoint, and the ASG replaces the instance.
- The ASG draws from `t3a.nano`, `t3.nano`, `t3a.micro`, `t3.micro`, `t4g.nano` and `t4g.micro`, with a launch template and AL2023 image for each architecture.

### Added

- `ipv4_enabled` (default `false`): an internet gateway, a default IPv4 route, a public address and IRC-port egress over IPv4, for servers with no AAAA record.

## v0.1.0

### Added

- Initial release: network, compute, monitoring, status and edge modules for a stateless Eggdrop op bot on IPv6-only Spot, with a status page behind an HMAC token.
