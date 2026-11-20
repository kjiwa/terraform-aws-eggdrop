#!/bin/sh
# Tests for modules/compute/files/eggdrop-slot.sh: which nick slot a booting
# bot takes, and that any failure leaves no slot file. aws and date are stubs;
# the fake group and bucket are directories under WORK.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly SLOT="$TESTS_DIR/../../modules/compute/files/eggdrop-slot.sh"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/eggdrop-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/bucket"
readonly NOW=1000000

# describe-auto-scaling-groups prints $WORK/group (instance id, state) unless
# $WORK/group_fails exists. s3 cp prints the snapshot, answers 404 for a
# missing one and 403 when $WORK/denied exists.
cat >"$WORK/bin/aws" <<'STUB'
#!/bin/sh
case "$1 $2" in
"autoscaling describe-auto-scaling-groups")
  [ ! -e "$WORK/group_fails" ] || exit 255
  cat "$WORK/group"
  ;;
"s3 cp")
  [ ! -e "$WORK/denied" ] || { echo "An error occurred (403) when calling the HeadObject operation: Forbidden" >&2; exit 1; }
  _key="${3##*/}"
  [ -f "$WORK/bucket/$_key" ] || { echo "An error occurred (404) when calling the HeadObject operation: Key \"$3\" does not exist" >&2; exit 1; }
  cat "$WORK/bucket/$_key"
  ;;
*) exit 2 ;;
esac
STUB
cat >"$WORK/bin/date" <<'STUB'
#!/bin/sh
echo 1000000
STUB
chmod +x "$WORK/bin/"*
PATH="$WORK/bin:$PATH"
export PATH WORK

echo "boot-one" >"$WORK/boot_id"
readonly SLOT_FILE="$WORK/slot.tcl"
SLOT_BOOT_ID_FILE="$WORK/boot_id"
EGGDROP_BUCKET="bucket"
export SLOT_BOOT_ID_FILE EGGDROP_BUCKET

reset() {
  rm -f "$SLOT_FILE" "$WORK/group" "$WORK/group_fails" "$WORK/denied" "$WORK/bucket/"*
  echo "boot-one" >"$WORK/boot_id"
  : >"$WORK/group"
}

# group ID STATE...
group() {
  printf '%s\t%s\n' "$1" "$2" >>"$WORK/group"
}

# snapshot ID NICK ONLINE_SINCE AGE_SECONDS
snapshot() {
  printf '{"nick":"%s","botname":"%s!bot@host","server_entry":"a.example.net:+6697","server_name":"a.example.net","online_since":%s,"on_slot":true,"channels":[],"probes":{},"updated":%s}' \
    "$2" "$2" "$3" "$((NOW - $4))" >"$WORK/bucket/$1.json"
}

# boot SELF: runs the script as that instance and prints the slot file's
# slot line, or "none" when no file was written.
boot() {
  EGGDROP_INSTANCE_ID="$1"
  export EGGDROP_INSTANCE_ID
  _boot_status=0
  sh "$SLOT" eggdrop "$SLOT_FILE" naju zera >/dev/null 2>&1 || _boot_status=$?
  assert_eq "script exits 0" 0 "$_boot_status"
  if [ -f "$SLOT_FILE" ]; then
    grep '^set eggdrop_boot_slot ' "$SLOT_FILE" || echo "none"
  else
    echo "none"
  fi
}

reset
group i-aaa Pending
group i-bbb Pending
assert_eq "simultaneous boot: lower id takes slot 0" "set eggdrop_boot_slot 0" "$(boot i-aaa)"
rm -f "$SLOT_FILE"
assert_eq "simultaneous boot: higher id takes slot 1" "set eggdrop_boot_slot 1" "$(boot i-bbb)"

reset
group i-aaa InService
group i-bbb Pending
snapshot i-aaa naju 900 60
assert_eq "slot 0 held: take slot 1" "set eggdrop_boot_slot 1" "$(boot i-bbb)"

reset
group i-aaa InService
group i-bbb Pending
snapshot i-aaa zera 900 60
assert_eq "slot 1 held: take slot 0" "set eggdrop_boot_slot 0" "$(boot i-bbb)"

reset
group i-aaa Pending:Wait
group i-bbb Pending
snapshot i-aaa naju 900 60
assert_eq "a peer waiting on its launch hook holds its slot" "set eggdrop_boot_slot 1" "$(boot i-bbb)"

reset
group i-aaa InService
group i-bbb Pending
snapshot i-aaa naju 900 901
assert_eq "snapshot older than 900 s is ignored" "set eggdrop_boot_slot 0" "$(boot i-bbb)"

reset
group i-aaa InService
group i-bbb Pending
snapshot i-aaa naju 0 60
assert_eq "snapshot of a disconnected bot holds nothing" "set eggdrop_boot_slot 0" "$(boot i-bbb)"

reset
group i-bbb Pending
snapshot i-gone naju 900 60
assert_eq "snapshot of an instance outside the group is ignored" "set eggdrop_boot_slot 0" "$(boot i-bbb)"

reset
group i-aaa Terminating
group i-bbb Pending
snapshot i-aaa naju 900 60
assert_eq "a terminating peer holds nothing" "set eggdrop_boot_slot 0" "$(boot i-bbb)"

reset
group i-bbb Pending
snapshot i-bbb zera 900 60
assert_eq "own snapshot is ignored" "set eggdrop_boot_slot 0" "$(boot i-bbb)"

reset
group i-aaa InService
group i-bbb InService
group i-ccc Pending
snapshot i-aaa naju 900 60
snapshot i-bbb zera 900 60
assert_eq "both slots held: spare writes nothing" "none" "$(boot i-ccc)"

reset
group i-aaa InService
group i-bbb Pending
snapshot i-aaa naju? 900 60
assert_eq "a peer on its alternate nick holds no slot" "set eggdrop_boot_slot 0" "$(boot i-bbb)"

reset
group i-aaa Pending
group i-bbb Pending
touch "$WORK/group_fails"
assert_eq "group call fails: nothing written" "none" "$(boot i-aaa)"

reset
group i-aaa InService
group i-bbb Pending
snapshot i-aaa naju 900 60
touch "$WORK/denied"
assert_eq "snapshot read denied: nothing written" "none" "$(boot i-bbb)"

reset
group i-aaa Pending
assert_eq "no instance id: nothing written" "none" "$(boot "")"

reset
group i-aaa InService
group i-bbb Pending
snapshot i-aaa naju 900 60
assert_eq "first start takes slot 1" "set eggdrop_boot_slot 1" "$(boot i-bbb)"
rm -f "$WORK/bucket/i-aaa.json"
snapshot i-aaa zera 900 60
assert_eq "restart keeps the slot" "set eggdrop_boot_slot 1" "$(boot i-bbb)"
echo "boot-two" >"$WORK/boot_id"
assert_eq "a new boot recomputes the slot" "set eggdrop_boot_slot 0" "$(boot i-bbb)"

reset
group i-aaa InService
group i-bbb Pending
snapshot i-aaa naju 900 60
printf '# boot boot-one\nset eggdrop_boot_slot 1\n' >"$SLOT_FILE"
touch "$WORK/group_fails"
assert_eq "restart keeps the slot without any AWS call" "set eggdrop_boot_slot 1" "$(boot i-bbb)"

reset
group i-aaa InService
group i-bbb Pending
snapshot i-aaa naju 900 60
printf '# boot older\nset eggdrop_boot_slot 1\n' >"$SLOT_FILE"
touch "$WORK/group_fails"
assert_eq "a slot file from an earlier boot is removed when the call fails" "none" "$(boot i-bbb)"

finish
