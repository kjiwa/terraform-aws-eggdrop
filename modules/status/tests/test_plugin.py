import importlib.util
import os
import time
from unittest import mock

import plugin
import pytest

KEY = b"0123456789abcdef"
MINT_PATH = os.path.join(
    os.path.dirname(__file__), "..", "..", "compute", "files", "naju-token.py"
)


def load_mint():
    spec = importlib.util.spec_from_file_location("naju_token", MINT_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.mint


mint = load_mint()


@pytest.fixture(autouse=True)
def key():
    with mock.patch.object(plugin, "_key", KEY):
        yield


def test_minted_token_is_accepted():
    assert plugin.authenticate({"x-naju-token": mint(KEY, 60)}) == "viewer"


def test_token_signed_with_another_key_is_rejected():
    assert plugin.authenticate({"x-naju-token": mint(b"other-key", 60)}) is None


def test_expired_token_is_rejected():
    assert (
        plugin.authenticate({"x-naju-token": mint(KEY, 60, time.time() - 120)}) is None
    )


def test_tampered_expiry_is_rejected():
    expiry, signature = mint(KEY, 60).split(".")
    assert (
        plugin.authenticate({"x-naju-token": f"{int(expiry) + 3600}.{signature}"})
        is None
    )


@pytest.mark.parametrize(
    "token",
    [
        "",
        "garbage",
        ".",
        "123.",
        ".abc",
        "abc.def",
        "1.2.3",
        "-5.abc",
        "\u00b2.abc",
        "123.\u00e9",
    ],
)
def test_malformed_token_is_rejected(token):
    assert plugin.authenticate({"x-naju-token": token}) is None


def test_missing_header_is_rejected():
    assert plugin.authenticate({}) is None


def test_key_is_read_from_ssm_once():
    client = mock.Mock()
    client.get_parameter.return_value = {"Parameter": {"Value": "secret\n"}}
    with (
        mock.patch.object(plugin, "_key", None),
        mock.patch.object(plugin.boto3, "client", return_value=client),
    ):
        assert plugin.load_key() == b"secret"
        assert plugin.load_key() == b"secret"
    client.get_parameter.assert_called_once_with(
        Name="/naju/status-key", WithDecryption=True
    )


def test_sections_adds_no_panels():
    assert plugin.sections() == {}
