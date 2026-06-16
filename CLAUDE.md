# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Layout

This directory is a research workspace, not the project itself. It contains:

- **`OpenShell/`** — the actual project: a git repository (NVIDIA OpenShell) with a Rust workspace, Python SDK, and a complete set of agent-facing docs. **Run all build/test/dev commands from inside `OpenShell/`.**
- **`corporate-gateway-setup.md`** — a standalone, self-contained guide for standing up an OpenShell gateway in an air-gapped corporate environment (Podman runtime, internal OpenAI-compatible model endpoint, no `api.anthropic.com` reachability). It is documentation only; nothing imports or depends on it.

The workspace root is *not* a git repo; `OpenShell/` is. Commit and branch from `OpenShell/`.

## Authoritative Docs (read these first)

The OpenShell project already maintains thorough agent instructions. Defer to them rather than re-deriving:

- `OpenShell/AGENTS.md` — primary agent instruction surface: architecture table, workflow chains, OCSF logging rules, commit/PR conventions. (`OpenShell/CLAUDE.md` simply imports this.)
- `OpenShell/CONTRIBUTING.md` — build setup, full `mise` task reference, project structure, the agent skills table, and the vouch system for external contributors.
- `OpenShell/.agents/skills/` — workflow skills (CLI usage, cluster/inference debugging, policy generation, spike/build, triage). Your harness discovers these natively; prefer the relevant skill over ad-hoc investigation.

## Common Commands

All commands run from `OpenShell/`. Tooling is managed by [mise](https://mise.jdx.dev/) (Rust 1.95, Python 3.14, Node 24, protoc, helm — pinned in `mise.toml`). Run `mise trust` once after cloning.

```bash
mise run gateway      # run a standalone gateway for local development
mise run sandbox      # create or reconnect to the dev sandbox
mise run test         # full test suite: Rust + Python + install.sh
mise run e2e          # end-to-end tests against a Docker-backed gateway
mise run ci           # full local CI (lint + compile/type checks + tests) — run before a PR
mise run pre-commit   # lint, format, license headers — run before every commit
```

`openshell` itself is a shortcut script at `scripts/bin/openshell` (added to PATH by mise); it builds and runs the local debug CLI, so `openshell --help` works directly from the repo.

### Running a single test

`mise run test` wraps these; run them directly to scope to one test:

```bash
cargo test --workspace                          # all Rust tests
cargo test -p openshell-policy <test_name>      # one crate / one test
uv run pytest python/path/to/test_file.py::name # one Python test (always use uv)
```

End-to-end lanes are separate and need a running gateway: `mise run e2e` (Docker), plus `e2e:podman`, `e2e:kubernetes`, `e2e:vm` for other compute drivers. See `OpenShell/tasks/test.toml`.

### External Z3 dependency

The `openshell-prover` crate links the system Z3 library via pkg-config (`brew install z3` on macOS). If you can't install it system-wide, build with the bundled feature: `cargo build -p openshell-prover --features bundled-z3`.

## Architecture (big picture)

OpenShell is a **safe, sandboxed runtime for autonomous AI agents**. A gateway control plane manages sandbox lifecycle through a pluggable compute driver (Docker, Podman, MicroVM, Kubernetes); every sandbox's outbound traffic is intercepted by the policy engine, which **allows**, **denies**, or **routes for inference** (stripping caller credentials and injecting backend credentials toward a managed model). This is the core control/data flow worth internalizing before changing any crate.

The Rust workspace is `crates/*`. Key boundaries (full table in `OpenShell/AGENTS.md`):

- `openshell-cli` — user-facing CLI; `openshell-server` — gateway control-plane API and auth boundary.
- `openshell-sandbox` — in-sandbox supervisor: container supervision and policy-enforced egress.
- `openshell-policy` (+ `openshell-prover`) — filesystem/network/process/inference constraints, hot-reloadable for network/inference; the prover verifies policy with Z3.
- `openshell-router` — privacy-aware LLM routing (the `inference.local` endpoint).
- `openshell-driver-{docker,kubernetes,vm}` — `ComputeDriver` backends; the VM driver is a standalone libkrun subprocess.
- `openshell-ocsf` — structured security event logging (see below).
- `openshell-core` (shared types/config/errors), `openshell-bootstrap`, `openshell-providers`, `openshell-tui`.

Supporting trees: `python/` (SDK + CLI packaging, always driven via `uv`), `proto/` (gRPC contracts), `deploy/` (Dockerfiles, Helm chart, K8s manifests), `architecture/` (canonical subsystem docs), `docs/` + `fern/` (published docs).

## Project-Specific Conventions

These are non-obvious and easy to get wrong — `OpenShell/AGENTS.md` is the source of truth:

- **OCSF vs plain tracing:** log emissions in `openshell-sandbox` that represent observable security behavior (network/HTTP/SSH decisions, process lifecycle, security findings, config changes) must use an OCSF builder + `ocsf_emit!()`; internal plumbing uses `info!`/`debug!`/`warn!`. Security findings dual-emit a domain event *and* a `DetectionFindingBuilder`. Never log secrets in OCSF messages. See the OCSF section of `AGENTS.md` for the builder/severity tables.
- **Conventional Commits**, no AI attribution in commit messages. Human contributions need a DCO `Signed-off-by` (`git commit -s`).
- **Docs**: update `architecture/` for design changes and `docs/` (+ `docs/index.yml`) for user-facing changes, in the same PR. Temporary plans go in the git-ignored `architecture/plans/`.
- **External contributors** are gated by a vouch system; skills that open PRs/issues must follow the templates and the vouch rules.
