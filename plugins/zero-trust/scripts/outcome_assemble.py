#!/usr/bin/env python3
"""Assemble an outcome snapshot from a DORA blob + an optional emission blob (ADR 0023).

Merges the Class-D DORA metrics (outcome_dora.py) with the optional Class-A
emission-share row (outcome_emission.py) and the run metadata into ONE snapshot
object the store writer appends verbatim. It performs no derivation of its own — it
is plumbing, so it can never introduce a number of a different honesty class than
its inputs already carry.

Output (stdout): {captured_at, git_sha, kind, window, window_short, metrics:[...]}.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


def _flag(argv, name, default=None):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default


def main(argv):
    dora_file = _flag(argv, "--dora-file")
    emission_file = _flag(argv, "--emission-file")
    metrics_file = _flag(argv, "--metrics-file")
    captured_at = _flag(argv, "--captured-at")
    git_sha = _flag(argv, "--git-sha", "")
    kind = _flag(argv, "--kind", "run")

    if not captured_at or (not dora_file and not emission_file and not metrics_file):
        sys.stderr.write("outcome_assemble: --captured-at and at least one of "
                         "--dora-file / --emission-file / --metrics-file required\n")
        return 64
    dora = {}
    if dora_file:
        try:
            dora = json.loads(Path(dora_file).read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            sys.stderr.write("outcome_assemble: bad dora blob: %s\n" % exc)
            return 64

    metrics = list(dora.get("metrics") or [])
    for extra in (emission_file, metrics_file):
        if not extra:
            continue
        try:
            blob = json.loads(Path(extra).read_text(encoding="utf-8"))
            # accept {ok, metrics:[...]} (producers) or a bare {metrics:[...]}.
            if blob.get("metrics") and (blob.get("ok", True)):
                metrics.extend(blob["metrics"])
        except (OSError, ValueError) as exc:
            sys.stderr.write("outcome_assemble: bad metrics blob (skipped): %s\n" % exc)

    snap = {
        "captured_at": captured_at,
        "git_sha": git_sha,
        "kind": kind,
        "metrics": metrics,
    }
    if "window" in dora:
        snap["window"] = dora["window"]
    if dora.get("window_short"):
        snap["window_short"] = True
    sys.stdout.write(json.dumps(snap, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
