# zero-trust

The whole Zero-Trust Verification suite in one Claude Code plugin (ADR 0025 —
consolidation of the former `spec-gen`, `autopilot`, `codebase-health`,
`marshal`, `org-memory`, and `triage` plugins into a single install).

- **Commands:** `/spec`, `/autopilot` (skill), `/audit`, `/verify`,
  `/remediate`, `/health-loop`, `/health-audit`, `/architecture`,
  `/dead-code`, `/diagnose-bug`, `/incomplete-logic`, `/marshal-pass`,
  `/marshal-staleness`, `/triage` — names unchanged from v1.x.
- **Skills:** `skills/spec/`, `skills/autopilot/`, `skills/cleanup-audit/`,
  `skills/triage/`.
- **One copy of everything vendored:** the Verification-Manifest schema
  (`schema/verification-manifest/`), the validator toolchain
  (`scripts/validate_manifest.{sh,py}`), `claim_overlap.sh`
  (`skills/autopilot/scripts/`), `mutation_adapter.sh`
  (`skills/cleanup-audit/scripts/`), and the ADR 0002 escalation criterion
  (`references/escalation-criterion.md`).
- **MCP:** the org-memory read-only query server is registered via `.mcp.json`
  (refuse-by-default; see `references/operations.md`).

Full suite documentation lives in the repository root `README.md`; per-domain
documentation is under `docs/<domain>/` here (autopilot's under
`skills/autopilot/`).

**Migrating from v1.x:** uninstall the six old plugins, then install
`zero-trust` from this marketplace — see the migration note in the root
`README.md`.
