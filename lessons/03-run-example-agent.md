# Lesson 03 — Run the Example Agent (local model, corporate-ready)

This is the capstone. You'll run a real agent inside a sandbox that talks to a **local Ollama
model** through OpenShell's inference router — under a policy that allows **no** general network
egress — and then see how the *same* agent points at a **corporate endpoint** by editing one file.

It uses the runnable project in [`../example-agent/`](../example-agent/).

**Prerequisites**

- You finished your OS's **Step 01** (gateway + CLI running) —
  [macOS](macos/01-setup-gateway-macos.md) · [Linux](linux/01-setup-gateway-linux.md) ·
  [Windows](windows/01-setup-gateway-windows.md) — and ideally skimmed
  **[02](02-policies-and-custom-agents.md)** (policies, providers, inference).
- [Ollama](https://ollama.com) installed and running with a model pulled:
  ```shell
  ollama pull llama3.2        # or any model; check with: ollama list
  ```

> **Verified.** The commands and outputs below were run live (OpenShell 0.0.62, Podman on macOS,
> Ollama 0.30.8 serving `nemotron:latest`). Your model name and the reply text will differ.

---

## The big idea

The agent always calls `https://inference.local/v1`. It has no idea which model answers. The
backend lives in the **gateway**, set from `config.env`. So "local vs corporate" is a config edit —
the agent code and the sandbox command never change.

```
agent.py (in sandbox) ─► https://inference.local/v1 ─► gateway router ─► backend from config.env
                                                                          local:     Ollama (your host)
                                                                          corporate: vLLM / NIM / ...
```

`inference.local` is special: it's **exempt from network policy**. That's why the agent works even
under a policy that blocks all other egress.

---

## Step 1 — Look at the pieces

```shell
cd example-agent
ls
# agent.py  config.env  policy.yaml  setup.sh  run.sh  teardown.sh
```

- **`config.env`** — the only file you edit to choose a backend. Defaults:
  ```shell
  PROVIDER_NAME=ollama-local
  MODEL=nemotron:latest
  BACKEND_BASE_URL=http://host.openshell.internal:11434/v1   # your host's Ollama
  BACKEND_API_KEY=empty                                       # Ollama needs no key
  ```
  Set `MODEL` to one you've pulled (`ollama list`). `host.openshell.internal` is the host alias
  OpenShell makes reachable from sandboxes.
- **`agent.py`** — dependency-free (stdlib only); POSTs a chat completion to `inference.local` and
  prints the reply.
- **`policy.yaml`** — `network_policies: {}` → no general egress at all.

## Step 2 — Point inference.local at local Ollama

```shell
./setup.sh
```

This (re)creates an `openai`-type provider for Ollama and sets the route:

```text
Provider 'ollama-local' -> http://host.openshell.internal:11434/v1   (model: nemotron:latest)
✓ Created provider ollama-local

Gateway inference:
  Provider:  ollama-local
  Model:     nemotron:latest
  Timeout:   180s
```

> **Why `setup.sh` uses `--no-verify`.** `openshell inference set` normally probes the backend
> before saving. A large local model may not be loaded yet, so the probe can time out. We skip it
> and prove the route from inside the sandbox in the next step instead.

## Step 3 — Run the agent in a sandbox

```shell
./run.sh example-agent "Reply with exactly: hello from the example agent"
```

```text
Created sandbox: example-agent
  • Uploading files to ~...
  ✓ Files uploaded
-> endpoint: https://inference.local/v1
-> prompt:   Reply with exactly: hello from the example agent

<- model: nemotron:latest
<- reply: hello from the example agent
```

What just happened, end to end:

1. `run.sh` created a sandbox with `--policy policy.yaml` (no egress) and uploaded `agent.py`.
2. `agent.py` POSTed to `https://inference.local/v1/chat/completions`.
3. The router **stripped** the agent's placeholder key, **injected** the provider credential,
   **rewrote** the model to `nemotron:latest`, and forwarded to your host's Ollama via
   `host.openshell.internal`.
4. The reply came back — even though the policy blocks all other network access.

Run it again with your own prompt:

```shell
./run.sh example-agent "In one sentence, what is OpenShell?"
```

## Step 4 — Prove the policy really is locked down (optional)

The agent reached the model, but *general* egress is denied. Connect and try a normal site:

```shell
openshell sandbox connect example-agent
# inside the sandbox:
curl -sS https://api.github.com/zen
# -> curl: (56) CONNECT tunnel failed, response 403   (denied by policy)
exit
```

The only thing this sandbox can reach is the model. That's the security story in one policy file.

## Step 5 — Switch to a corporate endpoint

Edit `config.env`: comment out the LOCAL block, uncomment the CORPORATE block, and fill in your
endpoint:

```shell
MODEL=meta-llama/Llama-3.1-70B-Instruct
BACKEND_BASE_URL=https://vllm.corp.example.com/v1
BACKEND_API_KEY="$CORP_LLM_TOKEN"
```

Then:

```shell
./setup.sh        # re-points inference.local at the corporate backend
./run.sh          # same agent, same sandbox command, new backend
```

`agent.py`, `policy.yaml`, and `run.sh` don't change. (This guide can't run against a real corporate
endpoint, so Step 5 is the one part shown without live output — but it's the same `setup.sh`/`run.sh`
path you just used.)

## Step 6 — Clean up

```shell
./teardown.sh
```

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Agent hangs / times out | Model not loaded, or host Ollama unreachable from the sandbox | Confirm `ollama list` has your `MODEL`; if your Ollama only listens on loopback and isn't reachable, start it with `OLLAMA_HOST=0.0.0.0:11434 ollama serve` |
| `model "x" not found` from Ollama | `MODEL` in `config.env` isn't pulled | `ollama pull <model>`, set `MODEL` to match `ollama list` |
| `inference set` errors on verify | Backend probe timed out | `setup.sh` already passes `--no-verify`; ensure Ollama is running |
| Reply works but `curl github.com` also works | Policy too open | Make sure you ran with `--policy policy.yaml` (run.sh does) |
| TLS error from `agent.py` | Endpoint override is wrong | Leave `OPENAI_BASE_URL` unset so it defaults to `https://inference.local/v1` |

## Where to go next

- Tighten or extend access with [02 · Policies & Custom Agents](02-policies-and-custom-agents.md).
- For a production-style corporate setup (Podman + internal model, egress hard-blocked to public
  LLM APIs), see [`../corporate-gateway-setup.md`](../corporate-gateway-setup.md).
