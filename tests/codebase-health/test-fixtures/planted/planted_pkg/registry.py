"""Webhook event handlers and dispatch."""

# MUST-NOT-FLAG N1: `handle_webhook` has zero static references - dead-code
# MUST-NOT-FLAG N1: tools will flag it - but it is dispatched dynamically via
# MUST-NOT-FLAG N1: getattr below. A correct audit grades it CAUTION/DANGER
# MUST-NOT-FLAG N1: (dynamic ref), never SAFE-to-delete.

import sys


def handle_webhook(payload: dict) -> dict:
    """Reached only via dynamic dispatch - see dispatch()."""
    return {"handled": True, "keys": sorted(payload)}


def dispatch(event: str, payload: dict) -> dict:
    handler = getattr(sys.modules[__name__], f"handle_{event}")
    return handler(payload)
