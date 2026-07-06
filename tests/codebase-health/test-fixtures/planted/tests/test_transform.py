"""Tests for planted_pkg.transform. MUST-NOT-FLAG N5 lives here."""

import asyncio

from planted_pkg.transform import classify, fetch_batch


# MUST-NOT-FLAG N5: real behavior-constraining tests — specific inputs pinned
# MUST-NOT-FLAG N5: to specific expected outputs, every assertion capable of
# MUST-NOT-FLAG N5: failing. Any line of this file in test_vacuity.txt, or an
# MUST-NOT-FLAG N5: agent vacuity finding on it, is a precision failure.
def test_classify_user_maps_to_person():
    assert classify("user") == "person"


def test_classify_org_maps_to_company():
    assert classify("org") == "company"


def test_classify_kinds_map_to_distinct_labels():
    assert classify("user") != classify("org")


def test_fetch_batch_returns_one_record_per_id_in_order():
    records = asyncio.run(fetch_batch([3, 1, 2]))
    assert [r["id"] for r in records] == [3, 1, 2]
