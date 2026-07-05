# Changelog

All notable changes to the **marshal** plugin. This file is the single source of
truth for version history; `plugin.json` carries the current version number.

## 0.1.0 — 2026-07-05

First release. The Merge Marshal serial, deterministic composed-state merge
backstop (the fourth Zero-Trust Verification plugin, ADR 0011).

### Added

- **`scripts/marshal.sh`** — one serial pass of the merge queue (ADR 0010):
  enumerate ready+approved PRs, strict FIFO by ready-for-review timestamp, rebase
  the head onto trunk **or refuse** per the D7.0 file/hunk budget (file-surface
  intersection) with a kickback comment, verify the composed state via
  `build-status` on the **post-rebase sha**, and green→merge / red→comment+evict+
  next / in-progress→wait. One PR in flight; no speculation, no batching. The only
  override is a human hotfix pin, logged to the Force Audit. Deterministic
  decision log; write scope is rebase-push + merge only (ADR 0011). All PR/build
  ops go through the host adapter (ADR 0013); host-agnostic across GitHub +
  Bitbucket DC + the mock.
- **`scripts/claim_overlap.sh`** — the vendored claim-overlap check (ADR 0009):
  a pure `(claim-id, file)`-pair set-intersection kernel with a default
  contended-surface report and a `--for <id>` collision query. Authored here as
  the **canonical** copy (autopilot has no claim-overlap check on main yet); its
  future vendor in autopilot G4 must be byte-identical.
- **`scripts/branch_age_watcher.sh`** — the 48h staleness / planning-failure
  watcher (ADR 0012/0009): flags branches whose last commit is older than the
  trunk-based ceiling, from `<id>\t<epoch>` pairs or a `--refs` git glob, with a
  `--now` override for deterministic sweeps.
- **`scripts/mock_host.py` + `scripts/mock_host.sh`** — a hermetic mock host
  backend (Python via `uv`, ADR 0015) implementing the subcommand contract the
  Marshal drives, including a real **Composition Break** build model (a symbol
  defined/called check over the composed tree) so the compose-verify path is
  exercised end-to-end, not stubbed.
- **`scripts/self_test.sh`** — hermetic self-test driving the loop
  through the mock across FIFO, rebase-refuse (budget + conflict), compose-verify
  (green, red, in-progress), merge-or-evict, hotfix-pin/Force-Audit, and pin-
  ignored scenarios, plus claim-overlap (both modes) and branch-age fixtures.
- **`commands/marshal-pass.md`**, **`commands/marshal-staleness.md`** — operator
  entry points for a manual pass and the watcher sweep.
- **`reference/marshal-loop.md`**, **`reference/host-contract.md`** — the loop
  state machine + cron entry, and the host adapter surface (including the new
  `pr-list-ready` primitive the queue needs).

### Notes

- The `pr-list-ready` host primitive (queue enumeration with the ready timestamp
  + approval state) is specified in `reference/host-contract.md` and implemented
  in the mock. Wiring it into the real `host.sh` / `github.sh` / `bitbucket.sh`
  adapters (covered by the T01-class mock matrix, for byte-identical backends) is
  a tracked follow-up in the autopilot host-adapter, kept out of this diff to
  preserve the AV3-15 adapter's guarantees.
- Scripts target bash 3.2 (macOS default) + BSD userland, matching the rest of the
  suite's deterministic substrate.
