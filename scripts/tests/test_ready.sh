#!/bin/sh
# Tests for modules/compute/files/ready.sh: the launch hook is completed for
# this instance with CONTINUE, and nothing is completed when the instance id
# cannot be read. curl and aws are stubs.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly READY="$TESTS_DIR/../../modules/compute/files/ready.sh"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/eggdrop-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
readonly AWS_LOG="$WORK/aws.log"
export AWS_LOG

# The stub curl answers the token request and the instance-id request, or
# fails when IMDS_FAIL is set.
cat >"$WORK/bin/curl" <<'STUB'
#!/bin/sh
[ -z "${IMDS_FAIL:-}" ] || exit 22
case "$*" in
  *api/token*) echo token ;;
  *meta-data/instance-id*) echo i-0123456789abcdef0 ;;
  *) exit 22 ;;
esac
STUB
cat >"$WORK/bin/aws" <<'STUB'
#!/bin/sh
echo "$*" >>"$AWS_LOG"
STUB
chmod +x "$WORK/bin/"*
PATH="$WORK/bin:$PATH"
export PATH

: >"$AWS_LOG"
assert_status "success exits 0" 0 sh "$READY" eggdrop launching
assert_eq "completes this instance's hook" \
  "autoscaling complete-lifecycle-action --lifecycle-action-result CONTINUE --lifecycle-hook-name launching --auto-scaling-group-name eggdrop --instance-id i-0123456789abcdef0" \
  "$(cat "$AWS_LOG")"

: >"$AWS_LOG"
IMDS_FAIL=1
export IMDS_FAIL
_status=0
sh "$READY" eggdrop launching >/dev/null 2>&1 || _status=$?
assert_eq "IMDS failure exits non-zero" "yes" "$([ "$_status" -ne 0 ] && echo yes || echo no)"
assert_eq "IMDS failure completes nothing" "" "$(cat "$AWS_LOG")"
unset IMDS_FAIL

assert_status "wrong argument count exits 2" 2 sh "$READY" eggdrop

finish
