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
A finished turn whose result has not yet been reviewed by the user.
_Avoid_: Unread message, pending question
