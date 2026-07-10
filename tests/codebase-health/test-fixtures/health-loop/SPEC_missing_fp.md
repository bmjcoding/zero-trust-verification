# Implementation Spec — missing-fingerprint planted fixture

## Summary
- 1 finding.

## Wave 1 — SAFE & reversible (no behavior change)

### [DC-L1] delete dead helper
- **Status**: Todo
- **Severity / strength**: LOW
- **Location**: `src/util.py:10-20`
- **What's wrong**: helper has no callers; item forgot its Fingerprint field.
- **Fix**: delete it.
- **Regression-test seam**: grep gate.
- **Risk / reversibility**: none.
- **Depends on**: none
