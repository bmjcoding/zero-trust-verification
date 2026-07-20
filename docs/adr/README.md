# ADR index

ADR bodies are history: they are annotated, never rewritten. Supersessions and
narrowings are recorded here (and as additive notes in the ADRs themselves);
an ADR with no note stands as written. Two frontmatter styles coexist on
purpose — 0001–0024 use post-title YAML frontmatter, 0025+ use bold-markdown
status lines — do not "fix" either to match the other.

| # | Title | Status | Superseded / narrowed by |
|---|---|---|---|
| [0001](0001-three-tier-suite-verification-manifest.md) | Three-tier suite in one marketplace repo, integrated via the Verification Manifest | accepted | Packaging + vendoring clauses retired: one plugin (ADR 0025), marketplace retired (ADR 0027), per-plugin byte-identity vendoring retired (ADR 0025). The manifest-as-shared-contract doctrine stands. |
| [0002](0002-agent-escalation-criterion.md) | Agent autonomy boundary: the two-part escalation criterion | accepted | |
| [0003](0003-rot-enforcement-and-pr-gate-placement.md) | Three-point rot enforcement; PR Gate is a mode of the audit, not a fourth checker | agent-decided | |
| [0004](0004-pr-gate-ratcheted-blocking.md) | PR Gate: ratcheted blocking on new debt, never on inherited debt | accepted | |
| [0005](0005-bdd-semantics-no-gherkin-runtime.md) | Given/When/Then-shaped behaviors; no Gherkin runtime | agent-decided | |
| [0006](0006-observability-otel-profiles-agent-first.md) | OTEL-standard vendor-neutral core, LOB config profiles, agent-first triage | accepted | |
| [0007](0007-pr-per-story-granularity.md) | PRs are Stories, Subtasks are commits | accepted | |
| [0008](0008-manifest-bearing-specs-drain-straight-through.md) | Manifest-bearing specs drain straight through | accepted | |
| [0009](0009-derived-ownership-claims.md) | Derived ownership claims from open PRs — no ledger, no service | accepted | |
| [0010](0010-merge-marshal-serial-backstop.md) | The Merge Marshal: serial, deterministic composed-state verifier | accepted | |
| [0011](0011-marshal-fourth-plugin.md) | Marshal as a fourth plugin: wiring, not a checker | accepted | Plugin boundary dissolved by ADR 0025 (the capability stands as a skill/scripts inside `zero-trust`); its claim-overlap vendoring clause retired with the vendoring (ADR 0025). |
| [0012](0012-trunk-based-story-sizing.md) | Trunk-based development, 48-hour Story sizing (amends 0007) | accepted | |
| [0013](0013-host-agnostic-autopilot.md) | Host-agnostic autopilot: Bitbucket DC and GitHub as adapters behind one surface | accepted | |
| [0014](0014-manifest-validator-toolchain.md) | Validator toolchain: Python + ruamel.yaml (YAML 1.2) + jsonschema | accepted | Extended by ADR 0032 (public parse contract). |
| [0015](0015-substrate-shell-python-uv-not-rust.md) | Substrate stays shell + Python-on-uv | accepted | |
| [0016](0016-mutation-testing-first-class-gate.md) | Mutation testing as a first-class gate (D6.5 + PR Gate) | agent-decided | Its per-plugin vendored adapter map + V7 byte-identity lint retired by ADR 0025 (single canonical copy). The D6.5 and PR-Gate mutation gates stand. |
| [0017](0017-remediation-loop-wiring.md) | The remediation loop is wiring, not a fifth checker | agent-decided | Stands; its ratchet guards live in ADR 0018, and its "vendored byte-identical block in all three tiers" language is single-copy post-ADR-0025. (Title line mis-numbered itself "ADR 0018" until 2026-07-17 — typo fixed; body unchanged.) |
| [0018](0018-remediation-ratchet-guards.md) | The remediation ratchet: three named guards | agent-decided | |
| [0019](0019-org-wide-memory-index.md) | Org-Wide Memory: read-only index/crawler, never a second store of truth | agent-decided | Host-enumeration's vendored-transport half superseded by ADR 0028 (`host.sh repo-list` backend method); fifth-plugin packaging dissolved by ADR 0025. The index-not-store doctrine stands. |
| [0020](0020-triage-fifth-plugin.md) | Production-telemetry triage as the fifth (non-tier) plugin | accepted | Plugin boundary dissolved by ADR 0025 (the capability stands); its reconciliation note's "CH-02 unbuilt" premise was retired as false by ADR 0029. |
| [0021](0021-manifest-control-locus.md) | Manifest declares a control `locus`; audit honestly silent off-repo | agent-decided | |
| [0022](0022-out-of-scope-by-declaration.md) | Out-of-scope-by-declaration: a report class that never blocks | agent-decided | |
| [0023](0023-outcome-measurement-report-only.md) | Outcome measurement: report-only, baseline-at-adoption, two honesty classes | accepted | File placement narrowed by ADR 0031 (the outcome runtime family moves into the plugin). The report-only posture stands. |
| [0024](0024-health-loop-attended-wave-drain.md) | /health-loop: attended wave drain, merge-before-verify | accepted | Component paths updated by the ADR 0025 consolidation (its "six plugins unchanged" framing reads historically); the loop semantics stand. |
| [0025](0025-single-plugin-consolidation-prose-diet.md) | Consolidate six plugins into one; put the prose on a diet | accepted | Its "marketplace registers one entry" clause retired by ADR 0027 (skills-dir distribution); the single-plugin invariant stands. |
| [0026](0026-grill-first-spec-inversion.md) | Grill-first inversion of /spec | accepted | |
| [0027](0027-skills-dir-distribution.md) | Skills-dir distribution: the marketplace entry point is retired | accepted | |
| [0028](0028-repo-list-host-backend-method.md) | Repo enumeration becomes a `host.sh` backend method | agent-decided | |
| [0029](0029-wire-section-12-join-retire-ch02-unbuilt.md) | The §12 join fires when its inputs exist; "CH-02 unbuilt" retired as false | agent-decided | |
| [0030](0030-single-copy-contracts-h1-pins-survive.md) | Contract prose is single-copy; the H1 anti-laundering pins outlive the copies | agent-decided | |
| [0031](0031-post-consolidation-residue-one-project-one-version.md) | Post-consolidation residue: outcome family in the plugin; one uv project; one version surface | agent-decided | |
| [0032](0032-manifest-module-owns-parsing.md) | The manifest module owns parsing end-to-end | agent-decided | |
