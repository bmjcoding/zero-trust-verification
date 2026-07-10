# Implementation Spec — health-loop fixture

## Summary
- 4 findings: 0 CRITICAL, 2 HIGH, 2 MED/LOW.
- Highest-leverage first fix: delete the dead helper.
- Stack / constraints: python fixture; no CI seams.

## Wave 1 — SAFE & reversible (no behavior change)
Dead code removal, doc hygiene. Each is independently revertable.

### [DC-L1] delete dead helper
- **Status**: Todo
- **Fingerprint**: `aaaa11111111`
- **Severity / strength**: LOW
- **Location**: `src/util.py:10-20`
- **What's wrong**: helper has no callers.
- **Fix**: delete it.
- **Regression-test seam**: grep gate in CI; no runtime seam needed.
- **Risk / reversibility**: none; single revertable commit.
- **Depends on**: none

### [DC-L2] stale docstring
- **Status**: Todo
- **Fingerprint**: `bbbb22222222`
- **Severity / strength**: LOW
- **Location**: `src/util.py:1-8`
- **What's wrong**: docstring names a removed flag.
- **Fix**: rewrite docstring.
- **Regression-test seam**: doc lint.
- **Risk / reversibility**: none.
- **Depends on**: none

## Wave 2 — Confirmed correctness bugs (HIGH)
Lock each with a red test BEFORE fixing.

### [IL-H1] fake validator accepts anything
- **Status**: Todo
- **Fingerprint**: `cccc33333333`
- **Severity / strength**: HIGH
- **Location**: `src/auth.py:12-30`
- **What's wrong**: returns bool(key); no key-store check.
- **Fix**: check the key store.
- **Regression-test seam**: tests/test_auth.py::test_rejects_unknown_key.
- **Risk / reversibility**: auth path; revert restores old behavior.
- **Depends on**: DC-L1

## Wave 3 — Security
Sequence after correctness so tests are trustworthy.

### [SEC-H1] verify=False on outbound call
- **Status**: Todo
- **Fingerprint**: `dddd44444444`
- **Severity / strength**: HIGH
- **Location**: `src/client.py:44`
- **What's wrong**: TLS verification disabled.
- **Fix**: drop verify=False; pin CA bundle via config.
- **Regression-test seam**: tests/test_client.py::test_tls_verify_on (transport injection point).
- **Risk / reversibility**: config change; revertable.
- **Depends on**: IL-H1

## Wave 4 — Performance
No performance findings this audit.
