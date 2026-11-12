#!/usr/bin/env python3
"""Print a status page token: <expiry>.<HMAC-SHA256 hex of the expiry>.

Usage: eggdrop-token KEY_FILE TTL_SECONDS
modules/status/plugin/plugin.py verifies the same format.
"""

import hmac
import sys
import time


def mint(key, ttl_seconds, now=None):
    expiry = str(int((time.time() if now is None else now) + ttl_seconds))
    signature = hmac.new(key, expiry.encode(), "sha256").hexdigest()
    return f"{expiry}.{signature}"


def main():
    with open(sys.argv[1], "rb") as key_file:
        key = key_file.read().strip()
    print(mint(key, int(sys.argv[2])))


if __name__ == "__main__":
    main()
