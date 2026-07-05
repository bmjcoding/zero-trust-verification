#!/usr/bin/env python3
"""Deterministic ID allocator for the Spec Generation tier (SG-4).

Implements the Verification Manifest §6 ID grammar and stability rules as a
pure, table-testable function — the one seam of ID allocation that CAN be
self-tested (spec-gen §7.3). The LLM interrogation proposes journeys/behaviors;
this module hands it the next legal ID and refuses any that is already reserved.

§6 grammar (schema-enforced elsewhere; re-pinned here so allocation never emits
an ID the vendored schema would reject):

  - Journey:  ^J-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{3}$
  - Behavior: ^B-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{3}$
  - DL entry: ^DL-[0-9]{3}$            (no slug; per-manifest scope)

  The numeric suffix is the FINAL hyphen-delimited token, always exactly three
  digits (001-999). The slug is everything between the type prefix and suffix.
  **At 999, allocate a NEW slug** — suffixes never grow a fourth digit (§6).

Reservation scope (Hard Contract 7): IDs are never reused and never renumbered.
`existing` is the union read at S1 of (a) main's lineage and (b) the open
spec-session branches touching the same manifest path. Tombstoned (withdrawn)
IDs stay in `existing` forever, so a withdrawn J-pay-003 still pushes the next
allocation to J-pay-004. Allocation NEVER returns a member of `existing`.

CLI (JSON in, JSON out — the skill calls this via `uv run`):
  echo '{"prefix":"J","slug":"pay","existing":["J-pay-001"]}' | id_alloc.py alloc
    -> {"id": "J-pay-002"}
  echo '{"prefix":"J","slug":"pay","existing":[...999...],"overflow_slug":"pay-x"}' \
      | id_alloc.py alloc  ->  {"id":"J-pay-x-001","overflow":true}
  echo '{"id":"J-pay-001","existing":["J-pay-001"]}' | id_alloc.py claim
    -> {"error":"reserved: J-pay-001"}  (exit 3)
"""
from __future__ import annotations

import json
import re
import sys

# Full §6 grammars (kept in lockstep with schema/verification-manifest/v1.schema.json
# $defs.journeyId / behaviorId; the byte-identity lint guards the schema copy, and
# id_alloc self-tests assert every emitted ID matches these).
_GRAMMAR = {
    "J": re.compile(r"^J-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{3}$"),
    "B": re.compile(r"^B-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{3}$"),
    "DL": re.compile(r"^DL-[0-9]{3}$"),
}
_SLUG_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
_SUFFIX_RE = re.compile(r"^[0-9]{3}$")

MAX_SUFFIX = 999


class IdError(ValueError):
    """Malformed input (bad grammar, unknown prefix, bad slug)."""


class IdOverflow(Exception):
    """(prefix, slug) exhausted at suffix 999 (§6: allocate a new slug)."""


def valid(id_: str) -> bool:
    """True iff `id_` matches its type's §6 grammar."""
    if not isinstance(id_, str):
        return False
    prefix = id_.split("-", 1)[0]
    rx = _GRAMMAR.get(prefix)
    return bool(rx and rx.match(id_))


def parse_id(id_: str):
    """Return (prefix, slug, suffix:int) or None if `id_` is not a legal ID.

    slug is "" for DL (which has no slug). Rejects anything the §6 grammar
    would reject, so callers can trust the tuple.
    """
    if not isinstance(id_, str) or not valid(id_):
        return None
    parts = id_.split("-")
    prefix, suffix = parts[0], parts[-1]
    slug = "-".join(parts[1:-1])
    return (prefix, slug, int(suffix))


def _check_slug(slug: str) -> None:
    if not isinstance(slug, str) or not _SLUG_RE.match(slug):
        raise IdError(f"illegal slug {slug!r} (must match {_SLUG_RE.pattern})")


def next_id(prefix: str, slug: str, existing) -> str:
    """Next monotonic ID for (prefix, slug) not present in `existing`.

    Monotonic == max reserved suffix for this exact (prefix, slug) + 1, so a gap
    left by a withdrawn/tombstoned ID is NEVER refilled (§6 no-reuse). Raises
    IdOverflow when the next suffix would exceed 999 (caller supplies a new slug).
    """
    if prefix not in ("J", "B"):
        raise IdError(f"prefix must be J or B for slug allocation, got {prefix!r}")
    _check_slug(slug)
    reserved = set(existing or [])
    hi = 0
    for e in reserved:
        p = parse_id(e)
        if p and p[0] == prefix and p[1] == slug:
            hi = max(hi, p[2])
    nxt = hi + 1
    if nxt > MAX_SUFFIX:
        raise IdOverflow(f"{prefix}-{slug} exhausted at {MAX_SUFFIX}; allocate a new slug (§6)")
    cand = f"{prefix}-{slug}-{nxt:03d}"
    # Invariant: monotonic max+1 can never collide, but assert the no-reuse
    # contract explicitly — a bug here would silently double-allocate an ID.
    if cand in reserved:
        raise IdError(f"internal: candidate {cand} already reserved")
    return cand


def allocate(prefix: str, slug: str, existing, overflow_slug: str | None = None):
    """next_id with §6 overflow handling. Returns (id, overflowed:bool).

    On overflow, allocates under `overflow_slug` instead; re-raises IdOverflow
    if the caller supplied none (the skill must mint a fresh slug at S3).
    """
    try:
        return next_id(prefix, slug, existing), False
    except IdOverflow:
        if not overflow_slug:
            raise
        return next_id(prefix, overflow_slug, existing), True


def claim(id_: str, existing) -> str:
    """Validate an explicitly-proposed ID against grammar + reservation.

    Returns the ID if it is well-formed AND not already reserved; raises
    IdError otherwise. This is the reuse/refusal check for a human- or
    agent-proposed explicit ID (e.g. an amendment naming a specific behavior).
    """
    if not valid(id_):
        raise IdError(f"malformed id: {id_}")
    if id_ in set(existing or []):
        raise IdError(f"reserved: {id_}")
    return id_


def _main(argv) -> int:
    if len(argv) != 2 or argv[1] not in ("alloc", "claim", "parse"):
        print("usage: id_alloc.py {alloc|claim|parse}  (JSON on stdin)", file=sys.stderr)
        return 64
    mode = argv[1]
    try:
        req = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(json.dumps({"error": f"bad json: {exc}"}))
        return 64
    try:
        if mode == "alloc":
            id_, overflowed = allocate(
                req["prefix"], req["slug"], req.get("existing", []),
                overflow_slug=req.get("overflow_slug"),
            )
            print(json.dumps({"id": id_, "overflow": overflowed}))
            return 0
        if mode == "claim":
            id_ = claim(req["id"], req.get("existing", []))
            print(json.dumps({"id": id_}))
            return 0
        # parse
        p = parse_id(req["id"])
        if p is None:
            print(json.dumps({"error": f"malformed id: {req['id']}"}))
            return 3
        print(json.dumps({"prefix": p[0], "slug": p[1], "suffix": p[2]}))
        return 0
    except IdOverflow as exc:
        print(json.dumps({"error": str(exc), "overflow": True}))
        return 3
    except (IdError, KeyError) as exc:
        print(json.dumps({"error": str(exc)}))
        return 3


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
