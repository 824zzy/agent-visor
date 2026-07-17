#!/usr/bin/env python3
"""
Agent Visor hook shim for Augment's `auggie` CLI.

Auggie emits a different on-stdin schema from claude-code. This shim
translates Auggie's wire format into agent-visor's internal HookEvent
shape and forwards to /tmp/agent-visor.sock. The `agent: "auggie"`
stamp lets the single socket multiplex.

Auggie events we observe:
  PreToolUse, PostToolUse, SessionStart, SessionEnd, Stop

Auggie does NOT emit PermissionRequest, Notification, UserPromptSubmit,
SubagentStop, or PreCompact. Permission gating in Auggie is via
PreToolUse exit code 2; we don't synthesize a prompt from PreToolUse
today (would gate every tool call). That's a Phase 3b decision.

Key remapping (Auggie → agent-visor):
  hook_event_name → event
  conversation_id → session_id
  workspace_roots[0] → cwd
  tool_name → tool
  tool_input → tool_input (verbatim)

Status mapping mirrors claude-code's:
  PreToolUse → running_tool
  PostToolUse → processing
  SessionStart → idle
  SessionEnd → ended
  Stop → waiting_for_input

Source spec: https://docs.augmentcode.com/cli/hooks.md
"""
import json
import os
import socket
import subprocess
import sys

SOCKET_PATH = "/tmp/agent-visor.sock"


def get_tty():
    """Resolve TTY of the parent (auggie) process; falls back to our own."""
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


def send_event(state):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())
        sock.close()
    except (socket.error, OSError):
        pass


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        # Bad input; don't block auggie.
        sys.exit(0)

    event = data.get("hook_event_name", "")
    conversation_id = data.get("conversation_id", "unknown")
    roots = data.get("workspace_roots", []) or []
    cwd = roots[0] if roots else os.environ.get("AUGMENT_PROJECT_DIR", "")

    state = {
        "session_id": conversation_id,
        "cwd": cwd,
        "event": event,
        "pid": os.getppid(),
        "tty": get_tty(),
        "agent": "auggie",
    }

    if event == "PreToolUse":
        state["status"] = "running_tool"
        if data.get("tool_name") is not None:
            state["tool"] = data.get("tool_name")
        if data.get("tool_input") is not None:
            state["tool_input"] = data.get("tool_input")
    elif event == "PostToolUse":
        state["status"] = "processing"
        if data.get("tool_name") is not None:
            state["tool"] = data.get("tool_name")
        if data.get("tool_input") is not None:
            state["tool_input"] = data.get("tool_input")
    elif event == "SessionStart":
        state["status"] = "idle"
    elif event == "SessionEnd":
        state["status"] = "ended"
    elif event == "Stop":
        state["status"] = "waiting_for_input"
    else:
        state["status"] = "unknown"

    send_event(state)
    # Always exit 0: this shim observes only, never blocks auggie.
    sys.exit(0)


if __name__ == "__main__":
    main()
