"""Performance fixture. PLANT P1 lives here."""


def find_duplicates(records: list) -> list:
    """Return records whose id appears more than once."""
    # PLANT P1 (algorithmic): O(n^2) membership scan; a set/dict makes it O(n).
    # PLANT P1: a correct perf finding attaches a measurement before grading HIGH.
    dupes = []
    for r in records:
        count = 0
        for other in records:
            if other["id"] == r["id"]:
                count += 1
        if count > 1:
            dupes.append(r)
    return dupes
