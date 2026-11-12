"""Gate for the status-page core.

A token is "<expiry>.<hex HMAC-SHA256 of the expiry>", minted by the bot's
status command (modules/compute/files/naju-token.py) with the same key held
here in SSM. The token arrives in X-Naju-Token, not Authorization: CloudFront's
OAC overwrites Authorization with its SigV4 signature on the way to the
Function URL. The check needs nothing from the instance, so the gate works
while the bot is down.
"""

import hmac
import os
import time

import boto3

_key = None


def load_key():
    global _key
    if _key is None:
        ssm = boto3.client("ssm")
        response = ssm.get_parameter(
            Name=os.environ["STATUS_KEY_PARAMETER"], WithDecryption=True
        )
        _key = response["Parameter"]["Value"].strip().encode()
    return _key


def valid(token, key, now):
    expiry, _, signature = token.partition(".")
    # isascii first: str.isdigit() is true for characters int() rejects, and
    # compare_digest raises on a non-ASCII str.
    if not (expiry.isascii() and expiry.isdigit() and signature.isascii()):
        return False
    expected = hmac.new(key, expiry.encode(), "sha256").hexdigest()
    return hmac.compare_digest(signature, expected) and int(expiry) > now


def authenticate(headers):
    token = headers.get("x-naju-token", "")
    return "viewer" if token and valid(token, load_key(), time.time()) else None


def sections():
    return {}
