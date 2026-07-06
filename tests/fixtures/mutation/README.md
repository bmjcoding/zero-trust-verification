# Mutation adapter fixtures (MT-01)

Hermetic sample tool outputs + expected normalized survivor sets for the
`mutation_adapter.sh normalize <tool>` resolver (ADR 0016 / mutation-testing
register MT-01). NO mutation tool is ever run in CI — these are canned outputs,
exactly as `run_audit.sh` would ingest them.

| tool | `*.raw.*` (tool output) | `*.expected.txt` (normalized `path:line`) | granularity |
|---|---|---|---|
| StrykerJS | `stryker.raw.json` | `stryker.expected.txt` | LINE (only `Survived`; `Killed`/`NoCoverage` excluded) |
| cargo-mutants | `cargo.raw.txt` | `cargo.expected.txt` | LINE (`missed.txt`) |
| mutmut | `mutmut.raw.txt` | `mutmut.expected.txt` | FILE at invocation; line via `mutmut show` |
| go-mutesting | `go.raw.txt` | `go.expected.txt` | FILE — every survivor degrades to `path:-` |

The go-mutesting pair is also the MT-01 "a tool with no line resolver degrades to
file granularity" acceptance: every expected row ends in `:-`.
