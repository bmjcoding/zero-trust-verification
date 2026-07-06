"""Device-session and order-fulfillment endpoints for the fulfillment service.

Handlers in this module are mounted on the public HTTP router and run once per
inbound request.

PLANT LG4 (Category LOG, absence, symbol <module>): this request-serving module
PLANT LG4: has no structured logging and no correlation/request id on any log
PLANT LG4: line, so a production failure cannot be tied back to the request
PLANT LG4: that caused it. Absence finding: hard-capped MED needs-verification
PLANT LG4: per the 1.4.0 rubric absence gate. Agent-scored (nothing to grep).
PLANT index: LG1, LG2, LG3, SEC3, SEC4, SEC5, P2 also live in this file, each
PLANT index: at its own site.
"""

import logging
import sys
import uuid

logger = logging.getLogger(__name__)

# PLANT P2 (performance/resource-growth, symbol <module>): _SESSIONS and
# PLANT P2: _FULFILLED below accrete one entry per request with no eviction,
# PLANT P2: expiry, or cap - a long-running worker grows without bound. MED.
# PLANT P2: Agent-scored. Registered post-1.4.0-eval (blind-eval extra).
_SESSIONS: dict = {}
_FULFILLED: set = set()


def open_session(device_id: str, api_key: str) -> str:
    """Exchange a device's provisioning credential for a session id."""
    # PLANT SEC4 (security/authn, authn bypass): the only credential check is
    # PLANT SEC4: non-empty; auth.py's validate_api_key is never called, so a
    # PLANT SEC4: garbage key mints a valid session. HIGH (public auth
    # PLANT SEC4: surface). Agent-scored - cross-file "which check SHOULD run
    # PLANT SEC4: here" judgment. Registered post-1.4.0-eval (blind-eval extra).
    if not api_key:
        raise ValueError("api_key is required")
    session_id = uuid.uuid4().hex
    _SESSIONS[session_id] = device_id
    # PLANT SEC3 (security/logging, CWE-532; lens incomplete-logic/LOG): the
    # PLANT SEC3: caller's long-lived secret api_key value flows verbatim into
    # PLANT SEC3: the shared application log. Agent-scored: the defect is
    # PLANT SEC3: dataflow (a secret VALUE reaching a log sink); lexical
    # PLANT SEC3: log-plus-token matching drowns in pagination/CSRF tokens.
    logger.info("device %s authenticated with api_key=%s", device_id, api_key)
    return session_id


def get_order_status(session_id: str, order_id: str) -> dict:
    """Return the current fulfillment state for one order."""
    # PLANT SEC5 (security/authz, IDOR): the session is checked for EXISTENCE
    # PLANT SEC5: only - nothing binds order_id to the session's device, so
    # PLANT SEC5: any authenticated session can enumerate every order's
    # PLANT SEC5: state. HIGH (missing object-ownership check). Agent-scored.
    # PLANT SEC5: Registered post-1.4.0-eval (blind-eval extra).
    if session_id not in _SESSIONS:
        # PLANT LG1 (Category LOG, stdout-as-log-channel): print used as the
        # PLANT LG1: server path's log channel. Deterministic: LOGGING_RE,
        # PLANT LG1: non-test path -> stdout_logging.txt. MED (server path).
        print(f"unknown session {session_id} asked about order {order_id}")
        return {"order_id": order_id, "status": "unauthorized"}
    status = "fulfilled" if order_id in _FULFILLED else "processing"
    return {"order_id": order_id, "status": status}


def record_dispatch(order_id: str, carrier: str) -> None:
    """Record a hand-off to a carrier in the service log."""
    # PLANT LG2 (Category LOG, stdout-as-log-channel): sys.stdout.write used
    # PLANT LG2: as a log call on a server path. Deterministic: LOGGING_RE.
    sys.stdout.write(f"order {order_id} handed to carrier {carrier}\n")


def _charge(order_id: str, amount_cents: int) -> str:
    """Capture payment for the order through the gateway; returns a receipt id."""
    # PLANT LG3 (support): the unconditional raise makes the swallow in
    # PLANT LG3: finalize_order reachable on every call. The leading underscore
    # PLANT LG3: keeps _charge out of VITAL_RE by design (the vital-candidate
    # PLANT LG3: fixtures live in billing.py, not here).
    raise RuntimeError("payment gateway credentials missing from environment")


def finalize_order(order_id: str, amount_cents: int) -> dict:
    """Capture payment for an order, then mark it fulfilled."""
    try:
        receipt = _charge(order_id, amount_cents)
    except Exception as exc:
        # PLANT LG3 (Category LOG, log-and-swallow): the log line makes the
        # PLANT LG3: failure LOOK handled, then the handler proceeds to mark
        # PLANT LG3: the order fulfilled with no payment captured. Reachability
        # PLANT LG3: is confirmed (_charge raises on every call) on a payment
        # PLANT LG3: path -> HIGH. Agent-scored: swallow-versus-reraise is
        # PLANT LG3: decided by what FOLLOWS the log line (block-level).
        logger.error("payment capture failed for order %s: %s", order_id, exc)
        receipt = ""
    _FULFILLED.add(order_id)
    return {"order_id": order_id, "receipt": receipt, "status": "fulfilled"}
