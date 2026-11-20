#!/bin/sh
# Picks the nick slot this bot takes before it first connects, so it joins its
# slot server as its slot nick instead of moving there later. Writes SLOT_FILE
# with "set eggdrop_boot_slot N", which eggdrop.conf reads. Writes nothing, and
# exits 0, when the group or a snapshot cannot be read or no slot is free: the
# bot then boots as the first nick and claims one later.
# Usage: eggdrop-slot ASG_NAME SLOT_FILE NICK...
# Environment: EGGDROP_INSTANCE_ID, EGGDROP_BUCKET; SLOT_BOOT_ID_FILE for tests.
set -eu

# A bot rewrites its snapshot every 900 s on a one-minute tick, so a live bot's
# snapshot can be a little over 960 s old.
readonly FRESH_SECONDS=1200
readonly BOOT_ID_FILE="${SLOT_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
readonly AWS_TIMEOUTS="--cli-connect-timeout 5 --cli-read-timeout 10"
NOW="$(date +%s)"
readonly NOW

log() {
  echo "[eggdrop-slot] $*" >&2
}

# Peers that are or will be serving: a bot waiting on its launch hook is
# Pending:Wait and already holds its nick.
list_peers() {
  # shellcheck disable=SC2086 # AWS_TIMEOUTS is two options
  aws autoscaling describe-auto-scaling-groups $AWS_TIMEOUTS \
    --auto-scaling-group-names "$1" \
    --query 'AutoScalingGroups[0].Instances[].[InstanceId,LifecycleState]' \
    --output text
}

# Prints the snapshot, or nothing when the bot has written none. A failure
# other than a missing object is an error: the peer may hold a slot.
read_snapshot() {
  # shellcheck disable=SC2086
  if _read_out="$(aws s3 cp "s3://$EGGDROP_BUCKET/bots/$1.json" - $AWS_TIMEOUTS --only-show-errors 2>&1)"; then
    printf '%s' "$_read_out"
    return 0
  fi
  case "$_read_out" in
  *"(404)"*) return 0 ;;
  esac
  echo "$_read_out" >&2
  return 1
}

snapshot_field() {
  printf '%s' "$2" | sed -n "s/.*\"$1\":\"\\{0,1\\}\\([^\",}]*\\).*/\\1/p"
}

# What a peer's snapshot says about it, given the listed nicks: "held N" when it
# wears the nick at index N, "claimant" when it has no snapshot yet or wears
# another nick (it will take a free slot), "ignore" when the snapshot is stale.
# A disconnected bot keeps its nick for its reconnect, so it holds its slot.
peer_role() {
  _role_json="$1"
  shift
  if [ -z "$_role_json" ]; then
    echo claimant
    return 0
  fi
  _role_updated="$(snapshot_field updated "$_role_json")"
  _role_nick="$(snapshot_field nick "$_role_json")"
  if [ -z "$_role_updated" ] || [ $((NOW - _role_updated)) -gt "$FRESH_SECONDS" ]; then
    echo ignore
    return 0
  fi
  _role_index=0
  for _role_name in "$@"; do
    if [ "$_role_name" = "$_role_nick" ]; then
      echo "held $_role_index"
      return 0
    fi
    _role_index=$((_role_index + 1))
  done
  echo claimant
}

# The r-th (from 0) slot of 0..COUNT-1 not named in HELD.
free_slot() {
  _free_count="$1"
  _free_held=" $2 "
  _free_rank="$3"
  _free_index=0
  while [ "$_free_index" -lt "$_free_count" ]; do
    case "$_free_held" in
    *" $_free_index "*) ;;
    *)
      if [ "$_free_rank" -eq 0 ]; then
        echo "$_free_index"
        return 0
      fi
      _free_rank=$((_free_rank - 1))
      ;;
    esac
    _free_index=$((_free_index + 1))
  done
}

# Position of ID among the sorted words of IDS.
rank_of() {
  _rank_position=0
  # shellcheck disable=SC2086 # IDS is a word list
  for _rank_id in $(printf '%s\n' $2 | sort); do
    [ "$_rank_id" != "$1" ] || break
    _rank_position=$((_rank_position + 1))
  done
  echo "$_rank_position"
}

# Prints the slot, or nothing for a spare. Fails when it cannot tell.
choose_slot() {
  _choose_asg="$1"
  shift
  _choose_peers="$(list_peers "$_choose_asg")" || return 1
  _choose_held=""
  _choose_unsettled="$EGGDROP_INSTANCE_ID"
  while read -r _choose_id _choose_state; do
    case "$_choose_state" in
    InService | Pending | Pending:Wait | Pending:Proceed) ;;
    *) continue ;;
    esac
    [ "$_choose_id" != "$EGGDROP_INSTANCE_ID" ] || continue
    _choose_json="$(read_snapshot "$_choose_id")" || return 1
    _choose_role="$(peer_role "$_choose_json" "$@")"
    case "$_choose_role" in
    "held "*) _choose_held="$_choose_held ${_choose_role#held }" ;;
    claimant) _choose_unsettled="$_choose_unsettled $_choose_id" ;;
    esac
  done <<EOF
$_choose_peers
EOF
  free_slot "$#" "$_choose_held" "$(rank_of "$EGGDROP_INSTANCE_ID" "$_choose_unsettled")"
}

# A slot file from this boot survives a service restart; one from an earlier
# boot is stale.
slot_file_is_current() {
  [ -f "$1" ] && [ "$(sed -n '1s/^# boot //p' "$1")" = "$(cat "$BOOT_ID_FILE")" ]
}

write_slot() {
  _write_tmp="$1.tmp"
  printf '# boot %s\nset eggdrop_boot_slot %s\n' "$(cat "$BOOT_ID_FILE")" "$2" >"$_write_tmp"
  mv "$_write_tmp" "$1"
}

main() {
  if [ "$#" -lt 3 ]; then
    echo "usage: eggdrop-slot ASG_NAME SLOT_FILE NICK..." >&2
    return 2
  fi
  _main_asg="$1"
  _main_file="$2"
  shift 2
  if slot_file_is_current "$_main_file"; then
    return 0
  fi
  rm -f "$_main_file"
  if [ -z "${EGGDROP_INSTANCE_ID:-}" ] || [ -z "${EGGDROP_BUCKET:-}" ]; then
    log "no instance id or bucket; booting as the first nick"
    return 0
  fi
  if ! _main_slot="$(choose_slot "$_main_asg" "$@")"; then
    log "could not read the group or its snapshots; booting as the first nick"
    return 0
  fi
  if [ -z "$_main_slot" ]; then
    log "every slot is held; booting as a spare"
    return 0
  fi
  write_slot "$_main_file" "$_main_slot"
  log "slot $_main_slot"
}

main "$@"
