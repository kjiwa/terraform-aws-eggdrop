#!/bin/sh
# Completes the ASG launch lifecycle hook for this instance. Until it does,
# the instance waits in Pending:Wait and the instance refresh does not retire
# the old bot. Usage: eggdrop-ready <asg-name> <hook-name>
set -eu

readonly IMDS="http://169.254.169.254/latest"

imds_get() {
  _imds_get_token="$(curl -sf -m 2 -X PUT "$IMDS/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60")"
  curl -sf -m 2 -H "X-aws-ec2-metadata-token: $_imds_get_token" "$IMDS/meta-data/$1"
}

main() {
  if [ "$#" -ne 2 ]; then
    echo "usage: eggdrop-ready <asg-name> <hook-name>" >&2
    return 2
  fi
  _main_instance_id="$(imds_get instance-id)"
  # Eggdrop runs this synchronously, so a stalled API call must not hold up
  # its PING replies.
  aws autoscaling complete-lifecycle-action \
    --cli-connect-timeout 5 --cli-read-timeout 10 \
    --lifecycle-action-result CONTINUE \
    --lifecycle-hook-name "$2" \
    --auto-scaling-group-name "$1" \
    --instance-id "$_main_instance_id"
}

main "$@"
