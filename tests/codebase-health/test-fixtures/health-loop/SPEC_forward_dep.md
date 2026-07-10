# Implementation Spec — forward-dep planted fixture

## Summary
- 3 findings. Wave 1 plants all three refusal classes: a forward dep on a
  letter-leading tag, a forward dep on a DIGIT-leading tag, and a dep that
  resolves to no item at all.

## Wave 1 — SAFE & reversible (no behavior change)

### [DC-L1] delete dead helper
- **Status**: Todo
- **Fingerprint**: `aaaa11111111`
- **Severity / strength**: LOW
- **Location**: `src/util.py:10-20`
- **What's wrong**: helper has no callers.
- **Fix**: delete it.
- **Regression-test seam**: grep gate.
- **Risk / reversibility**: none.
- **Depends on**: IL-H1, 2FA-H2

### [DC-L3] stale reference in comment
- **Status**: Todo
- **Fingerprint**: `ffff66666666`
- **Severity / strength**: LOW
- **Location**: `src/util.py:30`
- **What's wrong**: comment names a removed module.
- **Fix**: drop the comment.
- **Regression-test seam**: doc lint.
- **Risk / reversibility**: none.
- **Depends on**: NOPE-X9

## Wave 2 — Confirmed correctness bugs (HIGH)

### [IL-H1] fake validator accepts anything
- **Status**: Todo
- **Fingerprint**: `cccc33333333`
- **Severity / strength**: HIGH
- **Location**: `src/auth.py:12-30`
- **What's wrong**: returns bool(key).
- **Fix**: check the key store.
- **Regression-test seam**: tests/test_auth.py::test_rejects_unknown_key.
- **Risk / reversibility**: auth path.
- **Depends on**: none

### [2FA-H2] digit-leading tag, second factor skipped
- **Status**: Todo
- **Fingerprint**: `1111aaaa2222`
- **Severity / strength**: HIGH
- **Location**: `src/auth.py:40-55`
- **What's wrong**: TOTP check commented out.
- **Fix**: restore the check.
- **Regression-test seam**: tests/test_auth.py::test_totp_required.
- **Risk / reversibility**: auth path.
- **Depends on**: none
