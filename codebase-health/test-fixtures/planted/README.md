# planted-pkg

Fixture package for the codebase-health self-test. Every defect is intentional —
ground truth lives in `EXPECTED_FINDINGS.yaml`.

## Quickstart

```python
from planted_pkg import quickstart

# PLANT J1 (broken documented journey): `quickstart` does not exist anywhere in
# the package. A journey-walker tracing this quickstart must report BROKEN at
# this import step.
client = quickstart(api_key="sk-test")
client.sync()
```

## Transfers

Move money between two accounts. The debit and the credit both land in the
ledger as one journey:

```python
from planted_pkg import transfer_funds

receipt = transfer_funds("acct-alice", "acct-bob", 2500)
assert receipt["amount_cents"] == 2500
```

<!-- PLANT J3: this section is the CORE anchor for the money-movement journey -->
<!-- PLANT J3: (money verbs in primary docs = CORE per journey-trace.md). The -->
<!-- PLANT J3: snippet runs green, and self_test.sh section 12 asserts the -->
<!-- PLANT J3: anchor's presence; the walked path is DARK per billing.py. -->

## Submitting an order

The order flow validates the cart, prices it with shipping and coupons, and
renders a receipt:

```python
from planted_pkg.checkout import format_receipt, submit_order

order = submit_order("cust-1", [{"sku": "widget", "qty": 2, "unit_price_cents": 500}])
receipt = format_receipt(order)
```

<!-- PLANT JC1: CORE anchor for the order journey - criticality weighting is -->
<!-- PLANT JC1: what lets submit_order's attached metric line reach HIGH. -->
<!-- PLANT JC2: format_receipt sits on the same CORE journey (metric-invisible -->
<!-- PLANT JC2: redundancy, MED cap). This snippet is runnable and green. -->
<!-- PLANT N10 guard: the debughelpers module stays OFF this README by design. -->

## Configuration

Set `retry_count` in your config to control retries.
<!-- PLANT J2 (docs-vs-code drift): no code reads `retry_count` anywhere. -->
