#!/bin/sh
# Picks the nick slot this bot takes before it first connects; see "Slot
# assignment" in the README.
# Usage: eggdrop-slot ASG_NAME SLOT_FILE NICK...
# Environment: EGGDROP_INSTANCE_ID, EGGDROP_BUCKET; SLOT_BOOT_ID_FILE for tests.
set -eu

# A bot rewrites its snapshot every 900 s on a one-minute tick, so a live bot's
# snapshot can be a little over 960 s old.
readonly FRESH_SECONDS=1200
# One attempt per call: the unit bounds the whole run, not each call.
export AWS_MAX_ATTEMPTS=1
readonly BOOT_ID_FILE="${SLOT_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
readonly AWS_TIMEOUTS="--cli-connect-timeout 2 --cli-read-timeout 5"
NOW="$(date +%s)"
readonly NOW

log() {
  echo "[eggdrop-slot] $*" >&2
}

# One line per instance: id, lifecycle state, launch template id and version.
# A bot waiting on its launch hook is Pending:Wait and already holds its nick.
list_peers() {
  # shellcheck disable=SC2086 # AWS_TIMEOUTS is two options
  aws autoscaling describe-auto-scaling-groups $AWS_TIMEOUTS \
    --auto-scaling-group-names "$1" \
    --query 'AutoScalingGroups[0].Instances[].[InstanceId,LifecycleState,LaunchTemplate.LaunchTemplateId,LaunchTemplate.Version]' \
    --output text
}

# Prints bots/KEY, or nothing when it does not exist. Any other failure is an
# error: the peer may hold a slot. Stderr goes to ERR_FILE, apart from the
# object, and is read only to tell a missing object from the rest.
read_object() {
  # shellcheck disable=SC2086
  if _read_out="$(aws s3 cp "s3://$EGGDROP_BUCKET/bots/$1" - $AWS_TIMEOUTS --only-show-errors 2>"$ERR_FILE")"; then
    rm -f "$ERR_FILE"
    printf '%s' "$_read_out"
    return 0
  fi
  if grep -q '(404)' "$ERR_FILE"; then
    rm -f "$ERR_FILE"
    return 0
  fi
  cat "$ERR_FILE" >&2
  rm -f "$ERR_FILE"
  return 1
}

is_number() {
  case "$1" in
  '' | *[!0-9]*) return 1 ;;
  esac
}

# The slot named by a fresh marker "SLOT UPDATED", else nothing. COUNT is the
# number of listed nicks.
marker_slot() {
  # shellcheck disable=SC2086 # two words
  set -- $1 "$2"
  if [ "$#" -eq 3 ] && is_number "$1" && is_number "$2" && [ "$1" -lt "$3" ] && [ $((NOW - $2)) -le "$FRESH_SECONDS" ]; then
    echo "$1"
  fi
}

snapshot_field() {
  printf '%s' "$2" | sed -n "s/.*\"$1\":\"\\{0,1\\}\\([^\",}]*\\).*/\\1/p"
}

# What a peer's files say about it, given the listed nicks: "held N" when it
# wears the nick at index N or has published a fresh marker for N, "claimant"
# when it has no snapshot yet or wears another nick, "ignore" when the snapshot
# is stale or malformed.
peer_role() {
  _role_json="$1"
  _role_marker="$2"
  shift 2
  _role_held="$(marker_slot "$_role_marker" "$#")"
  if [ -n "$_role_held" ]; then
    echo "held $_role_held"
    return 0
  fi
  if [ -z "$_role_json" ]; then
    echo claimant
    return 0
  fi
  _role_updated="$(snapshot_field updated "$_role_json")"
  _role_nick="$(snapshot_field nick "$_role_json")"
  if ! is_number "$_role_updated" || [ $((NOW - _role_updated)) -gt "$FRESH_SECONDS" ]; then
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

# The launch template (id and version) of instance ID in the listing PEERS.
template_of() {
  printf '%s\n' "$2" | while read -r _tpl_id _tpl_state _tpl_template _tpl_version; do
    if [ "$_tpl_id" = "$1" ]; then
      echo "$_tpl_template $_tpl_version"
    fi
  done
}

# Prints "slot N" for a free slot, "server N" for a spare whose retiring peer
# holds slot N, or nothing. Fails when it cannot tell.
choose_slot() {
  _choose_asg="$1"
  shift
  _choose_peers="$(list_peers "$_choose_asg")" || return 1
  _choose_own="$(template_of "$EGGDROP_INSTANCE_ID" "$_choose_peers")"
  _choose_held=""
  _choose_older=""
  _choose_unsettled="$EGGDROP_INSTANCE_ID"
  while read -r _choose_id _choose_state _choose_template _choose_version; do
    case "$_choose_state" in
    InService | Pending | Pending:Wait | Pending:Proceed) ;;
    *) continue ;;
    esac
    [ "$_choose_id" != "$EGGDROP_INSTANCE_ID" ] || continue
    _choose_json="$(read_object "$_choose_id.json")" || return 1
    _choose_marker="$(read_object "$_choose_id.slot")" || return 1
    _choose_role="$(peer_role "$_choose_json" "$_choose_marker" "$@")"
    _choose_peer_slot=x
    case "$_choose_role" in
    "held "*)
      _choose_peer_slot="${_choose_role#held }"
      _choose_held="$_choose_held $_choose_peer_slot"
      ;;
    claimant) _choose_unsettled="$_choose_unsettled $_choose_id" ;;
    esac
    if [ -n "$_choose_own" ] && [ "$_choose_template $_choose_version" != "$_choose_own" ] && [ "$_choose_role" != ignore ]; then
      _choose_older="$_choose_older $_choose_peer_slot"
    fi
  done <<EOF
$_choose_peers
EOF
  _choose_free="$(free_slot "$#" "$_choose_held" "$(rank_of "$EGGDROP_INSTANCE_ID" "$_choose_unsettled")")"
  if [ -n "$_choose_free" ]; then
    echo "slot $_choose_free"
    return 0
  fi
  # shellcheck disable=SC2086 # a word list
  set -- $_choose_older
  case "$#:${1:-}" in
  1:[0-9]*) echo "server $1" ;;
  esac
}

# A slot file from this boot survives a service restart; one from an earlier
# boot is stale.
slot_file_is_current() {
  [ -f "$1" ] && [ "$(sed -n '1s/^# boot //p' "$1")" = "$(cat "$BOOT_ID_FILE")" ]
}

write_slot() {
  _write_tmp="$1.tmp"
  printf '# boot %s\nset eggdrop_boot_%s\n' "$(cat "$BOOT_ID_FILE")" "$2" >"$_write_tmp"
  mv "$_write_tmp" "$1"
}

# Peers read it to see a slot taken before the bot's first snapshot exists.
publish_marker() {
  # shellcheck disable=SC2086
  printf '%s %s' "$1" "$NOW" | aws s3 cp - "s3://$EGGDROP_BUCKET/bots/$EGGDROP_INSTANCE_ID.slot" $AWS_TIMEOUTS --only-show-errors ||
    log "could not publish the slot marker"
}

main() {
  if [ "$#" -lt 3 ]; then
    echo "usage: eggdrop-slot ASG_NAME SLOT_FILE NICK..." >&2
    return 2
  fi
  _main_asg="$1"
  _main_file="$2"
  shift 2
  ERR_FILE="$_main_file.err"
  readonly ERR_FILE
  trap 'log "timed out; booting as the first nick"; rm -f "$_main_file" "$ERR_FILE"; exit 0' TERM
  if slot_file_is_current "$_main_file"; then
    return 0
  fi
  rm -f "$_main_file"
  if [ -z "${EGGDROP_INSTANCE_ID:-}" ] || [ -z "${EGGDROP_BUCKET:-}" ]; then
    log "no instance id or bucket; booting as the first nick"
    return 0
  fi
  if ! _main_choice="$(choose_slot "$_main_asg" "$@")"; then
    log "could not read the group or its snapshots; booting as the first nick"
    return 0
  fi
  if [ -z "$_main_choice" ]; then
    log "every slot is held; booting as a spare"
    return 0
  fi
  write_slot "$_main_file" "$_main_choice"
  case "$_main_choice" in
  "slot "*) publish_marker "${_main_choice#slot }" ;;
  esac
  log "$_main_choice"
}

main "$@"
