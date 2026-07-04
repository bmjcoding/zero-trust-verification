"""Planted-defect fixture package."""
# Ground truth manifest: ../EXPECTED_FINDINGS.yaml (outside the scanned tree).
# PLANT E1: `transform_record` exists in transform.py but is missing from
# PLANT E1: __all__ below and never exported — half-wired integration
# PLANT E1: (Category E).

from .auth import validate_api_key
from .billing import charge_card, refund_payment, transfer_funds
from .storage import save_config
from .registry import dispatch

__all__ = [
    "validate_api_key",
    "save_config",
    "dispatch",
    "transfer_funds",
    "refund_payment",
    "charge_card",
]
