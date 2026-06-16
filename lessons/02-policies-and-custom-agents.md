# Guide: Updating Policies & Running Custom Agents

This guide picks up where the getting-started lessons leave off. It covers two things in depth:

1. **Updating sandbox policies** — the full policy model, how to change what a sandbox can reach
   (including on a *running* sandbox), and worked patterns.
2. **Running a custom agent** — one that is **not** on the built-in list (`claude`, `codex`,
   `opencode`, `copilot`): packaging it, giving it credentials, and (optionally) routing it through
   managed inference.

Everything here is driven by the `openshell` CLI, which behaves the same on macOS, Linux, and
Windows, so this guide is **OS-neutral**. If you don't yet have a gateway running, do that first:

- macOS → [`macos/01-setup-gateway-macos.md`](macos/01-setup-gateway-macos.md)
- Linux → [`linux/01-setup-gateway-linux.md`](linux/01-setup-gateway-linux.md)
- Windows (WSL2) → [`windows/01-setup-gateway-windows.md`](windows/01-setup-gateway-windows.md)

> **The one rule to keep in mind.** Sandboxes are **default-deny**. Every outbound connection must
> match **both** an *endpoint* (host:port) **and** a *binary* in the same policy block. If nothing
> matches, the request is denied and logged. Policy is how you open up exactly what you intend —
> nothing more.

> **What's verified here.** The policy and provider commands and outputs below were run live
> against a containerized gateway (OpenShell 0.0.62, Podman on macOS). Where something is reproduced
> from the official docs or example rather than run here, it's labeled **(from the docs)**.

---

# Part 1 — Updating sandbox policies

## 1.1 Anatomy of a policy

A policy is one YAML document with five top-level sections:

```yaml
version: 1                 # schema version (always 1)
filesystem_policy: { … }   # what paths are readable / writable
landlock: { … }            # kernel-level filesystem enforcement mode
process: { … }             # which user/group the agent runs as
network_policies: { … }    # what the sandbox may reach on the network
```

The critical distinction is **static vs. dynamic**:

| Section | Changeable on a running sandbox? | To change it… |
| --- | --- | --- |
| `version` | No | recreate the sandbox |
| `filesystem_policy` | **No** (locked at creation) | recreate the sandbox |
| `landlock` | **No** (locked at creation) | recreate the sandbox |
| `process` | **No** (locked at creation) | recreate the sandbox |
| `network_policies` | **Yes — hot-reloads** | `openshell policy set` / `policy update` |

> **Why `policy set` makes you include the static sections.** `policy set` replaces the *entire*
> policy document, so even when you're only changing network rules, the file must still contain
> `version`, `filesystem_policy`, `landlock`, and `process`. The easiest way to avoid drift is to
> start from the live policy: `openshell policy get <name> --full`.

## 1.2 Network rules: L4 vs L7

Each entry under `network_policies` has `endpoints` (where traffic may go) and `binaries` (which
processes may use it).

**L4 (plain passthrough)** — omit `protocol`. The proxy checks only host:port + binary; it does not
look inside the connection, so *all* methods/paths are allowed to that host:

```yaml
network_policies:
  package_managers:
    name: package-managers
    endpoints:
      - { host: pypi.org, port: 443 }
      - { host: files.pythonhosted.org, port: 443 }
    binaries:
      - { path: /usr/bin/pip }
```

**L7 (inspected)** — set `protocol: rest` (also `websocket`, `graphql`). The proxy terminates TLS,
inspects each HTTP request, and enforces method/path rules. For HTTPS you must set `tls: terminate`:

```yaml
network_policies:
  github_api:
    name: github-api-readonly
    endpoints:
      - host: api.github.com
        port: 443
        protocol: rest
        tls: terminate
        enforcement: enforce
        access: read-only
    binaries:
      - { path: /usr/bin/curl }
```

### Endpoint fields you'll use most

| Field | Applies to | Meaning |
| --- | --- | --- |
| `host`, `port` | L4 + L7 | Destination. `host` allows first-label wildcards (below). |
| `protocol` | L7 | `rest` / `websocket` / `graphql`. Omit for L4 passthrough. |
| `tls` | L7 | `terminate` (required for HTTPS inspection) or `skip`. |
| `enforcement` | both | `enforce` (block violations) or `audit` (log only, allow). |
| `access` | L7 | Preset: `read-only` / `read-write` / `full`. Mutually exclusive with `rules`. |
| `rules` / `deny_rules` | L7 | Fine-grained allow/deny by method + path glob. |
| `allowed_ips` | both | CIDR allowlist to permit otherwise-blocked private IPs (SSRF guard). |

### Access presets

| Preset | HTTP methods allowed |
| --- | --- |
| `read-only` | GET, HEAD, OPTIONS |
| `read-write` | GET, HEAD, OPTIONS, POST, PUT, PATCH |
| `full` | all methods, including DELETE |

For anything finer than a preset, use explicit rules:

```yaml
        rules:
          - allow: { method: GET,  path: /repos/** }
          - allow: { method: POST, path: /repos/*/issues }
        deny_rules:
          - { method: DELETE, path: "**" }     # deny wins over allow
```

### enforce vs. audit

`enforcement: audit` **logs** what would be blocked but lets it through — perfect for discovering
what an agent actually needs before you lock it down. Switch to `enforce` once the policy is right.

### Host wildcards (first DNS label only)

| Pattern | Valid? | Matches |
| --- | --- | --- |
| `*.example.com` | ✓ | `api.example.com` |
| `**.example.com` | ✓ | `a.b.example.com` |
| `*-aiplatform.googleapis.com` | ✓ | `us-central1-aiplatform.googleapis.com` |
| `*` , `*.com` , `foo.*.example.com` | ✗ | rejected (too broad / wildcard not in first label) |

### Scoping to a binary

The `binaries` list binds a policy block to specific executables. Use exact paths or globs:

```yaml
    binaries:
      - { path: /usr/local/bin/claude }     # only this agent
      - { path: /sandbox/.venv/bin/** }     # anything under this tree
```

## 1.3 Updating a running sandbox

You have two ways to change `network_policies` live. Both hot-reload — no restart.

### Option A — Full replace (best for non-trivial edits)

Pull the live policy, edit the `network_policies` section, push it back:

```shell
openshell policy get learning --full > policy.yaml
# edit policy.yaml (leave version/filesystem_policy/landlock/process unchanged)
openshell policy set learning --policy policy.yaml --wait
```

`policy get --full` emits a metadata header, a `---` separator, then the complete document:

```text
Version:      2
Hash:         b8cf8d97…
Status:       Effective
Source:       sandbox
---
version: 1
filesystem_policy:
  …
network_policies:
  github_api:
    name: github-api-readonly
    …
```

(Strip the header lines above `---` before reusing the file.)

### Option B — Incremental (best for quick, scriptable tweaks)

`policy update` merges changes into the live policy without you hand-editing YAML:

```shell
# Add an L4 endpoint scoped to pip:
openshell policy update learning --add-endpoint pypi.org:443 --binary /usr/bin/pip --wait

# Add an L7 read-only REST endpoint scoped to gh:
openshell policy update learning \
  --add-endpoint api.github.com:443:read-only:rest:enforce \
  --binary /usr/bin/gh --wait

# Append a method/path rule to an existing REST endpoint:
openshell policy update learning --add-allow 'api.github.com:443:POST:/repos/*/issues' --wait

# Remove things:
openshell policy update learning --remove-endpoint pypi.org:443 --wait
```

The endpoint spec is `host:port[:access[:protocol[:enforcement[:options]]]]`.

**Preview before you commit** with `--dry-run` — it prints the merged result and sends nothing:

```shell
openshell policy update learning --add-endpoint pypi.org:443 --binary /usr/bin/pip --dry-run
```

```text
✓ Dry run preview for 1 incremental policy operation(s)
Policy:
  …
  network_policies:
    allow_pypi_org_443:          # auto-generated rule name
      name: allow_pypi_org_443
      endpoints:
      - host: pypi.org
        port: 443
      binaries:
      - path: /usr/bin/pip
    github_api:                  # existing rule preserved
      …
```

### Inspect & confirm

```shell
openshell policy get  learning          # summary of the active policy
openshell policy list learning          # revision history + load status
```

```text
VERSION  HASH           STATUS       CREATED
2        b8cf8d97ded0   Loaded       1781453101645
1        27380a8cbc68   Superseded   1781452440092
```

`--wait` exit codes: **0** loaded · **1** validation failed · **124** timeout.

### Iteration workflow

1. Create the sandbox (with an initial policy or the default-deny one).
2. `openshell logs <name> --tail` — watch what gets **denied**.
3. Add exactly those endpoints with `policy update` (or edit + `policy set`).
4. `openshell policy list <name>` — confirm the new revision is `Loaded`.
5. Repeat until the agent works with the least access necessary.

> **Tip:** the `generate-sandbox-policy` agent skill authors policy YAML from a plain-language
> description (or from an API's docs). And for high-assurance setups, `openshell policy prove` can
> formally check properties of a policy (e.g. "DELETE is never allowed") and find counterexamples.

## 1.4 Global policy

`openshell policy set --global --policy file.yaml` applies one policy to **all** sandboxes on the
gateway (per-sandbox updates are then rejected). Undo with `openshell policy delete --global`.

---

# Part 2 — Running a custom agent (not on the built-in list)

## 2.1 Why custom agents need extra setup

When you run `openshell sandbox create -- claude` (or `codex`/`opencode`/`copilot`), the CLI
recognizes the name and **auto-creates a credential provider** from your environment. Any other
command — say `my-agent` — is **not** recognized: no provider is created, and the agent starts with
no credentials. So for a custom agent you do three things yourself:

- **A.** Get the agent's binary into a sandbox image.
- **B.** Create a **provider** for its credentials and attach it.
- **C.** (Optional) Route it through managed inference.

## 2.2 Step A — Get your agent into an image (`--from`)

`openshell sandbox create --from <X>` accepts three forms **(from the docs)**:

| Form | Example | Behavior |
| --- | --- | --- |
| Community name | `--from base` | Expands to `ghcr.io/nvidia/openshell-community/sandboxes/<name>:latest` |
| Local Dockerfile/dir | `--from ./my-agent` | Builds locally, then hands the image to the gateway |
| Full image reference | `--from registry.io/org/img:tag` | Used as-is |

### BYOC Dockerfile requirements

Your image must be a normal Linux image the supervisor can run in (from the
`examples/bring-your-own-container/` example, and confirmed here):

```dockerfile
FROM debian:bookworm-slim            # a real distro, NOT distroless / scratch
RUN apt-get update && apt-get install -y --no-install-recommends \
      iproute2 nftables curl ca-certificates && rm -rf /var/lib/apt/lists/*
RUN groupadd -g 1000 sandbox && useradd -m -u 1000 -g sandbox sandbox
RUN install -d -o sandbox -g sandbox /sandbox     # writable workdir
WORKDIR /sandbox
RUN pip install my-custom-agent                   # ← install YOUR agent here
USER sandbox
CMD ["my-agent"]                                  # replaced at runtime (see note)
```

- `iproute2`/`nftables` are needed for the sandbox's network-namespace enforcement.
- The image's `CMD` is **replaced by the OpenShell supervisor**, so you must pass the start command
  on the CLI after `--` (Step C).

> **Verified gotcha — building on Podman.**
> - `--from ./Dockerfile` talks to a **Docker daemon**. On a Podman-only host (the macOS, Linux,
>   and Windows/WSL2 lessons), it fails with *"failed to query local Docker daemon info."* Instead, build with
>   Podman and pass the image reference:
>   ```shell
>   podman build -t localhost/my-agent:v1 .
>   openshell sandbox create --from localhost/my-agent:v1 --no-auto-providers -- my-agent
>   ```
>   The gateway uses the same Podman store, so a locally built `localhost/...` image is found
>   without a registry.
> - The BYOC example's `sandbox` UID `1000660000` (an OpenShift convention) **fails to build under
>   rootless Podman** (`install: cannot change owner … Invalid argument`) because it's outside the
>   subuid range. Use a normal UID like `1000` for local Podman/Docker, or push to a registry your
>   gateway can pull from.

A minimal end-to-end run of the above produced, in the sandbox:

```text
hello from my-custom-agent v1 (uid=1000)
```

## 2.3 Step B — Give the agent credentials with a provider

A **provider** is a named credential bundle the gateway injects into sandboxes. Create one:

```shell
# generic = arbitrary credentials for any custom service:
openshell provider create --name my-agent-creds --type generic \
  --credential API_KEY=sk-… \
  --config BASE_URL=https://api.example.com

# or pull from your current shell env (e.g. an OpenAI-compatible agent):
openshell provider create --name my-llm --type openai --from-existing
```

Recognized `--type` values include: `anthropic`, `claude`, `openai`, `codex`, `copilot`, `github`,
`gitlab`, `nvidia`, `opencode`, and **`generic`**. For a custom agent, use `generic` (arbitrary
keys) or `openai` (OpenAI-compatible). Credential sources: `--credential KEY=VALUE`,
`--credential KEY` (reads `$KEY` from your env), `--from-existing`, or `--runtime-credentials`.

Inspect and manage (verified — note it stores credential **keys**, never echoing secret values):

```shell
openshell provider get  my-agent-creds      # Type, Credential keys, Config keys
openshell provider list
openshell provider delete my-agent-creds
```

> **How credentials reach the agent — the placeholder model (from the docs).** The agent's
> environment variable holds a **placeholder**, not the real secret. When the agent makes an
> outbound request, the L7 proxy swaps the placeholder for the real credential before forwarding.
> The real secret therefore never lives inside the sandbox. This requires the destination to be an
> **L7 endpoint** in policy (`protocol: rest`, `tls: terminate`) so the proxy can rewrite the
> request. If the proxy can't resolve a placeholder, it fails the request closed.

## 2.4 Step C — Launch the custom agent

Bring the image, the provider, and a policy together:

```shell
openshell sandbox create \
  --from localhost/my-agent:v1 \
  --provider my-agent-creds \
  --policy ./my-agent-policy.yaml \
  --name my-agent \
  -- my-agent --model my-model
```

`--provider` is repeatable (attach several). The command after `--` is what the supervisor runs.

## 2.5 Step D — (Optional) Route through managed inference

If your agent speaks the OpenAI or Anthropic API, you can keep its model calls on managed
infrastructure via `inference.local` instead of letting it call a model vendor directly:

```shell
# 1. provider holding the real backend credentials:
openshell provider create --name backend --type openai \
  --credential OPENAI_API_KEY="$BACKEND_TOKEN" \
  --config OPENAI_BASE_URL=https://your-model.internal/v1

# 2. point the gateway's inference.local at it:
openshell inference set --provider backend --model my-model
openshell inference get
```

Inside the sandbox, the agent targets `https://inference.local/v1` (e.g.
`OPENAI_BASE_URL=https://inference.local/v1`); the privacy router strips the caller's key, injects
the backend credential, and applies the configured model. `inference.local` is built in and
hot-reloadable, so a network policy allowing it takes effect without recreating the sandbox.

For a full, worked corporate setup of this pattern (Podman + an internal OpenAI-compatible
endpoint, agents like OpenCode/Codex/Aider), see
[`../corporate-gateway-setup.md`](../corporate-gateway-setup.md).

---

# Part 3 — Worked example: custom agent + scoped policy together

This combines everything: a BYOC image, a provider, and a policy that allows just the agent's API
(read-only) — then proves the policy by allowing one call and denying another.

```shell
# 1. Build the agent image (Podman path).
podman build -t localhost/my-agent:v1 ./my-agent      # Dockerfile from §2.2

# 2. Create its credential provider.
openshell provider create --name my-agent-creds --type generic --credential API_KEY=sk-demo

# 3. Write a least-privilege policy. Start from the example and edit the host/binary:
#    (github-readonly.yaml in this folder is a ready template — read-only api.github.com.)
cp github-readonly.yaml my-agent-policy.yaml

# 4. Launch the agent with image + provider + policy.
openshell sandbox create \
  --from localhost/my-agent:v1 \
  --provider my-agent-creds \
  --policy my-agent-policy.yaml \
  --name my-agent -- my-agent
```

With the read-only GitHub policy attached, the same contrast from the lessons holds inside the
sandbox: a `GET https://api.github.com/...` succeeds, while a `POST` to the same host returns
`{"error":"policy_denied","layer":"l7","method":"POST",…}`. Tighten or widen by editing the
`network_policies` section and re-running `openshell policy set my-agent --policy … --wait` — no
restart.

Clean up when done:

```shell
openshell sandbox delete my-agent
openshell provider delete my-agent-creds
```

---

# Part 4 — Troubleshooting & cross-references

| Symptom | Cause | Fix |
| --- | --- | --- |
| Custom agent has no API key inside the sandbox | Unrecognized agent name → no auto-provider | Create a provider and attach it with `--provider` |
| `policy set` rejected / validation failed | Missing static sections (file isn't a full policy) | Start from `policy get <name> --full`; keep `version`/`filesystem_policy`/`landlock`/`process` |
| Credentials never get injected | Destination is L4, so the proxy can't rewrite the request | Make that endpoint L7: `protocol: rest` + `tls: terminate` |
| `--from ./Dockerfile` → "failed to query local Docker daemon info" | Podman-only host; `--from <dir>` needs Docker | `podman build -t localhost/img:tag .` then `--from localhost/img:tag` |
| BYOC build: `install: cannot change owner … Invalid argument` | UID outside the rootless subuid range (e.g. `1000660000`) | Use a normal UID (e.g. `1000`) for local Podman, or push to a registry |
| Agent reaches a host you didn't intend | Policy too broad (L4 or `access: full`) | Narrow to a preset or explicit `rules`; verify with `policy get --full` |
| Not sure what an agent needs | — | Run with `enforcement: audit`, watch `openshell logs --tail`, then lock down |

**Related docs in this folder**

- [`README.md`](README.md) — index of the lesson set.
- [`macos/01-setup-gateway-macos.md`](macos/01-setup-gateway-macos.md) /
  [`linux/01-setup-gateway-linux.md`](linux/01-setup-gateway-linux.md) /
  [`windows/01-setup-gateway-windows.md`](windows/01-setup-gateway-windows.md) — stand up
  a gateway and create your first sandbox.
- [`github-readonly.yaml`](github-readonly.yaml) — the example policy reused above.
- [`../corporate-gateway-setup.md`](../corporate-gateway-setup.md) — managed inference against an
  internal model endpoint.
