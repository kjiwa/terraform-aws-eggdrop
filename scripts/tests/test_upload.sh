#!/bin/sh
# Tests for scripts/upload.sh: a tarball is uploaded only when its SHA-256
# matches the pin. curl and aws are stubs.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly UPLOAD="$TESTS_DIR/../upload.sh"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/eggdrop-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
readonly AWS_LOG="$WORK/aws.log"
readonly CURL_LOG="$WORK/curl.log"
export AWS_LOG CURL_LOG

# The stub curl writes the same bytes wherever it is told to (-o FILE).
cat >"$WORK/bin/curl" <<'STUB'
#!/bin/sh
echo "$*" >>"$CURL_LOG"
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    printf 'tarball-bytes' >"$2"
    exit 0
  fi
  shift
done
exit 1
STUB
cat >"$WORK/bin/aws" <<'STUB'
#!/bin/sh
echo "$*" >>"$AWS_LOG"
STUB
chmod +x "$WORK/bin/"*
PATH="$WORK/bin:$PATH"
export PATH

if command -v sha256sum >/dev/null 2>&1; then
  GOOD="$(printf 'tarball-bytes' | sha256sum | cut -d ' ' -f 1)"
else
  GOOD="$(printf 'tarball-bytes' | shasum -a 256 | cut -d ' ' -f 1)"
fi
readonly GOOD
readonly BAD="0000000000000000000000000000000000000000000000000000000000000000"

: >"$AWS_LOG"
assert_status "matching hash uploads" 0 sh "$UPLOAD" --version 1.10.2 --sha256 "$GOOD" --bucket b
assert_eq "uploads under eggdrop/" "s3://b/eggdrop/eggdrop-1.10.2.tar.gz" \
  "$(sed 's|^s3 cp [^ ]* ||' "$AWS_LOG")"

: >"$AWS_LOG"
assert_status "mismatching hash fails" 1 sh "$UPLOAD" --version 1.10.2 --sha256 "$BAD" --bucket b
assert_eq "mismatch uploads nothing" "" "$(cat "$AWS_LOG")"

assert_status "missing bucket is a usage error" 2 sh "$UPLOAD" --version 1.10.2 --sha256 "$GOOD"
assert_status "unknown flag is a usage error" 2 sh "$UPLOAD" --bogus

: >"$CURL_LOG"
sh "$UPLOAD" --version 1.10.2 --sha256 "$GOOD" --bucket b >/dev/null 2>&1
assert_eq "default URL follows the minor series" "yes" \
  "$(grep -q 'ftp.eggheads.org/pub/eggdrop/source/1.10/eggdrop-1.10.2.tar.gz' "$CURL_LOG" && echo yes || echo no)"

finish
