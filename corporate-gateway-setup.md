# Creating an OpenShell Gateway in a Corporate Environment Without Claude

## Context

You're standing up an OpenShell gateway in a corporate environment where:

- **`api.anthropic.com` is not reachable** — no Claude, no Claude Code against the public Anthropic endpoint.
- You have (or will have) an **internal OpenAI-compatible LLM endpoint** — vLLM, NVIDIA NIM, TGI, an internal LiteLLM proxy, or similar.
- **Podman**, not Docker, is the container runtime.
- This is a **single-machine, loopback-only dev setup** — TLS disabled, bound to `127.0.0.1`, single user. Production hardening is out of scope here.

Goal: end up with a working `openshell sandbox create` flow where the agent inside the sandbox can call `https://inference.local` and get a real response from your internal model, with zero outbound dependency on Anthropic or OpenAI public APIs.

---

## Prerequisites

Gather these before starting. The setup is fast once you have them; slow if you don't.

| Item | Notes |
|---|---|
| Rootless podman 5.x+ | `podman info` should report cgroups v2 and a running user socket at `$XDG_RUNTIME_DIR/podman/podman.sock`. Start it with `systemctl --user enable --now podman.socket` if needed. |
| Internal model endpoint URL | The full base URL ending in `/v1`, e.g. `https://vllm.corp.example.com/v1`. Must be reachable from the host running the gateway. |
| API key for that endpoint (or `empty`) | Whatever the endpoint expects in the `Authorization: Bearer ...` header. If it accepts unauthenticated calls, use the literal string `empty`. |
| Model name your endpoint serves | The string you pass as `model` in `/v1/chat/completions`. Example: `meta-llama/Llama-3.1-70B-Instruct`. |
| Corporate CA bundle (if applicable) | If your internal endpoint uses a cert signed by an internal CA, you'll need it both in the gateway container and in the sandbox. Path on most RHEL/Fedora hosts: `/etc/pki/ca-trust/source/anchors/`. |
| Network egress to `ghcr.io` **or** a mirrored gateway image | The published image is `ghcr.io/nvidia/openshell/gateway:latest`. If ghcr is blocked, mirror it into your internal registry first. |
| `openshell` CLI installed locally | Get it from the project's install script or the Python package: `pipx install openshell` (uses `uv` under the hood). |

---

## Step 1 — Make the gateway image available

If `ghcr.io` is reachable from this host, skip to step 2. Otherwise mirror the image into your internal registry once:

```shell
# Run this on a host that can reach BOTH ghcr.io AND your internal registry.
podman pull ghcr.io/nvidia/openshell/gateway:latest
podman tag ghcr.io/nvidia/openshell/gateway:latest registry.corp.example.com/openshell/gateway:latest
podman push registry.corp.example.com/openshell/gateway:latest
```

For every command below that references `ghcr.io/nvidia/openshell/gateway:latest`, substitute your mirrored image path. Verify pull works from the gateway host:

```shell
podman pull registry.corp.example.com/openshell/gateway:latest
```

---

## Step 2 — Start the gateway under podman

Bind to loopback, disable TLS (single-user dev only), mount the podman socket so the gateway can drive podman, and point persistence at a named volume.

```shell
podman run -d \
  --name openshell-gateway \
  --restart unless-stopped \
  -p 127.0.0.1:8080:8080 \
  -v openshell-state:/var/openshell \
  -v "$XDG_RUNTIME_DIR/podman/podman.sock:/var/run/podman.sock" \
  -e OPENSHELL_DRIVERS=podman \
  -e OPENSHELL_PODMAN_SOCKET=/var/run/podman.sock \
  -e OPENSHELL_DB_URL=sqlite:/var/openshell/openshell.db \
  -e OPENSHELL_DISABLE_TLS=true \
  ghcr.io/nvidia/openshell/gateway:latest
```

### If your internal model endpoint uses a corporate CA

The gateway terminates TLS to the upstream model server itself when routing through `inference.local`, so the gateway container needs to trust the corporate CA. Mount your CA bundle in:

```shell
podman run -d \
  --name openshell-gateway \
  --restart unless-stopped \
  -p 127.0.0.1:8080:8080 \
  -v openshell-state:/var/openshell \
  -v "$XDG_RUNTIME_DIR/podman/podman.sock:/var/run/podman.sock" \
  -v /etc/pki/ca-trust/source/anchors:/etc/pki/ca-trust/source/anchors:ro \
  -v /etc/pki/ca-trust/extracted:/etc/pki/ca-trust/extracted:ro \
  -e OPENSHELL_DRIVERS=podman \
  -e OPENSHELL_PODMAN_SOCKET=/var/run/podman.sock \
  -e OPENSHELL_DB_URL=sqlite:/var/openshell/openshell.db \
  -e OPENSHELL_DISABLE_TLS=true \
  -e SSL_CERT_FILE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
  ghcr.io/nvidia/openshell/gateway:latest
```

On Debian/Ubuntu hosts, swap the CA paths for `/usr/local/share/ca-certificates` and `/etc/ssl/certs`, and set `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt`.

Check it came up:

```shell
podman logs openshell-gateway | tail -20
```

You should see the gRPC listener bound on `0.0.0.0:8080`.

---

## Step 3 — Register the gateway with the local CLI

```shell
openshell gateway add http://127.0.0.1:8080 --local --name corp-local
openshell gateway select corp-local
openshell status
```

`openshell status` should report the gateway as healthy. If it can't connect, see Troubleshooting.

---

## Step 4 — Create the provider for your internal model

This is the crucial step that makes Claude irrelevant. You're telling OpenShell "the only model upstream we use is *this one*."

```shell
openshell provider create \
    --name internal-model \
    --type openai \
    --credential OPENAI_API_KEY="$INTERNAL_MODEL_TOKEN" \
    --config OPENAI_BASE_URL=https://vllm.corp.example.com/v1
```

Substitute:
- `internal-model` — any name you want for this provider record.
- `$INTERNAL_MODEL_TOKEN` — set this in your shell first. Use `empty` if the endpoint doesn't require auth.
- The base URL — your actual internal endpoint, ending in `/v1`.

Confirm it stored:

```shell
openshell provider get internal-model
```

### If your endpoint requires custom headers instead of a bearer token

The `--credential` flag accepts arbitrary `KEY=VALUE` pairs that become headers on the upstream call. For an `X-API-Key`-style endpoint:

```shell
openshell provider create \
    --name internal-model \
    --type openai \
    --credential X_API_KEY="$INTERNAL_MODEL_TOKEN" \
    --config OPENAI_BASE_URL=https://vllm.corp.example.com/v1
```

Check your endpoint's docs for the exact header it expects.

---

## Step 5 — Wire `inference.local` to that provider

```shell
openshell inference set \
    --provider internal-model \
    --model meta-llama/Llama-3.1-70B-Instruct \
    --timeout 120
```

Verify:

```shell
openshell inference get
```

You should see your provider, your model, and a non-zero timeout. From this point on, every sandbox on this gateway routes `https://inference.local` calls to your internal endpoint.

If `inference set` fails with a verification error, your endpoint isn't responding to the gateway's probe yet. Retry with `--no-verify` to persist the route anyway and debug separately.

---

## Step 6 — Smoke-test from a sandbox

This proves the whole loop works end-to-end without touching Anthropic.

```shell
openshell sandbox create -- \
    curl -sS https://inference.local/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
      "model": "ignored-the-router-rewrites-this",
      "messages": [{"role": "user", "content": "Say hi in five words."}],
      "max_tokens": 20
    }'
```

The output should be a `chat.completion` JSON object from your internal model. The `model` value in the request body is ignored — the privacy router substitutes the model you set in step 5.

---

## Step 7 — Pick an agent that doesn't depend on Claude

Since `api.anthropic.com` is unreachable, native Claude Code won't work out of the box (it phones home to Anthropic). Options that work against an internal OpenAI-compatible endpoint via `inference.local`:

| Agent | How to point it at `inference.local` |
|---|---|
| **OpenCode** | Set `OPENAI_BASE_URL=https://inference.local/v1` and `OPENAI_API_KEY=unused` in the sandbox environment. |
| **Codex (OpenAI CLI)** | Same env vars; uses the OpenAI SDK under the hood. |
| **Aider** | `aider --openai-api-base https://inference.local/v1 --openai-api-key unused`. |
| **Custom scripts** | Any code that uses the OpenAI Python/JS SDK respects `OPENAI_BASE_URL` / `OPENAI_API_KEY`. |

Example sandbox launch with OpenCode:

```shell
openshell sandbox create \
    --env OPENAI_BASE_URL=https://inference.local/v1 \
    --env OPENAI_API_KEY=unused \
    -- opencode
```

Claude Code can also be redirected if you stand up an Anthropic-protocol shim (LiteLLM in `anthropic` mode is the common pattern), but that's a separate provider record using `--type anthropic` and is out of scope for this guide.

---

## Step 8 (recommended) — Block external LLM egress in policy

Defense in depth. Even though `inference.local` is the configured path, an agent could in principle try to dial `api.anthropic.com` or `api.openai.com` directly. Make sure your sandbox policy denies that.

Sketch of the relevant policy section (full schema is documented under `docs/sandboxes/policies.mdx` in the OpenShell repo):

```yaml
network_policies:
  default:
    rules:
      # Allow only the in-sandbox loopback inference endpoint.
      - host: "inference.local"
        ports: [443]
        action: "allow"
      # Allow corporate-internal hosts the agent legitimately needs.
      - host: "*.corp.example.com"
        ports: [443]
        action: "allow"
      # Explicitly deny known LLM egress destinations.
      - host: "api.anthropic.com"
        action: "deny"
      - host: "api.openai.com"
        action: "deny"
      - host: "*.anthropic.com"
        action: "deny"
      - host: "*.openai.com"
        action: "deny"
      # Default deny everything else.
      - action: "deny"
```

Apply it with:

```shell
openshell policy set internal-only --policy /path/to/policy.yaml --wait
openshell sandbox create --policy internal-only -- opencode
```

OCSF events emitted by the supervisor will show any denied egress attempt with host, port, and the agent process that tried.

---

## Verification checklist

You're done when all of these pass:

1. `openshell status` → gateway healthy.
2. `podman ps` → `openshell-gateway` running.
3. `openshell provider get internal-model` → shows your base URL.
4. `openshell inference get` → shows `internal-model` and your model.
5. The smoke-test curl from step 6 returns a real model response.
6. With the policy from step 8 applied, a sandbox attempt to `curl https://api.anthropic.com` is denied and logged.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `openshell status` says unreachable | Wrong port, wrong scheme. With `OPENSHELL_DISABLE_TLS=true` use `http://127.0.0.1:8080`, not https. |
| Gateway exits immediately with "permission denied" on podman socket | Rootless socket path mismatch. Check `$XDG_RUNTIME_DIR/podman/podman.sock` exists; SELinux may need `:z` on the bind mount. |
| `inference set` verification fails | The gateway container can't reach your endpoint. Test from inside the container: `podman exec openshell-gateway curl -v https://vllm.corp.example.com/v1/models`. If TLS fails, your CA bundle isn't mounted right. |
| `curl https://inference.local` from sandbox → DNS failure | Make sure you're using `https://`, not `http://`. The router only intercepts HTTPS. |
| Sandbox can't trust internal CA | The supervisor reads `/etc/ssl/certs/ca-certificates.crt` and `/etc/pki/tls/certs/ca-bundle.crt` from the sandbox image. For most cases routing through `inference.local` avoids this — the gateway handles upstream TLS. If you need direct egress to internal services, bake the CA into the sandbox image or mount it via `--volume` on `sandbox create`. |
| `host.openshell.internal` not resolving for a host-bound model | Only relevant if your model runs on the same host as the gateway. For a remote internal endpoint, use the real hostname or LAN IP. |
| Image pull fails from internal registry | Add registry auth: `podman login registry.corp.example.com` before the `podman run`. Or use a service account credential file via `--authfile`. |

---

## What you have at the end

- A long-running gateway container on this host that talks only to your internal model endpoint for inference.
- A CLI registered against it.
- A provider record + inference route that makes `https://inference.local` work inside every sandbox.
- A policy template that hard-blocks accidental egress to public LLM APIs.
- A repeatable command set you can hand to other engineers — same six steps, swap the provider URL.

## Next moves once this works

- Replace `OPENSHELL_DISABLE_TLS=true` with the full mTLS setup (`docs/about/container-gateway.mdx` section "Full mTLS Setup") before letting more than one user touch the gateway.
- Author per-team sandbox policies under version control rather than ad-hoc YAML.
- Stand up an OCSF log shipper from the sandbox log stream into your SIEM so denied egress attempts get the same visibility as any other policy violation.
- If you ever need Claude Code itself, evaluate an Anthropic-protocol shim (e.g. LiteLLM in `anthropic` mode) so you can register a `--type anthropic` provider and have Claude Code work against an internal endpoint too.
