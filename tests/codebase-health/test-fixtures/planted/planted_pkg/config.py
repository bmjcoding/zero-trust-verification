"""Config module. PLANTS SEC2 (hardcoded secret) and G3 (file-level suppression)."""

# mypy: ignore-errors
# PLANT G3: file-level suppression - the comment above hides EVERY type error
# PLANT G3: this module produces, the strongest form of Category G.

# PLANT SEC2 (hardcoded secret): a live-looking AWS access key committed to
# PLANT SEC2: source. gitleaks (when installed) and the security-auditor must flag it.
AWS_ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE"
AWS_SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"  # pragma: allowlist-fixture


def get_credentials() -> dict:
    return {"key": AWS_ACCESS_KEY_ID, "secret": AWS_SECRET_ACCESS_KEY}
