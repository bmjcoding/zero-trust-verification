# Architecture & Strictness

The strictness layer. Dead-code/security/perf agents ask "is this correct/referenced/fast?" This file adds the harder question: **is this the right shape?** A codebase can pass strict mypy + ruff, have zero dead code, and still be architecturally shallow — that is exactly the codebase that *feels* clean but isn't.

Vocabulary and principles here are adapted from Matt Pocock's `codebase-design` and related engineering skills (https://github.com/mattpocock/skills, MIT). Use the terms **exactly** — consistent language is the point. Don't drift into "component", "service", "API", or "boundary".

## Vocabulary (use these exact terms)
- **Module** — anything with an interface + implementation (function, class, package, slice). Scale-agnostic.
- **Interface** — *everything a caller must know to use it correctly*: type signature AND invariants, ordering constraints, error modes, required config, performance characteristics. Broader than "the type signature".
- **Implementation** — what's inside.
- **Depth** — leverage at the interface: how much behavior a caller/test exercises per unit of interface they must learn. **Deep** = lots of behavior behind a small interface. **Shallow** = interface nearly as complex as the implementation.
- **Seam** (Feathers) — a place you can alter behavior without editing in that place; where a module's interface lives.
- **Adapter** — a concrete thing satisfying an interface at a seam.
- **Leverage** (callers) / **Locality** (maintainers) — what depth buys: capability per unit learned; and change/bugs/knowledge concentrated in one place.

## The strictness tests (apply these as judgment, not greps)

### 1. The deletion test
For any module you suspect is cruft or a pass-through, imagine deleting it.
- Complexity **vanishes** → it was a shallow pass-through. Finding: inline/remove it.
- Complexity **reappears across N callers** → it earns its keep. Not a finding.
This is stricter than "has callers": a shallow wrapper with 10 callers still fails the deletion test if deleting it just moves the same complexity to those 10 sites.

### 2. The interface is the test surface
Callers and tests cross the **same** seam. Red flags:
- Tests that reach *past* the public interface (poking privates, monkeypatching internals) → the module is the wrong shape.
- **Pure functions extracted only for testability**, while the real bugs live in *how they're called* (no locality). The unit is green; the integration is where it breaks. Flag this — it's the most common "looks tested, isn't" pattern.

Ownership seam: wrong-seam-but-**real** tests are this test's findings. A test that constrains nothing at all is test-health territory (`references/test-health.md`, owned by test-health-auditor); both at once → ONE finding, category `test-health/T*` per the precedence chain in `audit-state-and-verify.md`, with architecture in lenses.

### 3. One adapter = hypothetical seam; two = real
A seam (protocol/ABC/injection point) with exactly one implementation is speculative abstraction. Flag interfaces/Protocols with a single concrete impl and no test fake as candidate over-abstraction — unless a second adapter is imminent or it exists purely as a test seam (then the fake IS the second adapter).

### 4. Shallow-module scan
Flag modules where the interface is nearly as complex as the implementation:
- Wrappers that forward args with no added behavior.
- Classes that are bags of getters/setters with logic pushed to callers.
- "Manager/Helper/Util" modules that callers must orchestrate in a specific sequence (the ordering knowledge leaked out of the module = shallow interface).

### 5. Accept dependencies; return results
- Modules that `new`/construct their own dependencies instead of accepting them → hard to test, hidden coupling (a per-request-constructed client is also a perf smell — cross-link it).
- Side-effecting functions where a value-returning one would do → harder to test, worse locality.

## Locality includes the machine reader

The highest-volume maintainer of most codebases is now a coding agent, and "navigation cost" is a metered bill for it: a giant file forces partial reads, and partial reads cause **missed edits** (the agent changes three of the four call sites it never saw); a near-duplicate pair means the fix lands in one clone and the other diverges silently; commented-out blocks and misleading names feed the agent **hallucinated context**. The compounding harm is **definition-of-done erosion**: an agent that cannot see the whole shape declares victory on the part it saw.

### Giant-file triage (`audit/giant_files.txt`, 400/800/1600 ladder)
The ladder rungs (attention / warn / god-file, non-blank lines — threshold rationale in `cross-language-tooling.md`) are triage priority, never verdicts. Triage each entry:
- **Cohesive generated file** (lockfile-adjacent, codegen output, a single large table/schema with one reason to change) → **not a finding**. Size without accretion is fine; note it and move on.
- **Accreted god module** (many unrelated reasons to change, helpers gravitating in, callers importing it for disjoint slices) → a **seam-based split recommendation**: name the seams, show the interface before/after (per Output discipline below), and attach a strength label. Recommend the split along existing seams, not by line count.

## Severity for architecture findings
- **HIGH** — shallow module on a hot/public path whose shape is actively causing the bugs found elsewhere (e.g. leaked ordering that enables a wrong-target bug).
- **MED** — shallow module or speculative seam adding navigation cost — for the human *and* the machine reader (above) — but not (yet) causing bugs.
- **LOW / Worth-exploring** — deepening opportunity with real but modest payoff.
Navigability anchors (same rubric, no separate scale): giant file, near-duplicate pair, or commented-out block is **LOW–MED** — MED when it sits on a churn hotspot; a misleading name is **MED** (it actively feeds wrong context); **HIGH only via the existing confirmation gates** (a traced bug the shape caused, or the criticality-weighted journey gates in `severity-rubric.md`) — the token-burn framing raises no ceilings by itself.
Use Pocock's recommendation-strength labels in reports: **Strong / Worth exploring / Speculative**.

## Output discipline
Architecture findings name the **module**, the **shape problem** (shallow / leaky seam / speculative abstraction / extracted-for-testability), the **deletion-test result**, and a **before/after** of the interface — not just the implementation. Tie every benefit to **locality** and **leverage**, and to how **tests** would improve.

## Connecting bugs to architecture (the loop that makes it strict)
When a confirmed bug has **no correct test seam** to lock it down, that absence *is* an architecture finding (per `diagnosing-bugs`): the shape is preventing the bug from being caught. Route it here. Make the recommendation *after* the fix, when you know the most.
