# OpenShell Explore — a hands-on way to learn NVIDIA OpenShell

A self-teaching workspace for **[NVIDIA OpenShell](https://github.com/NVIDIA/openshell)**, a safe,
sandboxed runtime for autonomous AI agents. It contains a numbered set of **verified, start-to-finish
lessons**, a **runnable example agent**, and a **corporate setup guide** — everything you need to go
from nothing installed to an agent running inside a locked-down sandbox.

> Unofficial learning material — not affiliated with NVIDIA. The lessons install the real
> `openshell` CLI and gateway image; you don't need OpenShell's source to follow them.

## What is OpenShell? (30 seconds)

OpenShell gives an AI agent an **isolated sandbox** whose filesystem, processes, and — above all —
**network egress** are governed by a declarative policy. A **gateway** (control plane) creates
sandboxes through a pluggable **compute driver** (Podman/Docker/VM/Kubernetes); every outbound
connection hits a **policy engine** that does one of three things — **allow**, **deny**, or **route
for inference** (swap the agent's API key for a managed one). The default is **deny everything**, so
an agent can run freely inside the box but can't touch the network or your files unless a policy you
wrote says so.

## Start here

👉 **[`lessons/README.md`](lessons/README.md)** — the numbered path. Do the steps in order:

1. **Set up your gateway & first sandbox** — pick your OS:
   [macOS](lessons/macos/01-setup-gateway-macos.md) ·
   [Linux](lessons/linux/01-setup-gateway-linux.md) ·
   [Windows (WSL2)](lessons/windows/01-setup-gateway-windows.md).
   Stand up a containerized gateway, create a sandbox, watch its network get **denied by default**,
   then **hot-reload a policy** and watch the same request succeed.
2. **[Policies & custom agents](lessons/02-policies-and-custom-agents.md)** — the full policy model
   (L4 vs L7, hot-reload, presets) and how to package, credential, and run an agent that isn't on
   the built-in list.
3. **[Run the example agent](lessons/03-run-example-agent.md)** — use [`example-agent/`](example-agent/)
   to point a small agent at a **local Ollama model** through `inference.local`, under a no-egress
   policy. The same agent flips to a **corporate endpoint** by editing one config file.

## Layout

| Path | What it is |
| --- | --- |
| [`lessons/`](lessons/) | The numbered lesson set (start at its `README.md`). OS-specific setup lives in `macos/`, `linux/`, `windows/`. |
| [`example-agent/`](example-agent/) | A tiny, dependency-free agent + scripts that exercise the whole stack (sandbox + policy + provider + inference). Ollama locally; corporate-ready. |
| [`corporate-gateway-setup.md`](corporate-gateway-setup.md) | Standalone guide for an air-gapped corporate gateway (Podman, internal OpenAI-compatible endpoint, public LLM APIs hard-blocked). |
| [`CLAUDE.md`](CLAUDE.md) | Orientation notes for AI coding assistants working in this workspace. |

> The upstream OpenShell **source tree is intentionally not included** here — the lessons install the
> `openshell` CLI with `uv` and pull the gateway image with Podman, so there's nothing to vendor.

## Prerequisites at a glance

- **[Podman](https://podman.io) 5.x** (the container runtime the lessons use) and **[uv](https://docs.astral.sh/uv/)** (to install the `openshell` CLI).
- Network access to `ghcr.io` — the `base` sandbox image is ~2.8 GB.
- **[Ollama](https://ollama.com)** for lesson 03 (a local model to talk to).

## A note on verification

The **macOS** path was verified end-to-end on real hardware (OpenShell 0.0.62 + Podman, talking to a
local Ollama model through `inference.local` under a no-egress policy). The **Linux** and **Windows
(WSL2)** lessons are adapted from that verified flow plus standard rootless-Podman-on-Linux behavior,
and each says so in its own "About this version" note.
