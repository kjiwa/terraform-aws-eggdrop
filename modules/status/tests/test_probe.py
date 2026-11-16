"""The bot's server probe against a local TLS server standing in for an IRC server."""

import importlib.util
import json
import os
import socket
import ssl
import subprocess
import sys
import threading
import time

import pytest

PROBE_PATH = os.path.join(
    os.path.dirname(__file__), "..", "..", "compute", "files", "eggdrop-probe.py"
)
spec = importlib.util.spec_from_file_location("eggdrop_probe", PROBE_PATH)
eggdrop_probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eggdrop_probe)


@pytest.fixture(scope="module")
def certificate(tmp_path_factory):
    directory = tmp_path_factory.mktemp("tls")
    key, cert = directory / "key.pem", directory / "cert.pem"
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key]
        + ["-out", cert, "-subj", "/CN=localhost", "-days", "1"],
        check=True,
        capture_output=True,
    )
    return cert, key


@pytest.fixture(autouse=True)
def localhost_only_ipv6(monkeypatch):
    """Every probe resolves its host to ::1, or to nothing for no-aaaa.example."""
    resolve = socket.getaddrinfo

    def getaddrinfo(host, *arguments):
        if host == "no-aaaa.example":
            raise socket.gaierror
        return resolve("::1", *arguments)

    monkeypatch.setattr(socket, "getaddrinfo", getaddrinfo)


class Server:
    """Accepts one connection, runs script(connection, received) and records the lines received."""

    def __init__(self, certificate, script):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(*certificate)
        self.listener = socket.socket(socket.AF_INET6)
        self.listener.bind(("::1", 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.received = []
        self.script = script
        self.context = context
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        connection, _ = self.listener.accept()
        try:
            with self.context.wrap_socket(connection, server_side=True) as tls:
                tls.settimeout(5)
                self.script(tls, self.received)
        except OSError:
            pass
        finally:
            self.listener.close()


def welcome(connection, received):
    buffer = b""
    while b"USER" not in buffer:
        buffer += connection.recv(4096)
    received.extend(buffer.decode().split("\r\n"))
    nick = received[0].split()[1]
    connection.sendall(f":irc.test 001 {nick} :Welcome\r\n".encode())
    received.extend(connection.recv(4096).decode().split("\r\n"))


def ping_then_welcome(connection, received):
    connection.sendall(b"PING :token\r\n")
    welcome(connection, received)


def silence(connection, received):
    connection.recv(4096)
    threading.Event().wait(2)


def error(connection, received):
    connection.recv(4096)
    connection.sendall(b"ERROR :Closing Link: (K-Lined)\r\n")


def test_welcome_is_ok_with_the_seconds_taken(certificate):
    server = Server(certificate, welcome)
    result = eggdrop_probe.probe("localhost", server.port)
    server.thread.join()
    assert result["ok"] is True
    assert 0 <= result["seconds"] < 5


def test_probe_sends_a_random_nick_and_quits_without_joining(certificate):
    nicks = []
    for _ in range(2):
        server = Server(certificate, welcome)
        eggdrop_probe.probe("localhost", server.port)
        server.thread.join()
        nicks.append(server.received[0])
        assert server.received[0].startswith("NICK p")
        assert not any(line.startswith("JOIN") for line in server.received)
        assert "QUIT" in server.received
    assert nicks[0] != nicks[1]


def test_ping_before_the_welcome_is_answered(certificate):
    server = Server(certificate, ping_then_welcome)
    result = eggdrop_probe.probe("localhost", server.port)
    server.thread.join()
    assert result["ok"] is True
    assert "PONG :token" in server.received


def test_no_welcome_times_out(certificate):
    server = Server(certificate, silence)
    result = eggdrop_probe.probe("localhost", server.port, welcome_seconds=0.5)
    assert result == {"ok": False, "error": "timeout"}


def test_error_line_is_the_failure(certificate):
    server = Server(certificate, error)
    result = eggdrop_probe.probe("localhost", server.port)
    assert result == {"ok": False, "error": "ERROR :Closing Link: (K-Lined)"}


def test_closed_without_a_welcome_is_a_failure(certificate):
    server = Server(certificate, lambda connection, received: connection.recv(4096))
    result = eggdrop_probe.probe("localhost", server.port)
    assert result == {"ok": False, "error": "closed"}


def test_refused_connection_is_a_failure():
    listener = socket.socket(socket.AF_INET6)
    listener.bind(("::1", 0))
    port = listener.getsockname()[1]
    listener.close()
    result = eggdrop_probe.probe("localhost", port)
    assert result["ok"] is False
    assert result["error"].startswith("connect: ")


def test_plain_text_server_is_a_tls_failure():
    listener = socket.socket(socket.AF_INET6)
    listener.bind(("::1", 0))
    listener.listen(1)

    def plain():
        connection, _ = listener.accept()
        connection.sendall(b"not tls at all\r\n")
        connection.close()

    thread = threading.Thread(target=plain, daemon=True)
    thread.start()
    result = eggdrop_probe.probe("localhost", listener.getsockname()[1])
    listener.close()
    assert result == {"ok": False, "error": "tls"}


def test_host_without_aaaa_is_a_failure():
    assert eggdrop_probe.probe("no-aaaa.example", 6697) == {
        "ok": False,
        "error": "no AAAA",
    }


def test_main_writes_every_server_in_order(certificate, tmp_path, monkeypatch):
    server = Server(certificate, welcome)
    out = tmp_path / "probes.json"
    live = f"localhost:+{server.port}"
    monkeypatch.setattr(sys, "argv", ["probe", str(out), live, "no-aaaa.example:+6697"])
    eggdrop_probe.main()
    body = json.loads(out.read_text())
    assert list(body["results"]) == [live, "no-aaaa.example:+6697"]
    assert body["results"][live]["ok"] is True
    assert body["results"]["no-aaaa.example:+6697"]["error"] == "no AAAA"
    assert isinstance(body["at"], int)
    assert not (tmp_path / "probes.json.tmp").exists()


def test_server_entry_splits_host_and_port():
    assert eggdrop_probe.parse_server("irc.example.net:+6697") == (
        "irc.example.net",
        6697,
    )
    assert eggdrop_probe.parse_server("2001:db8::1:6697") == ("2001:db8::1", 6697)


class Scripted:
    """A connection fed canned lines, whose writes can fail."""

    def __init__(self, lines, fail_on=None):
        self.lines = [line.encode() + b"\r\n" for line in lines]
        self.fail_on = fail_on
        self.sent = []

    def settimeout(self, seconds):
        pass

    def recv(self, size):
        return self.lines.pop(0) if self.lines else b""

    def sendall(self, data):
        if self.fail_on and data.startswith(self.fail_on):
            raise BrokenPipeError(32, "Broken pipe")
        self.sent.append(data.decode())

    def close(self):
        pass


def test_a_failed_quit_after_the_welcome_leaves_the_probe_ok(monkeypatch):
    connection = Scripted([":irc.test 001 nick :Welcome"], fail_on=b"QUIT")
    monkeypatch.setattr(eggdrop_probe, "connect", lambda *arguments: connection)
    assert eggdrop_probe.probe("localhost", 6697)["ok"] is True


def test_the_handshake_gets_only_the_time_left(monkeypatch):
    seen = []

    class Context:
        check_hostname = verify_mode = None

        def wrap_socket(self, raw, server_hostname):
            seen.append(raw.gettimeout())
            raw.close()
            raise ssl.SSLError("stop")

    connect = socket.socket.connect

    def slow_connect(self, address):
        threading.Event().wait(0.3)
        connect(self, address)

    listener = socket.socket(socket.AF_INET6)
    listener.bind(("::1", 0))
    listener.listen(1)
    monkeypatch.setattr(socket.socket, "connect", slow_connect)
    monkeypatch.setattr(ssl, "create_default_context", lambda: Context())
    eggdrop_probe.probe("localhost", listener.getsockname()[1], welcome_seconds=1.0)
    listener.close()
    assert seen[0] < 0.75


def refuse(numeric):
    def script(connection, received):
        connection.recv(4096)
        connection.sendall(f":irc.test {numeric} * :Not for you\r\n".encode())
        threading.Event().wait(2)

    return script


@pytest.mark.parametrize("numeric", ["465", "464", "463", "432", "484"])
def test_a_registration_refusal_fails_at_once_with_numeric_and_text(
    certificate, numeric
):
    server = Server(certificate, refuse(numeric))
    started = time.monotonic()
    result = eggdrop_probe.probe("localhost", server.port)
    assert result == {"ok": False, "error": f"{numeric} Not for you"}
    assert time.monotonic() - started < 1.5


def nick_in_use_then(second):
    def script(connection, received):
        connection.recv(4096)
        connection.sendall(b":irc.test 433 * pfirst :Nickname is already in use\r\n")
        received.append(connection.recv(4096).decode().strip())
        connection.sendall(second.encode())
        threading.Event().wait(1)

    return script


def test_a_nick_in_use_is_retried_once_with_a_new_nick(certificate):
    server = Server(certificate, nick_in_use_then(":irc.test 001 x :Welcome\r\n"))
    result = eggdrop_probe.probe("localhost", server.port)
    assert result["ok"] is True
    assert server.received[0].startswith("NICK p")


def test_a_second_nick_in_use_is_the_failure(certificate):
    second = ":irc.test 433 * p :Nickname is already in use\r\n"
    server = Server(certificate, nick_in_use_then(second))
    result = eggdrop_probe.probe("localhost", server.port)
    assert result == {"ok": False, "error": "433 Nickname is already in use"}


def test_main_writes_a_top_level_error_when_the_probe_dies(tmp_path, monkeypatch):
    def explode(*arguments):
        raise RuntimeError("disk full")

    out = tmp_path / "probes.json"
    monkeypatch.setattr(eggdrop_probe, "probe", explode)
    monkeypatch.setattr(sys, "argv", ["probe", str(out), "a.example:+6697"])
    eggdrop_probe.main()
    body = json.loads(out.read_text())
    assert body["error"] == "RuntimeError: disk full"
    assert isinstance(body["at"], int)
    assert "results" not in body
