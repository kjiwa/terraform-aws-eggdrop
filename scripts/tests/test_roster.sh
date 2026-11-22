#!/bin/sh
# Renders modules/compute/files/eggdrop.tcl.tftpl with Terraform and runs
# test_roster.tcl against it under tclsh, with Eggdrop's commands stubbed.
# Locally it skips when tclsh or terraform is missing; under CI that is a failure.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly TEMPLATE="$TESTS_DIR/../../modules/compute/files/eggdrop.tcl.tftpl"

render() {
  _render_dir="$WORK/render"
  mkdir -p "$_render_dir"
  cat >"$_render_dir/main.tf" <<HCL
output "roster" {
  value = templatefile("$TEMPLATE", {
    region           = "us-west-2"
    metric_namespace = "Eggdrop"
    domain_name      = "status.example.net"
    owner            = "alice"
    users            = { alice = ["*!*alice@host.example"], bob = ["*!*bob@host.example", "*!*bob@other.example"] }
    peer_masks       = ["*!*@2001:db8:1:1:*", "*!*@2001:db8:1:2:*"]
    channels         = { "#guarded" = { ops = ["alice", "bob"], bitch = true, revenge = true }, "#plain" = { ops = ["bob"], bitch = false, revenge = false } }
    channel_ops      = [{ channel = "#guarded", handle = "alice" }, { channel = "#guarded", handle = "bob" }, { channel = "#plain", handle = "bob" }]
  })
}
HCL
  terraform -chdir="$_render_dir" apply -auto-approve -input=false >/dev/null
  terraform -chdir="$_render_dir" output -raw roster >"$WORK/roster.tcl"
}

main() {
  for _main_tool in tclsh terraform; do
    if ! command -v "$_main_tool" >/dev/null 2>&1; then
      if [ -n "${CI:-}" ]; then
        echo "FAIL: $_main_tool is not installed" >&2
        return 1
      fi
      echo "skipped: $_main_tool is not installed"
      return 0
    fi
  done
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/eggdrop-test.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT
  render
  (cd "$WORK" && tclsh "$TESTS_DIR/test_roster.tcl" "$WORK")
}

main "$@"
