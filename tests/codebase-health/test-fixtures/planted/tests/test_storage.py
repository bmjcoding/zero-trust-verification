"""Tests for planted_pkg.storage. PLANT TQ5 lives here."""

from planted_pkg.storage import load_config


def test_load_config_missing_file_returns_empty():
    result = load_config("/no/such/path/config.json")
    # MUST-NOT-FLAG (tests-path exemption pin, no id): this deliberate debug
    # MUST-NOT-FLAG: print is what makes self_test's "tests/ gated out of
    # MUST-NOT-FLAG: stdout_logging.txt" assertion non-vacuous - LOGGING_RE
    # MUST-NOT-FLAG: matches the line, TEST_PATH_RE must gate it out. Tests are
    # MUST-NOT-FLAG: out of scope for Category LOG (guardrail).
    print("load_config on a missing path returned", result)
    assert result == {}


# PLANT TQ5 (identity tautology): the roundtrip's closing assertion compares
# PLANT TQ5: the result to ITSELF — x == x holds for any value, so nothing
# PLANT TQ5: about load_config is constrained and the test stays green if
# PLANT TQ5: parsing breaks. Expected: agent finding, test-health/T9 identity
# PLANT TQ5: form (ERE has no backreferences, so this slice is agent-owned,
# PLANT TQ5: not TEST_VACUOUS_RE).
def test_load_config_roundtrip(tmp_path):
    config_path = tmp_path / "config.json"
    config_path.write_text('{"retries": 3, "endpoint": "api.example.com"}')
    result = load_config(str(config_path))
    assert result == result
