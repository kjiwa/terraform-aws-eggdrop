# Changelog

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
