#!/bin/sh
# Renders modules/compute/files/eggdrop.conf.tftpl with Terraform and runs
# test_conf.tcl against it under tclsh, with Eggdrop's commands stubbed. Locally
# it skips when tclsh or terraform is missing; under CI that is a failure.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly TEMPLATE="$TESTS_DIR/../../modules/compute/files/eggdrop.conf.tftpl"

# render NAME NICKS_HCL SERVERS_HCL: writes $WORK/NAME.conf
render() {
  _render_dir="$WORK/render-$1"
  mkdir -p "$_render_dir"
  cat >"$_render_dir/main.tf" <<HCL
output "conf" {
  value = templatefile("$TEMPLATE", {
    nicks               = $2
    irc_servers         = $3
    net_type            = "Other"
    asg_name            = "eggdrop"
    log_group           = "/eggdrop/irc"
    slot_gate_seconds   = 1800
    lifecycle_hook_name = "launching"
  })
}
HCL
  terraform -chdir="$_render_dir" apply -auto-approve -input=false >/dev/null
  terraform -chdir="$_render_dir" output -raw conf >"$WORK/$1.conf"
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
  render two_by_three '["naju", "zera"]' '[{ host = "a.example.net", port = 6697 }, { host = "b.example.net", port = 7000 }, { host = "c.example.net", port = 6697 }]'
  render three_by_two '["naju", "zera", "kali"]' '[{ host = "a.example.net", port = 6697 }, { host = "b.example.net", port = 7000 }]'
  render one_server '["naju", "zera"]' '[{ host = "a.example.net", port = 6697 }]'
  (cd "$WORK" && tclsh "$TESTS_DIR/test_conf.tcl" "$WORK")
}

main "$@"
