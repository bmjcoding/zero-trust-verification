# ADR 0033 — Config Profiles removed: one vocabulary, no tailoring seam

- **Status:** Accepted (operator-decided, Bailey 2026-07-21)
- **Date:** 2026-07-21
- **Supersedes/amends:** narrows ADR 0006 (the config-profile clause is retired; the vendor-neutral OTEL core and the agent-first principle stand untouched). Amends ADR 0020's wording: telemetry *adapter* selection stays (env/config-selected per deployment, register TR-01); the profile indirection in front of it goes.

## Context

ADR 0006 introduced Config Profiles as the tailoring seam: a named preset
layered over the vendor-neutral defaults, encoding a line of business's vitals
taxonomy, event vocabulary, and alert seams as pure data, so an LOB could
tailor the suite without forking a tier.

Three years of design-weight later, the verified inventory of what that seam
actually is:

- **Two profile names exist and neither is real.** `default` (the do-nothing
  profile) and `payments` (a test-fixture example). No production profile ever
  shipped; the intended first target now lives outside this repo entirely.
- **The machinery is not thin.** A dedicated resolver module
  (`profile_resolve.py`) plus a resume script (`profile_resume.sh`); a
  three-way resolution precedence (flag > repo config > manifest) with its own
  escalation path and ~26 spec-gen test sites; `KNOWN_PROFILES` recognition in
  the audit comparator (`manifest_join.py`); the CH-08 severity-cap rule whose
  only job is to stop a profile from doing something no existing profile ever
  attempts; a **required** `observability.profile` schema field copied into
  every fixture manifest (~10 files); TR-04's vendored-resolver acceptance;
  and lint/self-test pins holding all of it in place.
- **The cap rule proves the point.** CH-08 exists so a profile "cannot push an
  untraced step above MED" — i.e., the suite already guarantees that profiles
  cannot change verification outcomes. A seam that is contractually forbidden
  from affecting verdicts, has no users, and costs a module, a script, a
  schema requirement, and dozens of test sites is speculative machinery.

Operator decision (2026-07-21): simplification of the plugin as a whole wins.
This follows the same doctrine as ADRs 0025/0030/0031 — keep the gates, gut
the machinery that no gate needs.

## Decision

**Config Profiles are removed from the suite entirely.** One vocabulary — the
vendor-neutral defaults — is THE vocabulary.

1. **Schema:** `observability.profile` becomes *optional and ignored*
   (`required` drops to `[]` for the observability block's profile key;
   the property is retained as a tolerated, documented no-op). This is a
   loosening — every previously-valid manifest stays valid — so
   `schema_version` stays 1. A future v2 may drop the key.
2. **Delete:** `profile_resolve.py`, `profile_resume.sh`, the spec-gen
   resolution precedence (S-flow asks nothing about profiles), the
   `KNOWN_PROFILES` set and profile read in `manifest_join.py`, the CH-08
   profile-cap branch (severity is purely evidence-derived — a behavioral
   no-op, since the cap already guaranteed profiles could not raise it), the
   TR-04 vendored-resolution path in triage, and every `profile:` line in
   fixtures.
3. **Docs:** the `Config Profile` term is retired from CONTEXT.md;
   `verification-manifest-v1.md` (MS, living contract — edited in place per
   its genre) documents the field as accepted-and-ignored; ADR 0006 carries an
   additive narrowing note; register corrections land as new dated notes
   citing this ADR (append-only discipline: TR-04 in the prod-triage register,
   plus any spec-gen register entries that name resolution precedence).
4. **Lint/tests:** every lint pin and self-test assertion that names a profile
   is updated in the same wave; `suite_self_test` must be green with zero
   skips before and after.

**Tailoring, if it ever returns,** re-enters by a new ADR carrying a concrete,
shipped profile — not by speculative machinery. Downstream deployments that
want LOB vocabulary do it downstream, in their own config, outside this
suite's contract.

## Alternatives rejected

- **Keep the seam as-is** — rejected: zero users, the first target moved to a
  private repo, and the seam's only guarantee is that it changes nothing.
- **schema_version 2 with the field dropped** — rejected: contract churn for
  consumers pinning v1, with no behavior change to justify it.
- **Partial removal (opaque passthrough field, no logic)** — rejected as the
  worst of both: the field survives with even less meaning, and every future
  reader asks what it does. The tolerated-no-op in this ADR differs only in
  being *documented* as dead and slated for v2 removal.

## Consequences

- One removal wave (estimated ~25–30 files), PR'd through the standard gate.
- Spec-gen's interview shortens (no profile question, no escalate-on-unknown
  path); the manifest is one required field lighter for authors.
- CH-08's grading loses a branch and gains nothing to explain: severity comes
  from evidence, full stop.
- The suite's public posture simplifies: there is no "your vocabulary here"
  door to document, test, or defend.
