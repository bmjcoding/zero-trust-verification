# docs/specs — what each file is, and how alive it is

Three genres live here; read each accordingly.

- **Living contract** — [`verification-manifest-v1.md`](verification-manifest-v1.md) ("MS"): the normative Verification Manifest spec. Edited in place as the contract evolves.
- **Frozen build records** — [`codebase-health-spec-1.4.0.md`](codebase-health-spec-1.4.0.md) (history, but its §12 determinism sweep is LIVE grep-input to root lint V10 — never reword §12) and [`refactor-2026-07-consolidation.md`](refactor-2026-07-consolidation.md) (the ADR 0025 wave plan; see its dated Status block for what actually ran).
- **Append-only registers** — `*-register.md` and [`spec-gen-tier-v1.md`](spec-gen-tier-v1.md): acceptance entries are never rewritten; corrections land as new dated notes citing an ADR. [`outcome-measurement-register.md`](outcome-measurement-register.md) is live grep-input to root lint V11's H1 anti-laundering guard.

Supporting inputs: [`behavior-coverage-format.md`](behavior-coverage-format.md) (LIVE line-shape input to root lint V2) and [`outcome-store-contract.md`](outcome-store-contract.md) (canonical outcome-store block, pinned by V11).
