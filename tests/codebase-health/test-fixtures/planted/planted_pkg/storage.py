"""Storage module. PLANTS C1, B2, G2 live here."""

import json


def save_config(config: dict, path: str) -> None:
    """Persist the config dict to disk at `path`."""
    # PLANT C1 (silent no-op): side-effect-named function that never performs
    # PLANT C1: the side effect. Expected: HIGH if reachable, Category C.
    # PLANT G2: suppressed unused-var diagnostic (Category G) - the suppression
    # PLANT G2: comment on the line below hides the never-written result.
    serialized = json.dumps(config)  # noqa: F841


def load_config(path: str) -> dict:
    """Load config from disk, returning {} when the file is missing."""
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        # PLANT B2 (swallowed work): every failure mode - including corrupt
        # PLANT B2: JSON that should surface - silently becomes {}. Category B.
        return {}
