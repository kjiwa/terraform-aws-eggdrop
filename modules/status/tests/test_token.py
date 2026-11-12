"""The bot's token minter, run as the instance runs it: a script that reads the key from a file."""

import hmac
import os
import subprocess
import sys
import time

MINT_PATH = os.path.join(
    os.path.dirname(__file__), "..", "..", "compute", "files", "eggdrop-token.py"
)


def run_minter(key_file, ttl):
    result = subprocess.run(
        [sys.executable, MINT_PATH, str(key_file), str(ttl)],
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.strip()


def test_token_is_expiry_and_hmac_of_the_expiry(tmp_path):
    key_file = tmp_path / "status.key"
    key_file.write_bytes(b"0123456789abcdef\n")
    before = int(time.time())

    expiry, signature = run_minter(key_file, 43200).split(".")

    assert before + 43200 <= int(expiry) <= int(time.time()) + 43200
    assert (
        signature
        == hmac.new(b"0123456789abcdef", expiry.encode(), "sha256").hexdigest()
    )


def test_missing_key_file_fails(tmp_path):
    result = subprocess.run(
        [sys.executable, MINT_PATH, str(tmp_path / "absent"), "60"],
        capture_output=True,
        check=False,
    )
    assert result.returncode != 0
