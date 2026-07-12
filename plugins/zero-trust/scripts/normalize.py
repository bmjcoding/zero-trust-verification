#!/usr/bin/env python3
"""Normalize a backend-native telemetry response into TR-02 incident-window NDJSON.

Vendor-neutrality lives HERE (TR-01/TR-02, ADR 0006/0013): three backend formats
collapse to ONE normalized shape carrying the manifest §12 discovered-side field
names, so TR-03 joins a single schema regardless of source. The caller
(`telemetry.sh window`, already past the bounded-window guard) never sees the
format — it selects a backend; this module adapts the format.

Stdlib only (no jsonschema, no ruamel) so it runs on the bare `python3` substrate
(ADR 0015). The output's SCHEMA VALIDITY is asserted separately, by `uv run`
jsonschema in the self-test — that assertion is what makes "works on
CloudWatch/Dynatrace" real (canned fixtures in, schema-valid TR-02 out), not a mock.

  normalize.py --format otlp|cloudwatch|dynatrace --source <file>
               --since <epoch> --until <epoch> [--service S] [--event E]

Windowing (since<=ts<=until) and scoping (--service/--event) are applied here on
the parsed records; a record with no `event_name` is KEPT (DARK-in-prod is TR-03's
bucket, not a drop) unless an explicit `--event` filter excludes it by non-match.
"""
from __future__ import annotations

import argparse
import datetime
import json
import sys

_SEV = {
    "TRACE": "info", "DEBUG": "info", "INFO": "info", "INFORMATION": "info",
    "WARN": "warn", "WARNING": "warn",
    "ERROR": "error", "ERR": "error",
    "FATAL": "critical", "CRITICAL": "critical", "CRIT": "critical",
}


def _sev(raw):
    if raw is None:
        return None
    return _SEV.get(str(raw).strip().upper())


def _rfc3339(dt: datetime.datetime) -> str:
    return dt.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _epoch(dt: datetime.datetime) -> int:
    return int(dt.astimezone(datetime.timezone.utc).timestamp())


def _parse_ts(raw):
    """Return (rfc3339, epoch) or None. Accepts epoch(int/ns), RFC3339, CW format."""
    if raw is None:
        return None
    s = str(raw).strip()
    if not s:
        return None
    # OTLP timeUnixNano (19-digit) or plain epoch seconds.
    if s.isdigit():
        n = int(s)
        if n > 10_000_000_000_000:  # nanoseconds
            n //= 1_000_000_000
        dt = datetime.datetime.fromtimestamp(n, tz=datetime.timezone.utc)
        return _rfc3339(dt), _epoch(dt)
    for fmt in (
        "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S",
    ):
        try:
            dt = datetime.datetime.strptime(s, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=datetime.timezone.utc)
            return _rfc3339(dt), _epoch(dt)
        except ValueError:
            pass
    return None


def _clean_vital(v):
    """'', 'null', None -> explicit None; else the string class."""
    if v is None:
        return None
    s = str(v).strip()
    if s == "" or s.lower() == "null":
        return None
    return s


def _record(*, event_name, vital_class, service, env, ts_raw, emitter,
            severity=None, count=None, trace_id=None, span_id=None,
            attributes=None, vital_present=False):
    """Build a TR-02 dict from raw pieces (omitting absent optionals)."""
    parsed = _parse_ts(ts_raw)
    if parsed is None:
        return None  # unwindowable malformed source record
    rfc, epoch = parsed
    rec = {
        "service": service,
        "env": env,
        "timestamp": rfc,
        "emitter": emitter or service,
    }
    rec["_epoch"] = epoch  # internal; stripped before emit
    if event_name:
        rec["event_name"] = event_name
    vc = _clean_vital(vital_class)
    if vc is not None:
        rec["vital_class"] = vc
    elif vital_present:
        rec["vital_class"] = None
    sev = _sev(severity)
    if sev is not None:
        rec["severity"] = sev
    if count is not None:
        try:
            rec["count"] = int(count)
        except (TypeError, ValueError):
            pass
    if trace_id:
        rec["trace_id"] = str(trace_id)
    if span_id:
        rec["span_id"] = str(span_id)
    if attributes:
        rec["attributes"] = attributes
    return rec


# ── OTLP/OTEL-JSON logs (the default, hermetic, community format) ──────────────

def _attr_value(v):
    if not isinstance(v, dict):
        return v
    for k in ("stringValue", "boolValue", "doubleValue"):
        if k in v:
            return v[k]
    if "intValue" in v:
        return v["intValue"]
    return None


def _attrs(lst):
    out = {}
    for a in lst or []:
        if isinstance(a, dict) and "key" in a:
            out[a["key"]] = _attr_value(a.get("value"))
    return out


def _iter_otlp(doc):
    for rl in doc.get("resourceLogs", []) or []:
        rattrs = _attrs((rl.get("resource") or {}).get("attributes"))
        for sl in rl.get("scopeLogs", []) or []:
            for lr in sl.get("logRecords", []) or []:
                a = dict(rattrs)
                a.update(_attrs(lr.get("attributes")))
                yield _record(
                    event_name=a.get("event.name") or a.get("event_name"),
                    vital_class=a.get("vital.class", a.get("vital_class")),
                    vital_present=("vital.class" in a or "vital_class" in a),
                    service=a.get("service.name") or a.get("service"),
                    env=a.get("deployment.environment") or a.get("env"),
                    ts_raw=lr.get("timeUnixNano") or lr.get("observedTimeUnixNano"),
                    emitter=a.get("emitter"),
                    severity=lr.get("severityText"),
                    count=a.get("count"),
                    trace_id=lr.get("traceId"),
                    span_id=lr.get("spanId"),
                )


# ── CloudWatch Logs Insights (results = list of [{field,value}, ...]) ──────────

def _iter_cloudwatch(doc):
    for row in doc.get("results", []) or []:
        f = {c.get("field"): c.get("value") for c in row if isinstance(c, dict)}
        yield _record(
            event_name=f.get("event_name"),
            vital_class=f.get("vital_class"),
            vital_present=("vital_class" in f),
            service=f.get("service"),
            env=f.get("env"),
            ts_raw=f.get("@timestamp") or f.get("timestamp"),
            emitter=f.get("emitter"),
            severity=f.get("severity"),
            count=f.get("count"),
            trace_id=f.get("trace_id"),
            span_id=f.get("span_id"),
        )


# ── Dynatrace Grail/DQL (records = list of objects) ────────────────────────────

def _iter_dynatrace(doc):
    for r in doc.get("records", []) or []:
        if not isinstance(r, dict):
            continue
        yield _record(
            event_name=r.get("event_name") or r.get("event.name"),
            vital_class=r.get("vital_class", r.get("vital.class")),
            vital_present=("vital_class" in r or "vital.class" in r),
            service=r.get("service") or r.get("dt.entity.service.name"),
            env=r.get("env") or r.get("environment"),
            ts_raw=r.get("timestamp"),
            emitter=r.get("emitter"),
            severity=r.get("severity") or r.get("loglevel"),
            count=r.get("count"),
            trace_id=r.get("trace_id"),
            span_id=r.get("span_id"),
        )


_READERS = {"otlp": _iter_otlp, "cloudwatch": _iter_cloudwatch, "dynatrace": _iter_dynatrace}


def main(argv) -> int:
    ap = argparse.ArgumentParser(prog="normalize.py")
    ap.add_argument("--format", required=True, choices=sorted(_READERS))
    ap.add_argument("--source", required=True)
    ap.add_argument("--since", type=int, required=True)
    ap.add_argument("--until", type=int, required=True)
    ap.add_argument("--service", default=None)
    ap.add_argument("--event", default=None)
    args = ap.parse_args(argv[1:])

    try:
        with open(args.source, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        print(f"normalize.py: cannot read {args.format} source {args.source}: {exc}", file=sys.stderr)
        return 1

    for rec in _READERS[args.format](doc):
        if rec is None:
            continue
        ep = rec.pop("_epoch")
        if ep < args.since or ep > args.until:
            continue
        if args.service is not None and rec.get("service") != args.service:
            continue
        if args.event is not None and rec.get("event_name") != args.event:
            continue
        sys.stdout.write(json.dumps(rec, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
