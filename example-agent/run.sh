#!/usr/bin/env bash
# Run the example agent inside a fresh sandbox. The agent calls inference.local,
# which the gateway routes to the backend you configured with setup.sh.
#
# Usage: ./run.sh [sandbox-name] [prompt]
set -euo pipefail
cd "$(dirname "$0")"

NAME="${1:-example-agent}"
PROMPT="${2:-In one sentence, what is OpenShell?}"

# --policy policy.yaml  : no general egress; only inference.local is reachable
# --upload agent.py     : copy the agent into the sandbox working dir (/sandbox)
# --no-auto-providers   : this agent isn't on the built-in list; no auto creds
openshell sandbox create --name "$NAME" --no-auto-providers --no-tty \
  --policy policy.yaml \
  --upload agent.py \
  -- python3 /sandbox/agent.py "$PROMPT"
