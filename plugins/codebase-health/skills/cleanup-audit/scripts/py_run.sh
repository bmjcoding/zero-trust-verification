# Shared uv-first Python runner (ADR 0015 "everything uv"). Sourced, never run.
#
# Prefer `uv run` against the PLUGIN's OWN minimal, dependency-free pyproject — a
# hermetic interpreter that self-bootstraps without a hand-managed venv and, by
# pinning --project to the plugin, NEVER syncs the target repo's dependencies
# during an audit. Commit to the runner choice up front (no trial-run probe) so a
# stdin-consuming caller is never double-read; a uv INFRA failure surfaces as a
# normal non-zero exit the caller's own fallback already handles. Fall back to an
# ambient python3 where uv is absent or the plugin dir is read-only (the
# validate_manifest.sh precedent). The plugin's Python is stdlib-only, so the
# fallback interpreter needs no extra packages.
CHPR_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
pyrun() {
  if command -v uv >/dev/null 2>&1 && [ -f "$CHPR_PLUGIN_DIR/pyproject.toml" ]; then
    uv run --quiet --project "$CHPR_PLUGIN_DIR" python "$@"
  else
    python3 "$@"
  fi
}
