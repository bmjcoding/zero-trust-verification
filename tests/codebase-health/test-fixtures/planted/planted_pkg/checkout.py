"""Checkout: cart validation, pricing, and receipt rendering.

The order flow is documented in the README under "Submitting an order" and
runs green end to end — every defect here is structural, not behavioral.
"""
# PLANTS JC1, JC2, CO1 live here. Ground truth: ../../EXPECTED_FINDINGS.yaml.

_ORDERS: list = []


def submit_order(customer_id, items, coupon=None, shipping="standard"):
    """Validate a cart, price it with shipping and coupons, and record the order."""
    # PLANT JC1 (journey/path-complexity, agent-scored): convoluted branching on
    # PLANT JC1: the CORE order journey (README '## Submitting an order'). C901
    # PLANT JC1: lands ~15-16 (ruff-conditional integrity check in self_test.sh
    # PLANT JC1: section 12); the judgment cues beyond the raw metric are the
    # PLANT JC1: re-tested qty condition inside the loop and the coupon ladder
    # PLANT JC1: that re-derives shipping already settled above it. HIGH is
    # PLANT JC1: reachable ONLY because this step is CORE in journeys.json AND a
    # PLANT JC1: deterministic metric line attaches; the same shape off-journey
    # PLANT JC1: is N10's LOW-hygiene twin in debughelpers.py.
    if not customer_id:
        raise ValueError("customer_id is required")
    if not items:
        raise ValueError("cannot submit an empty cart")
    total_cents = 0
    for item in items:
        if "sku" not in item:
            raise ValueError("line item is missing a sku")
        if item.get("qty", 0) <= 0:
            raise ValueError("qty must be a positive integer")
        if item.get("unit_price_cents", 0) <= 0:
            raise ValueError("unit_price_cents must be positive")
        if item.get("qty", 0) > 0:
            total_cents += item["qty"] * item["unit_price_cents"]
    if shipping == "express":
        shipping_cents = 2500
    elif shipping == "standard":
        if total_cents >= 5000:
            shipping_cents = 0
        else:
            shipping_cents = 900
    else:
        raise ValueError(f"unknown shipping method: {shipping}")
    if coupon is not None:
        if coupon == "SAVE10":
            total_cents = apply_discount(total_cents, 10)
        elif coupon == "SAVE20":
            total_cents = apply_discount(total_cents, 20)
        elif coupon == "FREESHIP":
            if shipping_cents > 0:
                shipping_cents = 0
        else:
            raise ValueError(f"unknown coupon: {coupon}")
    order = {
        "order_id": f"ord-{len(_ORDERS) + 1}",
        "customer_id": customer_id,
        "items": list(items),
        "total_cents": total_cents,
        "shipping_cents": shipping_cents,
    }
    _ORDERS.append(order)
    return order


def format_receipt(order):
    """Render an order record as a printable text receipt."""
    # PLANT JC2 (journey/path-complexity, agent-scored, MED cap): redundant
    # PLANT JC2: branching that is metric-INVISIBLE by construction — C901 stays
    # PLANT JC2: under 10 (its ABSENCE is asserted in self_test.sh section 12),
    # PLANT JC2: so only structural judgment catches it: the qty ladder below
    # PLANT JC2: has three IDENTICAL arms, and the total is re-checked against a
    # PLANT JC2: condition submit_order already guarantees. Same CORE order
    # PLANT JC2: journey as JC1.
    lines = [f"order {order['order_id']} for {order['customer_id']}"]
    for item in order["items"]:
        if item["qty"] == 1:
            lines.append(f"  {item['sku']}  x{item['qty']}  @ {item['unit_price_cents']}c")
        elif item["qty"] > 1:
            lines.append(f"  {item['sku']}  x{item['qty']}  @ {item['unit_price_cents']}c")
        else:
            lines.append(f"  {item['sku']}  x{item['qty']}  @ {item['unit_price_cents']}c")
    if order["shipping_cents"] == 0:
        lines.append("  shipping: free")
    else:
        lines.append(f"  shipping: {order['shipping_cents']}c")
    if order["total_cents"] >= 0:
        lines.append(f"  total: {order['total_cents'] + order['shipping_cents']}c")
    return "\n".join(lines)


# PLANT CO1 (commented-out code block, deterministic): the nine dead lines below
# PLANT CO1: are the pre-coupon apply_discount kept as a comment fossil. The run
# PLANT CO1: is >= CO_MIN_RUN comment lines with >= CO_MIN_CODE code-shaped
# PLANT CO1: lines, contains no marker or suppression tokens and no LOGGING_RE
# PLANT CO1: tokens, and must land in audit/commented_code.txt.
# def apply_discount(total_cents, percent, coupon_code, audit=None):
#     discounted = total_cents - (total_cents * percent) / 100.0
#     if audit is not None:
#         audit.append(("discount", coupon_code, percent))
#     rounded = int(round(discounted))
#     if rounded < 0:
#         rounded = 0
#     _DISCOUNT_HISTORY.append(rounded)
#     return rounded
def apply_discount(total_cents: int, percent: int) -> int:
    """Return the total after applying a whole-percent discount, floored at 0."""
    discounted = total_cents - (total_cents * percent) // 100
    if discounted < 0:
        return 0
    return discounted
