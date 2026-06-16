# OpenShell Example Agent

A tiny, runnable agent that exercises the whole OpenShell stack end-to-end: a **sandbox** with a
locked-down **policy**, a credential **provider**, and the **inference router**. It talks to a
**local Ollama model** today and flips to a **corporate endpoint** by editing one file.

## The idea (why this is "extensible")

The agent always calls `https://inference.local/v1`. It never knows or cares what model is behind
it. The backend (URL + API key + model) lives in the **gateway**, configured by `setup.sh` from
`config.env`. So moving from a local model to a corporate one is a config edit — **the agent code
and the sandbox command never change.**

```
agent (in sandbox) ──► https://inference.local/v1 ──► gateway router ──► <backend from config.env>
                                                                          • local:     Ollama on your host
                                                                          • corporate: vLLM/NIM/LiteLLM/...
```

## Files

| File | Purpose |
| --- | --- |
| `config.env` | **The only file you edit to switch backends** — provider name, model, base URL, API key. |
| `agent.py` | Dependency-free agent (stdlib only). Sends a chat completion to `inference.local`, prints the reply. |
| `policy.yaml` | Tightest sandbox policy — **no** general egress. The agent still reaches the model because `inference.local` is policy-exempt. |
| `setup.sh` | Creates the provider and points `inference.local` at it (reads `config.env`). Re-run after editing config. |
| `run.sh` | Creates a sandbox, uploads `agent.py`, runs it. |
| `teardown.sh` | Deletes the sandbox and provider. |

## Prerequisites

- A running OpenShell gateway + CLI (see [`../lessons/`](../lessons/), step 01).
- [Ollama](https://ollama.com) installed and running, with a model pulled (e.g. `ollama pull llama3.2`).
  On macOS, Linux, and Windows/WSL2 alike, sandboxes reach your host's Ollama through the
  `host.openshell.internal` alias the Podman driver injects — even when Ollama is bound to the
  default `127.0.0.1:11434`. If yours isn't reachable, start it with `OLLAMA_HOST=0.0.0.0:11434 ollama serve`.
  (On Windows the agent and Ollama both live inside the WSL2 distro, so the same alias applies.)

## Quickstart (local Ollama)

```shell
# 1. Edit config.env if needed (defaults to model nemotron:latest).
#    Set MODEL to a model you've pulled: `ollama list`.

# 2. Point inference.local at your local Ollama:
./setup.sh

# 3. Run the agent in a sandbox:
./run.sh
#   -> endpoint: https://inference.local/v1
#   <- model: <your-model>
#   <- reply: <the model's answer>

# 4. Clean up:
./teardown.sh
```

Pass your own prompt: `./run.sh my-agent "Summarize what OpenShell does."`

## Switch to a corporate endpoint

1. Edit `config.env`: comment out the LOCAL block, uncomment the CORPORATE block, and set
   `MODEL`, `BACKEND_BASE_URL`, and `BACKEND_API_KEY` for your endpoint.
2. `./setup.sh`
3. `./run.sh`

That's it — `agent.py`, `policy.yaml`, and `run.sh` are unchanged.

## What this demonstrates

- **Sandbox** isolation (`run.sh` creates one per run).
- **Policy**: `policy.yaml` allows *no* general network egress, yet the agent works — proving
  `inference.local` is routed, not proxied through the egress policy.
- **Provider**: `setup.sh` stores the backend credential in the gateway; the agent only ever sees a
  placeholder.
- **Inference routing**: the gateway rewrites the model and forwards to your configured backend.

For the full narrated walkthrough, see [`../lessons/03-run-example-agent.md`](../lessons/03-run-example-agent.md).
