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


def stub_group(autoscaling, instance_ids):
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
                            "LifecycleState": "InService",
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


def run_bots(instance_ids, objects):
    autoscaling, autoscaling_stub = stubbed("autoscaling")
    s3, s3_stub = stubbed("s3")
    stub_group(autoscaling_stub, instance_ids)
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


def test_sections_name_both_collectors():
    assert set(plugin.sections()) == {"bots", "servers"}


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


def test_other_s3_errors_propagate():
    autoscaling, autoscaling_stub = stubbed("autoscaling")
    s3, s3_stub = stubbed("s3")
    stub_group(autoscaling_stub, ["i-1"])
    s3_stub.add_client_error("get_object", service_error_code="AccessDenied")
    clients = patch_clients(autoscaling=autoscaling, s3=s3)
    with (
        autoscaling_stub,
        s3_stub,
        clients,
        pytest.raises(Exception, match="AccessDenied"),
    ):
        plugin.bots(NOW)


def run_servers(messages):
    logs, logs_stub = stubbed("logs")
    logs_stub.add_response(
        "filter_log_events",
        {
            "events": [
                {"timestamp": int(seconds * 1000), "message": message}
                for seconds, message in messages
            ]
        },
        {"logGroupName": GROUP, "startTime": (NOW - 24 * 3600) * 1000},
    )
    with logs_stub, patch_clients(logs=logs):
        return plugin.servers(NOW)


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
