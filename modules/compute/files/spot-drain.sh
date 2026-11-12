#!/bin/sh
# Polls IMDSv2 for the EC2 Spot interruption notice (issued about two minutes
# before reclaim) and stops eggdrop.service on notice. Eggdrop then QUITs the
# IRC server instead of timing out, so the replacement's nick is free sooner.
# Covers Spot reclaims only: ASG terminations do not emit the notice.
set -eu

readonly IMDS="http://169.254.169.254/latest"
readonly POLL_SECONDS=5

log() {
  echo "[spot-drain] $*"
}

imds_token() {
  curl -sf -m 2 -X PUT "$IMDS/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}

main() {
  _main_token=""
  log "Watching $IMDS/meta-data/spot/instance-action every ${POLL_SECONDS}s..."
  while :; do
    if [ -z "$_main_token" ]; then
      _main_token="$(imds_token)" || _main_token=""
    fi
    if [ -n "$_main_token" ]; then
      _main_code="$(curl -s -o /dev/null -w '%{http_code}' -m 2 \
        -H "X-aws-ec2-metadata-token: $_main_token" \
        "$IMDS/meta-data/spot/instance-action")" || _main_code=000
      case "$_main_code" in
      200)
        log "Spot interruption notice received; stopping eggdrop..."
        systemctl stop eggdrop || log "systemctl stop failed"
        return 0
        ;;
      401) _main_token="" ;;
      esac
    fi
    sleep "$POLL_SECONDS"
  done
}

main "$@"
