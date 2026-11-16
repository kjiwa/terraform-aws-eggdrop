import io
import json
from unittest import mock

import boto3
import plugin
import pytest
from botocore.stub import Stubber

NOW = 1_800_000_000
BUCKET = "bot-bucket"
GROUP = "/eggdrop/irc"
SERVERS = ["a.example.net:+6697", "b.example.net:+6697", "c.example.net:+6697"]


@pytest.fixture(autouse=True)
def environment(monkeypatch):
    monkeypatch.setenv("ASG_NAME", "eggdrop")
    monkeypatch.setenv("BOT_BUCKET", BUCKET)
    monkeypatch.setenv("IRC_LOG_GROUP", GROUP)
    monkeypatch.setenv("IRC_SERVERS", json.dumps(SERVERS))
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-west-2")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "test")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "test")


def snapshot(**fields):
    return {
        "nick": "naju",
        "botname": "naju!naju@2001:db8::1",
        "server_entry": "a.example.net:+6697",
        "server_name": "a1.example.net:+6697",
        "online_since": NOW - 3600,
        "on_slot": True,
        "channels": [
            {"name": "#one", "joined": True, "opped": True, "members": 4},
            {"name": "#two", "joined": False, "opped": False, "members": 0},
        ],
        "updated": NOW - 120,
    } | fields


def stubbed(service):
    client = boto3.client(service)
    return client, Stubber(client)


def patch_clients(**clients):
    return mock.patch.object(boto3, "client", side_effect=clients.__getitem__)


def object_response(body):
    return {"Body": io.BytesIO(json.dumps(body).encode())}


def stub_group(autoscaling, instance_ids, states=None):
    autoscaling.add_response(
        "describe_auto_scaling_groups",
        {
            "AutoScalingGroups": [
                {
                    "AutoScalingGroupName": "eggdrop",
                    "MinSize": 0,
                    "MaxSize": 3,
                    "DesiredCapacity": 2,
                    "DefaultCooldown": 300,
                    "AvailabilityZones": ["us-west-2a"],
                    "HealthCheckType": "EC2",
                    "CreatedTime": "2026-01-01T00:00:00Z",
                    "Instances": [
                        {
                            "InstanceId": instance_id,
                            "AvailabilityZone": "us-west-2a",
                            "LifecycleState": (states or {}).get(
                                instance_id, "InService"
                            ),
                            "HealthStatus": "Healthy",
                            "ProtectedFromScaleIn": False,
                        }
                        for instance_id in instance_ids
                    ],
                }
            ]
        },
        {"AutoScalingGroupNames": ["eggdrop"]},
    )


def run_bots(instance_ids, objects, states=None):
    autoscaling, autoscaling_stub = stubbed("autoscaling")
    s3, s3_stub = stubbed("s3")
    stub_group(autoscaling_stub, instance_ids, states)
    for instance_id, body in objects.items():
        key = f"bots/{instance_id}.json"
        if body is None:
            s3_stub.add_client_error(
                "get_object",
                service_error_code="NoSuchKey",
                expected_params={"Bucket": BUCKET, "Key": key},
            )
        else:
            s3_stub.add_response(
                "get_object",
                object_response(body),
                {"Bucket": BUCKET, "Key": key},
            )
    with autoscaling_stub, s3_stub, patch_clients(autoscaling=autoscaling, s3=s3):
        return plugin.bots(NOW)


def test_two_bots_show_server_ident_and_channels():
    facts = run_bots(
        ["i-1", "i-2"],
        {
            "i-1": snapshot(),
            "i-2": snapshot(nick="zera", server_entry="b.example.net:+6697"),
        },
    )
    assert facts["title"] == "Bots"
    first, second = facts["rows"]
    assert first["label"] == "naju"
    assert "a.example.net:+6697 (a1.example.net:+6697)" in first["value"]
    assert "on its slot server" in first["value"]
    assert "naju!naju@2001:db8::1" in first["caption"]
    assert "#one opped, 4 members" in first["caption"]
    assert "#two not joined" in first["caption"]
    assert "snapshot 2 min old" in first["caption"]
    assert second["label"] == "zera"
    assert "b.example.net:+6697" in second["value"]


def test_old_snapshot_is_marked_stale():
    facts = run_bots(["i-1"], {"i-1": snapshot(updated=NOW - 1500)})
    assert "STALE, snapshot 25 min old" in facts["rows"][0]["caption"]


def test_missing_snapshot_reads_no_snapshot():
    facts = run_bots(["i-1"], {"i-1": None})
    assert facts["rows"] == [{"label": "i-1", "value": "no snapshot"}]


def test_bot_off_its_slot_server_is_flagged():
    facts = run_bots(["i-1"], {"i-1": snapshot(on_slot=False)})
    assert "OFF its slot server" in facts["rows"][0]["value"]


def test_disconnected_bot_reads_disconnected():
    facts = run_bots(["i-1"], {"i-1": snapshot(online_since=0, server_entry="")})
    assert facts["rows"][0]["value"] == "disconnected"


def test_unreadable_snapshot_leaves_the_other_rows():
    autoscaling, autoscaling_stub = stubbed("autoscaling")
    s3, s3_stub = stubbed("s3")
    stub_group(autoscaling_stub, ["i-1", "i-2"])
    s3_stub.add_client_error("get_object", service_error_code="AccessDenied")
    s3_stub.add_response("get_object", object_response(snapshot(nick="zera")))
    with autoscaling_stub, s3_stub, patch_clients(autoscaling=autoscaling, s3=s3):
        facts = plugin.bots(NOW)
    assert facts["rows"][0] == {"label": "i-1", "value": "snapshot unreadable"}
    assert facts["rows"][1]["label"] == "zera"


@pytest.mark.parametrize(
    "state", ["Terminating", "Terminating:Wait", "Terminating:Proceed"]
)
def test_terminating_instances_get_no_row(state):
    facts = run_bots(["i-1", "i-2"], {"i-1": snapshot()}, states={"i-2": state})
    assert [row["label"] for row in facts["rows"]] == ["naju"]


@pytest.mark.parametrize("state", ["InService", "Pending:Wait", "Pending:Proceed"])
def test_launching_and_serving_instances_get_a_row(state):
    facts = run_bots(["i-1"], {"i-1": snapshot()}, states={"i-1": state})
    assert [row["label"] for row in facts["rows"]] == ["naju"]


def log_page(messages, token=None):
    page = {
        "events": [
            {"timestamp": int(seconds * 1000), "message": message}
            for seconds, message in messages
        ]
    }
    if token:
        page["nextToken"] = token
    return page


WINDOWS = ((0, 3600), (3600, 6 * 3600), (6 * 3600, 24 * 3600))


def log_params(window, token=None):
    newer, older = WINDOWS[window]
    params = {
        "logGroupName": GROUP,
        "startTime": (NOW - older) * 1000,
        "endTime": (NOW - newer) * 1000,
        "filterPattern": "?accepted ?failed ?refused",
    }
    if token:
        params["nextToken"] = token
    return params


def run_windows(windows, snapshots=None):
    """windows: the pages of each window in the order it must be read."""
    logs, logs_stub = stubbed("logs")
    for number, pages in enumerate(windows):
        token = None
        for page in pages:
            logs_stub.add_response("filter_log_events", page, log_params(number, token))
            token = page.get("nextToken")
    autoscaling, autoscaling_stub = stubbed("autoscaling")
    s3, s3_stub = stubbed("s3")
    snapshots = snapshots or {}
    stub_group(autoscaling_stub, list(snapshots))
    for instance_id, body in snapshots.items():
        s3_stub.add_response(
            "get_object",
            object_response(body),
            {"Bucket": BUCKET, "Key": f"bots/{instance_id}.json"},
        )
    with (
        logs_stub,
        autoscaling_stub,
        s3_stub,
        patch_clients(logs=logs, autoscaling=autoscaling, s3=s3),
    ):
        return plugin.servers(NOW)


def run_servers(messages):
    """Every window is read: the listed servers never all settle."""
    return run_windows([[log_page(messages)], [log_page([])], [log_page([])]])


def settled_messages(seconds):
    return [
        (seconds, f"{kind} {address} text")
        for address in SERVERS
        for kind in ("accepted", "failed")
    ]


def test_refusal_row_carries_the_reason_and_the_last_accept():
    facts = run_servers(
        [
            (NOW - 7200, "accepted a.example.net:+6697 a1.example.net:+6697"),
            (NOW - 600, "refused b.example.net:+6697 ERROR :Closing Link: (K-Lined)"),
            (NOW - 300, "refused b.example.net:+6697 ERROR :Closing Link: (Z-Lined)"),
            (NOW - 200, "failed c.example.net:+6697 Failed to connect (refused)"),
            (NOW - 100, "trying a.example.net:+6697 "),
        ]
    )
    accepted, refused, failed = facts["rows"]
    assert facts["title"] == "Servers"
    assert accepted["label"] == "a.example.net:+6697"
    assert accepted["value"].startswith("accepted ")
    assert "caption" not in accepted
    assert refused["value"] == "no accept in 24 h"
    assert refused["caption"].endswith("ERROR :Closing Link: (Z-Lined)")
    assert refused["caption"].startswith("last refused ")
    assert failed["caption"].startswith("last failed ")


def test_server_with_no_events_has_a_bare_row():
    facts = run_servers([])
    assert facts["rows"][0] == {
        "label": "a.example.net:+6697",
        "value": "no accept in 24 h",
    }


def test_targetless_events_belong_to_no_row():
    facts = run_servers(
        [
            (NOW - 100, "failed - something went wrong"),
            (NOW - 90, "accepted - a.example.net:+6697"),
        ]
    )
    assert all(row["value"] == "no accept in 24 h" for row in facts["rows"])
    assert all("caption" not in row for row in facts["rows"])


def test_newest_accept_is_found_in_the_first_window_without_reading_older_ones():
    facts = run_windows([[log_page(settled_messages(NOW - 60))]])
    assert all(row["value"].startswith("accepted ") for row in facts["rows"])
    assert all(
        "caption" in row and "truncated" not in row["caption"] for row in facts["rows"]
    )


def test_newest_accept_wins_over_thousands_of_older_events():
    older = [
        (NOW - 20 * 3600 + n, "accepted a.example.net:+6697 old") for n in range(5000)
    ]
    facts = run_windows(
        [
            [log_page([(NOW - 60, "accepted a.example.net:+6697 new")])],
            [log_page([])],
            [log_page(older)],
        ]
    )
    assert facts["rows"][0]["value"] == f"accepted {plugin.clock(NOW - 60)}"


def test_windows_are_read_newest_first_until_every_server_has_both():
    first = [
        (NOW - 60, "accepted a.example.net:+6697 x"),
        (NOW - 50, "failed a.example.net:+6697 x"),
    ]
    second = [
        (NOW - 7200, "accepted b.example.net:+6697 x"),
        (NOW - 7100, "failed b.example.net:+6697 x"),
    ]
    third = [
        (NOW - 30000, "accepted c.example.net:+6697 x"),
        (NOW - 29000, "failed c.example.net:+6697 x"),
    ]
    facts = run_windows([[log_page(first)], [log_page(second)], [log_page(third)]])
    assert [row["value"].startswith("accepted ") for row in facts["rows"]] == [True] * 3


def test_a_window_that_hits_the_page_cap_is_flagged_by_name():
    capped = [log_page([], token=f"t{n}") for n in range(plugin.EVENT_MAX_PAGES)]
    facts = run_windows([capped, [log_page([])], [log_page([])]])
    assert all(row["caption"] == "truncated in 1 h" for row in facts["rows"])


def test_every_capped_window_is_named():
    capped = [log_page([], token=f"t{n}") for n in range(plugin.EVENT_MAX_PAGES)]
    facts = run_windows([capped, [log_page([])], capped])
    assert all(row["caption"] == "truncated in 1 h, 6-24 h" for row in facts["rows"])


def test_a_short_history_is_not_truncated():
    facts = run_windows(
        [[log_page([], token="t1"), log_page([])], [log_page([])], [log_page([])]]
    )
    assert all("caption" not in row for row in facts["rows"])


def test_truncation_follows_the_failure_caption():
    capped = [log_page([(NOW - 60, "failed a.example.net:+6697 down")], token="t0")]
    capped += [log_page([], token=f"t{n}") for n in range(1, plugin.EVENT_MAX_PAGES)]
    facts = run_windows([capped, [log_page([])], [log_page([])]])
    assert facts["rows"][0]["caption"].endswith("down; truncated in 1 h")


def probes(at, **results):
    return {"at": at, "results": results}


def test_the_newest_probe_across_bots_is_shown_per_server():
    old = probes(NOW - 7200, **{SERVERS[0]: {"ok": False, "error": "timeout"}})
    new = probes(
        NOW - 600,
        **{
            SERVERS[0]: {"ok": True, "seconds": 1.34},
            SERVERS[1]: {"ok": False, "error": "no AAAA"},
        },
    )
    facts = run_windows(
        [[log_page([])], [log_page([])], [log_page([])]],
        {"i-1": snapshot(probes=old), "i-2": snapshot(probes=new)},
    )
    first, second, third = facts["rows"]
    assert first["caption"] == f"probe ok 1.3 s {plugin.clock(NOW - 600)}"
    assert second["caption"] == f"probe no AAAA {plugin.clock(NOW - 600)}"
    assert "caption" not in third


def test_snapshots_without_probes_add_no_caption():
    facts = run_windows(
        [[log_page([])], [log_page([])], [log_page([])]],
        {"i-1": snapshot(), "i-2": snapshot(probes={})},
    )
    assert all("caption" not in row for row in facts["rows"])


def test_probe_caption_follows_the_failure_caption():
    pages = [
        [log_page([(NOW - 60, "failed a.example.net:+6697 down")])],
        [log_page([])],
        [log_page([])],
    ]
    result = probes(NOW - 600, **{SERVERS[0]: {"ok": False, "error": "tls"}})
    facts = run_windows(pages, {"i-1": snapshot(probes=result)})
    assert facts["rows"][0]["caption"].endswith(
        f"down; probe tls {plugin.clock(NOW - 600)}"
    )


def test_a_busy_window_is_read_past_five_pages_without_truncation():
    pages = [log_page([], token=f"t{n}") for n in range(6)]
    pages.append(log_page([(NOW - 60, "accepted a.example.net:+6697 a1")]))
    facts = run_windows([pages, [log_page([])], [log_page([])]])
    assert facts["rows"][0]["value"] == f"accepted {plugin.clock(NOW - 60)}"
    assert "caption" not in facts["rows"][0]


def test_a_window_keeps_only_its_newest_events(monkeypatch):
    monkeypatch.setattr(plugin, "EVENT_KEEP", 1)
    pages = [
        log_page([(NOW - 3000, "failed a.example.net:+6697 old")], token="t0"),
        log_page([(NOW - 100, "accepted a.example.net:+6697 a1")]),
    ]
    facts = run_windows([pages, [log_page([])], [log_page([])]])
    assert "caption" not in facts["rows"][0]
    assert facts["rows"][0]["value"] == f"accepted {plugin.clock(NOW - 100)}"


def test_both_sections_share_one_roster_read():
    logs, logs_stub = stubbed("logs")
    for number in range(3):
        logs_stub.add_response("filter_log_events", log_page([]), log_params(number))
    autoscaling, autoscaling_stub = stubbed("autoscaling")
    s3, s3_stub = stubbed("s3")
    stub_group(autoscaling_stub, ["i-1", "i-2"])
    for instance_id in ("i-1", "i-2"):
        s3_stub.add_response(
            "get_object",
            object_response(snapshot()),
            {"Bucket": BUCKET, "Key": f"bots/{instance_id}.json"},
        )
    with (
        logs_stub,
        autoscaling_stub,
        s3_stub,
        patch_clients(logs=logs, autoscaling=autoscaling, s3=s3),
        mock.patch.object(plugin.time, "time", return_value=NOW),
    ):
        sections = plugin.sections()
        bots, servers = sections["bots"](), sections["servers"]()
    assert len(bots["rows"]) == 2
    assert len(servers["rows"]) == 3


GOOD = {"ok": True, "seconds": 1.0}
MALFORMED = [
    "text",
    ["list"],
    {"results": {SERVERS[0]: GOOD}},
    {"at": "soon", "results": {SERVERS[0]: GOOD}},
    {"at": True, "results": {SERVERS[0]: GOOD}},
    {"at": 1e30, "results": {SERVERS[0]: GOOD}},
    {"at": NOW, "results": ["list"]},
    {"at": NOW, "results": {SERVERS[0]: "text"}},
    {"at": NOW, "results": {SERVERS[0]: {"seconds": 1.0}}},
    {"at": NOW, "results": {SERVERS[0]: {"ok": True}}},
    {"at": NOW, "results": {SERVERS[0]: {"ok": True, "seconds": "fast"}}},
    {"at": NOW, "results": {SERVERS[0]: {"ok": False}}},
    {"at": NOW, "results": {SERVERS[0]: {"ok": False, "error": 5}}},
]


@pytest.mark.parametrize("block", MALFORMED)
def test_a_malformed_probe_block_never_breaks_the_servers_section(block):
    facts = run_windows(
        [[log_page([])], [log_page([])], [log_page([])]],
        {"i-1": snapshot(probes=block)},
    )
    assert len(facts["rows"]) == 3
    assert "caption" not in facts["rows"][0]


def test_one_malformed_result_leaves_the_others():
    block = {
        "at": NOW - 60,
        "results": {SERVERS[0]: {"ok": True}, SERVERS[1]: GOOD},
    }
    facts = run_windows(
        [[log_page([])], [log_page([])], [log_page([])]],
        {"i-1": snapshot(probes=block)},
    )
    assert "caption" not in facts["rows"][0]
    assert facts["rows"][1]["caption"].startswith("probe ok 1.0 s")


def test_a_probe_that_died_is_shown_as_a_failed_probe_row():
    block = {"at": NOW - 60, "error": "RuntimeError: disk full"}
    facts = run_windows(
        [[log_page([])], [log_page([])], [log_page([])]],
        {"i-1": snapshot(probes=block)},
    )
    assert facts["rows"][-1] == {
        "label": "probe",
        "value": "failed",
        "caption": f"RuntimeError: disk full {plugin.clock(NOW - 60)}",
    }
    assert len(facts["rows"]) == 4


def test_an_older_probe_error_yields_to_newer_results():
    old = {"at": NOW - 7200, "error": "RuntimeError: disk full"}
    new = probes(NOW - 60, **{SERVERS[0]: GOOD})
    facts = run_windows(
        [[log_page([])], [log_page([])], [log_page([])]],
        {"i-1": snapshot(probes=old), "i-2": snapshot(probes=new)},
    )
    assert len(facts["rows"]) == 3
