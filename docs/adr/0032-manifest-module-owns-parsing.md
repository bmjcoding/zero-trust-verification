# ADR 0032 — The manifest module owns parsing end-to-end: one public load API, zero duplicate loaders

- **Status:** Agent-decided (2026-07-17 architecture review #02, verified and found understated)
- **Date:** 2026-07-17
- **Supersedes/amends:** extends ADR 0014 (validator toolchain) with a public parse contract.

## Context

`validate_manifest.py` exposes validation (`validate_file` → `(code, lines)`)
but not the parsed data, so every consumer that needs the data reaches through
the interface or forks the loader. Verified inventory:

- **Private reach:** `correlate.py:105`, `emit_incident_spec.py:268`, and
  `owm.py:249,:337` call `V._load_yaml_12` directly; `owm.py:237+249` parses
  the same file twice (validate, then reload).
- **The module itself has the defect:** `validate_union` parses every file
  twice (`validate_file` then `_load_yaml_12`).
- **Duplicate loaders:** `profile_resolve.py:43-60` is a full reimplementation
  with a *divergent* error contract (raises `ValueError` vs returns a tuple);
  `manifest_join.py:111-117` and both `run_cases.py` test drivers re-declare
  the `YAML(typ="safe", pure=True); version=(1,2)` recipe. Seven ruamel
  loader constructions exist for one discipline.
- **Writer asymmetry:** `emit_incident_spec.py:_yaml_dump` writes with
  round-trip-default `YAML()` — no `typ="safe"`, no 1.2 pin — a latent
  Norway-guard asymmetry between what the suite writes and what it reads.
- Stale comments cite retired lints (V1/V3/V8) and a "byte-identical repo
  root copy" that no longer exists.

No lint or self-test pins the import structure (verified) — the real
constraints are the schema co-location (`SD-01`), file presence (L4), and the
0/3/4/5 CLI exit contract, all untouched by this change.

## Decision

1. `validate_manifest.py` gains a public `load_manifest(path) -> (data, err)`
   (the promoted loader; `_load_yaml_12` goes away, callers updated same-PR).
   `validate_union` parses each file once.
2. Consumers converge: `correlate.py`, `owm.py` (single parse), and
   `emit_incident_spec.py`'s *reader* use `load_manifest`;
   `profile_resolve.py` deletes its duplicate loader and imports the public
   API (preserving its ValueError boundary contract by wrapping — its
   malformed-YAML→clean-exit-3 CLI test stays green); both `run_cases.py`
   drivers use it (they already import the module). `emission_check.py`/
   `loop_guard.py` parse non-manifest YAML with the same recipe — they adopt
   the shared loader too (same directory, trivial import).
   **`manifest_join.py` is NOT co-located** (it lives in
   `skills/cleanup-audit/scripts/`): its wrapper already locates the
   validator dir via `chpr_find_validator` for the uv path, so the wrapper
   passes that dir to the py (env or argv) for a `sys.path` import — and the
   bare-`python3` fallback branch keeps a guarded local fallback loader for
   the standalone/target-repo case where the validator is unlocatable (the
   one deliberate exception to zero-duplicate, stated in a comment).
3. `emit_incident_spec.py`'s **subprocess round-trip stays**: validating the
   *written file* through the real `validate_manifest.sh` CLI is the
   incomplete-by-construction acceptance proof (exit-3 round-trip), a
   stronger property than in-memory validation — that reach-through is
   load-bearing, not sloppiness. Its *writer* is pinned to the same
   safe/YAML-1.2 discipline as the loader (the emitted byte shape changes —
   `%YAML 1.2` directive, safe-dumper formatting — which is acceptable: no
   test asserts emitted bytes, and the exit-3 round-trip is the designated
   acceptance proof).
4. Stale vendoring comments in these files are corrected as they are touched.

## Consequences

- One YAML-1.2/Norway-guard code path for every manifest read in the tree;
  a loader fix lands once.
- `owm.py`'s double parse and `validate_union`'s double parse disappear.
- CLI exit contract, schema co-location, and every lint stay byte-identical;
  self-tests must stay green with no assertion-count loss.
- Future consumers have a public door — the private-reach pattern has nothing
  left to imitate.
