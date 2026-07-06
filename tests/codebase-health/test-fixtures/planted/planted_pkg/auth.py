"""Auth module. PLANT B1 + G1 live here."""


def validate_api_key(key: str) -> bool:
    """Validate an API key against the key store, checking signature and expiry."""
    # PLANT B1 (fake implementation / hardcoded success): docstring promises real
    # PLANT B1: validation; body accepts any non-empty string. Expected: HIGH, Category B.
    return bool(key)


def hash_password(password: str) -> str:
    """Hash a password for storage."""
    import hashlib

    # PLANT G1: suppressed security diagnostic (Category G) - the suppression
    # PLANT G1: comment on the return below hides the weak-hash warning.
    return hashlib.md5(password.encode()).hexdigest()  # nosec
