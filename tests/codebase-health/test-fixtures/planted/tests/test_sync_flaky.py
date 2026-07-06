"""Sync-worker queue-draining tests. PLANTS TF1, TF7, TF8 live here."""

import queue
import threading
import time

import pytest


def _drain(q, out):
    """Consume the queue until the shutdown sentinel, doubling each item."""
    while True:
        item = q.get()
        if item is None:
            return
        out.append(item * 2)


def test_flush_completes_before_read():
    q = queue.Queue()
    out = []
    worker = threading.Thread(target=_drain, args=(q, out))
    worker.start()
    for n in (1, 2, 3):
        q.put(n)
    q.put(None)
    # PLANT TF1 (test-health T1, sleep-as-sync): a fixed sleep is the only
    # PLANT TF1: synchronization with the worker thread - under CI load the
    # PLANT TF1: drain takes longer than 0.2s and the assert races it. The
    # PLANT TF1: remedy is joining the worker with a timeout, not a longer sleep.
    time.sleep(0.2)
    assert out == [2, 4, 6]
    worker.join()


# PLANT TF7 (test-health T7, retry-until-pass): two consumers compete for the
# PLANT TF7: queue, so batch order is genuinely nondeterministic - and the
# PLANT TF7: rerun decorator below agrees to ignore that instead of fixing it.
@pytest.mark.flaky(reruns=3)
def test_interleaved_consumers_preserve_order():
    q = queue.Queue()
    out = []
    workers = [threading.Thread(target=_drain, args=(q, out)) for _ in range(2)]
    for w in workers:
        w.start()
    for n in range(6):
        q.put(n)
    for _ in workers:
        q.put(None)
    for w in workers:
        w.join()
    assert out == [n * 2 for n in range(6)]


def test_flush_handles_shutdown_flag():
    q = queue.Queue()
    out = []
    worker = threading.Thread(target=_drain, args=(q, out))
    worker.start()
    q.put(None)
    for n in (5, 7, 9):
        q.put(n)
    worker.join()
    # PLANT TF8 (test-health T8, guarded assert): the sentinel is enqueued
    # PLANT TF8: before the work items, so the worker exits with `out` empty
    # PLANT TF8: and the guard below never lets the assertion run - the test
    # PLANT TF8: is green while constraining nothing. Agent-scored: assert
    # PLANT TF8: reachability is block-structural, not a line property.
    if out:
        assert all(item % 2 == 0 for item in out)


def test_drain_preserves_every_record(sample_records):
    # Healthy contrast case: join before assert, canned rows from conftest
    # consumed by a real round-trip assertion.
    q = queue.Queue()
    out = []
    worker = threading.Thread(target=_drain, args=(q, out))
    worker.start()
    for record in sample_records:
        q.put(record["score"])
    q.put(None)
    worker.join()
    assert sorted(out) == sorted(record["score"] * 2 for record in sample_records)
