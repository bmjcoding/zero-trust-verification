#!/usr/bin/env python3
"""TR-loop-guard — no self-ingestion + open-incident dedupe (ADR 0002 refuse-by-default).

Two independent guarantees keep the tier from triaging its own tail:

  (a) SELF-EMITTER EXCLUSION (pre-correlation): drop window records whose `emitter`
      matches any identity in triage.config.yaml loop_guard.self_emitters, so the
      correlation can never see an event the tier (or its incident-Spec tooling)
      produced.

  (b) OPEN-INCIDENT DEDUPE (pre-emission): suppress a second incident-Spec for an
      incident whose prior incident-Spec PR is still open. The dedupe key is
      (event_name, derived journey, drift-class) — it DELIBERATELY excludes any
      timestamp so retries of the same incident collapse to one Spec. Openness is
      confirmed against the host adapter (`host.sh pr-state` on the triage-owned
      ledger — this is what catches a still-DRAFT incident-Spec that `pr-list-ready`
      omits by contract — plus `pr-list-ready` for ready ones).

Subcommands:
  exclude-self --window <ndjson|-> [--config <cfg>]
                 -> filtered NDJSON on stdout (self-emitter records dropped)
  incident-key --event <e> --journey <j> --drift-class <d>
                 -> the timestamp-free dedupe key on stdout
  is-open --key <k> [--config <cfg>] [--host <host.sh>] [--ledger <f>]
                 -> exit 0 + "open" if a prior incident-Spec PR is still open;
                    exit 1 + "clear" otherwise (host failures fail-safe to clear
                    ONLY for enumeration; a ledgered PR that cannot be queried is
                    reported open, never silently cleared).

Runs via `uv run` (ruamel to read the committed config); the host calls shell out
through $TRIAGE_HOST (default: sibling autopilot host.sh), overridable to a mock.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))
import validate_manifest as _VM  # noqa: E402  the public load API (ADR 0032)
_DEFAULT_CONFIG = _HERE.parent / "triage.config.yaml"
_DEFAULT_HOST = _HERE.parent / "skills" / "autopilot" / "scripts" / "host.sh"
# States that mean the incident-Spec PR is NO LONGER an open proposal.
_TERMINAL = {"MERGED", "DECLINED", "NONE", "CLOSED"}


def _load_config(path: Path) -> dict:
    """Config YAML through the canonical loader (ADR 0032); any failure degrades
    to {} — the config is hand-editable and this guard must never crash."""
    try:
        data, err = _VM.load_manifest(path)
    except Exception:  # noqa: BLE001 - config is hand-editable; degrade to defaults
        return {}
    if err is not None:
        return {}
    return data if isinstance(data, dict) else {}


def _self_emitters(cfg: dict) -> set[str]:
    lg = (cfg.get("loop_guard") or {}) if isinstance(cfg, dict) else {}
    return {str(x) for x in (lg.get("self_emitters") or [])}


def _slug(s) -> str:
    out = re.sub(r"[^A-Za-z0-9]+", "-", str(s)).strip("-").lower()
    return out or "x"


def incident_key(event_name, journey, drift_class) -> str:
    """The dedupe key over (event, journey, drift-class) ONLY. It takes no clock
    input and references no ordering field, so retries of one incident collapse to a
    single key (grep-provable: this whole region names no such field)."""
    return "__".join((
        _slug(event_name or "dark"),
        _slug(journey or "no-journey"),
        _slug(drift_class or "vital-incident"),
    ))


def _read_lines(src: str):
    fh = sys.stdin if src == "-" else open(src, encoding="utf-8")
    with fh:
        return [ln for ln in fh]


def cmd_exclude_self(args) -> int:
    cfg = _load_config(Path(args.config))
    selfset = _self_emitters(cfg)
    dropped = 0
    for ln in _read_lines(args.window):
        s = ln.strip()
        if not s:
            continue
        try:
            rec = json.loads(s)
        except ValueError:
            continue  # malformed source line; never fabricate
        if str(rec.get("emitter", "")) in selfset:
            dropped += 1
            continue
        sys.stdout.write(json.dumps(rec, sort_keys=True) + "\n")
    sys.stderr.write(f"[loop-guard] excluded {dropped} self-emitter record(s)\n")
    return 0


def cmd_incident_key(args) -> int:
    print(incident_key(args.event, args.journey, args.drift_class))
    return 0


def _host(args):
    return args.host or os.environ.get("TRIAGE_HOST") or str(_DEFAULT_HOST)


def _ledger_path(args, cfg) -> Path:
    if args.ledger:
        return Path(args.ledger)
    lg = (cfg.get("loop_guard") or {}) if isinstance(cfg, dict) else {}
    return Path(lg.get("ledger") or "triage/open-incidents.tsv")


def _pr_state(host: str, num: str):
    try:
        out = subprocess.run(["bash", host, "pr-state", "--num", str(num)],
                             capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip().upper()


def cmd_is_open(args) -> int:
    cfg = _load_config(Path(args.config))
    host = _host(args)
    ledger = _ledger_path(args, cfg)
    key = args.key

    # (1) the triage-owned ledger: prior incident-Spec PRs keyed by incident-key.
    if ledger.exists():
        for ln in ledger.read_text(encoding="utf-8").splitlines():
            parts = ln.split("\t")
            if len(parts) >= 2 and parts[0] == key:
                num = parts[1].strip()
                state = _pr_state(host, num)
                if state is None:
                    # a ledgered PR we cannot query is reported OPEN (never silently
                    # cleared — that would let a duplicate through on a host blip).
                    print("open")
                    print(f"[note] already-open-incident-spec (key={key} pr={num} state=unqueryable)", file=sys.stderr)
                    return 0
                if state not in _TERMINAL:
                    print("open")
                    print(f"[note] already-open-incident-spec (key={key} pr={num} state={state})", file=sys.stderr)
                    return 0

    # (2) belt: a ready (non-draft) incident-Spec PR whose src-branch encodes the key.
    try:
        out = subprocess.run(["bash", host, "pr-list-ready"],
                             capture_output=True, text=True, timeout=30)
        if out.returncode == 0:
            for row in out.stdout.splitlines():
                cols = row.split("\t")
                if len(cols) >= 3 and key in cols[2]:  # src_branch column
                    print("open")
                    print(f"[note] already-open-incident-spec (key={key} branch={cols[2]})", file=sys.stderr)
                    return 0
    except (OSError, subprocess.SubprocessError):
        pass  # enumeration is best-effort; the ledger is the authoritative check

    print("clear")
    return 1


def main(argv) -> int:
    ap = argparse.ArgumentParser(prog="loop_guard.py")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("exclude-self")
    p.add_argument("--window", required=True)
    p.add_argument("--config", default=str(_DEFAULT_CONFIG))
    p.set_defaults(fn=cmd_exclude_self)

    p = sub.add_parser("incident-key")
    p.add_argument("--event", default=None)
    p.add_argument("--journey", default=None)
    p.add_argument("--drift-class", dest="drift_class", default=None)
    p.set_defaults(fn=cmd_incident_key)

    p = sub.add_parser("is-open")
    p.add_argument("--key", required=True)
    p.add_argument("--config", default=str(_DEFAULT_CONFIG))
    p.add_argument("--host", default=None)
    p.add_argument("--ledger", default=None)
    p.set_defaults(fn=cmd_is_open)

    args = ap.parse_args(argv[1:])
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
