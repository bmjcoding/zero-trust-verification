"""Tests for planted_pkg.auth. PLANTS TQ1, TQ2, TQ4, TQ6 live here."""

from unittest import mock

import pytest

from planted_pkg import auth


# PLANT TQ1 (assertion-free / call-and-pray): the ONLY executing coverage of
# PLANT TQ1: validate_api_key — the B1 fake validator — and it asserts nothing,
# PLANT TQ1: so the fake implementation ships green. Expected: agent finding,
# PLANT TQ1: test-health/T8, HIGH (vacuity-by-construction + sole executing
# PLANT TQ1: coverage of a public auth symbol).
def test_validate_api_key_smoke():
    auth.validate_api_key("prod-key-01")
    auth.validate_api_key("prod-key-rotated-2026")


# PLANT TQ2 (literal tautology): the test was scaffolded and the real
# PLANT TQ2: signature check never written — the constant-true assert below is
# PLANT TQ2: the entire test. Expected: deterministic via TEST_VACUOUS_RE,
# PLANT TQ2: test-health/T9.
def test_key_signature_verified():
    key = "prod-key-01"
    assert True


# PLANT TQ4 (mocks the unit under test): hash_password itself is patched, so
# PLANT TQ4: both assertions check the mock's canned return value and its call
# PLANT TQ4: record — the real digest logic never executes and could be
# PLANT TQ4: deleted without this test going red. Expected: agent finding,
# PLANT TQ4: test-health/T10.
def test_hash_password_produces_hex_digest():
    with mock.patch.object(auth, "hash_password", return_value="0" * 32) as fake_hash:
        digest = auth.hash_password("correct horse battery staple")
    assert digest == "0" * 32
    fake_hash.assert_called_once_with("correct horse battery staple")


# PLANT TQ6 (skipped test): the one genuine auth assertion in this file,
# PLANT TQ6: disabled at the decorator — the suite shrinks and nobody notices.
# PLANT TQ6: Expected: deterministic via TEST_SKIP_RE, test-health/T12. (Being
# PLANT TQ6: skipped, it adds no executing coverage — TQ1 above stays
# PLANT TQ6: validate_api_key's sole coverage.)
@pytest.mark.skip(reason="key-store fixture was removed in the vault migration")
def test_rejects_empty_key():
    assert auth.validate_api_key("") is False
