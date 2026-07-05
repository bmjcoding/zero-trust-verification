# Substrate stays shell + Python-on-uv; not a Rust port

---
status: accepted
date: 2026-07-05
---

The suite's deterministic substrate stays **shell + Python**, with **uv** as the single Python toolchain (replacing pip+venv). We do **not** port the logic to Rust. Decided by Bailey 2026-07-05 after explicitly weighing a Rust port.

**Why not Rust.** The overwhelming majority of the suite is not code that any language could hold: the autopilot, spec-gen, and audit "logic" is LLM-orchestration prose — SKILL.md, reference/role prompts, ADRs, specs, and the Verification Manifest — consumed by Claude Code. That surface is language-agnostic and unportable; Rust touches none of it. The only Rust-addressable code is the deterministic substrate (shell glue over git/curl, the ~200-line manifest validator, the audit's detection core), a minority of the artifact — and the shell glue is already hardened and self-tested (autopilot 96 + codebase-health 138 assertions). Rewriting working, tested glue buys nothing, and Rust's compile/ceremony would tax a project that iterates fast on specs. The suite's thesis is "raise the floor"; shell + Python + markdown is maximally forkable and reviewable for the target engineering org and the broader community, where Rust would raise the contribution floor.

**Why uv.** uv gives reproducible, lockfile-pinned Python (`pyproject.toml` + `uv.lock`) and `uv run` self-bootstrapping — directly killing the python3-not-on-PATH / manual-venv fragility we hit repeatedly. Every Python invocation across the repo routes through `uv run`; no `pip install`, no hand-managed `.venv`.

## Considered Options

- **Full Rust port** — rejected: addresses ~20% of the artifact (the deterministic substrate) while leaving the LLM-prose core untouched, at the cost of months of rewrite and slower iteration; the tested shell glue would be rewritten for no functional gain.
- **Rust for the manifest validator + audit engine only** — deferred (not dismissed): a single static `ztv-engine` binary would erase runtime-dependency fragility for org rollout, but that is a v2 packaging optimization, worthwhile only once the contracts are proven and only if dependency fragility becomes the actual adoption blocker. uv closes most of that gap now. Revisit trigger: dependency install becomes a documented adoption blocker.

## Consequences

- Root `pyproject.toml` + committed `uv.lock` define the Python toolchain; scripts call `uv run`. The manifest validator migrates first (this ADR's PR); each plugin's Python (codebase-health, autopilot mock server) migrates to `uv run` within its own build task.
- A future optional `ztv-engine` binary, if ever built, ships *behind the existing script contracts* (`validate_manifest.sh`, audit entrypoints) so it is a drop-in fast/dependency-free path, never a new caller surface.
