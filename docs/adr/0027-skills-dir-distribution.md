# ADR 0027 — Skills-dir distribution: the plugin marketplace entry point is retired

- **Status:** Accepted (operator directed 2026-07-16)
- **Date:** 2026-07-16
- **Amends:** ADR 0001 (the marketplace as the product entry point) and ADR 0025
  (which kept the root marketplace registering the one consolidated plugin).
  The single-plugin invariant of ADR 0025 is unchanged; only the delivery
  channel moves.

## Context

Managed (enterprise) Claude Code deployments now ship an **allowed-marketplace
list** in managed settings (`strictKnownMarketplaces`, Claude Code v2.1+). A
third-party marketplace that cannot join the allowlist cannot be added at all —
and the restriction applies equally to a *local filesystem* marketplace add, so
a git clone does not escape it by itself. The operator's environment confirmed
exactly this: `bmjcoding/zero-trust-verification` cannot be allowlisted.

Two non-marketplace doors exist:

1. **The skills directory.** A plugin directory (or symlink) under
   `~/.claude/skills/<name>/` auto-loads as `<name>@skills-dir` — the same
   mechanism `claude plugin init` scaffolds into. Verified against this repo
   (Claude Code 2.1.210, isolated `CLAUDE_CONFIG_DIR`): the full plugin loads —
   every skill and command, the seven audit agents, the PostToolUse hook, and
   the org-memory MCP server.
2. **`--plugin-dir <path>`** — loads a plugin for one session only, and managed
   settings can disable it outright (`disableSideloadFlags`).

## Decision

Distribution is a **local git clone consumed through the skills directory**:

    git clone <repo>
    ln -s <clone>/plugins/zero-trust ~/.claude/skills/zero-trust

- The root `.claude-plugin/marketplace.json` is **deleted**, not kept
  alongside: two documented install paths for one product is drift surface,
  and the marketplace one is dead in the environments this suite targets.
- The product entry point is the plugin's own
  `plugins/zero-trust/.claude-plugin/plugin.json`.
- **Lint V6 inverts**: from "ONE root marketplace registers exactly the one
  plugin" to "NO marketplace.json anywhere in the product tree (residue
  guard), exactly one installable plugin under `plugins/`, plugin.json named
  `zero-trust`". The V13 full-tree cross-domain presence key moves from the
  marketplace file to the plugin.json.
- Updates are `git pull` in the clone (the symlink tracks it); a release is
  pinned by checking out its tag. `--plugin-dir` stays documented as the
  try-before-install door only.

## Considered options

- **Keep the marketplace alongside the skills-dir path** — rejected: residue.
  Two install stories drift apart, and the marketplace one silently fails for
  the primary audience (managed enterprise environments).
- **Internal git-host mirror added to the org allowlist** — the cleanest
  channel where an operator can win that conversation; rejected as the
  *product's* ship path because it depends on per-org IT approval this repo
  cannot assume. It remains the recommended escalation for orgs that also
  block the skills-dir source.
- **Ship a .zip for `--plugin-url` / `--plugin-dir`** — session-only, and
  managed settings can disable the sideload flags entirely; a demo door, not
  an install.

## Consequences

- Install/update UX changes (clone + symlink + `git pull`); every command
  name, agent, MCP server, and in-plugin path is unchanged.
- `/plugin update` and marketplace auto-update no longer apply; freshness is
  the clone's `git pull` discipline, and version pinning is a tag checkout.
- A managed environment that also blocks the skills-dir source
  (`blockedMarketplaces: [{"source": "skills-dir"}]`) has no self-serve door
  left; that org needs the internal-mirror allowlist conversation above.
- `claude plugin tag` still validates releases (plugin.json alone; there is no
  enclosing marketplace entry to agree with).
