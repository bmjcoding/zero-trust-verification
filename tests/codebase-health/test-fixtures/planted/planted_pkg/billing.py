"""Billing: money movement, PSP webhook handlers, loan state transitions.

Every ledger write goes through the in-memory `_post_to_ledger`, so this whole
module is safe to execute — the README "Transfers" snippet runs green.
"""
# PLANTS J3, J4, J5, TX1-TX7 and MUST-NOT-FLAG N8, N9 live here, plus the
# PLANT V1-V3 deterministic seeds. Ground truth: ../../EXPECTED_FINDINGS.yaml.

import logging

_LOG = logging.getLogger(__name__)

# In-memory ledger: tuples of (entry_id, kind, account, amount_cents).
_LEDGER: list = []

# Loan application id -> {"state": ..., "approved_by": ...}.
_LOAN_STATES: dict = {}

# Webhook event ids already handled by handle_refund_webhook.
# PLANT TX6 (security/transactional-integrity, symbol <module>): this dedup
# PLANT TX6: store is a process-local in-memory set - a restart or a second
# PLANT TX6: worker forgets every id and replays PSP redeliveries as fresh
# PLANT TX6: events; it also grows without bound. Slug
# PLANT TX6: non-durable-dedup-store; MED needs-verification. N8 still
# PLANT TX6: protects the guard LOGIC in handle_refund_webhook - this plant
# PLANT TX6: scores the STORE. Registered post-1.4.0-eval (blind-eval extra).
_PROCESSED_EVENTS: set = set()


class LedgerTimeout(Exception):
    """Raised when the ledger backend does not acknowledge a write in time."""


def _post_to_ledger(kind: str, account: str, amount_cents: int) -> int:
    """Append one ledger entry and return its id (in-memory, always succeeds)."""
    entry_id = len(_LEDGER) + 1
    _LEDGER.append((entry_id, kind, account, amount_cents))
    return entry_id


def emit_event(name: str, **fields) -> None:
    """Forward one structured business event to the business logger."""
    # MUST-NOT-FLAG N9: this is a REAL emission sink, not a Category-B stand-in.
    # MUST-NOT-FLAG N9: it forwards a stable dot-namespaced name plus structured
    # MUST-NOT-FLAG N9: identifier fields; grading it fake is a precision failure.
    logging.getLogger("business").info(name, extra=fields)


def transfer_funds(source: str, dest: str, amount_cents: int) -> dict:
    """Move funds between accounts: debit `source`, credit `dest`.

    Documented in the README under "Transfers" — the package's primary
    money-movement journey.
    """
    # PLANT J3 (dark vital, journey/uninstrumented): a CORE money-movement path
    # PLANT J3: whose body reaches the ledger yet produces no business signal of
    # PLANT J3: any kind — nothing structured, nothing prose. Deterministic seed
    # PLANT J3: arithmetic scores it: def-site in vital_candidates.txt AND zero
    # PLANT J3: lines here in telemetry.txt; the README anchor makes it CORE, so
    # PLANT J3: HIGH is reachable per the Decision-4 gate. The journey-walker's
    # PLANT J3: DARK grade is the corroborating lens, not the score.
    # PLANT TX4 (security/transactional-integrity): the debit and credit below
    # PLANT TX4: are two uncoordinated ledger writes - no transaction, no
    # PLANT TX4: compensating action - so a backend failure between them (this
    # PLANT TX4: module's own LedgerTimeout names the mode) strands the
    # PLANT TX4: debited funds. Slug missing-compensation; CORE '## Transfers'
    # PLANT TX4: journey, HIGH reachable. Distinct defect from J3 - same
    # PLANT TX4: symbol, different slug. Registered post-1.4.0-eval
    # PLANT TX4: (blind-eval extra).
    if amount_cents <= 0:
        raise ValueError("transfer amount must be positive")
    debit_id = _post_to_ledger("debit", source, -amount_cents)
    credit_id = _post_to_ledger("credit", dest, amount_cents)
    return {"debit_id": debit_id, "credit_id": credit_id, "amount_cents": amount_cents}


def approve_loan(application_id: str, approver: str) -> dict:
    """Transition a loan application from SUBMITTED to APPROVED."""
    # PLANT J4 (dark vital, state transition): a business-critical state change
    # PLANT J4: that leaves no trace anywhere — the approver is stored but no
    # PLANT J4: business signal, no audit line, nothing an operator could watch.
    # PLANT J4: Deterministic seed arithmetic: def-site in vital_candidates.txt
    # PLANT J4: AND zero lines here in telemetry.txt. Untraced flow, so severity
    # PLANT J4: hard-caps at MED needs-verification (Decision-4 gate); the
    # PLANT J4: journey-walker's DARK grade is the lens.
    record = _LOAN_STATES.get(application_id, {"state": "SUBMITTED"})
    if record["state"] != "SUBMITTED":
        raise ValueError(f"cannot approve a loan in state {record['state']}")
    _LOAN_STATES[application_id] = {"state": "APPROVED", "approved_by": approver}
    return _LOAN_STATES[application_id]


def refund_payment(charge_id: str, account: str, amount_cents: int) -> dict:
    """Refund a captured charge back to the customer's account."""
    # PLANT J5 (LOG-ONLY vital, agent-scored): the refund reaches the ledger and
    # PLANT J5: leaves ONLY the prose log line below — no stable dot-namespaced
    # PLANT J5: name, identifiers buried in printf-style prose. Judging that a
    # PLANT J5: prose line is not an emission (LOG-ONLY, not DARK, not OBSERVED;
    # PLANT J5: severity MED) is the agent's call. Seed half is deterministic:
    # PLANT J5: def-site in vital_candidates.txt AND zero lines in telemetry.txt.
    # PLANT TX5 (security/transactional-integrity): nothing records or checks
    # PLANT TX5: charge_id, so the same charge can be refunded any number of
    # PLANT TX5: times by a retrying caller or a double-submitted request.
    # PLANT TX5: Slug missing-dedup-guard. Registered post-1.4.0-eval
    # PLANT TX5: (blind-eval extra).
    entry_id = _post_to_ledger("refund", account, -amount_cents)
    _LOG.info("processed refund of %d cents for charge %s", amount_cents, charge_id)
    return {"refund_entry": entry_id, "charge_id": charge_id, "status": "refunded"}


def charge_card(account: str, amount_cents: int, card_token: str) -> dict:
    """Charge a customer's card and record the ledger entry."""
    # MUST-NOT-FLAG N9: fully instrumented vital. The business signal below has
    # MUST-NOT-FLAG N9: a stable dot-namespaced name plus identifier fields, so
    # MUST-NOT-FLAG N9: the vitals table grades this OBSERVED; flagging it
    # MUST-NOT-FLAG N9: journey/uninstrumented is a precision failure. The card
    # MUST-NOT-FLAG N9: token is deliberately never logged (SEC3 lives in
    # MUST-NOT-FLAG N9: service.py, not here).
    # MUST-NOT-FLAG N9 (scope, post-1.4.0-eval): N9 covers ONLY the
    # MUST-NOT-FLAG N9: journey/uninstrumented lens - the keyless-charge facet
    # MUST-NOT-FLAG N9: is plant TX7 below.
    # PLANT TX7 (security/transactional-integrity): the charge is keyless - no
    # PLANT TX7: client-supplied retry-collapse key parameter, nothing
    # PLANT TX7: ledger-side to fold a caller's retry into one charge. Slug in
    # PLANT TX7: the manifest only - its token is itself a TX_GUARD_RE
    # PLANT TX7: alternate, so naming it here would leak this comment into
    # PLANT TX7: tx_guards.txt (the TX1 'Slugs in the manifest' precedent).
    # PLANT TX7: MED needs-verification (direct-call function, no in-repo
    # PLANT TX7: duplicate deliverer nameable). Registered post-1.4.0-eval
    # PLANT TX7: (blind-eval extra).
    if not card_token:
        raise ValueError("a card token is required")
    entry_id = _post_to_ledger("charge", account, amount_cents)
    emit_event("payment.charged", account=account, amount_cents=amount_cents,
               ledger_entry=entry_id)
    return {"charge_entry": entry_id, "account": account, "status": "charged"}


def handle_payment_webhook(event: dict) -> dict:
    """Process one `payment.succeeded` webhook delivery from the PSP."""
    # PLANT TX1 (security/transactional-integrity, agent-scored): the PSP
    # PLANT TX1: redelivers webhooks — the same event id arrives at least twice
    # PLANT TX1: during incident replay — but nothing here checks event["id"]
    # PLANT TX1: before the ledger write, so a redelivered webhook charges the
    # PLANT TX1: customer again. Contrast handle_refund_webhook (N8), which
    # PLANT TX1: checks its seen-set first. Who delivers the double execution is
    # PLANT TX1: nameable (the PSP's documented redelivery), so CRITICAL is
    # PLANT TX1: reachable per the data-corruption row. Slugs in the manifest.
    account = event["account"]
    amount_cents = event["amount_cents"]
    entry_id = _post_to_ledger("charge", account, amount_cents)
    emit_event("payment.charged", account=account, amount_cents=amount_cents,
               ledger_entry=entry_id)
    return {"status": "charged", "ledger_entry": entry_id}


def submit_payout(account: str, amount_cents: int) -> dict:
    """Submit a payout to a vendor account, absorbing transient ledger timeouts."""
    # PLANT TX2 (unsafe retry, agent-scored): a timeout does not mean the write
    # PLANT TX2: failed — the first attempt may have committed, so re-posting on
    # PLANT TX2: LedgerTimeout can pay the vendor up to three times. The write
    # PLANT TX2: is keyless: nothing correlates the attempts, so the ledger
    # PLANT TX2: cannot collapse them. Deterministic seed: the loop below lands
    # PLANT TX2: in tx_retries.txt. Slug: unsafe-retry.
    last_error = None
    for attempt in range(3):
        try:
            entry_id = _post_to_ledger("payout", account, -amount_cents)
            return {"status": "paid", "ledger_entry": entry_id, "attempts": attempt + 1}
        except LedgerTimeout as exc:
            last_error = exc
    raise last_error


def transfer_batch(source: str, payments: list) -> list:
    """Debit `source` once for the batch total, then credit each payee."""
    # PLANT TX3 (missing compensating action, agent-scored): the debit commits
    # PLANT TX3: FIRST; if any credit below raises (the amount check makes that
    # PLANT TX3: reachable mid-loop), the money has already left `source` and
    # PLANT TX3: nothing re-credits it or records the partial failure — the
    # PLANT TX3: batch dies between steps with funds in limbo, and there is no
    # PLANT TX3: audit line to reconstruct it from. Slug: missing-compensation.
    total = sum(p["amount_cents"] for p in payments)
    _post_to_ledger("debit", source, -total)
    receipts = []
    for payment in payments:
        if payment["amount_cents"] <= 0:
            raise ValueError("payout amounts must be positive")
        receipts.append(_post_to_ledger("credit", payment["account"], payment["amount_cents"]))
    return receipts


def handle_refund_webhook(event: dict) -> dict:
    """Process one `refund.requested` webhook delivery from the PSP."""
    # MUST-NOT-FLAG N8: CORRECT idempotency guard — event["id"] is checked
    # MUST-NOT-FLAG N8: against _PROCESSED_EVENTS BEFORE the ledger write, so a
    # MUST-NOT-FLAG N8: redelivered webhook is a recorded no-op. A Category-TX
    # MUST-NOT-FLAG N8: finding here is a precision failure; the guard line is
    # MUST-NOT-FLAG N8: asserted PRESENT in tx_guards.txt by the self-test.
    # MUST-NOT-FLAG N8 (scope, post-1.4.0-eval): N8 protects the guard LOGIC
    # MUST-NOT-FLAG N8: only - the STORE's durability is plant TX6 at the
    # MUST-NOT-FLAG N8: module-level set, and signature-verification chatter
    # MUST-NOT-FLAG N8: on either webhook handler is EN5 expected noise.
    event_id = event["id"]
    if event_id in _PROCESSED_EVENTS:
        return {"status": "duplicate", "event_id": event_id}
    entry_id = _post_to_ledger("refund", event["account"], -event["amount_cents"])
    _PROCESSED_EVENTS.add(event_id)
    emit_event("refund.processed", event_id=event_id, account=event["account"],
               amount_cents=event["amount_cents"], ledger_entry=entry_id)
    return {"status": "refunded", "event_id": event_id, "ledger_entry": entry_id}
