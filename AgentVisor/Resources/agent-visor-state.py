#!/usr/bin/env python3
"""
Agent Visor Hook
- Sends session state to Agent Visor via Unix socket
- For PermissionRequest: waits for user decision from the app
"""
import json
import os
import socket
import sys

SOCKET_PATH = "/tmp/agent-visor.sock"
# Split the socket timeout into two phases. CONNECT_TIMEOUT covers
# "is the daemon reachable" and must be short so a dead or wedged daemon
# can't stall every claude-code session on the machine for hours.
# DECISION_TIMEOUT covers "user is reviewing in the notch" and matches
# Claude Code's PermissionRequest hook ceiling (24h); anything shorter
# closes the socket mid-review and a later "approve" click hits EPIPE.
CONNECT_TIMEOUT = 1.0
DECISION_TIMEOUT = 86400


def get_tty():
    """Get the TTY of the Claude process (parent)"""
    import subprocess

    # Get parent PID (Claude process)
    ppid = os.getppid()

    # Try to get TTY from ps command for the parent process
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2
        )
        tty = result.stdout.strip()
        if tty and tty != "??" and tty != "-":
            # ps returns just "ttys001", we need "/dev/ttys001"
            if not tty.startswith("/dev/"):
                tty = "/dev/" + tty
            return tty
    except Exception:
        pass

    # Fallback: try current process stdin/stdout
    try:
        return os.ttyname(sys.stdin.fileno())
    except (OSError, AttributeError):
        pass
    try:
        return os.ttyname(sys.stdout.fileno())
    except (OSError, AttributeError):
        pass
    return None


def send_event(state):
    """Send event to app, return response if any"""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())

        # For permission requests, switch to the long decision timeout
        # only AFTER the daemon has accepted the message. This isolates
        # "daemon unreachable" failures (fast fail-open) from
        # "user is reviewing" waits (slow, up to 24h).
        if state.get("status") == "waiting_for_approval":
            sock.settimeout(DECISION_TIMEOUT)
            response = sock.recv(4096)
            sock.close()
            if response:
                return json.loads(response.decode())
        else:
            sock.close()

        return None
    except (socket.error, OSError, json.JSONDecodeError):
        return None


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")
    tool_input = data.get("tool_input", {})

    # Get process info
    claude_pid = os.getppid()
    tty = get_tty()

    # Build state object. `agent` stamps which CLI emitted the event so
    # the single hook socket can multiplex across concurrent agents.
    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": claude_pid,
        "tty": tty,
        "agent": "claude",
    }

    # Map events to status
    if event == "UserPromptSubmit":
        # User just sent a message - Claude is now processing
        state["status"] = "processing"

    elif event == "PreToolUse":
        state["status"] = "running_tool"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id to Swift for caching
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event in ("PostToolUse", "PostToolUseFailure"):
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id so Swift can cancel the specific pending permission
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PermissionRequest":
        # Pass through only when the operator has explicitly waived per-tool
        # gating via permission_mode == "bypassPermissions" (bots, CI, the
        # --dangerously-skip-permissions flag). Respecting it honors
        # claude-code's own contract.
        #
        # Sessions without a controlling TTY (Cursor's Claude Code extension,
        # launchd-spawned headless runs, etc.) used to auto-allow as well,
        # but agent-visor's notch IS reachable for those — the user just
        # didn't have a terminal in the parent chain. From v2.1.8 onward
        # they route through the same Approve/Deny UI as Ghostty/iTerm2
        # sessions.
        permission_mode = data.get("permission_mode", "")
        operator_opted_out = permission_mode == "bypassPermissions"
        if operator_opted_out:
            state["status"] = "running_tool"
            state["tool"] = data.get("tool_name")
            state["tool_input"] = tool_input
            send_event(state)
            output = {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {"behavior": "allow"},
                }
            }
            print(json.dumps(output))
            sys.exit(0)

        # Interactive path: gate on the notch UI.
        state["status"] = "waiting_for_approval"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Forward upstream's `permission_suggestions` field VERBATIM
        # (including its presence/absence), regardless of contents. We
        # use the field as a binary "is option 2 eligible?" signal:
        # if claude-code's TUI would hide option 2 here (unsafe
        # compound, ineligible tool, etc.) it omits the field entirely
        # — that's our cue to hide it too. The actual rule is built
        # locally from tool_input by PermissionSuggestionBuilder, so
        # the contents claude-code sends here can be anything (often
        # Read rules even for Bash invocations).
        if "permission_suggestions" in data:
            state["permission_suggestions"] = data.get("permission_suggestions")
        # tool_use_id lookup handled by Swift-side cache from PreToolUse

        # Send to app and wait for decision
        response = send_event(state)

        if response:
            decision = response.get("decision", "ask")
            reason = response.get("reason", "")

            if decision == "allow":
                # Output JSON to approve. When agent-visor responds
                # with `updated_input` (snake_case Swift→Python wire),
                # forward it as `decision.updatedInput` (camelCase) so
                # claude-code's `PermissionContext.handleHookAllow`
                # uses it as the tool's `finalInput`. This is how the
                # AskUserQuestion form delivers `{questions, answers}`
                # without driving the in-terminal TUI.
                decision_obj = {"behavior": "allow"}
                updated_input = response.get("updated_input")
                if updated_input is not None:
                    decision_obj["updatedInput"] = updated_input
                # When the user picked the "Yes, and don't ask again…"
                # option, agent-visor sent back the upstream-supplied
                # `permission_suggestions` array verbatim. Forward it
                # as `updatedPermissions` (camelCase) so claude-code
                # persists the rule into settings AND applies it to
                # the in-memory permission context for the session.
                updated_permissions = response.get("updated_permissions")
                if updated_permissions is not None:
                    decision_obj["updatedPermissions"] = updated_permissions
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": decision_obj,
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

            elif decision == "deny":
                # Output JSON to deny
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {
                            "behavior": "deny",
                            "message": reason or "Denied by user via Agent Visor",
                        },
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

        # No response or "ask" - let Claude Code show its normal UI
        sys.exit(0)

    elif event == "Notification":
        notification_type = data.get("notification_type")
        # Skip permission_prompt - PermissionRequest hook handles this with better info
        if notification_type == "permission_prompt":
            sys.exit(0)
        elif notification_type == "idle_prompt":
            state["status"] = "waiting_for_input"
        else:
            state["status"] = "notification"
        state["notification_type"] = notification_type
        state["message"] = data.get("message")

    elif event == "Stop":
        state["status"] = "waiting_for_input"

    elif event == "StopFailure":
        state["status"] = "waiting_for_input"

    elif event == "SubagentStop":
        # The parent turn continues after a subagent returns its result.
        state["status"] = "processing"

    elif event == "SessionStart":
        # A live process with no turn is idle, not a completed result.
        state["status"] = "idle"

    elif event == "SessionEnd":
        state["status"] = "ended"

    elif event == "PreCompact":
        # Context is being compacted (manual or auto)
        state["status"] = "compacting"

    elif event == "PostCompact":
        state["status"] = (
            "waiting_for_input" if data.get("trigger") == "manual" else "processing"
        )

    else:
        state["status"] = "unknown"

    # Send to socket (fire and forget for non-permission events)
    send_event(state)


if __name__ == "__main__":
    main()
