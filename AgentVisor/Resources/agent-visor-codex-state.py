#!/usr/bin/env python3
"""
Agent Visor observer hook for OpenAI Codex.

This observer hook is read-only: forward lifecycle/tool events to Agent Visor
so the app can show live Codex sessions, but never approve/deny on Codex's
behalf. Codex-owned PermissionRequest events fall through to Codex's native UI.
"""
import json
import os
import socket
import subprocess
import sys

SOCKET_PATH = "/tmp/agent-visor.sock"
CONNECT_TIMEOUT = 1.0


def get_tty():
    ppid = os.getppid()
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2,
        )
        tty = result.stdout.strip()
        if tty and tty not in ("??", "-"):
            return tty if tty.startswith("/dev/") else "/dev/" + tty
    except Exception:
        pass
    for fd in (sys.stdin.fileno(), sys.stdout.fileno()):
        try:
            return os.ttyname(fd)
        except (OSError, AttributeError):
            continue
    return None


def first(data, *keys):
    for key in keys:
        value = data.get(key)
        if value not in (None, ""):
            return value
    return None


def send_event(state):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())
        sock.close()
    except (socket.error, OSError):
        pass


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    event = first(data, "hook_event_name", "event") or ""
    # Some Codex hook payloads expose a per-turn id in `session_id`.
    # Agent Visor tracks Codex sessions by the stable thread id.
    session_id = first(data, "thread_id", "conversation_id", "session_id") or "unknown"
    cwd = first(data, "cwd", "workspace_root") or os.getcwd()
    tool_input = first(data, "tool_input", "arguments") or {}

    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": os.getppid(),
        "tty": get_tty(),
        "agent": "codex",
    }

    if event == "UserPromptSubmit":
        state["status"] = "processing"
    elif event == "PreToolUse":
        state["status"] = "running_tool"
        state["tool"] = first(data, "tool_name", "tool", "name")
        state["tool_input"] = tool_input
        tool_id = first(data, "tool_use_id", "tool_call_id", "call_id")
        if tool_id:
            state["tool_use_id"] = tool_id
    elif event == "PostToolUse":
        state["status"] = "processing"
        state["tool"] = first(data, "tool_name", "tool", "name")
        state["tool_input"] = tool_input
        tool_id = first(data, "tool_use_id", "tool_call_id", "call_id")
        if tool_id:
            state["tool_use_id"] = tool_id
    elif event == "PermissionRequest":
        # Surface the awaiting-approval status so Agent Visor shows it
        # accurately. This is read-only: unlike the claude-code hook we
        # never wait for or send a decision — Codex's native UI owns the
        # approve/deny. Agent Visor gates `expectsResponse` to claude-code,
        # so this status drives the phase without opening a response path.
        state["status"] = "waiting_for_approval"
        state["tool"] = first(data, "tool_name", "tool", "name")
        state["tool_input"] = tool_input
    elif event == "Stop":
        state["status"] = "waiting_for_input"
    elif event == "SessionStart":
        state["status"] = "idle"
    elif event == "SessionEnd":
        state["status"] = "ended"
    elif event == "PreCompact":
        state["status"] = "compacting"
    else:
        state["status"] = "unknown"

    send_event(state)
    sys.exit(0)


if __name__ == "__main__":
    main()
