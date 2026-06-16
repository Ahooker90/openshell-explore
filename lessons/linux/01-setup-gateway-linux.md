# Lesson: Run OpenShell from scratch on Linux (native rootless Podman)

**Goal:** Start with nothing and finish with a working OpenShell gateway running as a
container, a sandbox you created, and a hands-on understanding of the security model —
you'll watch the sandbox's network get **denied by default**, then **hot-reload a policy**
and watch the *same* request succeed while a write is still blocked.

**Time:** ~20–30 minutes (including image downloads).
**Platform:** Any modern Linux distro (Fedora/RHEL, Debian/Ubuntu, Arch, …) with **Podman 5.x**
and **systemd**, running **rootless**. No VM, no WSL — just your host.

> **About this version.** The companion macOS lesson was verified end-to-end on real hardware.
> This Linux lesson is the **native rootless-Podman** path that the macOS and Windows/WSL2 lessons
> both ultimately emulate — on macOS Podman runs in a VM, and the Windows lesson runs these exact
> steps *inside* a WSL2 Linux distro. The OpenShell commands (Steps 3–11) are identical to the
> verified macOS run; the runtime setup (Steps 1–2) is standard rootless-Podman-on-Linux. If
> anything, this path is **more robust** than macOS because there's no VM boundary to cross. Where
> Linux differs from macOS, there's a **Why** callout.

---

## What you'll build

```
   Linux host
   ┌─────────────────────────────────────────────────────────┐
   │  openshell CLI  ──http──►  gateway (container)            │
   │                              │  drives rootless Podman    │
   │                              ▼                            │
   │                          sandbox (container)              │
   │                          • your code/agent runs here      │
   │                          • ALL egress goes through a      │
   │                            policy-enforcing proxy         │
   └─────────────────────────────────────────────────────────┘
```

The CLI, Podman, the gateway container, and the sandboxes all live on one host, in one Linux
filesystem and network namespace. You drive it from a normal terminal.

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

- A Linux host where you have a normal (non-root) login account.
- Ability to `sudo` to install packages (one-time, for Podman and uv).

---

## Step 1 — Install Podman (rootless, cgroups v2)

Install Podman with your distro's package manager:

```shell
# Fedora / RHEL / CentOS Stream:
sudo dnf install -y podman

# Debian / Ubuntu:
sudo apt-get update && sudo apt-get install -y podman uidmap

# Arch:
sudo pacman -S --needed podman
```

Confirm you're rootless on cgroups v2:

```shell
podman info | grep -iE "rootless|cgroupVersion"   # expect rootless: true, cgroupVersion: v2
```

> **Why cgroups v2 + rootless.** OpenShell's sandbox supervisor relies on the cgroups-v2 resource
> controls that systemd wires up for your user session, and runs everything as your unprivileged
> user (no daemon, no root). All current mainstream distros default to cgroups v2; if `podman info`
> reports v1, your distro is unusually old — enable unified cgroups (`systemd.unified_cgroup_hierarchy=1`)
> and reboot.

## Step 2 — Start the rootless Podman socket (and keep it alive)

OpenShell talks to Podman over its API socket, exposed as a per-user systemd unit:

```shell
systemctl --user enable --now podman.socket
systemctl --user status podman.socket | grep -i listen   # note the socket path

# keep the user session (and its socket) alive after you log out:
loginctl enable-linger "$USER"
```

The socket path is `$XDG_RUNTIME_DIR/podman/podman.sock` — typically
`/run/user/$(id -u)/podman/podman.sock`.

Also install **uv** (used to install the `openshell` CLI in Step 3) if you don't have it:

```shell
curl -LsSf https://astral.sh/uv/install.sh | sh && source ~/.bashrc
```

> **Why `enable-linger`.** Without it, systemd tears down your user session — and the Podman
> socket with it — the moment your last login closes. Lingering keeps the user manager (and the
> gateway it's serving) running across logout/SSH disconnects, which is what you want for a
> long-lived gateway.

## Step 3 — Install the `openshell` CLI (version matters)

```shell
uv tool install -U openshell
openshell --version
```

> **Why this matters — version match.** The CLI and the gateway **must be the same version**.
> The gateway image you pull below is tagged `:latest` (currently `0.0.62`). If your CLI is
> older (e.g. `0.0.39`), sandboxes still *start*, but the CLI shows their phase as
> `Unspecified` and **hangs forever** when it tries to attach. If you hit that, pin the CLI to
> match the gateway image: `uv tool install 'openshell==0.0.62'`.

## Step 4 — Pull the gateway image

```shell
podman pull ghcr.io/nvidia/openshell/gateway:latest
```

## Step 5 — One-time gateway setup (certs + config)

Two pieces of setup the simple "TLS-disabled" quickstart skips — and without them sandboxes
fail to start on current versions.

**5a. Generate the sandbox-JWT signing material** into a reusable Podman volume:

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

**5b. Create a gateway config** that lets your local CLI connect without certificates. Save as
`~/.config/openshell-container-gw/gateway.toml`:

```shell
mkdir -p ~/.config/openshell-container-gw
cat > ~/.config/openshell-container-gw/gateway.toml <<'EOF'
# Local/dev only: plaintext + unauthenticated CLI, while the gateway still
# mints per-sandbox JWTs for the sandbox supervisors.
[openshell.gateway.auth]
allow_unauthenticated_users = true
EOF
```

> **Why — enabling JWTs turns on auth.** Once the gateway can mint sandbox JWTs, it *also*
> starts requiring an auth header on every inbound request — which would lock out your
> certificate-less local CLI. `allow_unauthenticated_users = true` is the documented local
> escape hatch. **Never use this on a shared or exposed gateway.**

**5c. Create a directory for sandbox tokens:**

```shell
mkdir -p ~/.local/state/openshell-cgw
```

## Step 6 — Run the gateway container

```shell
podman run -d \
  --name openshell-gateway \
  --restart unless-stopped \
  --user 0:0 \
  --security-opt label=disable \
  -p 127.0.0.1:8080:8080 \
  -v openshell-state:/var/openshell \
  -v "$XDG_RUNTIME_DIR/podman/podman.sock:/var/run/podman.sock" \
  -v ~/.config/openshell-container-gw/gateway.toml:/gateway.toml:ro \
  -v ~/.local/state/openshell-cgw:"$HOME/.local/state/openshell-cgw" \
  -e OPENSHELL_DRIVERS=podman \
  -e OPENSHELL_PODMAN_SOCKET=/var/run/podman.sock \
  -e OPENSHELL_DB_URL=sqlite:/var/openshell/openshell.db \
  -e OPENSHELL_DISABLE_TLS=true \
  -e OPENSHELL_LOCAL_TLS_DIR=/var/openshell/tls \
  -e XDG_STATE_HOME="$HOME/.local/state/openshell-cgw" \
  ghcr.io/nvidia/openshell/gateway:latest \
  --config /gateway.toml --bind-address 0.0.0.0 --port 8080
```

Confirm it connected to Podman and enabled JWTs:

```shell
podman logs openshell-gateway | grep -iE "connected to podman|jwt enabled|listening"
```

You should see `Connected to Podman ... rootless=true`, `gateway-minted sandbox JWT enabled`,
and `Server listening address=0.0.0.0:8080`.

> **Why these flags** (mostly identical to macOS, two differences called out):
> - **`-v $XDG_RUNTIME_DIR/podman/podman.sock`** — on native Linux this is the *real* rootless
>   socket, mounted directly. (On macOS you'd have to dig the socket out of the Podman VM.)
> - **`--user 0:0`** — container-root maps to your rootless user, which owns the socket; the
>   image's default user (1000) can't read it.
> - **Token-dir mounts (`XDG_STATE_HOME` + identical bind path)** — the gateway writes each
>   sandbox's JWT to a file and asks Podman to mount it into the sandbox. Binding the directory
>   at the *same absolute path* the gateway records lets Podman find it. On native Linux it's one
>   filesystem, so any `$HOME` path works — no cross-VM sharing needed (unlike macOS, where the
>   path must live under `/Users` to be visible to the Podman VM).
> - **`--security-opt label=disable`** — **distro-dependent.** On SELinux-enforcing distros
>   (Fedora/RHEL/CentOS) it's **required** so the gateway can read the mounted socket; on
>   Debian/Ubuntu/Arch (no SELinux, or AppArmor) it's a harmless no-op. Keep it either way — it's
>   correct on every distro. (Check with `getenforce`: `Enforcing` means you need it.)

## Step 7 — Register the CLI and check health

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

---

## Step 8 — Create your first sandbox

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

## Step 9 — Watch default-deny in action

Inside the sandbox:

```shell
curl -sS https://api.github.com/zen
```

```text
curl: (56) CONNECT tunnel failed, response 403
```

**Denied.** The egress proxy rejected the HTTPS CONNECT because no policy authorizes `curl` to
reach `api.github.com`. Exit (the sandbox keeps running):

```shell
exit
```

> **Why `podman exec` would "work" — and why that's not a bug.** If you bypass OpenShell with
> `podman exec openshell-sandbox-learning curl ...`, it succeeds — enforcement lives on the
> **supervised entry path** (the SSH session OpenShell gives you), which injects the proxy. A raw
> `podman exec` is an operator backdoor outside the sandbox model. Always enter via `openshell`.

## Step 10 — Read the deny log

```shell
openshell logs learning --since 10m
```

You'll see a structured (OCSF) event for the blocked request:

```text
NET:OPEN [MED] DENIED /usr/bin/curl -> api.github.com:443
  [reason: binary '/usr/bin/curl' not allowed in policy ...]
```

---

## Step 11 — Hot-reload a policy and watch it succeed

Save this as `github-readonly.yaml`:

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

Now try a **write** to the same host:

```shell
curl -sS -X POST https://api.github.com/repos/octocat/hello-world/issues -d '{"title":"oops"}'
```

```json
{"error":"policy_denied","layer":"l7","method":"POST",
 "detail":"POST /repos/octocat/hello-world/issues not permitted by policy",
 "policy":"github_api","host":"api.github.com","path":"/repos/octocat/hello-world/issues"}
```

The CONNECT succeeded (host allowed), but the proxy inspected the HTTP method and blocked `POST`
— the `read-only` preset permits reads only. **This is L7 enforcement.** Exit:

```shell
exit
```

## Step 12 — Read the L7 deny log, then clean up

```shell
openshell logs learning --level warn --since 10m   # shows the blocked POST: method, path, reason

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

## Why this works — the key fixes (reference)

The official "TLS-disabled" quickstart will get you a gateway that reports *healthy* but **can't
create a working sandbox**. The fixes, all encoded above:

1. **Rootless Podman socket** mounted directly from `$XDG_RUNTIME_DIR` (native Linux is one env).
2. **`--user 0:0`** so the gateway can read the rootless socket.
3. **Sandbox JWT material** (`generate-certs` + `OPENSHELL_LOCAL_TLS_DIR`) — required or
   supervisors exit 1.
4. **`allow_unauthenticated_users`** so the CLI can still connect once JWT auth is on.
5. **Shared token dir** (`XDG_STATE_HOME` + bind-mount at the identical `$HOME` path) so Podman
   can hand the JWT file to each sandbox.

Plus the one that isn't about config: **CLI and gateway versions must match.**

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `podman info` shows `rootless: false` or cgroup v1 | Old distro / unified cgroups off | Enable `systemd.unified_cgroup_hierarchy=1`, reboot; run Podman as your user (not `sudo`) |
| `Cannot connect to Podman socket` | User socket not started | `systemctl --user enable --now podman.socket` |
| Socket dies after you log out | No lingering | `loginctl enable-linger $USER` |
| Gateway can't read the socket on Fedora/RHEL | SELinux enforcing | Keep `--security-opt label=disable` (Step 6); confirm with `getenforce` |
| `openshell status` → connection refused | Wrong scheme/port | Use `http://127.0.0.1:8080` (TLS disabled) |
| Sandbox exits 1: `no sandbox token source available` | No JWT signing key | Do Step 5a + set `OPENSHELL_LOCAL_TLS_DIR` |
| `status: Unauthenticated, missing authorization header` | JWT on but CLI has no creds | Add the `gateway.toml` from Step 5b |
| `statfs .../sandbox.jwt: permission denied` | Token dir not bound at the recorded path | Set `XDG_STATE_HOME` and bind-mount that dir at the identical absolute path |
| `sandbox list` phase `Unspecified`, attach hangs | CLI/gateway version skew | `uv tool install 'openshell==<gateway version>'` |
| Image pull fails on first create | No `ghcr.io` access | Check networking/DNS; pre-pull `ghcr.io/nvidia/openshell-community/sandboxes/base:latest` |

## Next steps

- Change `access: read-only` to `read-write`, or add more `endpoints` (PyPI, npm, your APIs).
- Scope a policy to an agent: replace `/usr/bin/curl` in `binaries` with your agent's binary.
- Run a real agent: `openshell sandbox create -- claude` (needs `ANTHROPIC_API_KEY`).
- Try `enforcement: audit` to log violations without blocking — useful for building a policy
  iteratively.
- Continue to **[02 · Policies & Custom Agents](../02-policies-and-custom-agents.md)**.
