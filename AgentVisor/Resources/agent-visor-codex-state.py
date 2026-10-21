#!/usr/bin/env python3
"""
Agent Visor observer hook for OpenAI Codex.

This observer hook is read-only: forward lifecycle/tool events to Agent Visor
so the app can show live Codex sessions, but never approve/deny on Codex's
behalf. Codex-owned PermissionRequest events fall through to Codex's native UI.
"""
import datetime
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import tempfile

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


def observe_frontend(session_id, cwd, data, event):
    """Capture the native CLI ancestor, never the short-lived hook shell."""
    if event not in ("SessionStart", "UserPromptSubmit", "SessionEnd"):
        return None
    if not isinstance(session_id, str) or not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", session_id):
        return None
    if not isinstance(cwd, str) or not os.path.isabs(cwd):
        return None
    inherited = os.environ.get("CODEX_THREAD_ID")
    if inherited and inherited.lower() != session_id.lower():
        return None
    try:
        result = subprocess.run(
            ["/bin/ps", "-axww", "-o", "pid=,ppid=,lstart=,tty=,comm="],
            env={**os.environ, "TZ": "UTC", "LC_ALL": "C"},
            capture_output=True, text=True, timeout=2,
        )
        if result.returncode != 0:
            return None
        rows = {}
        for line in result.stdout.splitlines():
            match = re.fullmatch(r"\s*(\d+)\s+(\d+)\s+(\S+\s+\S+\s+\d+\s+[\d:]+\s+\d+)\s+(\S+)\s+(.+)", line)
            if match:
                pid, parent, started, tty, command = match.groups()
                rows[int(pid)] = (int(parent), started, tty, command)
        pid, visited = os.getppid(), set()
        while pid in rows and pid not in visited:
            visited.add(pid)
            parent, started, tty, command = rows[pid]
            if os.path.basename(command) == "codex":
                break
            pid = parent
        else:
            return None
        if not re.fullmatch(r"tty[A-Za-z0-9]+", tty):
            return None
        started_ms = int(datetime.datetime.strptime(started, "%a %b %d %H:%M:%S %Y")
                         .replace(tzinfo=datetime.timezone.utc).timestamp() * 1000)
        digest = hashlib.sha256(f"{pid}|{started_ms}".encode()).hexdigest()
        home = os.path.realpath(os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex"))
        observation = {"version": 1, "sessionId": session_id.lower(), "pid": pid,
                       "tty": tty, "cwd": cwd, "home": home,
                       "processStartToken": f"v1:{pid}:{started_ms}:{digest}",
                       "observedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       "ended": event == "SessionEnd"}
        session_file = first(data, "transcript_path", "session_file")
        if isinstance(session_file, str) and os.path.isabs(session_file):
            observation["sessionFile"] = session_file
        directory = os.path.join(home, "agent-visor", "cli")
        os.makedirs(directory, mode=0o700, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=f".{pid}-", dir=directory)
        try:
            with os.fdopen(fd, "w") as handle:
                json.dump(observation, handle)
            os.replace(temporary, os.path.join(directory, f"{pid}.json"))
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        return observation
    except (OSError, ValueError, subprocess.SubprocessError):
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

    observation = observe_frontend(session_id, cwd, data, event)

    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": os.getppid(),
        "tty": get_tty(),
        "agent": "codex",
    }

    if observation:
        state["pid"] = observation["pid"]
        state["tty"] = "/dev/" + observation["tty"]
        if "sessionFile" in observation:
            state["session_file"] = observation["sessionFile"]

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
