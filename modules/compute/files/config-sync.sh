#!/bin/sh
# Applies a changed roster (config/eggdrop.tcl) from the bot bucket: replaces
# the live script and reloads the running bot, which rehashes without
# dropping its IRC connection. Usage: config-sync.sh BUCKET
set -eu

readonly SCRIPT_DIR="${EGGDROP_SCRIPTS_DIR:-/opt/eggdrop/scripts}"
readonly SCRIPT="$SCRIPT_DIR/eggdrop.tcl"
readonly KEY="config/eggdrop.tcl"

log() {
  echo "[config-sync] $*"
}

main() {
  _main_bucket="$1"
  _main_tmp="$(mktemp "$SCRIPT_DIR/eggdrop.tcl.XXXXXX")"
  if ! aws s3 cp "s3://$_main_bucket/$KEY" "$_main_tmp" --only-show-errors; then
    rm -f "$_main_tmp"
    log "fetch failed; keeping the current roster"
    return 1
  fi
  if cmp -s "$_main_tmp" "$SCRIPT"; then
    rm -f "$_main_tmp"
    return 0
  fi
  chown eggdrop "$_main_tmp"
  mv "$_main_tmp" "$SCRIPT"
  log "roster changed"
  if systemctl is-active --quiet eggdrop.service; then
    systemctl reload eggdrop.service
    log "eggdrop reloaded"
  fi
}

main "$@"
