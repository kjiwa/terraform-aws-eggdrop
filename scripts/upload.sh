#!/bin/sh
# Fetches an Eggdrop release tarball, checks it against a pinned SHA-256, and
# uploads it to the bot bucket for the instance to compile. The instance
# checks the same hash again, so a bad upload cannot run.
#
#   upload.sh --version X.Y.Z --sha256 HEX --bucket NAME [--url URL]
set -eu

readonly DEFAULT_URL_BASE="https://ftp.eggheads.org/pub/eggdrop/source"

usage() {
  echo "usage: upload.sh --version X.Y.Z --sha256 HEX --bucket NAME [--url URL]" >&2
  exit 2
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "upload.sh: $1 is required but not installed" >&2
    exit 1
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

main() {
  _main_version=""
  _main_sha256=""
  _main_bucket=""
  _main_url=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --version) [ "$#" -ge 2 ] || usage; _main_version="$2"; shift 2 ;;
    --sha256) [ "$#" -ge 2 ] || usage; _main_sha256="$2"; shift 2 ;;
    --bucket) [ "$#" -ge 2 ] || usage; _main_bucket="$2"; shift 2 ;;
    --url) [ "$#" -ge 2 ] || usage; _main_url="$2"; shift 2 ;;
    *) usage ;;
    esac
  done
  { [ -n "$_main_version" ] && [ -n "$_main_sha256" ] && [ -n "$_main_bucket" ]; } || usage

  require_tool curl
  require_tool aws

  if [ -z "$_main_url" ]; then
    _main_minor="${_main_version%.*}"
    _main_url="$DEFAULT_URL_BASE/$_main_minor/eggdrop-$_main_version.tar.gz"
  fi

  _main_dir="$(mktemp -d "${TMPDIR:-/tmp}/eggdrop-upload.XXXXXX")"
  trap 'rm -rf "$_main_dir"' EXIT
  _main_file="$_main_dir/eggdrop-$_main_version.tar.gz"

  curl -fsSL -o "$_main_file" "$_main_url"
  _main_actual="$(sha256_of "$_main_file")"
  if [ "$_main_actual" != "$_main_sha256" ]; then
    echo "upload.sh: SHA-256 mismatch: expected $_main_sha256, got $_main_actual" >&2
    exit 1
  fi

  aws s3 cp "$_main_file" "s3://$_main_bucket/eggdrop/eggdrop-$_main_version.tar.gz"
}

main "$@"
