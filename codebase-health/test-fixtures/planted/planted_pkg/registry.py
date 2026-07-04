"""Dynamic-dispatch trap. MUST-NOT-FLAG N1 lives here.

`handle_webhook` has zero static references - dead-code tools will flag it -
but it is dispatched dynamically via getattr below. A correct audit grades it
CAUTION/DANGER (dynamic ref), never SAFE-to-delete.
"""

import sys


def handle_webhook(payload: dict) -> dict:
    """Reached only via dynamic dispatch - see dispatch()."""
    return {"handled": True, "keys": sorted(payload)}


def dispatch(event: str, payload: dict) -> dict:
    handler = getattr(sys.modules[__name__], f"handle_{event}")
    return handler(payload)
