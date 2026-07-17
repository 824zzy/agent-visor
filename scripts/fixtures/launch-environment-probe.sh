#!/bin/zsh

set -euo pipefail

print -r -- "${AGENT_VISOR_LAUNCH_ENV_PROBE:-missing}" \
  >"$AGENT_VISOR_LAUNCH_ENV_OUTPUT"
