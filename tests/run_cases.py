#!/usr/bin/env python3
"""Hermetic test driver for the Verification Manifest validator.

Three case groups:
  A. file fixtures      — canonical valid + distinct structural fixtures on disk
  B. mutation cases     — one targeted mutation of the valid manifest per §10 rule
  C. §12 join proof     — the intended↔discovered comparator over the join fixture pair

No network, no external state. Exits non-zero on any failure.
"""
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
# the canonical validator lives inside the single plugin (ADR 0025)
sys.path.insert(0, str(ROOT / "plugins" / "zero-trust" / "scripts"))

import validate_manifest as V  # noqa: E402
from ruamel.yaml import YAML  # noqa: E402  (dump-side only; loads go through V.load_manifest)

FIX = HERE / "fixtures" / "manifest"
passed = 0
failed = 0


def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  ok   - {name}")
    else:
        failed += 1
        print(f"  FAIL - {name} {detail}")


def load(path):
    data, err = V.load_manifest(Path(path))  # the public load API (ADR 0032)
    assert err is None, err
    return data


def code_of(data):
    return V.validate_mapping(data)[0]


def has_token(data, token):
    _, lines = V.validate_mapping(data)
    return any(token in ln for ln in lines)


# ---- A. file fixtures ------------------------------------------------------------
print("== A. file fixtures ==")
check("valid-complete -> exit 0", V.validate_file(FIX / "valid-complete.yaml")[0] == 0)
check("unsupported-version -> exit 5", V.validate_file(FIX / "unsupported-version.yaml")[0] == 5)
check("norway-enum (vital_class: no) -> exit 4", V.validate_file(FIX / "norway-enum.yaml")[0] == 4)

base = load(FIX / "valid-complete.yaml")
check("base fixture is genuinely complete", code_of(base) == 0)


# ---- B. mutation cases (one per rule) --------------------------------------------
print("== B. completeness-rule mutations ==")

def mutate(fn):
    d = copy.deepcopy(base)
    fn(d)
    return d

def m_rule0(d): d["behaviors"] = []
def m_rule1(d): d["journeys"][0]["steps"][0].pop("alert_seam")
def m_rule2(d): d["journeys"][0]["steps"][0].pop("idempotency")
def m_rule3(d): d["behaviors"][0]["then"] = ""
def m_rule4(d): d["journeys"][0]["confirmation"] = "proposed"
def m_rule5_dangling(d): d["behaviors"][0]["journey"] = "J-nope-001"
def m_rule5_dupid(d): d["behaviors"].append(copy.deepcopy(d["behaviors"][0]))
def m_rule6(d): d.setdefault("interrogation", {}).setdefault("log", []).append(
    {"id": "DL-002", "summary": "x", "resolved_by": "agent", "dissent": ""})
def m_rule7(d): d["journeys"][1]["lifecycle"] = "withdrawn"
def m_rule8(d): d["journeys"][0].pop("confirmed_by")
def m_badid(d): d["journeys"][0]["id"] = "J-BadID-1"
def m_declared_incomplete(d):
    d["completeness"] = "incomplete"
    d["incomplete_fields"] = ["rule-1: journeys[J-pricing-001].steps[0].alert_seam.default"]
    d["journeys"][0]["steps"][0].pop("alert_seam")

cases = [
    ("rule 0 empty-behaviors -> 3", m_rule0, 3, "rule-0"),
    ("rule 1 missing alert_seam.default -> 3", m_rule1, 3, "rule-1"),
    ("rule 2 missing idempotency -> 3", m_rule2, 3, "rule-2"),
    ("rule 3 empty then -> 3", m_rule3, 3, "rule-3"),
    ("rule 4 CORE proposed -> 3", m_rule4, 3, "rule-4"),
    ("rule 5 dangling journey ref -> 3", m_rule5_dangling, 3, "rule-5"),
    ("rule 5 duplicate id -> 3", m_rule5_dupid, 3, "duplicate id"),
    ("rule 6 agent resolution no dissent -> 3", m_rule6, 3, "rule-6"),
    ("rule 7 withdrawn no reason -> 3", m_rule7, 3, "rule-7"),
    ("rule 8 CORE confirmed no confirmed_by -> 3", m_rule8, 3, "rule-8"),
    ("schema: bad journey id -> 4", m_badid, 4, "schema-invalid"),
    ("declared incomplete -> 3", m_declared_incomplete, 3, "SPEC-INCOMPLETE"),
]
for name, fn, want_code, token in cases:
    d = mutate(fn)
    check(name, code_of(d) == want_code and has_token(d, token),
          f"(got exit {code_of(d)})")


# ---- C. §12 intended <-> discovered join proof -----------------------------------
print("== C. §12 join comparability ==")

def compare_step(intent, found):
    """Implement the manifest spec §12 rows. Returns list of (row, satisfied)."""
    rows = []
    # required_emission vs emission_grade
    re_, eg = intent.get("required_emission"), found.get("emission_grade")
    ok = (re_ == "OBSERVED" and eg == "OBSERVED") or \
         (re_ == "LOG-ONLY" and eg in ("OBSERVED", "LOG-ONLY"))
    rows.append(("emission", ok))
    # alert_seam intent vs discovered
    ai = (intent.get("alert_seam") or {}).get("default")
    ad = found.get("alert_seam")
    ok = (ai == "paged" and ad == "paged") or \
         (ai == "dashboard-only" and ad in ("paged", "dashboard-only")) or \
         (ai == "none")
    rows.append(("alert_seam", ok))
    # idempotency.required vs duplicate_guard
    if (intent.get("idempotency") or {}).get("required") is True:
        rows.append(("idempotency", found.get("duplicate_guard") == "present"))
    # criticality declared vs derived
    return rows

man = load(HERE / "fixtures" / "join" / "manifest.yaml")
disc = json.loads((HERE / "fixtures" / "join" / "journeys.json").read_text())

# join journeys by manifest_journey_id, steps by event_name
mj = {j["id"]: j for j in man["journeys"]}
joined = 0
for dj in disc["journeys"]:
    mid = dj.get("manifest_journey_id")
    ij = mj.get(mid)
    check(f"journey join key resolves ({mid})", ij is not None)
    if not ij:
        continue
    check(f"criticality matches ({mid})", ij["criticality"] == dj["criticality"])
    di = {s["event_name"]: s for s in dj["steps"] if "event_name" in s}
    for istep in ij["steps"]:
        fstep = di.get(istep.get("event_name"))
        check(f"step join key resolves ({istep.get('event_name')})", fstep is not None)
        if fstep:
            joined += 1
            for row, ok in compare_step(istep, fstep):
                check(f"§12 {row} satisfied on clean pair", ok)

check("join actually exercised a step", joined >= 1)

# negative: DARK discovered emission must FAIL an OBSERVED intent
dj0 = copy.deepcopy(disc["journeys"][0])
dj0["steps"][0]["emission_grade"] = "DARK"
istep = mj["J-pay-001"]["steps"][0]
rows = dict(compare_step(istep, dj0["steps"][0]))
check("§12 DARK discovered fails OBSERVED intent", rows["emission"] is False)


# ---- D. union validation (AV3-03) ------------------------------------------------
print("== D. union validation ==")
import tempfile  # noqa: E402

def write_tmp(data, name):
    p = Path(tempfile.gettempdir()) / name
    with open(p, "w") as fh:
        YAML().dump(data, fh)
    return p

a = copy.deepcopy(base)
b = copy.deepcopy(base)  # same IDs as a -> collision
pa, pb = write_tmp(a, "union_a.yaml"), write_tmp(b, "union_b.yaml")
code, lines = V.validate_union([pa, pb])
check("union with colliding ids -> non-zero", code != 0)
check("union reports id collision", any("ID-COLLISION" in ln for ln in lines))

b2 = copy.deepcopy(base)
for j in b2["journeys"]:
    j["id"] = j["id"].replace("J-pricing", "J-billing")
for x in b2["behaviors"]:
    x["id"] = x["id"].replace("B-pricing", "B-billing")
    if x.get("journey"):
        x["journey"] = x["journey"].replace("J-pricing", "J-billing")
for j in b2["journeys"]:
    for s in j.get("steps", []):
        if (s.get("compensation") or {}).get("ref"):
            s["compensation"]["ref"] = s["compensation"]["ref"].replace("J-pricing", "J-billing")
pb2 = write_tmp(b2, "union_b2.yaml")
code2, _ = V.validate_union([pa, pb2])
check("union with disjoint ids -> 0", code2 == 0)

b3 = copy.deepcopy(b2)
b3["observability"]["profile"] = "trading"
pb3 = write_tmp(b3, "union_b3.yaml")
code3, lines3 = V.validate_union([pa, pb3])
check("union with profile mismatch -> non-zero", code3 != 0 and any("UNION-MISMATCH" in ln for ln in lines3))


print(f"\n== run_cases: {passed} passed, {failed} failed ==")
sys.exit(1 if failed else 0)
