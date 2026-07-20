# The telemetry adapter observable contract (the SINGLE SOURCE)

`telemetry.sh` is the one vendor-neutral surface the triage tier drives (TR-01;
ADR 0006 vendor-neutral / ADR 0013 host-adapter precedent). Every backend —
`otel_file` (default, hermetic), `cloudwatch`, `dynatrace` — implements the
**byte-identical observable contract** below. Callers never name a vendor; a new
backend (GCP Cloud Logging, Grafana Loki, …) is a new backend passing this same
contract, never a new caller path.

This file is the SINGLE copy of that contract (ADR 0030). Carriers (e.g.
`references/backends.md`) cite it instead of vendoring it; the lint **V9**
tripwire catches any re-vendored delimited-block copy (byte-identity or red), so
a producer/consumer drift stays impossible.

<!-- vendored:telemetry-contract:begin (ADR 0006/0013 — byte-identical across every telemetry backend contract copy; do NOT edit one copy) -->
## Subcommand surface (every backend implements it identically)

- `backend`  -> prints the detected backend id (OTEL_FILE | CLOUDWATCH | DYNATRACE),
  host-local; REFUSES when no backend is selected (a telemetry vendor is an external
  fact — ADR 0002 — never guessed; there is deliberately NO origin-sniff analog).
- `probe`    -> reachability/auth of the selected backend: exit 0, or non-zero + a
  reason on stderr. Touches no credential on the hermetic default backend.
- `window --since <ts> --until <ts> [--service S] [--event E]`
             -> normalized TR-02 incident-window NDJSON on stdout, one record per line.
  The BOUNDED-WINDOW guard is mechanical and non-negotiable: `--since` AND `--until`
  are REQUIRED; a span over `window.max_span` is REFUSED; a backend with unbounded
  retention REFUSES without a `--service` or `--event` scope. Never a whole-fleet scan.

## The normalized TR-02 record (what every backend emits, §12 field names verbatim)

- `event_name`  (string) — the §12 join key; the SAME string the manifest declares
  on the vital step. ABSENT => DARK-in-prod: bucketed by the correlation, never dropped.
- `vital_class` (money | state-transition | external-side-effect | auth | null).
- `service`, `env` (env ∈ the §4 environments reserved set), `timestamp` (RFC3339).
- `emitter` — the producing identity; the loop-guard drops records whose emitter is
  one of the tier's own (self-ingestion guard).
- `trace_id`/`span_id`/`severity`/`count`/`attributes` — optional OTEL passthrough.

There is NO `manifest_journey_id` in a window record: telemetry carries no
design-time IDs, so the journey is DERIVED from the `event_name` match — never a
backref (the journeys.json v2 backref lives in the UNBUILT codebase-health CH-02).

## Read-only + report-only

The adapter READS telemetry and nothing else. It mutates no running system, holds
no credential in agent context (secrets resolve through `secret_get.sh` on the live
path only), and its output feeds a Spec proposal — never a patch, never an auto-merge.
<!-- vendored:telemetry-contract:end -->
