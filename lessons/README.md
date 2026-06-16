# OpenShell from Scratch — Hands-on Lessons

A numbered path that takes you from **nothing installed** to a **running OpenShell gateway**, your
own **sandbox**, a working grasp of the **policy** and **custom-agent** model, and finally a real
**example agent talking to a local model** through OpenShell's managed inference.

Do the steps in order. Each builds on the last.

## The path

### Step 1 — Set up your gateway & first sandbox · *pick your OS*

Stand up a containerized gateway, create a sandbox, and watch its network get **denied by default**.
You only do **one** of these — pick the one that matches your machine:

| Lesson | For you if… |
| --- | --- |
| **[01 · macOS](macos/01-setup-gateway-macos.md)** | You're on a Mac (Apple Silicon or Intel). Verified end-to-end. |
| **[01 · Linux](linux/01-setup-gateway-linux.md)** | You're on a Linux host. Native rootless Podman — no VM, the simplest path. |
| **[01 · Windows (WSL2)](windows/01-setup-gateway-windows.md)** | You're on Windows 10/11. You'll work inside a WSL2 Linux distro (the most robust path). |

### Step 2 — Update policies & run custom agents

| Lesson | What it covers |
| --- | --- |
| **[02 · Policies & Custom Agents](02-policies-and-custom-agents.md)** | The full policy model and how to change what a sandbox can reach (including on a *running* sandbox), plus how to package, credential, and run an agent that isn't on the built-in list. |

### Step 3 — Run the example agent (local model, corporate-ready)

| Lesson | What it covers |
| --- | --- |
| **[03 · Run the Example Agent](03-run-example-agent.md)** | Use the runnable [`../example-agent/`](../example-agent/) project to point a small agent at a **local Ollama model** through `inference.local`. Written so the same agent flips to a **corporate endpoint** by editing one config file. |

## What you'll learn

- The OpenShell model: **gateway → compute driver → sandbox → policy engine → inference router**.
- How to stand up a containerized gateway and register the CLI against it.
- How to create a sandbox and why its egress is **default-deny**.
- How to **hot-reload** a network policy and how **L7 enforcement** (HTTP method/path) works.
- How to give a **custom agent** an image, credentials (providers), and managed inference.
- How every allow/deny decision is **audited** (OCSF logs).

## Before you start

- ~30–40 minutes for Step 1, plus network access to `ghcr.io` (the `base` sandbox image is ~2.8 GB).
- Step 3 also needs a local model runtime ([Ollama](https://ollama.com)) — the example walks you through it.
- The example policy reused across steps is [`github-readonly.yaml`](github-readonly.yaml).

## Why these exist (and differ from the official quickstart)

The upstream "TLS-disabled" container-gateway quickstart gets you a gateway that *reports healthy*
but **can't actually create a working sandbox** on current versions. These lessons fill the gaps the
docs omit — sandbox-JWT material, the unauthenticated-CLI escape hatch, the shared token directory,
runtime-socket access, running the gateway as root-in-container, and the CLI↔gateway **version
match** — each with a short *why* so you understand the model, not just the commands.

> **The three OSes in one line:** **Linux** is the native case — rootless Podman on one host, the
> socket mounts directly and any `$HOME` path works. **macOS** runs Podman in a separate VM (so the
> gateway must reach the socket inside that VM, share file paths across the boundary, and work around
> the VM's SELinux). **Windows** runs the Linux steps *inside* a WSL2 distro, so it behaves like the
> Linux case once WSL2 is set up. The OpenShell steps themselves are identical across all three.
