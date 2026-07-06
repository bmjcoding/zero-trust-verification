# Business Vitals

The normative vocabulary for one question: **can the business see its own
critical operations happening?** This reference owns journey-scoped
instrumentation *placement* — whether a vital step emits anything, and whether
anyone would notice if it stopped. Log-line *quality* (stdout-as-log-channel,
log-and-swallow, correlation IDs) is taxonomy **Category LOG**
(`incomplete-logic-taxonomy.md`). The same underlying defect flagged by both
lenses = ONE finding, deduped per the precedence chain in
`audit-state-and-verify.md`, the other lens recorded in `lenses`; genuinely
different defects on one symbol (say, missing emission here AND
log-and-swallow there) keep their own slugs and stay separate findings.

Vitals are graded by `journey-walker` during the single trace walk and recorded
per step in `audit/journeys.json` (`journey-trace.md`).

## The four vital classes

| Class | What | Examples |
|---|---|---|
| money | Money movement | charge, refund, payout, transfer, invoice, settlement |
| state-transition | Business-state changes with consequences | order placed/cancelled, loan approved, subscription upgraded, account closed |
| external-side-effect | Irreversible effects leaving the system | email/SMS sent, webhook delivered, file shipped to a partner, third-party API mutation |
| auth | Auth events | login, token issued/revoked, permission granted, password reset |

`VITAL_RE` in `run_audit.sh` seeds only a **slice** of this vocabulary: the
merged money + auth-adjacent verb list (transfer/refund/charge/…/auth/approve
— its own comment says it merges the vitals and TX money-verb lists; bare
`wire` is deliberately excluded there, `transfer` covers `wire_transfer`).
It has **no verbs for the external-side-effect class** (email/SMS sent, webhook
delivered, file shipped) **and few for state-transition** (order
placed/cancelled, account closed) — those flows are inventoried by reading
entry points, handlers, and webhook/queue/notification consumers
(journey-walker Method step 1), never from the seed file alone. Change
`VITAL_RE` and the money/auth rows together; do not treat the seed as
class-complete.

## What counts as an emission

An emission is a **structured event with a stable dot-namespaced name plus
identifiers** (`emit_event("payment.charged", amount=..., account_id=...)`), a
**metric**, or a **span**. A prose log line does **not** count —
`log.info("charged the card ok")` has no stable name to alert on and no
identifiers to join on. (Grading the log line itself is Category LOG territory.)

Per-language idioms:

| Form | Python | TypeScript / JS | Rust | Go |
|---|---|---|---|---|
| Structured event | structlog / `logger.info("payment.charged", extra={...})` with stable name + fields | pino/winston `logger.info({event: 'payment.charged', ...})` | `tracing::info!(event = "payment.charged", amount)` | zap/slog `logger.Info("payment.charged", fields...)` |
| Metric | prometheus/statsd `counter.inc()` | prom-client `counter.inc()` | `metrics::counter!` | prometheus `counter.Inc()` |
| Span | OpenTelemetry `start_span` | OTel `startSpan` | `tracing` span | OTel `tracer.Start` |
| NOT an emission | `print()`, prose `log.info(...)` | `console.log`, prose string logs | `println!`, prose `log::info!` | `fmt.Println`, prose `log.Printf` |

## Emission grades — OBSERVED / LOG-ONLY / DARK

A **separate axis from severity**, same rule as SAFE/CAUTION/DANGER
(`severity-rubric.md`, Grade words) — don't mix the vocabularies.

- **OBSERVED** — a real emission at the vital step. Table output, never a finding.
- **LOG-ONLY** — only a prose log line. Someone grepping after the incident will
  find it; no alert ever fires from it.
- **DARK** — nothing. The vital could silently stop or spike and the code would
  not tell anyone.

## The alerting seam

The question, asked per emission: **would anyone be paged if this vital silently
stopped — or spiked?** Checklist against `audit/telemetry.txt` and
`audit/alerting_config.txt`:

1. Is the emitted name (or metric) referenced anywhere in alert/monitor/SLO
   config?
2. Does that reference page a human, or only paint a dashboard?
3. No alert config in the repo → the honest answer is
   **"unknown — no alert config in repo"**. Unknown is a valid grade
   (alerting often lives outside the repo); guessing `paged` is not.

Recorded as `alert_seam`: `paged` / `dashboard-only` / `unknown` in
`journeys.json`.

**Candidates, not verdicts.** `vital_candidates.txt`, `telemetry.txt`, and
`alerting_config.txt` are grep/find seeds. Presence in `telemetry.txt` does not
prove the emission fires on *this* path — trace it; absence does not prove DARK
— search before grading.

## Category TX critical-step questions

At every money / state-transition / external-side-effect step, ask in order
(answers recorded in `journeys.json` as `duplicate_guard` /
`compensation_note`; findings and severity are taxonomy **Category TX**):

1. **Arrives twice?** Who can deliver this input twice — webhook redelivery,
   at-least-once queue, user double-click, an enclosing retry loop? (CRITICAL
   still requires *naming* who delivers the duplicate.)
2. **Dies between steps?** If the process dies after step k of n, what state is
   left half-applied, and who notices?
3. **Guard before side effect?** Is the idempotency-key/dedup check evaluated
   *before* the side effect executes? A guard after the effect is a
   double-submit window.
4. **Compensation / audit trail?** Is there a compensating action for partial
   failure, and an audit record for money-like transitions?

**TRACE-ONLY.** These questions are never answered by submitting twice, and
money/auth paths are never executed — a probe that charges a card is not a
probe, it is an incident. Read the code; quote the guard or its absence.

## Severity mapping (per the 1.4.0 absence-finding gate)

Uninstrumented-vital findings are absence findings — there is no repro of
nothing; the trace is the only confirmation (`severity-rubric.md`, 1.4.0
amendment):

- **HIGH** only for DARK on a **traced CORE money-movement or auth path**, with
  the `journeys.json` trace attached as evidence — the wire-transfer exemplar.
- **Everything else hard-caps at MED**, no judgment escape above the cap. This
  list mirrors the rubric's 1.4.0 absence-gate list — change them together:
  LOG-ONLY = MED, even on a traced CORE money/auth path (HIGH is DARK-only);
  DARK or LOG-ONLY off a traced CORE money/auth path = MED. The
  **needs-verification** mark rides on untraced/unconfirmed reachability
  (DARK on an untraced flow = MED needs-verification); a capped vital on a
  traced path is confirmed MED, no mark.
- No trace (`journeys.json` missing/corrupt) → cap MED needs-verification per
  `journey-trace.md`'s degrade rules — never guess criticality.

Category `journey/uninstrumented`; canonical slugs like `dark-money-movement`,
`log-only-refund`.

## Judgment guardrails

- **Pure calculators are not vitals.** A function that computes a fee but moves
  no money, mutates no state, and touches nothing external emits nothing —
  correctly.
- **Instrumented vitals are table output.** An OBSERVED step appears in the
  per-journey vitals table, never as a finding.
- **Tests are excluded.** Test files are not production vitals.
- A side-effect function that *does* perform its effect but emits no business
  event is `journey/uninstrumented` — never taxonomy Category C (the
  disambiguation line under C routes here).
