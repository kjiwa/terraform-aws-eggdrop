#!/usr/bin/env python3
"""Write whether each IRC server welcomes a client over IPv6 and TLS.

Usage: eggdrop-probe OUT_FILE HOST:+PORT...
Each server in turn gets a TLS connection and a random nick, and no channel is
joined. OUT_FILE holds {"at": <epoch>, "results": {"HOST:+PORT": {"ok": true,
"seconds": 1.3} | {"ok": false, "error": "no AAAA"}}}; the status page reads it
through the bot's snapshot (modules/status/plugin/plugin.py).
"""

import json
import os
import secrets
import socket
import ssl
import sys
import time

WELCOME_SECONDS = 30
ERROR_MAX_CHARS = 120


class Failure(Exception):
    pass


# Python before 3.10 raises socket.timeout, and an SSL socket's own timeout
# error, rather than TimeoutError, so a timeout is told by the deadline.
def timed_out(error, deadline):
    return isinstance(error, TimeoutError) or time.monotonic() >= deadline


def failure_text(stage, error, deadline):
    if timed_out(error, deadline):
        return "timeout"
    return f"{stage}: {error.strerror or error}"


def read_lines(connection, deadline):
    buffer = b""
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise Failure("timeout")
        connection.settimeout(remaining)
        try:
            data = connection.recv(4096)
        except OSError as error:
            raise Failure(failure_text("read", error, deadline)) from None
        if not data:
            raise Failure("closed")
        buffer += data
        *lines, buffer = buffer.split(b"\n")
        for line in lines:
            yield line.decode(errors="replace").strip()


def await_welcome(connection, deadline):
    for line in read_lines(connection, deadline):
        words = line.split()
        if line.startswith("PING"):
            connection.sendall(f"PONG {line[5:]}\r\n".encode())
        elif line.startswith("ERROR") or (len(words) > 1 and words[1] == "ERROR"):
            raise Failure(line[:ERROR_MAX_CHARS])
        elif len(words) > 1 and words[1] == "001":
            return


def connect(host, port, deadline):
    try:
        family, kind, proto, _, address = socket.getaddrinfo(
            host, port, socket.AF_INET6, socket.SOCK_STREAM
        )[0]
    except socket.gaierror:
        raise Failure("no AAAA") from None
    raw = socket.socket(family, kind, proto)
    try:
        raw.settimeout(max(deadline - time.monotonic(), 0.001))
        raw.connect(address)
    except OSError as error:
        raw.close()
        raise Failure(failure_text("connect", error, deadline)) from None
    # A bot does not verify the server's certificate either: the question is
    # whether the server welcomes, not whether it is who it says.
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    try:
        return context.wrap_socket(raw, server_hostname=host)
    except OSError as error:
        raw.close()
        raise Failure("timeout" if timed_out(error, deadline) else "tls") from None


def probe(host, port, welcome_seconds=WELCOME_SECONDS):
    started = time.monotonic()
    deadline = started + welcome_seconds
    try:
        connection = connect(host, port, deadline)
    except Failure as failure:
        return {"ok": False, "error": str(failure)}
    try:
        nick = f"p{secrets.token_hex(4)}"
        connection.sendall(f"NICK {nick}\r\nUSER {nick} 0 * :{nick}\r\n".encode())
        await_welcome(connection, deadline)
        elapsed = round(time.monotonic() - started, 1)
        connection.sendall(b"QUIT\r\n")
        return {"ok": True, "seconds": elapsed}
    except Failure as failure:
        return {"ok": False, "error": str(failure)}
    except OSError as error:
        return {"ok": False, "error": f"write: {error.strerror or error}"}
    finally:
        connection.close()


def parse_server(entry):
    host, _, port = entry.rpartition(":")
    return host, int(port.lstrip("+"))


def write_results(path, results, now=None):
    body = {"at": int(time.time() if now is None else now), "results": results}
    temporary = f"{path}.tmp"
    with open(temporary, "w") as out:
        json.dump(body, out)
    os.replace(temporary, path)


def main():
    path, entries = sys.argv[1], sys.argv[2:]
    results = {entry: probe(*parse_server(entry)) for entry in entries}
    write_results(path, results)


if __name__ == "__main__":
    main()
