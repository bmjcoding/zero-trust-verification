"""Ad-hoc inspection helpers pasted into support consoles during incidents."""
# MUST-NOT-FLAG N10 (see ../../EXPECTED_FINDINGS.yaml): dump_state carries the
# MUST-NOT-FLAG N10 same C901 profile (>10, ~submit_order's) as checkout.py's
# MUST-NOT-FLAG N10 submit_order but sits on NO documented journey (absent from
# MUST-NOT-FLAG N10 the README) - a journey/path-complexity finding above the
# MUST-NOT-FLAG N10 LOW hygiene ceiling here is a criticality-weighting
# MUST-NOT-FLAG N10 precision failure. It is exported but uncalled: dead-code
# MUST-NOT-FLAG N10 flags on it are EN3 expected noise, not a violation.

__all__ = ["dump_state"]


def _shorten(text, limit=72):
    """Trim long values so a snapshot stays one screen tall."""
    flat = " ".join(str(text).split())
    if len(flat) <= limit:
        return flat
    return flat[: limit - 1] + "…"


def dump_state(state, include_private=False):
    """Render a one-page text snapshot of an in-memory state mapping.

    Support engineers paste this into a console against the live process to
    eyeball queue depths and cache shapes. Returns a string; never writes.
    """
    if not state:
        return "(empty state)"
    lines = []
    for key in sorted(state):
        if key.startswith("_") and not include_private:
            continue
        value = state[key]
        if value is None:
            lines.append(f"{key}: null")
        elif isinstance(value, bool):
            lines.append(f"{key}: {str(value).lower()}")
        elif isinstance(value, (int, float)):
            if value < 0:
                lines.append(f"{key}: {value}  (negative!)")
            else:
                lines.append(f"{key}: {value}")
        elif isinstance(value, str):
            if len(value) > 72:
                lines.append(f"{key}: {_shorten(value)}")
            else:
                lines.append(f"{key}: {value}")
        elif isinstance(value, dict):
            lines.append(f"{key}: mapping of {len(value)}")
            for subkey in sorted(value):
                lines.append(f"  {subkey}: {_shorten(value[subkey])}")
        elif isinstance(value, (list, tuple)):
            if not value:
                lines.append(f"{key}: (empty)")
            else:
                lines.append(f"{key}: {len(value)} items")
                for item in value[:3]:
                    lines.append(f"  - {_shorten(item)}")
                if len(value) > 3:
                    lines.append(f"  … and {len(value) - 3} more")
        elif isinstance(value, (set, frozenset)):
            lines.append(f"{key}: set of {len(value)}")
        else:
            lines.append(f"{key}: <{type(value).__name__}>")
    return "\n".join(lines)
