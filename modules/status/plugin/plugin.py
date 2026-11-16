"""Gate for the status-page core.

A token is "<expiry>.<hex HMAC-SHA256 of the expiry>", minted by the bot's
status command (modules/compute/files/eggdrop-token.py) with the same key held
here in SSM. The token arrives in X-Eggdrop-Token, not Authorization: CloudFront's
OAC overwrites Authorization with its SigV4 signature on the way to the
Function URL. The check needs nothing from the instance, so the gate works
while the bot is down.
"""

import datetime
import hmac
import json
import os
import time

import boto3
import botocore.exceptions

_key = None

# The bot rewrites its snapshot at least every 900 s.
SNAPSHOT_STALE_SECONDS = 1200
EVENT_WINDOW_SECONDS = 24 * 3600
FAILURE_EVENTS = ("failed", "refused")


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
    token = headers.get("x-eggdrop-token", "")
    return "viewer" if token and valid(token, load_key(), time.time()) else None


def clock(seconds):
    moment = datetime.datetime.fromtimestamp(seconds, datetime.UTC)
    return moment.strftime("%Y-%m-%d %H:%MZ")


def read_snapshot(s3, bucket, instance_id):
    try:
        body = s3.get_object(Bucket=bucket, Key=f"bots/{instance_id}.json")["Body"]
        return json.loads(body.read())
    except botocore.exceptions.ClientError as error:
        if error.response["Error"]["Code"] == "NoSuchKey":
            return None
        raise


def channel_text(channel):
    if not channel["joined"]:
        return f"{channel['name']} not joined"
    state = "opped" if channel["opped"] else "not opped"
    return f"{channel['name']} {state}, {channel['members']} members"


def bot_row(instance_id, snapshot, now):
    if snapshot is None:
        return {"label": instance_id, "value": "no snapshot"}
    age = int(now - snapshot["updated"])
    freshness = f"snapshot {age // 60} min old"
    if age > SNAPSHOT_STALE_SECONDS:
        freshness = f"STALE, {freshness}"
    if snapshot["online_since"] > 0:
        server = snapshot["server_entry"]
        if snapshot["server_name"]:
            server = f"{server} ({snapshot['server_name']})"
        slot = "on its slot server" if snapshot["on_slot"] else "OFF its slot server"
        value = f"{server}, since {clock(snapshot['online_since'])}, {slot}"
    else:
        value = "disconnected"
    details = [snapshot["botname"], *map(channel_text, snapshot["channels"]), freshness]
    return {
        "label": snapshot["nick"],
        "value": value,
        "caption": "; ".join(details),
    }


def bots(now=None):
    now = time.time() if now is None else now
    asg = boto3.client("autoscaling").describe_auto_scaling_groups(
        AutoScalingGroupNames=[os.environ["ASG_NAME"]]
    )["AutoScalingGroups"]
    s3 = boto3.client("s3")
    rows = [
        bot_row(
            instance["InstanceId"],
            read_snapshot(s3, os.environ["BOT_BUCKET"], instance["InstanceId"]),
            now,
        )
        for group in asg
        for instance in group["Instances"]
    ]
    return {"title": "Bots", "rows": rows}


def read_events(logs, start_ms):
    pages = logs.get_paginator("filter_log_events").paginate(
        logGroupName=os.environ["IRC_LOG_GROUP"], startTime=start_ms
    )
    for page in pages:
        for event in page["events"]:
            yield event["timestamp"] / 1000, event["message"]


def server_row(address, events):
    accepted = failure = None
    for seconds, message in events:
        kind, _, rest = message.partition(" ")
        target, _, text = rest.partition(" ")
        if target.lower() != address.lower():
            continue
        if kind == "accepted":
            accepted = seconds
        elif kind in FAILURE_EVENTS:
            failure = (seconds, kind, text)
    row = {
        "label": address,
        "value": f"accepted {clock(accepted)}" if accepted else "no accept in 24 h",
    }
    if failure:
        seconds, kind, text = failure
        row["caption"] = f"last {kind} {clock(seconds)}: {text}"
    return row


def servers(now=None):
    now = time.time() if now is None else now
    events = list(
        read_events(boto3.client("logs"), int((now - EVENT_WINDOW_SECONDS) * 1000))
    )
    events.sort(key=lambda event: event[0])
    addresses = json.loads(os.environ["IRC_SERVERS"])
    return {
        "title": "Servers",
        "rows": [server_row(address, events) for address in addresses],
    }


def sections():
    return {"bots": bots, "servers": servers}
