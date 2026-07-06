# Audit State & Verification

What makes the audit a **closed loop** instead of a one-shot report: every finding
gets a stable identity, every run persists state, and `/verify` grades closure with
evidence instead of trusting that findings were "addressed."

## Finding fingerprints (stable identity across runs)

```
fingerprint = first 12 hex of sha1("<path>:<symbol>:<slug>")
```

- `path` — file path relative to the repo root.
- `symbol` — the enclosing function/class/method name; use `<module>` for file-level findings.
- `slug` — a short kebab-case descriptor of the *defect kind*, derived from what
  is wrong, not from prose: `fake-validator`, `swallowed-error`,
  `todo-retry-path`, `missing-case-service`, `o-n2-scan`, `log-and-swallow`,
  `dark-money-movement`, `log-only-refund`, `convoluted-branching`. Where a
  reference defines canonical slugs, use them verbatim, never synonyms —
  taxonomy Category TX: `non-idempotent-handler`, `missing-dedup-guard`,
  `unsafe-retry`, `double-submit-window`, `missing-compensation`,
  `missing-audit-trail`. The slug is chosen at
  first detection, stored in state, and **reused verbatim** on later runs —
  match an existing finding by path+symbol+defect before minting a new slug.
  The slug exists because one symbol can carry several distinct defects (five
  different markers in one function must be five findings, not one blob).

**Category is metadata, not identity.** The same defect seen through two lenses
(a fake validator is both `incomplete-logic/B` and `security/authn`) must not
produce two findings. Dedup rule: same path+symbol and the same underlying
defect → ONE finding; its `category` is picked by the precedence chain

**security > incomplete-logic > test-health > performance > dead-code > architecture > navigability > journey**

and every other lens goes in `lenses` + evidence. This chain is defined here
and ONLY here — every other reference, agent, and command cites it, never
restates it. Slot mapping: `security/*` (including
`security/transactional-integrity` and `security/logging`) → security;
`incomplete-logic/A`–`G` and `incomplete-logic/LOG` → incomplete-logic;
`test-health/T1`–`T12` → test-health (EVERY finding whose subject is test code
— one owner, the test-health-auditor); `navigability/*` → navigability;
`journey/uninstrumented` and `journey/path-complexity` → journey.

Worked dedups the chain yields: a token logged on an auth path →
`security/logging`, lens `incomplete-logic/LOG`; a tx defect seen by both
security-auditor and journey-walker → `security/transactional-integrity`, lens
journey; a wrong-seam test that also constrains nothing →
`test-health/T*`, lens architecture; a convoluted CORE journey step also
flagged as a hot path → `journey/path-complexity` per the slot mapping above,
lens performance (filed solely by journey-walker — filer ownership is stated
once in its agent prompt, which performance-analyzer cites; severity stays
criticality-weighted). One deliberate non-dedup: a
rubber-stamp test blessing a reachable security defect is TWO findings on two
symbols, cross-linked, never merged. Genuinely different defects on
the same symbol keep different slugs and stay separate.

**No line numbers** — they drift on every unrelated edit.

**Renames and moves are not closures.** When a symbol or file disappears,
`/verify` must first look for it elsewhere (`git log --follow -- <path>`, grep
for the symbol name) and re-judge the defect at the new location. If found, the
finding's `path`/`symbol` are updated, the fingerprint is recomputed, and the
old fingerprint is kept in an `aliases` list — history survives the move. Only
a symbol that is genuinely gone proceeds to the removed-symbol rules below.

## `audit/state.json` (written by `/audit`, updated by `/verify`)

```json
{
  "schema_version": 2,
  "runs": [
    {
      "run": 1,
      "kind": "audit",
      "date": "2026-07-02",
      "git_sha": "abc1234",
      "target": "src/",
      "marker_count": 214,
      "suppression_count": 37,
      "flaky_count": 5,
      "test_vacuity_count": 1,
      "test_skip_count": 4,
      "stdout_logging_count": 12,
      "giant_file_count": 2,
      "commented_code_count": 3,
      "findings_by_severity": {"CRITICAL": 0, "HIGH": 6, "MED": 18, "LOW": 22}
    }
  ],
  "findings": {
    "a1b2c3d4e5f6": {
      "tag": "IL-H1",
      "slug": "fake-validator",
      "category": "incomplete-logic/B",
      "lenses": ["security/authn"],
      "path": "src/sdk/auth.py",
      "symbol": "validate_api_key",
      "aliases": [],
      "severity": "HIGH",
      "title": "validator accepts any non-empty string",
      "status": "OPEN",
      "first_seen": 1,
      "last_seen": 1,
      "evidence": "returns bool(key); no key-store check",
      "verified_by": null
    }
  },
  "not_covered": ["scripts/migrations/", "examples/legacy/"]
}
```

- All eight ratchet counts come from `audit/counts.env` (written by
  `run_audit.sh`) — deterministic, not model-estimated.
- The six counts after `suppression_count` are **optional** and new in 1.4.0:
  runs recorded by earlier versions simply lack them. An absent count means
  "no comparable baseline for `<count>`" — never read it as 0, never
  manufacture a fake regression from it. Adding optional fields is not a
  schema break: `schema_version` stays 2.
- `kind` is `audit` or `verify`; `target` is the scope the counts were computed
  over. Both matter for the ratchet (below).
- `verified_by` is set **only by `/verify`**, never at detection time, and must
  point at evidence: a test path that goes red without the fix **plus its
  rerun count from the determinism gate below** — e.g.
  `tests/test_auth.py::test_rejects_unknown_key (5/5)` — or `file:line`
  showing the corrected code plus the commit that fixed it.
- `not_covered` mirrors the report's Not-Covered section (see coverage ledger in
  `/audit`) — including any real source directories skipped because their names
  collide with the exclusion list (`audit/excluded_dirs.txt`).

### Findings a re-audit does not re-detect

Agent runs vary; a previously-OPEN finding that a new `/audit` fails to
rediscover is **not** thereby closed. It stays OPEN with `last_seen` unchanged,
and the new report lists it under "open findings not re-confirmed this run" so
a human sees the discrepancy. Only `/verify` (with evidence) or a human
(WONTFIX) moves a finding out of OPEN. `/audit` may only add findings, re-open
REGRESSED ones, and bump `last_seen`.

### Corrupt or missing state — degrade, never act

If `state.json` is missing, unparseable, or has an unknown `schema_version`:
say so explicitly and treat the run as a **first run**. Never guess at partial
state, never delete the file, never let a broken state influence any action.
A wrong loop must fail toward *reporting less*, not toward *doing more*.

## Status lifecycle

| Status | Meaning | Who sets it |
|---|---|---|
| OPEN | Detected, not yet verified fixed | `/audit` |
| PARTIAL | Symbol changed but the defect is only half-addressed, or fixed without a regression test, or fixed but the closing test is flaky or unrunnable | `/verify` |
| FIXED | Defect gone AND regression evidence exists (`verified_by` set) | `/verify` |
| REGRESSED | Previously FIXED, defect present again | `/verify` |
| STALE | Symbol genuinely gone (rename/move already ruled out) with no FIX_LOG/DELETION_LOG entry naming this finding — needs human | `/verify` |
| WONTFIX | Human explicitly declined; carries a reason; never re-reported except on request | human via `/verify --wontfix <tag> --reason "..."` |

**PARTIAL is the most important verdict.** A half-done fix is new half-baked code —
exactly the debt class this plugin exists to catch. `/verify` must never round
PARTIAL up to FIXED for want of a test.

**Removed symbols never round up to FIXED on a bare `git log` hit.** Every
deletion has *some* commit; "removed in abc123" explains nothing about whether
the defect's behavior was replaced or lost. FIXED-via-removal requires a
`FIX_LOG.md`/`DELETION_LOG.md` entry that names this finding's tag or
fingerprint. Anything less is STALE, and STALE means a human looks.

## Closing-test determinism (the FIXED gate)

A finding is only as closed as its closing test is trustworthy. One green run
proves almost nothing: a test that fails one run in three still passes a
single check two times in three — but passes five consecutive fresh runs only
~13% of the time. So before `verified_by` is set, `/verify` runs the closing
test **5 times, each in a fresh process** (same-process reruns share polluted
module and global state), **order-randomized on one of the five** where the
runner supports it (`pytest -p randomly`, `jest`, `go test -shuffle=on`).
**N=5 is fixed** — no override flag exists anywhere (Decision 3).

Alongside the reruns, the closing test's file is screened with `FLAKY_RE`
**sourced from `scripts/debt_patterns.sh`** — the same definition the detector
and the prevention hook use, so verification can never drift from them. Screen
hits are **judged, not auto-fatal**: seeded randomness, an injected/frozen
clock, a faked transport, `tmp_path` — a hit whose nondeterminism source is
demonstrably mitigated passes the screen with a note.

- 5/5 green + clean-or-mitigated screen → eligible for FIXED; `verified_by`
  records the path AND the rerun count:
  `tests/test_auth.py::test_rejects_unknown_key (5/5)`.
- Any red among the five, an unrunnable test, or an unmitigated screen hit →
  PARTIAL. Locked by a flaky test is not locked; a nondeterministic pass never
  rounds up to FIXED (loop-safety invariant 9).

## The ratchet

Counts are only comparable when they were computed over the same scope.
The ratchet therefore compares the fresh counts against **the most recent run
with the same `target`** (preferring the last `kind: "audit"` run as the
baseline, so repeated `/verify` runs don't creep the baseline forward and mask
drift since the last audit). No same-target prior run → say "no comparable
baseline" — never compare across targets.

Eight ratcheted counts, all from `audit/counts.env`:

| Count | Source artifact | Note |
|---|---|---|
| `marker_count` | `audit/markers.txt` | |
| `suppression_count` | `audit/suppressions.txt` | |
| `flaky_count` | `audit/test_flakiness.txt` | new in 1.4.0 |
| `test_vacuity_count` | `audit/test_vacuity.txt` | new in 1.4.0 |
| `test_skip_count` | `audit/test_skips.txt` | new in 1.4.0 |
| `stdout_logging_count` | `audit/stdout_logging.txt` | new in 1.4.0; **report-only on every surface** |
| `giant_file_count` | `audit/giant_files.txt` | new in 1.4.0 |
| `commented_code_count` | `audit/commented_code.txt` | new in 1.4.0 |

- Any count **increased** vs baseline → report as a regression with the
  newly-introduced lines (diff of the source artifact against the baseline's).
- A same-target baseline that predates a count (pre-1.4 runs lack the six new
  fields) → say "no comparable baseline for `<count>`" for that count alone —
  never read the absent field as 0, never report a fake regression.
- `stdout_logging_count` is report-only everywhere: it never flips a `/verify`
  verdict and never gates `check_new_debt.sh` even under `--strict`
  (legitimate-use-heavy; a gate that is often wrong gets disabled).
- Severity counts trending up across audits → surface the trend line.

The ratchet **reports**; it never blocks or mutates. Enforcement is the repo
owner's choice to wire on top: a CI step running `check_new_debt.sh` gates
strict by default since 1.4.0, with `--no-strict`/`WARN_ONLY=1` as the escape
hatches — the one strictness contract lives in that script's header.
(The prevention hook is a separate, diff-based early warning — it does not read
`state.json`.)

## The miss-to-fixture rule (how the loop converges)

When a real-world defect is discovered that an audit should have caught but
didn't (a missed stub, an unflagged fake implementation, a broken documented
journey):

1. **Plant it first**: add a minimal reproduction to `test-fixtures/planted/` and
   its expected entry to `EXPECTED_FINDINGS.yaml` — the self-test now goes red,
   **deterministically**: run `scripts/self_test.sh` twice and watch the new
   assertion fail both times. (An `expected_by: agent` entry has no automated
   red; it is scored by the manual blind-corpus eval under the recurrence rule
   — loop-safety invariant 9.)
2. **Then fix the detection gap** (taxonomy row, grep pattern, agent instruction)
   until the self-test is green.

Red before green, applied to the detector itself. A gap found once can never
silently recur; the corpus only grows. This is the plugin's own
`feedback-loop-diagnosis.md` discipline pointed at the plugin.
