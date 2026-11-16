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
EVENT_KINDS = ("accepted", *FAILURE_EVENTS)
EVENT_PATTERN = " ".join(f"?{kind}" for kind in EVENT_KINDS)
EVENT_MAX_PAGES = 5
EVENT_MAX_EVENTS = 2000
BOT_STATES = ("InService", "Pending:Wait", "Pending:Proceed")


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


def instance_row(s3, instance_id, now):
    try:
        snapshot = read_snapshot(s3, os.environ["BOT_BUCKET"], instance_id)
    except botocore.exceptions.ClientError:
        return {"label": instance_id, "value": "snapshot unreadable"}
    return bot_row(instance_id, snapshot, now)


def bots(now=None):
    now = time.time() if now is None else now
    asg = boto3.client("autoscaling").describe_auto_scaling_groups(
        AutoScalingGroupNames=[os.environ["ASG_NAME"]]
    )["AutoScalingGroups"]
    s3 = boto3.client("s3")
    rows = [
        instance_row(s3, instance["InstanceId"], now)
        for group in asg
        for instance in group["Instances"]
        if instance["LifecycleState"] in BOT_STATES
    ]
    return {"title": "Bots", "rows": rows}


def read_events(logs, start_ms):
    """Event kinds only, at most EVENT_MAX_PAGES pages and EVENT_MAX_EVENTS
    events; the flag says whether more remained."""
    events = []
    token = None
    for _ in range(EVENT_MAX_PAGES):
        arguments = {
            "logGroupName": os.environ["IRC_LOG_GROUP"],
            "startTime": start_ms,
            "filterPattern": EVENT_PATTERN,
        }
        if token:
            arguments["nextToken"] = token
        page = logs.filter_log_events(**arguments)
        events.extend((e["timestamp"] / 1000, e["message"]) for e in page["events"])
        token = page.get("nextToken")
        if not token:
            return events, False
        if len(events) >= EVENT_MAX_EVENTS:
            break
    return events[:EVENT_MAX_EVENTS], True


def server_row(address, events, truncated):
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
    captions = []
    if failure:
        seconds, kind, text = failure
        captions.append(f"last {kind} {clock(seconds)}: {text}")
    if truncated:
        captions.append("truncated")
    row = {
        "label": address,
        "value": f"accepted {clock(accepted)}" if accepted else "no accept in 24 h",
    }
    if captions:
        row["caption"] = "; ".join(captions)
    return row


def servers(now=None):
    now = time.time() if now is None else now
    events, truncated = read_events(
        boto3.client("logs"), int((now - EVENT_WINDOW_SECONDS) * 1000)
    )
    events.sort(key=lambda event: event[0])
    addresses = json.loads(os.environ["IRC_SERVERS"])
    return {
        "title": "Servers",
        "rows": [server_row(address, events, truncated) for address in addresses],
    }


def sections():
    return {"bots": bots, "servers": servers}
