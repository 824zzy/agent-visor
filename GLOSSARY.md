# Agent Visor

Agent Visor presents agent sessions and helps users return to their conversations. Session state and whether a result has been reviewed are separate concepts.

## Language

**Needs you**:
A session with an unanswered question or permission request addressed to the user.
_Avoid_: Unread message count, ready count

**Ready**:
A session whose current turn is complete and which can be continued. Ready describes availability; it does not by itself require user action.
_Avoid_: Needs you, unread

**Unopened completion**:
A finished turn whose result has not yet been reviewed by the user, whether its conversation remains open or has closed.
_Avoid_: Unread message, pending question

**Open conversation**:
A conversation confirmed to remain open in an application or terminal, or to have a live agent runtime, whether working or idle. A visible frontend is not required, and a saved catalog entry alone does not establish that it is open.
_Avoid_: Recent conversation, foreground conversation

**Saved**:
Retained conversations without verified current live presence. A saved conversation may be confirmed closed or have unknown current presence; it does not imply that the conversation is closed or inactive.
_Avoid_: Closed sessions, inactive sessions, unavailable sessions

**Current**:
Conversations confirmed to remain open, including working, idle, and live background conversations. Inactivity or closing one frontend alone does not remove a still-open conversation from Current.
_Avoid_: Recent sessions, running turns

**Inactive**:
An idle conversation without recent agent activity whose latest completion has already been reviewed. Inactive describes recency, not closure.
_Avoid_: Closed, stopped

**Status unavailable**:
Conversations whose current state cannot be checked because observation failed or is temporarily unavailable. A saved record without live-presence evidence alone does not indicate a detection failure.
_Avoid_: Saved, closed, deleted

**Closed terminal conversation**:
A saved terminal conversation confirmed to be no longer open in a frontend or live agent runtime. Completing a turn or closing one frontend while the conversation continues elsewhere does not establish closure.
_Avoid_: Finished session, deleted conversation

**Read chat**:
Read-only access to a conversation's transcript. Reading a chat does not allow sending messages or controlling the agent.
_Avoid_: Resume chat, continue the session, interactive Chat

**Retained history record**:
A searchable record of a previously observed conversation that remains available after its terminal closes and Agent Visor restarts. Retaining the record does not mean the conversation is running.
_Avoid_: Live session, active pill

**Resume in original terminal**:
Continue the same saved conversation in its previous terminal application, working directory and provider profile. If that conversation is already open, return to its existing instance.
_Avoid_: New conversation, open source app
