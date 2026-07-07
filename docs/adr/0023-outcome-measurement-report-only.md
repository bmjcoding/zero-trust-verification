# Outcome measurement: report-only, baseline-at-adoption, two honesty classes

---
status: accepted
date: 2026-07-07
---

The suite's four checkers, the Marshal, and the org-memory/triage plugins all
answer *"is this change safe to merge?"* None of them answers *"did installing the
suite make the software measurably better?"* — deploy cadence, lead time, change-
failure rate, build-MTTR, and whether the CORE money/auth journeys are actually
OBSERVED rather than DARK. That outcome question is what a VP asks before an org-
wide rollout, and it is the one question the checkers structurally cannot answer
about themselves without becoming a checker that grades its own homework.

Outcome measurement answers it as **wiring, not a checker** (the ADR 0011 test the
Marshal passed: every decision is a git-log fact, a host-API read, or a projection
of an artifact an agent already produced — no new quality opinion). It is a set of
**modes on two existing plugins** (a Marshal `outcome-capture`/digest mode and a
codebase-health audit `outcome-emit` step) plus one shared append-only store, a
baseline, and a renderer. It is **not a fifth/seventh plugin** — no marketplace
entry, no self-test root of its own (ADR 0003's no-new-checker test; the six-plugin
count in ADR 0001/0011/0019/0020 is unchanged).

## Decision

**Report-only, permanently (ADR 0004).** Outcome measurement forms no exit-code
authority, adds no gate or hook, opens no PR, files no finding, triggers no drain /
remediation / fresh audit. Every path exits 0. This is not a soak-then-block ramp;
it is permanent. The design closes the self-remediation attack surface at the
structural level: there is no autonomous action to be made infinite because there
is no autonomous action at all. It reads history + the last audit's output, writes
the store, and renders a report.

**Two honesty classes, never conflated.** Every metric row in the store carries a
mandatory `honesty_class`:

- **Class-D (`deterministic`)** — the four DORA-family metrics (deploy frequency,
  lead time, change-failure rate, build-MTTR). Each is `git log` first-parent /
  host-API `build-status` provable with **no agent in the loop**. Class-D is `[det]`
  on a fixture and `[drain]` on a live host.
- **Class-A (`agent-graded`)** — the journey emission share (OBSERVED vs
  LOG-ONLY/DARK on CORE money/auth vital steps). Its input is `audit/journeys.json`,
  written by the **journey-walker agent**, so the grade is a judgment, not a
  hermetic fact. The projection *arithmetic over a fixed fixture* is `[det]`; the
  metric *on a real repo* is `[audit-run]`, and the store + renderer label it so.
- **`human-annotated`** — the fallback for external facts the repo cannot observe
  (defect-escape without a configured source; incidents/MTTR/paged-share, whose
  alert seams live outside the repo, ADR 0006). Entered by an operator, tagged as
  annotated, and **never** dressed as derived.

Nothing is **model-estimated**. There is no LLM "code-quality score" — that would
make the checker grade itself, the exact circularity this layer exists to break.

**Baseline at adoption, frozen, refuse-second (the load-bearing constraint).** A
before/after is lost if the BEFORE is not captured at the adoption event. Because
deploy/merge cadence, post-merge build state, and lead time are reconstructable
from trailing `git log` + host history, the DORA baseline is captured
**retroactively** at adoption (no forward wait). The emission-share baseline is
asymmetric: it requires ONE audit run at adoption and is Class-A, so it is captured
but tagged `agent-graded`, never as retroactive `[det]` history. The baseline is
written once with `frozen: true`; a second capture is **refused** and leaves the
file byte-untouched. No captured baseline → absolute-value reporting with
`[OUTCOME-NO-BASELINE]`, never a fabricated "before".

**One store, one schema, degrade-never-act.** `schema/outcome/v1.schema.json` is the
single structural source of truth, validated by the SAME jsonschema toolchain as the
manifest (ADR 0014, `Draft202012Validator`, exit 0/4/64). A row without
`honesty_class` is schema-invalid — no unlabeled number can enter the store. The
store is append-only `runs[]` + one frozen `baseline`; a corrupt/unknown-version
store is refused (never overwritten), mirroring `state.json`'s degrade rule.

**Producers co-locate with the data owner; the digest rides an existing seam.** DORA
capture is a Marshal mode (it holds host write scope; ADR 0011 names it the future
home of the PR-event agent) — a NEW retroactive `git log` + `build-status` read, not
"the stream it already watches". Emission share is a read-only audit step consuming
the LAST `journeys.json` (no fresh walk). The scheduled digest is an added per-fire
step on the Marshal's EXISTING operator-wired single-fire cron (ADR 0010/0011); it
posts through the Marshal's host write scope (the audit side posts nothing), and
never triggers a fresh audit to freshen the share.

## Consequences

- **Alternatives rejected:** a forward-only baseline (loses the adoption before/after
  and tempts a fabricated "before"); a fifth plugin (fails ADR 0003's no-new-checker
  test and inflates the marketplace count); an LLM quality score (circular — the
  checker grading itself); a repo-derived paged-share (alert seams live outside the
  repo, ADR 0006, so a repo-derived number is near-zero-signal — paged-share moves
  behind the external adapter and degrades to `[OUTCOME-SOURCE-ABSENT: alert-config]`).
- **The emission share is suite-produced but agent-graded**, correlated-with-adoption
  with confounders named — never dressed as a hermetic causal proof. Deciding WHICH
  metric headlines the pitch, whether an agent-graded share is admissible as pitch
  evidence to a given audience, the defect-escape/incident sources, and the
  significance window are **escalated** (ADR 0002), not decided here.
- Supporting ADRs (cited, not superseded): 0002 (escalation), 0003 (no new checker;
  the ambient scheduled audit is design intent, not yet wired), 0004 (report-only,
  deterministic-evidence-only gating), 0006 (OTEL profiles; alert seam outside the
  repo), 0010/0011 (Marshal single-fire cron; wiring not a checker), 0013 (host.sh
  adapter contract), 0014 (validator toolchain + exit codes), 0015 (shell+python+uv).
- A skeptic can confirm the report-only posture mechanically: no gate/hook/PR/finding/
  fresh-audit path exists, and the lint's anti-laundering guard proves no `[det]`
  acceptance claims a real-repo agent-graded number.
