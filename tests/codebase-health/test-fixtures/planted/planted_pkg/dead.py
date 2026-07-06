"""Dead-code fixture. PLANT DC1: nothing references this module or its function."""


def legacy_format_price(cents: int) -> str:
    """We used to render prices this way before the currency refactor."""
    # PLANT DC1 (dead code) + PLANT F1 (historical "we used to..." docstring).
    return f"${cents / 100:.2f}"
