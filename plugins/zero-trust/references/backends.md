# Telemetry backends (selections behind one surface)

The triage tier ships three telemetry backends. Selecting one is CONFIG, not
architecture (ADR 0006): `$TRIAGE_TELEMETRY_BACKEND` or `triage.config.yaml
telemetry.backend`. The caller never branches on the vendor — it drives
`telemetry.sh` and gets the same normalized TR-02 shape regardless of source.

| Backend id | Script | Source | Posture |
|---|---|---|---|
| `OTEL_FILE` (default) | `scripts/backends/otel_file.sh` | an OTLP/OTEL-JSON logs file | hermetic + community; the self-test backend |
| `CLOUDWATCH` | `scripts/backends/cloudwatch.sh` | Logs Insights response (canned fixture = [det]; live = [drain]) | unbounded retention → `--service`/`--event` required |
| `DYNATRACE` | `scripts/backends/dynatrace.sh` | Grail/DQL response (canned fixture = [det]; live = [drain]) | unbounded retention → `--service`/`--event` required |

"Works on CloudWatch/Dynatrace" is the SAME assertion for all three: a real canned
response in, a SCHEMA-VALID TR-02 record out (jsonschema-asserted, no live call).
Live queries resolve tokens through `secret_get.sh` and are the honest [drain] residual.

Each backend honors the observable contract in `references/telemetry-contract.md`
(the single canonical copy, ADR 0030): the subcommand surface (`backend` / `probe` /
bounded `window`), the normalized TR-02 record shape, and the read-only + report-only
posture all live there — lint V9 stands tripwire against any re-vendored copy.
