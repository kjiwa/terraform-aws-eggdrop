#!/bin/sh
# Tests for modules/compute/files/config-sync.sh: the live roster is replaced
# and the bot reloaded only when the bucket copy differs. aws, systemctl and
# chown are stubs.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly SYNC="$TESTS_DIR/../../modules/compute/files/config-sync.sh"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/eggdrop-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/scripts"
readonly SYSTEMCTL_LOG="$WORK/systemctl.log"
readonly REMOTE="$WORK/remote.tcl"
readonly LIVE="$WORK/scripts/eggdrop.tcl"
export SYSTEMCTL_LOG REMOTE
export EGGDROP_SCRIPTS_DIR="$WORK/scripts"

# The stub aws copies REMOTE to the destination, or fails when AWS_FAIL is set.
cat >"$WORK/bin/aws" <<'STUB'
#!/bin/sh
[ -z "${AWS_FAIL:-}" ] || exit 1
cp "$REMOTE" "$4"
STUB
cat >"$WORK/bin/systemctl" <<'STUB'
#!/bin/sh
echo "$*" >>"$SYSTEMCTL_LOG"
[ "$1" != is-active ] || [ -z "${INACTIVE:-}" ]
STUB
cat >"$WORK/bin/chown" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$WORK/bin/"*
PATH="$WORK/bin:$PATH"
export PATH

reset() {
  printf 'old' >"$LIVE"
  printf 'new' >"$REMOTE"
  : >"$SYSTEMCTL_LOG"
  unset AWS_FAIL INACTIVE
}

reset
printf 'old' >"$REMOTE"
assert_status "unchanged exits 0" 0 sh "$SYNC" b
assert_eq "unchanged does not reload" "no" "$(grep -q '^reload' "$SYSTEMCTL_LOG" && echo yes || echo no)"
assert_eq "unchanged leaves no temp file" "1" "$(find "$WORK/scripts" -type f | wc -l | tr -d ' ')"
assert_eq "unchanged keeps the file" "old" "$(cat "$LIVE")"

reset
assert_status "changed exits 0" 0 sh "$SYNC" b
assert_eq "changed replaces the file" "new" "$(cat "$LIVE")"
assert_eq "changed reloads" "yes" "$(grep -q '^reload eggdrop.service' "$SYSTEMCTL_LOG" && echo yes || echo no)"
assert_eq "changed leaves no temp file" "1" "$(find "$WORK/scripts" -type f | wc -l | tr -d ' ')"

reset
INACTIVE=1
export INACTIVE
assert_status "inactive exits 0" 0 sh "$SYNC" b
assert_eq "inactive replaces the file" "new" "$(cat "$LIVE")"
assert_eq "inactive does not reload" "no" "$(grep -q '^reload' "$SYSTEMCTL_LOG" && echo yes || echo no)"

reset
AWS_FAIL=1
export AWS_FAIL
assert_status "aws failure exits non-zero" 1 sh "$SYNC" b
assert_eq "aws failure keeps the file" "old" "$(cat "$LIVE")"
assert_eq "aws failure does not reload" "no" "$(grep -q '^reload' "$SYSTEMCTL_LOG" && echo yes || echo no)"
assert_eq "aws failure leaves no temp file" "1" "$(find "$WORK/scripts" -type f | wc -l | tr -d ' ')"

finish
