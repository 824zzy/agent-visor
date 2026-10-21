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

**Closed terminal conversation**:
A conversation whose terminal frontend has closed, while its saved conversation remains available to continue. A completed turn alone does not make a conversation closed.
_Avoid_: Finished session, deleted conversation

**Retained history record**:
A searchable record of a previously observed conversation that remains available after its terminal closes and Agent Visor restarts. Retaining the record does not mean the conversation is running.
_Avoid_: Live session, active pill

**Resume in original terminal**:
Continue the same saved conversation in its previous terminal application, working directory and provider profile. If that conversation is already open, return to its existing instance.
_Avoid_: New conversation, open source app
