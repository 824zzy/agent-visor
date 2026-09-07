#!/usr/bin/env python3
"""Alfred client for Agent Visor's local session search interface (Python 3.9+)."""
import json
import os
from pathlib import Path
import socket
import stat
import sys
import time


def exchange(request):
    root = Path(os.environ.get("agent_visor_data_dir") or
                Path.home() / "Library/Application Support/Agent Visor")
    address = root.expanduser() / "alfred/s.sock"
    if len(os.fsencode(address)) > 103:
        raise ValueError("The data folder path is too long for the Alfred session socket.")
    parent = address.parent.lstat()
    info = address.lstat()
    if (not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid()
            or parent.st_mode & 0o077 or not stat.S_ISSOCK(info.st_mode)
            or info.st_uid != os.getuid() or info.st_mode & 0o077):
        raise ValueError("Agent Visor's session search socket is not private to your account.")
    deadline = time.monotonic() + (20 if request["action"] == "focus" else 2)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(max(0.01, deadline - time.monotonic()))
        client.connect(str(address))
        client.sendall((json.dumps(request) + "\n").encode("utf-8"))
        chunks = []
        size = 0
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Agent Visor did not respond in time.")
            client.settimeout(remaining)
            chunk = client.recv(65536)
            if not chunk:
                break
            size += len(chunk)
            if size > 1_048_576:
                raise ValueError("Agent Visor returned too many results. Narrow your search.")
            chunks.append(chunk)
    response = json.loads(b"".join(chunks).decode("utf-8"))
    if not isinstance(response, dict):
        raise ValueError("Unexpected response from Agent Visor.")
    if response.get("error"):
        raise ValueError(str(response["error"]))
    return response


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "search"
    value = sys.argv[2] if len(sys.argv) > 2 else ""
    try:
        if action not in ("search", "focus"):
            raise ValueError("Unknown workflow action.")
        request = {"action": action, "query" if action == "search" else "sessionId": value}
        response = exchange(request)
        if action == "search":
            if not isinstance(response.get("items"), list):
                raise ValueError("Agent Visor returned an invalid session list.")
            print(json.dumps(response))
        elif response.get("ok") is not True:
            raise ValueError("Agent Visor could not confirm opening this session.")
    except (OSError, ValueError) as error:
        if isinstance(error, (FileNotFoundError, ConnectionRefusedError)):
            message = "Open an Agent Visor build with Alfred support, then try again."
        else:
            message = str(error)
        if action == "search":
            print(json.dumps({"items": [{"title": "Agent Visor session search unavailable",
                                        "subtitle": message, "valid": False}]}))
        else:
            # Alfred shows nonempty output as an error notification. Successful navigation stays quiet.
            print(message)


if __name__ == "__main__":
    main()
