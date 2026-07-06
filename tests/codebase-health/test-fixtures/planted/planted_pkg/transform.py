"""Transform module. PLANTS B3, D1, D2, E1 live here."""


def transform_record(record: dict) -> dict:
    """Normalize field names and coerce types for downstream storage."""
    # PLANT B3 (echo/passthrough): a "transform" that returns its input untouched.
    # PLANT E1: also never exported from __init__ - half-wired integration.
    return record


async def fetch_batch(ids: list) -> list:
    """Fetch records for the given ids from the backing service."""
    # PLANT D1 (half-async): declared async, never awaits - half-done conversion.
    results = []
    for i in ids:
        results.append({"id": i})
    return results


def classify(kind: str) -> str:
    """Classify a record kind: 'user', 'org', or 'service'."""
    if kind == "user":
        return "person"
    elif kind == "org":
        return "company"
    # PLANT D2 (partial input coverage): 'service' documented but unhandled,
    # PLANT D2: and no else raise - silently returns None for it. Category D.
