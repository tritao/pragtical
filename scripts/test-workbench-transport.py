#!/usr/bin/env python3
"""Exercise Workbench framing with a byte-at-a-time Unix socket writer."""

import socket
import struct
import sys
import time


def pack_string(value):
    encoded = value.encode("utf-8")
    if len(encoded) >= 32:
        raise ValueError("fragmentation test strings must use MessagePack fixstr")
    return bytes((0xA0 | len(encoded),)) + encoded


def hello_message(workspace):
    fields = (
        pack_string("protocol") + b"\x02",
        pack_string("kind") + pack_string("hello"),
        pack_string("request_id") + pack_string("fragment-test"),
        pack_string("workspace_id") + pack_string(workspace),
    )
    return b"\x84" + b"".join(fields)


def read_exact(connection, length):
    result = bytearray()
    while len(result) < length:
        chunk = connection.recv(length - len(result))
        if not chunk:
            raise RuntimeError("agent closed the transport while replying")
        result.extend(chunk)
    return bytes(result)


def read_frame(connection):
    response_length = struct.unpack(">I", read_exact(connection, 4))[0]
    if response_length > 16 * 1024 * 1024:
        raise RuntimeError("agent returned an oversized response frame")
    return read_exact(connection, response_length)


def send_frame(connection, payload):
    connection.sendall(struct.pack(">I", len(payload)) + payload)


def exercise_rejection_paths(endpoint, workspace):
    # A malformed MessagePack payload must be rejected at the client boundary
    # without taking down the authoritative agent.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(endpoint)
        send_frame(connection, b"\xc1")
        response = read_frame(connection)
        if b"invalid_protocol" not in response:
            raise RuntimeError("malformed MessagePack did not receive invalid_protocol")

    # A hostile frame length must only disconnect that client. The next hello
    # proves the listening agent and its existing state survived the rejection.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(endpoint)
        connection.sendall(struct.pack(">I", 16 * 1024 * 1024 + 1))
        if connection.recv(1) != b"":
            raise RuntimeError("oversized Workbench frame was not rejected")

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(endpoint)
        send_frame(connection, hello_message(workspace))
        response = read_frame(connection)
        if b"hello_result" not in response:
            raise RuntimeError("agent did not survive malformed transport input")


def main():
    if len(sys.argv) not in (2, 3):
        raise SystemExit(f"usage: {sys.argv[0]} ENDPOINT [WORKSPACE]")
    endpoint = sys.argv[1]
    workspace = sys.argv[2] if len(sys.argv) == 3 else "fragment-test"
    payload = hello_message(workspace)
    frame = struct.pack(">I", len(payload)) + payload

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(endpoint)
        for byte in frame:
            connection.sendall(bytes((byte,)))
            # Let the agent observe the incomplete frame between bytes. This
            # exercises both persistent header and persistent payload offsets.
            time.sleep(0.001)

        response = read_frame(connection)
        if b"hello_result" not in response:
            raise RuntimeError("fragmented hello did not receive hello_result")

    exercise_rejection_paths(endpoint, workspace)


if __name__ == "__main__":
    main()
