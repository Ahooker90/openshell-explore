#!/usr/bin/env bash
# Remove the sandbox and provider this example created.
# Usage: ./teardown.sh [sandbox-name]
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./config.env; set +a

openshell sandbox delete "${1:-example-agent}" >/dev/null 2>&1 || true
openshell provider delete "$PROVIDER_NAME" >/dev/null 2>&1 || true
echo "cleaned up sandbox '${1:-example-agent}' and provider '$PROVIDER_NAME'"
