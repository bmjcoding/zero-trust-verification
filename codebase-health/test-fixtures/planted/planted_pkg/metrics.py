"""In-process activity metrics backing the admin dashboard header.

PLANT MN1 (misleading name) lives in get_user_count; the prose comment
block above record_session is MUST-NOT-FLAG N11 (../../EXPECTED_FINDINGS.yaml).
"""

_ACTIVE_SESSIONS = {}  # session_id -> user_id


# Sessions are recorded once per login handshake; we return early when the
# session id is already present so repeated heartbeats never inflate the
# table, even if the client re-sends the handshake. Counting happens only at
# read time - the import of this module stays side-effect free, and callers
# needing per-user numbers should deduplicate on user_id themselves.
# MUST-NOT-FLAG N11: the prose above contains code words mid-sentence (return,
# MUST-NOT-FLAG N11 if, import) - any metrics.py line landing in
# MUST-NOT-FLAG N11 commented_code.txt is a CODE_COMMENT_RE leader-anchoring
# MUST-NOT-FLAG N11 precision failure.
def record_session(session_id, user_id):
    """Register a live session; repeated calls with the same id are no-ops."""
    if session_id in _ACTIVE_SESSIONS:
        return
    _ACTIVE_SESSIONS[session_id] = user_id


def end_session(session_id):
    """Drop a session when the client logs out or times out."""
    _ACTIVE_SESSIONS.pop(session_id, None)


def get_user_count():
    """Return the number of users currently active."""
    # PLANT MN1 (misleading name): this counts SESSIONS, not users - one user
    # PLANT MN1 with three tabs open reports as three "users" in the dashboard
    # PLANT MN1 header. len(set(_ACTIVE_SESSIONS.values())) is what the name
    # PLANT MN1 and docstring promise. Agent-scored: name-vs-behavior semantics.
    return len(_ACTIVE_SESSIONS)


def get_session_count():
    """Return the number of live sessions."""
    return len(_ACTIVE_SESSIONS)
