# Autopilot is git-host agnostic; Bitbucket DC and GitHub are adapters behind one surface

---
status: accepted
date: 2026-07-04
---

Autopilot v2.4.0's Hard Contract 11 ("Bitbucket Data Center is the source-of-truth host; `gh` is NOT a dependency") is rewritten: **autopilot is host-agnostic by contract.** A single dispatch surface (`scripts/host.sh`, backend detected from `origin`) exposes the PR/build subcommand set (`pr-open [--draft]`, `pr-ready`, `pr-state`, `pr-comment`, `pr-merge`, `build-status`, …); `bitbucket.sh` becomes the Bitbucket DC backend, a `gh`-CLI backend implements the identical contract. Decided by Bailey 2026-07-04: DC is the host inside enterprise walls; GitHub is the host here and for community distribution — the adapter is the permanent architecture, not a dogfooding workaround.

Both backends run the same contract-test matrix (the T01-class mock suite) so "works on DC" and "works on GitHub" are the same assertion set. Loop-safety invariants, secret handling (resolver chain; tokens never in context), and the no-`gh`-in-DC-mode posture are per-backend properties behind the surface, not caller concerns.

## Consequences

- The suite can drain its own registers on this repo (self-hosting unblocked); enterprise deployment is a backend selection, not a fork.
- AV3-16b (Hard Contract 11 rewrite) is unconditional; register item AV3-15 is approved and leads the landing order.
- Any future host (GitLab, Gitea) is a new backend passing the existing matrix — never a new caller path.
