#!/usr/bin/env python3
"""Config-Profile resolution for the Spec Generation tier (SG-4, spec-gen §2).

Resolution order is criticality of correctness: a Config Profile (ADR 0006) is
an org-standard — an external fact — so when it is NOT configured the tier does
NOT silently assume `default`; it falls to `default` AND flags an S5 escalation
("no Config Profile is configured — is `default` correct for this repo?"),
because ADR 0002 forbids an agent from assuming an external fact.

**Fresh sessions** (`/spec ...`, `/spec @draft.md`) resolve in this order:
    1. `--profile <name>` flag                         -> source=flag,        escalate=false
    2. committed repo config `spec-gen.config.yaml`,
       `profile:` key at repo root                     -> source=repo-config, escalate=false
    3. `default`                                        -> source=default,     escalate=TRUE

**Resume / amend sessions** take the profile from the manifest's
`observability.profile` (already resolved in the originating session); no
re-escalation. A resume/amend manifest missing that field is malformed input.

CLI:
  profile_resolve.py --mode fresh [--profile X] [--config spec-gen.config.yaml]
  profile_resolve.py --mode resume --manifest <spec>.manifest.yaml
prints {"profile":..., "source":..., "escalate":bool[, "escalation":<question>]}
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

DEFAULT_PROFILE = "default"
CONFIG_FILENAME = "spec-gen.config.yaml"

# The exact S5 escalation surfaced when resolution falls through to `default`.
NO_PROFILE_ESCALATION = (
    "no Config Profile is configured (no --profile flag, no spec-gen.config.yaml "
    "`profile:` key) — is `default` (vendor-neutral) correct for this repo? "
    "An org-standard profile is an external fact; the tier will not assume one (ADR 0002)."
)


def _load_yaml_12(path: Path):
    """Parse with the same YAML 1.2 core-schema parser the validator uses (ADR 0014).

    A malformed config/manifest is hand-editable, so a parse error is surfaced as
    a clean ValueError (which `_main` renders as `{"error": ...}` + exit 3) rather
    than an uncaught YAMLError traceback — matching the canonical validator's own
    `_load_yaml_12` discipline.
    """
    from ruamel.yaml import YAML
    from ruamel.yaml.error import YAMLError

    yaml = YAML(typ="safe", pure=True)
    yaml.version = (1, 2)
    try:
        with path.open("r", encoding="utf-8") as fh:
            return yaml.load(fh)
    except YAMLError as exc:
        raise ValueError(f"{path}: YAML parse error: {exc}") from exc


def _config_profile(config_path: Path | None):
    """Return the `profile:` value from spec-gen.config.yaml, or None if absent/blank."""
    if config_path is None or not config_path.exists():
        return None
    data = _load_yaml_12(config_path)
    if not isinstance(data, dict):
        return None
    prof = data.get("profile")
    if isinstance(prof, str) and prof.strip():
        return prof.strip()
    return None


def resolve_fresh(flag: str | None = None, config_path: Path | None = None) -> dict:
    """Fresh-session resolution: flag -> repo config -> default+escalate."""
    if flag and flag.strip():
        return {"profile": flag.strip(), "source": "flag", "escalate": False}
    cfg = _config_profile(config_path)
    if cfg is not None:
        return {"profile": cfg, "source": "repo-config", "escalate": False}
    return {
        "profile": DEFAULT_PROFILE,
        "source": "default",
        "escalate": True,
        "escalation": NO_PROFILE_ESCALATION,
    }


def resolve_from_manifest(manifest_path: Path) -> dict:
    """Resume/amend resolution: read observability.profile from the manifest."""
    data = _load_yaml_12(manifest_path)
    prof = ((data or {}).get("observability") or {}).get("profile")
    if not isinstance(prof, str) or not prof.strip():
        raise ValueError(
            f"{manifest_path}: observability.profile missing/blank — a resume/amend "
            "manifest must carry the profile resolved in its originating session"
        )
    return {"profile": prof.strip(), "source": "manifest", "escalate": False}


def resolve(mode: str, *, flag=None, config_path=None, manifest_path=None) -> dict:
    if mode == "fresh":
        return resolve_fresh(flag, config_path)
    if mode in ("resume", "amend"):
        if manifest_path is None:
            raise ValueError(f"--mode {mode} requires --manifest")
        return resolve_from_manifest(Path(manifest_path))
    raise ValueError(f"unknown mode {mode!r} (expected fresh|resume|amend)")


def _main(argv) -> int:
    ap = argparse.ArgumentParser(prog="profile_resolve.py", add_help=True)
    ap.add_argument("--mode", choices=["fresh", "resume", "amend"], default="fresh")
    ap.add_argument("--profile", default=None)
    ap.add_argument("--config", default=CONFIG_FILENAME)
    ap.add_argument("--manifest", default=None)
    args = ap.parse_args(argv[1:])
    try:
        cfg_path = Path(args.config) if args.config else None
        out = resolve(
            args.mode, flag=args.profile, config_path=cfg_path, manifest_path=args.manifest
        )
    except (ValueError, OSError) as exc:
        print(json.dumps({"error": str(exc)}))
        return 3
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
