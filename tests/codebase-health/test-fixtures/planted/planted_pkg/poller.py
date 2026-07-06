"""Bounded polling for the sync worker: capped attempts, jittered backoff."""

# MUST-NOT-FLAG N4 (see ../../EXPECTED_FINDINGS.yaml): production code. The
# MUST-NOT-FLAG N4: time.sleep and random.random calls below are correct here
# MUST-NOT-FLAG N4: (bounded poll interval, thundering-herd jitter), and this
# MUST-NOT-FLAG N4: file deliberately avoids the attempt-counting retry-loop
# MUST-NOT-FLAG N4: shape, so the tx retry seed stays clean. Any line of this file in
# MUST-NOT-FLAG N4: test_flakiness.txt is a TEST_PATH_RE scoping failure, not
# MUST-NOT-FLAG N4: a detection win.

import random
import time

_BASE_DELAY = 0.25
_MAX_DELAY = 4.0


def backoff_delays(base=_BASE_DELAY, cap=_MAX_DELAY):
    """Yield capped exponential delays with full jitter.

    Jitter spreads simultaneous pollers apart so a recovering upstream is not
    hammered by a synchronized herd; the cap keeps the worst-case interval
    responsive.
    """
    delay = base
    while True:
        yield delay * (0.5 + random.random() / 2)
        delay = min(delay * 2, cap)


def wait_for(predicate, timeout=30.0):
    """Poll `predicate` until it returns true or `timeout` seconds elapse.

    Returns the number of intervening waits on success; raises TimeoutError
    when the deadline passes. The monotonic clock makes the deadline immune
    to wall-clock adjustments.
    """
    deadline = time.monotonic() + timeout
    delays = backoff_delays()
    attempts = 0
    while time.monotonic() < deadline:
        if predicate():
            return attempts
        attempts += 1
        time.sleep(next(delays))
    raise TimeoutError(f"condition not met within {timeout:.0f}s ({attempts} waits)")
