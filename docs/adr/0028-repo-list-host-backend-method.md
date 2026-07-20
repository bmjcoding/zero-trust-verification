# ADR 0028 — Repo enumeration becomes a `host.sh` backend method; `host_repo_list.sh`'s parallel transport is retired

- **Status:** Agent-decided (2026-07-17 architecture review, top recommendation; verified against the live tree)
- **Date:** 2026-07-17
- **Supersedes/amends:** executes ADR 0019's own forward plan ("`host.sh` gains a NEW `repo-list` backend method"); retires the vendored-transport half of that ADR, whose sole justification (ADR 0011 independent installability) was dissolved by ADR 0025.

## Context

`scripts/host_repo_list.sh` (OWM-09) enumerates org repositories with its own
backend detection and its own transport, outside the canonical host adapter
(`skills/autopilot/scripts/host.sh` + `bitbucket.sh`/`github.sh`). Verified
against the live tree, the duplicate transport is materially weaker than the
adapters it mirrors:

- **Token on argv.** The Bitbucket path passes `Authorization: Bearer $TOKEN`
  on curl's command line (`host_repo_list.sh:62-63`) — visible in
  `/proc/*/cmdline` — where `bitbucket.sh:210-239` writes the header to a 0600
  temp file and passes `-H @file`, a hardening autopilot regression-tests (T03).
- **Silent failure.** No `pipefail`, no HTTP-status checks, and both JSON
  parsers `except Exception: sys.exit(0)` — every live HTTP/auth/transport
  failure exits 0 with an empty TSV, indistinguishable from an org with zero
  repos. (The no-backend exit-3 fallback *is* reachable and test-asserted;
  the transport-failure paths never reach it.)
- **No pagination.** One `limit=1000` request; larger orgs silently truncate.
- **Duplicate backend detection** (`OWM_HOST_BACKEND` vs
  `AUTOPILOT_HOST_BACKEND`, near-identical origin-URL cases).

ADR 0019 rejected putting enumeration in `host.sh` *only* because org-memory
could take no runtime dependency on the autopilot plugin. Post-ADR-0025 both
files ship in the same `plugins/zero-trust` plugin; the constraint is moot.
ADR 0013's rule applies unimpeded: *a new capability is a backend method, never
a new caller path.* No production caller exists today (self-test OWM-09 and
operator docs only; enumeration is OFF by default), so this is the cheapest
moment to consolidate.

## Decision

1. `host.sh` gains a `repo-list --org <org>` subcommand, implemented by both
   backends (`cmd_repo_list`), emitting the existing TSV contract
   (`<slug>\t<clone-or-api-url>`) on stdout.
2. The Bitbucket implementation rides the hardened path: `secret_get.sh`
   resolution, `-H @file` auth, `bb_curl` status/retry/redaction semantics, and
   pagination (`isLastPage`/`nextPageStart` loop, as `pr-list-ready` already
   does — `bb_curl` itself needs no changes). The GitHub implementation uses
   `gh api --paginate /orgs/<org>/repos` (note: `gh repo list` has no
   `--paginate`) or an explicit `--limit` with a loud truncation warning on a
   full page (the `pr-list-ready` precedent), and surfaces `gh`'s exit status
   instead of discarding stderr.
3. Failure semantics are the adapter's: `die_state` + `LAST_STATE` on stderr,
   exit 1. The old soft exit-3 "fall back to the config list" posture moves to
   the *caller* seam: OWM's operator docs show the explicit-list-first,
   `repo-list`-as-optional-enrichment pattern (config-first per ADR 0019 is
   unchanged; enumeration stays OFF by default).
4. Both backends acquire lazy repo-coordinate derivation — split precisely:
   `PROJECT_KEY`/`REPO_SLUG` (genuinely unneeded by `repo-list`) move behind
   the subcommands that need them; on Bitbucket DC, `BB_HOST` resolution and
   sidecar detection are STILL required for `repo-list` (the REST target
   derives from origin unless `AUTOPILOT_BITBUCKET_HOST` or the sidecar
   supplies it), and outside a repo with no host source `repo-list` dies with
   a useful `LAST_STATE`, never skipping host resolution.
5. `OWM_HOST_BACKEND` is retired; `AUTOPILOT_HOST_BACKEND` is the one override.
6. `host_repo_list.sh` is deleted. OWM-09 self-tests re-target
   `host.sh repo-list` through both backends via the contract-matrix pattern,
   and a T03-analog asserts the token never appears on curl argv for the
   enumeration path. Assertion count does not decrease.

## Consequences

- One transport, one backend-detection, one credential discipline; the
  enumeration path inherits every hardening the adapters already carry and
  every future one for free.
- `docs/org-memory/README.md` (:28,:84) and `references/operations.md` (:19)
  re-point to `host.sh repo-list`.
- `docs/specs/org-wide-memory-register.md` OWM-09 gets a dated supersession
  note citing this ADR (registers are append-only; the entry's fallback
  exit-3 fixture acceptance is superseded by adapter `die_state` semantics).
- The `contract_matrix` grows a row; the DC mock server and the `gh` argv shim
  gain repo-list fixtures, and the re-targeted OWM-09 mocks inject credentials
  (sidecar or secret_get env tier) since they now traverse the hardened path.
  The L16(c) invocation-discipline verbs list and the `host-contract.md`
  subcommand table gain `repo-list`.
- The OWM fallback contract changes shape (die vs exit 3): the crawl config
  remains the source of truth and enumeration remains optional, so no caller
  behavior changes in the shipped tree.
