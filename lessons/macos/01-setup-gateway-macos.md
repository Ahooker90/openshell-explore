# Lesson: Run OpenShell from scratch on macOS (Podman)

**Goal:** Start with nothing and finish with a working OpenShell gateway running as a
container, a sandbox you created, and a hands-on understanding of the security model —
you'll watch the sandbox's network get **denied by default**, then **hot-reload a policy**
and watch the *same* request succeed while a write is still blocked.

**Time:** ~30 minutes (most of it image downloads).
**Platform:** macOS (Apple Silicon or Intel), using **Podman** as the container runtime.

> Every command and output in this lesson was run and verified on macOS with Podman 5.8 and
> OpenShell 0.0.62. Where a step is non-obvious, there's a **Why** callout — that's the part
> the official quickstart leaves out.

---

## What you'll build

```
   your Mac
   ┌─────────────────────────────────────────────────────────┐
   │  openshell CLI  ──http──►  gateway (container)            │
   │                              │  drives Podman             │
   │                              ▼                            │
   │                          sandbox (container)              │
   │                          • your code/agent runs here      │
   │                          • ALL egress goes through a      │
   │                            policy-enforcing proxy         │
   └─────────────────────────────────────────────────────────┘
```

## Concepts (2-minute read)

OpenShell gives an AI agent (or any process) a **sandbox**: an isolated container whose
filesystem, processes, and — most importantly — **network egress** are governed by a
declarative policy. Four pieces:

- **Gateway** — the control plane. You talk to it with the `openshell` CLI. It creates and
  supervises sandboxes through a **compute driver**.
- **Compute driver** — how sandboxes actually run. Here it's **Podman** (Docker, MicroVM, and
  Kubernetes are also supported).
- **Sandbox** — the isolated runtime. Every outbound connection is intercepted.
- **Policy engine** — for each connection it does one of three things: **allow**, **deny**, or
  **route for inference** (swap the agent's API key for a managed one). The default is
  **deny everything**.

The whole point: an agent can run freely *inside* the box, but it can't reach the network,
read your files, or exfiltrate data unless a policy you wrote says so.

---

## Prerequisites

- **Podman 5.x** — `brew install podman`
- **uv** (to install the CLI) — `brew install uv`
- Network access to `ghcr.io` (to pull images)

---

## Step 1 — Start the Podman machine

On macOS, Podman runs Linux containers inside a lightweight VM called a *machine*. Create and
start it once:

```shell
podman machine init      # first time only
podman machine start
podman info | grep -i rootless   # expect: rootless: true
```

## Step 2 — Install the `openshell` CLI (version matters)

```shell
uv tool install -U openshell
openshell --version
```

> **Why this matters — version match.** The CLI and the gateway **must be the same version**.
> The gateway image you pull below is tagged `:latest` (currently `0.0.62`). If your CLI is
> older (e.g. `0.0.39`), sandboxes still *start*, but the CLI shows their phase as
> `Unspecified` and **hangs forever** when it tries to attach. If you hit that, pin the CLI to
> match the gateway image: `uv tool install 'openshell==0.0.62'`.

## Step 3 — Pull the gateway image

```shell
podman pull ghcr.io/nvidia/openshell/gateway:latest
```

## Step 4 — One-time gateway setup (certs + config)

Two pieces of setup the simple "TLS-disabled" quickstart skips — and without them sandboxes
fail to start on current versions.

**4a. Generate the sandbox-JWT signing material.** Store it inside a Podman volume that the
gateway will reuse:

```shell
podman volume create openshell-state

podman run --rm --user 0:0 --security-opt label=disable \
  -v openshell-state:/var/openshell \
  ghcr.io/nvidia/openshell/gateway:latest \
  generate-certs --output-dir /var/openshell/tls
```

> **Why — sandboxes need a token.** Each sandbox's supervisor must authenticate back to the
> gateway to fetch its policy. The gateway mints a short-lived **JWT** per sandbox, signed with
> the key produced above. With no signing key, the supervisor exits immediately with
> `no sandbox token source available` and the sandbox never becomes ready.

**4b. Create a gateway config** that lets your local CLI connect without certificates. Save this
as `~/.config/openshell-container-gw/gateway.toml`:

```toml
# Local/dev only: plaintext + unauthenticated CLI, while the gateway still
# mints per-sandbox JWTs for the sandbox supervisors.
[openshell.gateway.auth]
allow_unauthenticated_users = true
```

> **Why — enabling JWTs turns on auth.** Once the gateway can mint sandbox JWTs, it *also*
> starts requiring an auth header on every inbound request — which would lock out your
> certificate-less local CLI. `allow_unauthenticated_users = true` is the documented local
> escape hatch: the CLI connects as a trusted local developer, while sandboxes still use real
> JWTs. **Never use this on a shared or exposed gateway.**

**4c. Create a host directory for sandbox tokens** (explained in Step 5):

```shell
mkdir -p ~/.local/state/openshell-cgw
```

## Step 5 — Run the gateway container

```shell
# Find the Podman socket *inside* the VM (note the uid; usually 501 on macOS):
podman machine ssh 'ls -l /run/user/$(id -u)/podman/podman.sock'
```

Then start the gateway (replace `501` if your uid differs, and `ahooker` with your username):

```shell
podman run -d \
  --name openshell-gateway \
  --restart unless-stopped \
  --user 0:0 \
  --security-opt label=disable \
  -p 127.0.0.1:8080:8080 \
  -v openshell-state:/var/openshell \
  -v /run/user/501/podman/podman.sock:/var/run/podman.sock \
  -v ~/.config/openshell-container-gw/gateway.toml:/gateway.toml:ro \
  -v ~/.local/state/openshell-cgw:/Users/$(whoami)/.local/state/openshell-cgw \
  -e OPENSHELL_DRIVERS=podman \
  -e OPENSHELL_PODMAN_SOCKET=/var/run/podman.sock \
  -e OPENSHELL_DB_URL=sqlite:/var/openshell/openshell.db \
  -e OPENSHELL_DISABLE_TLS=true \
  -e OPENSHELL_LOCAL_TLS_DIR=/var/openshell/tls \
  -e XDG_STATE_HOME=/Users/$(whoami)/.local/state/openshell-cgw \
  ghcr.io/nvidia/openshell/gateway:latest \
  --config /gateway.toml --bind-address 0.0.0.0 --port 8080
```

Confirm it connected to Podman and enabled JWTs:

```shell
podman logs openshell-gateway | grep -iE "connected to podman|jwt enabled|listening"
```

You should see `Connected to Podman ... rootless=true`, `gateway-minted sandbox JWT enabled`,
and `Server listening address=0.0.0.0:8080`.

> **Why these four flags are the whole game on macOS+Podman** (this is what the docs omit):
> - **`--security-opt label=disable`** — the Podman VM is Fedora CoreOS with SELinux
>   *enforcing*. Without this, mounting the socket fails with `permission denied`.
> - **`-v /run/user/501/podman/podman.sock`** — you must mount the socket *as it exists inside
>   the VM*. The macOS-side socket path does **not** work for a containerized gateway.
> - **`--user 0:0`** — the image's default user (1000) can't read the socket; container-root
>   maps to the VM user that owns it.
> - **The token-dir mounts (`XDG_STATE_HOME` + identical bind path under `/Users`)** — the
>   gateway writes each sandbox's JWT to a file, then asks Podman to mount that file into the
>   sandbox. Podman (in the VM) can only see paths under `/Users` (shared from macOS). Mounting
>   the directory at the *identical absolute path* the gateway records is what makes the
>   hand-off work. Without it: `statfs ... permission denied` and sandbox creation fails.

## Step 6 — Register the CLI and check health

```shell
openshell gateway add http://127.0.0.1:8080 --local --name container-local
openshell gateway select container-local
openshell status
```

Expected:

```text
  Gateway:  container-local
  Server:   http://127.0.0.1:8080
  Status:   Connected
  Version:  0.0.62
```

(You may see a one-time "mTLS certificates found... did you mean https?" warning — ignore it;
we're intentionally on plaintext for local dev.)

---

## Step 7 — Create your first sandbox

```shell
openshell sandbox create --from base --no-auto-providers --name learning
```

- `--from base` uses the default sandbox image (Python, Node, git, curl, …).
- `--no-auto-providers` skips credential setup — we're not running an AI agent yet.

The first run pulls the `base` image (~2.8 GB) and the supervisor image, so give it a minute.
You'll land in a shell inside the sandbox:

```text
sandbox@learning:~$
```

## Step 8 — Watch default-deny in action

Inside the sandbox, try to reach the GitHub API:

```shell
curl -sS https://api.github.com/zen
```

```text
curl: (56) CONNECT tunnel failed, response 403
```

**Denied.** The sandbox's egress proxy rejected the HTTPS CONNECT because no policy authorizes
`curl` to reach `api.github.com`. Exit the sandbox (it keeps running):

```shell
exit
```

> **Why `podman exec` would "work" — and why that's not a bug.** If you bypass OpenShell and run
> `podman exec openshell-sandbox-learning curl ...`, it succeeds — because policy enforcement
> lives on the **supervised entry path** (the SSH session OpenShell gives you), which injects the
> proxy. A raw `podman exec` is an operator backdoor outside the sandbox model. Always enter via
> `openshell`.

## Step 9 — Read the deny log

```shell
openshell logs learning --since 10m
```

You'll see a structured (OCSF) security event for the blocked request:

```text
NET:OPEN [MED] DENIED /usr/bin/curl -> api.github.com:443
  [reason: binary '/usr/bin/curl' not allowed in policy ...]
```

Every denied connection is logged with the destination, the binary that tried, and why. Nothing
leaves silently.

---

## Step 10 — Hot-reload a policy and watch it succeed

Now the payoff. Save this as `github-readonly.yaml`:

```yaml
version: 1
# Static filesystem + process settings. `openshell policy set` replaces the
# ENTIRE policy, so these defaults must be present even when you only care
# about the network rules.
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /proc, /dev/urandom, /app, /etc, /var/log]
  read_write: [/sandbox, /tmp, /dev/null]
landlock:
  compatibility: best_effort
process:
  run_as_user: sandbox
  run_as_group: sandbox
network_policies:
  github_api:
    name: github-api-readonly
    endpoints:
      - host: api.github.com
        port: 443
        protocol: rest
        enforcement: enforce
        access: read-only      # GET/HEAD/OPTIONS only
    binaries:
      - { path: /usr/bin/curl }
```

Apply it to the **running** sandbox — no restart:

```shell
openshell policy set learning --policy github-readonly.yaml --wait
```

```text
✓ Policy version 2 submitted (hash: b8cf8d97ded0)
✓ Policy version 2 loaded (active version: 2)
```

Reconnect and try again:

```shell
openshell sandbox connect learning
```

```shell
# inside the sandbox — a GET now succeeds:
curl -sS https://api.github.com/zen
```

```text
Design for failure.
```

It works. Now try a **write** to the same host:

```shell
curl -sS -X POST https://api.github.com/repos/octocat/hello-world/issues -d '{"title":"oops"}'
```

```json
{"error":"policy_denied","layer":"l7","method":"POST",
 "detail":"POST /repos/octocat/hello-world/issues not permitted by policy",
 "policy":"github_api","host":"api.github.com","path":"/repos/octocat/hello-world/issues"}
```

The CONNECT succeeded (the host is allowed), but the proxy inspected the HTTP method and blocked
`POST` — the `read-only` preset permits reads only. **This is L7 enforcement:** your agent can
read from GitHub but can't open issues, push, or modify anything. Exit:

```shell
exit
```

## Step 11 — Read the L7 deny log

```shell
openshell logs learning --level warn --since 10m
```

You'll see the method, path, and deny reason for the blocked `POST` — a full audit trail you
could ship to a SIEM.

## Step 12 — Clean up

```shell
openshell sandbox delete learning
podman rm -f openshell-gateway
# optional: podman volume rm openshell-state
```

---

## What you just learned

| You saw | The lesson |
| --- | --- |
| `curl` → `403 CONNECT tunnel failed` | Sandboxes are **default-deny**. Nothing reaches the network unless a policy says so. |
| `policy set --wait` → version 2 loaded | Network policy **hot-reloads** on a running sandbox — no restart. |
| GET allowed, POST → `policy_denied` | Enforcement is **L7** (HTTP method/path), not just host/port. |
| OCSF deny logs | Every decision is **audited** with who/what/why. |

## Why this works — the six non-obvious fixes (reference)

The official "TLS-disabled" quickstart will get you a gateway that reports *healthy* but **can't
create a working sandbox**. These are the gaps, all encoded above:

1. **SELinux** in the Podman VM → `--security-opt label=disable` on the socket mount.
2. **In-VM socket path** (`/run/user/<uid>/podman/podman.sock`), not the macOS-side path.
3. **`--user 0:0`** so the gateway can read the rootless socket.
4. **Sandbox JWT material** (`generate-certs` + `OPENSHELL_LOCAL_TLS_DIR`) — required or
   supervisors exit 1.
5. **`allow_unauthenticated_users`** so the CLI can still connect once JWT auth is on.
6. **Shared token dir** (`XDG_STATE_HOME` under `/Users`, bind-mounted at the identical path) so
   Podman can hand the JWT file to each sandbox.

Plus the one that isn't about config: **CLI and gateway versions must match.**

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `openshell status` → connection refused | Wrong scheme/port | Use `http://127.0.0.1:8080` (TLS disabled) |
| Gateway log: `permission denied` on socket | SELinux in the VM | Add `--security-opt label=disable` |
| Gateway log: `Podman socket not found` | `podman machine` not running / wrong uid | `podman machine start`; re-check the socket path |
| Sandbox exits 1: `no sandbox token source available` | No JWT signing key | Do Step 4a + set `OPENSHELL_LOCAL_TLS_DIR` |
| `status: Unauthenticated, missing authorization header` | JWT on but CLI has no creds | Add the `gateway.toml` from Step 4b |
| `statfs .../sandbox.jwt: permission denied` | Token dir not visible to the VM | Set `XDG_STATE_HOME` to a `/Users/...` path bind-mounted at the identical path |
| `sandbox list` phase `Unspecified`, attach hangs | CLI/gateway version skew | `uv tool install 'openshell==<gateway version>'` |
| Image pull fails on first create | No `ghcr.io` access | Pre-pull: `podman machine ssh 'podman pull ghcr.io/nvidia/openshell-community/sandboxes/base:latest'` |

## Next steps

- Change `access: read-only` to `read-write`, or add more `endpoints` (PyPI, npm, your APIs).
- Scope a policy to an agent: replace `/usr/bin/curl` in `binaries` with your agent's binary.
- Run a real agent: `openshell sandbox create -- claude` (needs `ANTHROPIC_API_KEY`).
- Try `enforcement: audit` to log violations without blocking — useful for building a policy
  iteratively.
