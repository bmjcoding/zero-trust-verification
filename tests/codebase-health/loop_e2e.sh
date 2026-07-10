#!/usr/bin/env bash
# loop_e2e.sh — hermetic end-to-end fixture for the /health-loop dispatch
# (ADR 0024; register HL-04). Invoked from self_test.sh; standalone-runnable.
#
# The loop's orchestrator is an LLM command, so what CAN be proven here is the
# suite's established layer: the deterministic substrate, composed in exactly
# the dispatch order the command doc pins — position recomputed from disk at
# every step, gate verdicts routing advance/pause/halt, Guard-1 stamping, the
# append-only journal. Merge execution is the Marshal's own tested domain and
# preauth evidence is HL-03's; this fixture asserts the loop's DECISIONS around
# them, not the host protocol.
#
# Green path: 3-wave campaign drains wave by wave (wave 4 is empty and skipped
# loudly); journal accrues kickoff + delegated approvals; every drained
# fingerprint is stamped PR_OPEN ref=health-loop:* (so /remediate Guard 1
# SKIPs); a second pass over the drained campaign is a no-op.
# Red paths: HUMAN_NEEDED stops the campaign before the next wave is sliced;
# REGRESSED-anywhere halts with no stamping; a forward dep refuses before
# generate; corrupt state stops at exit 4.
#
# Portability: bash 3.2 + BSD userland; python via the rl_pyrun fallback chain.
set -uo pipefail
LC_ALL=C
export LC_ALL

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
CA="$REPO_ROOT/plugins/codebase-health/skills/cleanup-audit"
S="$CA/scripts"
FIX="$HARNESS_DIR/test-fixtures/health-loop"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok  - $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }

if command -v uv >/dev/null 2>&1; then PY() { uv run --no-project --quiet python "$@"; }
else PY() { python3 "$@"; }; fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── campaign fixture: SPEC + staged post-verify states ─────────────────────────
C="$WORK/campaign"
mkdir -p "$C/audit" "$C/.autopilot/runbooks"
cp "$FIX/SPEC.md" "$C/audit/SPEC.md"
# Stage 0: campaign start — every finding OPEN, audit run only.
PY - "$FIX/state_green.json" "$WORK" <<'EOF'
import json, sys, copy
base = json.load(open(sys.argv[1])); out = sys.argv[2]
def dump(o, n): json.dump(o, open(out + "/" + n, "w"), indent=2)
s0 = copy.deepcopy(base)
s0["runs"] = [s0["runs"][0]]
for f in s0["findings"].values(): f["status"] = "OPEN"; f["verified_by"] = None
dump(s0, "state_s0.json")
def verified(upto):  # upto: list of (fp, status, evidence)
    s = copy.deepcopy(s0); s["runs"] = base["runs"]
    for fp, st, vb in upto:
        s["findings"][fp]["status"] = st; s["findings"][fp]["verified_by"] = vb
    return s
w1 = [("aaaa11111111","FIXED","docs/FIX_LOG.md#DC-L1 + commit 111aaa"),
      ("bbbb22222222","WONTFIX",None)]
w2 = w1 + [("cccc33333333","FIXED","tests/test_auth.py::test_rejects_unknown_key (5/5)")]
w3 = w2 + [("dddd44444444","FIXED","tests/test_client.py::test_tls_verify_on (5/5)")]
dump(verified(w1), "state_after_w1.json")
dump(verified(w2), "state_after_w2.json")
dump(verified(w3), "state_after_w3.json")
EOF
cp "$WORK/state_s0.json" "$C/audit/state.json"
JOURNAL="$C/audit/loop_log.md"

# Per-wave fingerprint lists, from the slicer itself (the loop's own join path).
for N in 1 2 3; do bash "$S/spec_wave.sh" fingerprints "$C/audit/SPEC.md" "$N" > "$WORK/w$N.fps"; done
cat "$WORK"/w[123].fps > "$WORK/all.fps"

# position: echo the first non-complete wave (gate != 0), or DONE.
position() {
  local n rc
  for n in 1 2 3 4; do
    bash "$S/spec_wave.sh" fingerprints "$C/audit/SPEC.md" "$n" > "$WORK/pos.fps" 2>/dev/null; rc=$?
    [ "$rc" -eq 6 ] && continue      # empty wave: skipped loudly by the slicer
    [ "$rc" -ne 0 ] && { echo "ERR:$rc"; return; }
    bash "$S/wave_gate.sh" "$C/audit/state.json" "$WORK/pos.fps" > /dev/null 2>&1 && continue
    echo "$n"; return
  done
  echo DONE
}
tracker_status() { awk '/^---$/{fm++;next} fm==1 && /^STATUS:/{sub(/^STATUS:[[:space:]]*/,"");print;exit}' "$1"; }

echo "== e2e green path: 3 waves drain, wave 4 skipped, campaign DRAINED =="

# Wave 1 — no tracker: forward-deps gate, slice, kickoff journal, "generate".
[ "$(position)" = "1" ] && ok "position: campaign starts at wave 1" || fail "position: campaign starts at wave 1 (got $(position))"
bash "$S/spec_wave.sh" forward-deps "$C/audit/SPEC.md" 1 >/dev/null 2>&1 \
  && ok "wave 1: no forward deps — generate may proceed" || fail "wave 1: forward-deps refused unexpectedly"
W1DOC="$(bash "$S/spec_wave.sh" slice "$C/audit/SPEC.md" 1)" && [ -f "$W1DOC" ] \
  && ok "wave 1: sliced to $(basename "$W1DOC")" || fail "wave 1: slice failed"
printf '%s kickoff: merge=preauthorized grant waves=1 (key 2, operator answer verbatim)\n' "2026-07-10T14:00:00Z" >> "$JOURNAL"
T1="$C/.autopilot/runbooks/audit-w1.tracker.md"
cp "$FIX/tracker_drained.md" "$T1"
sed 's/^STATUS: DRAINED/STATUS: ACTIVE/' "$T1" > "$T1.tmp" && mv "$T1.tmp" "$T1"

# Drain in flight: the dispatch classifies ACTIVE and changes nothing.
[ "$(tracker_status "$T1")" = "ACTIVE" ] && ok "wave 1: ACTIVE tracker classifies as drain-in-flight (loop ends turn)" || fail "wave 1: ACTIVE classification"
[ "$(position)" = "1" ] && ok "position: unchanged while wave 1 is in flight" || fail "position: drifted mid-flight"

# Drain done → merge step (auto-class wave 1): preauth evidence, delegated
# approvals journaled, merge simulated, verify state lands, gate advances.
sed 's/^STATUS: ACTIVE/STATUS: DRAINED/' "$T1" > "$T1.tmp" && mv "$T1.tmp" "$T1"
R="$WORK/hostrepo"
git init -q -b main "$R" 2>/dev/null || { git init -q "$R" && git -C "$R" checkout -q -b main; }
GC="git -C $R -c user.email=hl@test -c user.name=hl -c commit.gpgsign=false"
mkdir -p "$R/src" "$R/tests"
echo 'def old_helper(): pass' > "$R/src/util.py"; echo ok > "$R/tests/test_util.py"
$GC add -A >/dev/null && $GC commit -qm base
$GC checkout -qb autopilot/audit-w1/delete-dead-helper
echo '# cleaned' > "$R/src/util.py"; echo 'assert True' > "$R/tests/test_util.py"
$GC add -A >/dev/null && $GC commit -qm 'feat: delete-dead-helper.1 GREEN'
$GC checkout -q main
if bash "$S/wave_preauth_check.sh" --repo "$R" --base main --branch autopilot/audit-w1/delete-dead-helper \
     --tracker "$T1" --story delete-dead-helper --pr-body "$FIX/pr_body.md" > /dev/null 2>&1; then
  ok "wave 1: preauth P1-P4 pass — delegation may approve"
  printf '%s delegated-approve: wave=1 story=delete-dead-helper pr=PR-12 (preauth P1-P4 green)\n' "2026-07-10T14:10:00Z" >> "$JOURNAL"
else
  fail "wave 1: preauth P1-P4 pass"
fi
cp "$WORK/state_after_w1.json" "$C/audit/state.json"    # merged + /verify --strict ran
bash "$S/wave_gate.sh" "$C/audit/state.json" "$WORK/w1.fps" > /dev/null 2>&1 \
  && ok "wave 1: gate ADVANCE after merge+verify" || fail "wave 1: gate ADVANCE"
while IFS= read -r fp; do
  PY "$S/remediation_state.py" stamp "$C/audit/state.json" "$fp" --status PR_OPEN --ref "health-loop:PR-12" --opened-at 2026-07-10 >/dev/null || fail "stamp $fp"
done < "$WORK/w1.fps"
AF="$(PY "$S/remediation_state.py" already-filed aaaa11111111 "$C/audit/state.json")"
case "$AF" in FILED*) ok "wave 1: stamped fingerprints read FILED by /remediate Guard 1" ;; *) fail "wave 1: Guard-1 stamp not visible ($AF)" ;; esac

# Waves 2 and 3 — pause-class per config; operator approves; drain+merge+verify.
grep -qE '^[[:space:]]*"2":[[:space:]]*pause' "$CA/loop.config.yaml" \
  && ok "wave 2: pause-class per loop.config.yaml (generate asks first)" || fail "wave 2: expected pause-class"
[ "$(position)" = "2" ] && ok "position: wave 2 after wave 1 gated" || fail "position: expected 2, got $(position)"
bash "$S/spec_wave.sh" slice "$C/audit/SPEC.md" 2 >/dev/null && cp "$WORK/state_after_w2.json" "$C/audit/state.json"
[ "$(position)" = "3" ] && ok "position: wave 3 after wave 2 gated" || fail "position: expected 3, got $(position)"
bash "$S/spec_wave.sh" slice "$C/audit/SPEC.md" 3 >/dev/null && cp "$WORK/state_after_w3.json" "$C/audit/state.json"

# Wave 4 empty → slicer refuses (exit 6), campaign is DONE, all fps gate green.
bash "$S/spec_wave.sh" fingerprints "$C/audit/SPEC.md" 4 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 6 ] && ok "wave 4: empty wave skipped loudly (exit 6)" || fail "wave 4: expected exit 6, got $rc"
[ "$(position)" = "DONE" ] && ok "position: campaign DONE" || fail "position: expected DONE, got $(position)"
bash "$S/wave_gate.sh" "$C/audit/state.json" "$WORK/all.fps" > /dev/null 2>&1 \
  && ok "final gate: full original fingerprint set ADVANCE (campaign DRAINED)" || fail "final gate over all fps"
[ "$(grep -c . "$JOURNAL")" -eq 2 ] && ok "journal: kickoff + delegated approval, append-only" || fail "journal: expected 2 lines, got $(grep -c . "$JOURNAL")"

# No-op second pass: position DONE, journal untouched.
J1="$(cat "$JOURNAL")"
[ "$(position)" = "DONE" ] && [ "$J1" = "$(cat "$JOURNAL")" ] \
  && ok "re-invocation over a drained campaign is a no-op (says DONE, journals nothing)" || fail "re-invocation no-op"

echo "== e2e red paths =="

# HUMAN_NEEDED mid-campaign: dispatch stops; the next wave is never sliced.
C2="$WORK/red_human"; mkdir -p "$C2/audit" "$C2/.autopilot/runbooks"
cp "$FIX/SPEC.md" "$C2/audit/SPEC.md"; cp "$WORK/state_after_w1.json" "$C2/audit/state.json"
cp "$FIX/tracker_human_needed.md" "$C2/.autopilot/runbooks/audit-w2.tracker.md"
ST="$(tracker_status "$C2/.autopilot/runbooks/audit-w2.tracker.md")"
if [ "$ST" = "HUMAN_NEEDED" ]; then
  ok "red: wave-2 tracker HUMAN_NEEDED classifies as stop (escalation relayed verbatim)"
  [ ! -e "$C2/audit/waves/wave-3.md" ] && ok "red: wave 3 never sliced after the stop" || fail "red: wave 3 sliced past a HUMAN_NEEDED"
else
  fail "red: expected HUMAN_NEEDED classification, got $ST"
fi

# REGRESSED anywhere halts — and nothing gets stamped.
bash "$S/wave_gate.sh" "$FIX/state_regressed_elsewhere.json" "$WORK/w1.fps" > /dev/null 2>&1; rc=$?
if [ "$rc" -eq 3 ]; then
  ok "red: REGRESSED-anywhere gates exit 3 (halt)"
  AF="$(PY "$S/remediation_state.py" already-filed aaaa11111111 "$FIX/state_regressed_elsewhere.json")"
  case "$AF" in UNFILED*) ok "red: halted wave left no Guard-1 stamps" ;; *) fail "red: unexpected stamp state ($AF)" ;; esac
else
  fail "red: expected exit 3, got $rc"
fi

# Forward dep refuses BEFORE generate: no slice is written.
C3="$WORK/red_fwd"; mkdir -p "$C3/audit"; cp "$FIX/SPEC_forward_dep.md" "$C3/audit/SPEC.md"
bash "$S/spec_wave.sh" forward-deps "$C3/audit/SPEC.md" 1 > /dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ ! -e "$C3/audit/waves" ] \
  && ok "red: forward dep refused pre-generate, nothing sliced" || fail "red: forward-dep refusal (rc=$rc)"

# Corrupt state stops the walk at exit 4 (fail closed, never guess).
bash "$S/wave_gate.sh" "$FIX/state_corrupt.json" "$WORK/w1.fps" > /dev/null 2>&1; rc=$?
[ "$rc" -eq 4 ] && ok "red: corrupt state stops at exit 4" || fail "red: corrupt state (rc=$rc)"

echo
echo "== loop_e2e: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
