"""Gate for the status-page core.

A token is "<expiry>.<hex HMAC-SHA256 of the expiry>", minted by the bot's
status command (modules/compute/files/eggdrop-token.py) with the same key held
here in SSM. The token arrives in X-Eggdrop-Token, not Authorization: CloudFront's
OAC overwrites Authorization with its SigV4 signature on the way to the
Function URL. The check needs nothing from the instance, so the gate works
while the bot is down.
"""

import collections
import datetime
import functools
import hmac
import json
import os
import threading
import time

import boto3
import botocore.exceptions

_key = None

# The bot rewrites its snapshot at least every 900 s.
SNAPSHOT_STALE_SECONDS = 1200
# Newest first: a row shows only the last accept and failure per server, so
# most servers are settled by the first window and the rest cost no reads.
EVENT_WINDOWS = (
    ("1 h", 0, 3600),
    ("1-6 h", 3600, 6 * 3600),
    ("6-24 h", 6 * 3600, 24 * 3600),
)
FAILURE_EVENTS = ("failed", "refused")
EVENT_KINDS = ("accepted", *FAILURE_EVENTS)
EVENT_PATTERN = " ".join(f"?{kind}" for kind in EVENT_KINDS)
EVENT_MAX_PAGES = 20
# A window keeps its newest events: the log is read oldest first.
EVENT_KEEP = 2000
PROBE_MAX_SECONDS = 4_000_000_000
UNREADABLE = object()
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
    return f"{channel['name']} {state}, {channel['members']} members{settings_text(channel)}"


def settings_text(channel):
    """A snapshot from a bot that predates channel settings has none: no claim."""
    if not isinstance(channel.get("settings"), list):
        return ""
    if not channel["settings"]:
        return ", no channel protection"
    return ", " + " ".join(f"+{name}" for name in channel["settings"])


def mode_value(snapshot):
    """A snapshot from a bot that predates user modes has none: no claim."""
    return f", mode {snapshot['umode']}" if snapshot.get("umode") else ""


def not_deaf_note(snapshot):
    """The deaf letter is the one the server advertised, trusted as such; no
    letter, or a letter missing from the mode string, means the bot hears
    channel text."""
    umode = snapshot.get("umode")
    if not umode:
        return []
    letter = snapshot.get("deaf", "")
    return [] if letter and letter in set(umode.lstrip("+-")) else ["not deaf"]


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
        value = f"{server}, since {clock(snapshot['online_since'])}, {slot}{mode_value(snapshot)}"
    else:
        value = "disconnected"
    details = [
        snapshot["botname"],
        *map(channel_text, snapshot["channels"]),
        *not_deaf_note(snapshot),
        freshness,
    ]
    return {
        "label": snapshot["nick"],
        "value": value,
        "caption": "; ".join(details),
    }


def bot_instance_ids():
    asg = boto3.client("autoscaling").describe_auto_scaling_groups(
        AutoScalingGroupNames=[os.environ["ASG_NAME"]]
    )["AutoScalingGroups"]
    return [
        instance["InstanceId"]
        for group in asg
        for instance in group["Instances"]
        if instance["LifecycleState"] in BOT_STATES
    ]


def read_snapshots():
    """Instance id to its snapshot, None when it has none, UNREADABLE on an error."""
    s3 = boto3.client("s3")
    snapshots = {}
    for instance_id in bot_instance_ids():
        try:
            snapshots[instance_id] = read_snapshot(
                s3, os.environ["BOT_BUCKET"], instance_id
            )
        except botocore.exceptions.ClientError:
            snapshots[instance_id] = UNREADABLE
    return snapshots


class Roster:
    """The bots and their snapshots, read once for the sections of one request."""

    def __init__(self):
        self._lock = threading.Lock()
        self._snapshots = None

    def snapshots(self):
        with self._lock:
            if self._snapshots is None:
                self._snapshots = read_snapshots()
            return self._snapshots


def instance_row(instance_id, snapshot, now):
    if snapshot is UNREADABLE:
        return {"label": instance_id, "value": "snapshot unreadable"}
    return bot_row(instance_id, snapshot, now)


def bots(now=None, roster=None):
    now = time.time() if now is None else now
    snapshots = (roster or Roster()).snapshots()
    rows = [instance_row(i, snapshot, now) for i, snapshot in snapshots.items()]
    return {"title": "Bots", "rows": rows}


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise TypeError("not a number")
    return value


def probe_time(at):
    if not 0 <= number(at) < PROBE_MAX_SECONDS:
        raise ValueError("probe time out of range")
    return at


def probe_text(at, result):
    probe_time(at)
    if result["ok"] is True:
        outcome = f"ok {number(result['seconds']):.1f} s"
    elif result["ok"] is False and isinstance(result["error"], str):
        outcome = result["error"]
    else:
        raise ValueError("probe result")
    return f"probe {outcome} {clock(at)}"


def probe_failure_text(block):
    if not isinstance(block["error"], str):
        raise TypeError("probe error")
    return f"{block['error']} {clock(probe_time(block['at']))}"


def newest_probes(snapshots):
    """Per server, the newest probe of any bot: (finished at, caption). Also
    the newest top-level probe failure as (at, caption), or None when a newer
    result exists. A malformed block or result is skipped."""
    newest = {}
    failure = None
    for snapshot in snapshots.values():
        try:
            block = snapshot["probes"]
            if "error" in block:
                text = probe_failure_text(block)
                if failure is None or block["at"] > failure[0]:
                    failure = (block["at"], text)
                continue
            at, results = probe_time(block["at"]), block["results"]
            if not isinstance(results, dict):
                raise TypeError("probe results")
        except (KeyError, TypeError, ValueError):
            continue
        for address, result in results.items():
            try:
                text = probe_text(at, result)
            except (KeyError, TypeError, ValueError):
                continue
            if address not in newest or at > newest[address][0]:
                newest[address] = (at, text)
    if failure and any(at >= failure[0] for at, _ in newest.values()):
        failure = None
    return newest, failure


def read_window(logs, start_ms, end_ms):
    """Event kinds only, oldest first, the newest EVENT_KEEP of them; the flag
    says whether more remained after EVENT_MAX_PAGES pages."""
    events = collections.deque(maxlen=EVENT_KEEP)
    token = None
    for _ in range(EVENT_MAX_PAGES):
        arguments = {
            "logGroupName": os.environ["IRC_LOG_GROUP"],
            "startTime": start_ms,
            "endTime": end_ms,
            "filterPattern": EVENT_PATTERN,
        }
        if token:
            arguments["nextToken"] = token
        page = logs.filter_log_events(**arguments)
        events.extend((e["timestamp"] / 1000, e["message"]) for e in page["events"])
        token = page.get("nextToken")
        if not token:
            return list(events), False
    return list(events), True


def parse_event(message):
    kind, _, rest = message.partition(" ")
    target, _, text = rest.partition(" ")
    return kind, target.lower(), text


def settled(addresses, events):
    """Whether every address has an accept and a failure among the events."""
    seen = set()
    for _, message in events:
        kind, target, _ = parse_event(message)
        if kind == "accepted":
            seen.add((target, "accepted"))
        elif kind in FAILURE_EVENTS:
            seen.add((target, "failure"))
    return all(
        (address.lower(), outcome) in seen
        for address in addresses
        for outcome in ("accepted", "failure")
    )


def read_events(logs, now, addresses):
    """Windows newest first, until every address has an accept and a failure.
    Returns the events oldest first and the windows that hit the page cap."""
    events = []
    capped = []
    for label, newer, older in EVENT_WINDOWS:
        window, hit_cap = read_window(
            logs, int((now - older) * 1000), int((now - newer) * 1000)
        )
        events = window + events
        if hit_cap:
            capped.append(label)
        if settled(addresses, events):
            break
    return events, capped


def server_row(address, events, capped, probe=None):
    accepted = failure = None
    for seconds, message in events:
        kind, target, text = parse_event(message)
        if target != address.lower():
            continue
        if kind == "accepted":
            accepted = seconds
        elif kind in FAILURE_EVENTS:
            failure = (seconds, kind, text)
    captions = []
    if failure:
        seconds, kind, text = failure
        captions.append(f"last {kind} {clock(seconds)}: {text}")
    if probe:
        captions.append(probe[1])
    if capped:
        captions.append(f"truncated in {', '.join(capped)}")
    row = {
        "label": address,
        "value": f"accepted {clock(accepted)}" if accepted else "no accept in 24 h",
    }
    if captions:
        row["caption"] = "; ".join(captions)
    return row


def servers(now=None, roster=None):
    now = time.time() if now is None else now
    addresses = json.loads(os.environ["IRC_SERVERS"])
    events, capped = read_events(boto3.client("logs"), now, addresses)
    probes, failure = newest_probes((roster or Roster()).snapshots())
    rows = [
        server_row(address, events, capped, probes.get(address))
        for address in addresses
    ]
    if failure:
        rows.append({"label": "probe", "value": "failed", "caption": failure[1]})
    return {"title": "Servers", "rows": rows}


def sections():
    roster = Roster()
    return {
        "bots": functools.partial(bots, roster=roster),
        "servers": functools.partial(servers, roster=roster),
    }
