# Agent Visor Sessions for Alfred

Type `av` in Alfred to search sessions by title, project, agent, owner, or folder.
Add multiple words to narrow the list, for example `av cursor visor`.
Press Return to open the selected session in its original app or terminal.
Results show the session's status, source, project, owner, and folder.

Requires Alfred Powerpack, Python 3.9+ at `/usr/bin/python3` (provided by Apple's
Command Line Tools), and a running Agent Visor **build that includes Alfred support**.
The workflow does not add the companion interface to an older running app.

## Install

1. Build and launch the companion Agent Visor app after reviewing its changes.
2. Build the workflow from the repository root:
   `python3 integrations/alfred/build_workflow.py`
3. Double-click `build/Agent-Visor-Sessions.alfredworkflow` and install it in Alfred.
4. Open Alfred and type `av` followed by a space.

The default data folder is `~/Library/Application Support/Agent Visor`.
If a development app uses a different profile, set its absolute data folder in
the workflow configuration. Do not point it at another user's profile.

## Behavior

- Matches come from the running app's current session summaries, including Recent sessions.
- All query words must match. Matches in the title lead, then the latest session
  activity sorts first. With no query, the most recent activity leads. Status stays
  visible but does not affect ordering. Up to 100 matches appear; keep typing to narrow them.
- Results refresh every two seconds while the search remains open.
- Sessions without an available original owner remain visible but cannot be opened.
- Selecting a result calls the app's existing `focusSession` path, including its
  existing Ready acknowledgment and exact-owner checks. Stale results fail with an
  error instead of opening an unrelated app or falling back to Chat.
- Searching does not mark completions as seen, read conversation bodies, or send agent messages.
- Navigation failures appear through Alfred's notification output; successful navigation is quiet.

## Local interface

The daemon creates `alfred/s.sock` in its data folder. The directory is
restricted to the current user (0700), and the Unix socket is 0600. It accepts one
newline-terminated JSON request per connection: `search` with a `query`, or `focus`
with a `sessionId`. It exposes no chat, approval, deletion, settings, or credential operations.
Requests and responses are bounded. No network listener or daemon authentication
token is exposed to Alfred, and the workflow stores no session index.

JSON result fields follow the [Alfred Script Filter format](https://www.alfredapp.com/help/workflows/inputs/script-filter/json/).
