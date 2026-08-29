#!/usr/bin/env python3
"""Exercise the headless control CLI against a small public-protocol server."""

from __future__ import annotations

import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


def pack(value):
    if value is None:
        return b"\xc0"
    if value is True:
        return b"\xc3"
    if value is False:
        return b"\xc2"
    if isinstance(value, int):
        if 0 <= value < 128:
            return bytes((value,))
        if -32 <= value < 0:
            return bytes((256 + value,))
        if value >= 0:
            if value < 256:
                return b"\xcc" + bytes((value,))
            if value < 65536:
                return b"\xcd" + struct.pack(">H", value)
            return b"\xce" + struct.pack(">I", value)
        if value >= -128:
            return b"\xd0" + struct.pack(">b", value)
        if value >= -32768:
            return b"\xd1" + struct.pack(">h", value)
        return b"\xd2" + struct.pack(">i", value)
    if isinstance(value, str):
        data = value.encode()
        if len(data) < 32:
            return bytes((0xA0 | len(data),)) + data
        if len(data) < 256:
            return b"\xd9" + bytes((len(data),)) + data
        return b"\xda" + struct.pack(">H", len(data)) + data
    if isinstance(value, list):
        if len(value) >= 16:
            return b"\xdc" + struct.pack(">H", len(value)) + b"".join(pack(item) for item in value)
        return bytes((0x90 | len(value),)) + b"".join(pack(item) for item in value)
    if isinstance(value, dict):
        items = sorted(value.items())
        if len(items) >= 16:
            prefix = b"\xde" + struct.pack(">H", len(items))
        else:
            prefix = bytes((0x80 | len(items),))
        return prefix + b"".join(pack(key) + pack(item) for key, item in items)
    raise TypeError(type(value))


def unpack(data, position=0):
    marker = data[position]
    position += 1
    if marker <= 0x7F:
        return marker, position
    if marker >= 0xE0:
        return marker - 256, position
    if 0xA0 <= marker <= 0xBF:
        length = marker - 0xA0
        return data[position:position + length].decode(), position + length
    if 0x90 <= marker <= 0x9F:
        result = []
        for _ in range(marker - 0x90):
            item, position = unpack(data, position)
            result.append(item)
        return result, position
    if 0x80 <= marker <= 0x8F:
        result = {}
        for _ in range(marker - 0x80):
            key, position = unpack(data, position)
            value, position = unpack(data, position)
            result[key] = value
        return result, position
    if marker == 0xC0:
        return None, position
    if marker == 0xC2 or marker == 0xC3:
        return marker == 0xC3, position
    sizes = {0xCC: (1, ">B"), 0xCD: (2, ">H"), 0xCE: (4, ">I"), 0xD0: (1, ">b"), 0xD1: (2, ">h"), 0xD2: (4, ">i")}
    if marker in sizes:
        size, format_ = sizes[marker]
        return struct.unpack(format_, data[position:position + size])[0], position + size
    if marker in (0xD9, 0xDA):
        size = 1 if marker == 0xD9 else 2
        format_ = ">B" if size == 1 else ">H"
        length = struct.unpack(format_, data[position:position + size])[0]
        position += size
        return data[position:position + length].decode(), position + length
    if marker in (0xDE,):
        count = struct.unpack(">H", data[position:position + 2])[0]
        position += 2
        result = {}
        for _ in range(count):
            key, position = unpack(data, position)
            value, position = unpack(data, position)
            result[key] = value
        return result, position
    raise ValueError(f"unsupported marker {marker:#x}")


def read_exact(connection, length):
    result = bytearray()
    while len(result) < length:
        chunk = connection.recv(length - len(result))
        if not chunk:
            raise RuntimeError("control endpoint closed")
        result.extend(chunk)
    return bytes(result)


def read_frame(connection):
    length = struct.unpack(">I", read_exact(connection, 4))[0]
    return read_exact(connection, length)


def send_frame(connection, value):
    payload = pack(value)
    connection.sendall(struct.pack(">I", len(payload)) + payload)


class PublicServer:
    def __init__(self, endpoint, descriptor):
        self.endpoint = endpoint
        self.descriptor = descriptor
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.bind(endpoint)
        self.socket.listen(8)
        self.socket.settimeout(0.2)
        self.stop = False
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self):
        self.thread.start()

    def close(self):
        self.stop = True
        self.thread.join(5)
        self.socket.close()

    def run(self):
        while not self.stop:
            try:
                connection, _ = self.socket.accept()
            except socket.timeout:
                continue
            with connection:
                connection.settimeout(0.25)
                while True:
                    try:
                        request, _ = unpack(read_frame(connection))
                    except (socket.timeout, RuntimeError):
                        # Instance discovery probes the endpoint and closes it
                        # without sending a protocol request.
                        break
                    method = request["method"]
                    if method == "control.hello":
                        result = {"protocol_version": 1, "instance_id": self.descriptor["instance_id"]}
                    elif method == "instance.status":
                        result = self.descriptor
                    else:
                        result = {"ok": True}
                    send_frame(connection, {
                        "version": 1,
                        "kind": "response",
                        "id": request["id"],
                        "result": result,
                    })


def run(binary, args, environment):
    completed = subprocess.run([binary, "--ctl", *args], env=environment,
        text=True, capture_output=True, check=False)
    if completed.returncode:
        raise AssertionError(f"{args}: exit {completed.returncode}: stdout={completed.stdout!r} stderr={completed.stderr!r}")
    return json.loads(completed.stdout)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} PRAGTICAL-BINARY")
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="pragtical-ctl-test-") as root:
        root = Path(root)
        alias = root / "pragtical-ctl"
        alias.symlink_to(binary)
        runtime = root / "runtime"
        instances = runtime / "pragtical" / "instances"
        sockets = runtime / "pragtical" / "sockets"
        instances.mkdir(parents=True)
        sockets.mkdir()
        os.chmod(runtime, 0o700)
        endpoint = sockets / "test.sock"
        descriptor = {
            "version": 1,
            "instance_id": "test-instance",
            "pid": os.getpid(),
            "endpoint": str(endpoint),
            "started_at": int(time.time()),
            "protocol_version": 1,
            "project_roots": [str(root)],
        }
        (instances / "test-instance.msgpack").write_bytes(pack(descriptor))
        server = PublicServer(str(endpoint), descriptor)
        os.chmod(endpoint, 0o600)
        server.start()
        environment = dict(os.environ)
        environment["XDG_RUNTIME_DIR"] = str(runtime)
        environment["PRAGTICAL_USERDIR"] = str(root / "user")
        try:
            listed = run(binary, ["--output", "json", "list"], environment)
            assert listed[0]["instance_id"] == "test-instance", listed
            status = run(binary, ["--output", "json", "status"], environment)
            assert status["endpoint"] == str(endpoint), status
            selected = run(binary, ["--instance", "test-instance", "--timeout", "500ms", "--output", "json", "status"], environment)
            assert selected["instance_id"] == "test-instance", selected
            selected = run(binary, ["--project", str(root), "--output", "json", "status"], environment)
            assert selected["instance_id"] == "test-instance", selected
            assert run(binary, ["--output", "json", "call", "control.ping", '{"x":7}'], environment) == {"ok": True}
            alias_result = subprocess.run([str(alias), "--output", "json", "list"], env=environment,
                text=True, capture_output=True, check=False)
            assert alias_result.returncode == 0, alias_result
            assert json.loads(alias_result.stdout)[0]["instance_id"] == "test-instance", alias_result.stdout
            invalid = subprocess.run([binary, "--ctl", "--output", "json", "unknown"], env=environment,
                text=True, capture_output=True, check=False)
            assert invalid.returncode == 2, invalid
            assert json.loads(invalid.stdout)["error"]["code"] == "usage"
        finally:
            server.close()
    print("Control CLI test passed.")


if __name__ == "__main__":
    main()
