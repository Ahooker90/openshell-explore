#!/usr/bin/env bash
# Point OpenShell's inference.local at the backend defined in config.env.
# Idempotent: it recreates the provider each run. Re-run after editing config.env.
set -euo pipefail
cd "$(dirname "$0")"

# Load PROVIDER_NAME / MODEL / BACKEND_BASE_URL / BACKEND_API_KEY
set -a; . ./config.env; set +a

echo "Provider '$PROVIDER_NAME' -> $BACKEND_BASE_URL   (model: $MODEL)"

# (Re)create the credential provider for the backend.
openshell provider delete "$PROVIDER_NAME" >/dev/null 2>&1 || true
openshell provider create --name "$PROVIDER_NAME" --type openai \
  --credential OPENAI_API_KEY="$BACKEND_API_KEY" \
  --config OPENAI_BASE_URL="$BACKEND_BASE_URL"

# Route inference.local at that provider/model.
# --no-verify: the gateway's reachability probe can time out on a large local
# model that hasn't been loaded yet. We prove the route from inside the sandbox
# (run.sh) instead. Drop --no-verify once your endpoint answers quickly.
openshell inference set --provider "$PROVIDER_NAME" --model "$MODEL" --timeout 180 --no-verify

echo
openshell inference get
