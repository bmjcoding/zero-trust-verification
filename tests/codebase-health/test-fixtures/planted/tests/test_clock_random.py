"""Report stamping and payload generation tests. PLANTS TF3, TF4 live here."""

import random
from datetime import datetime


def _make_payload(seq):
    return {"seq": seq, "batch": f"batch-{seq:05d}"}


def _stamp_report(rows):
    return {"rows": rows, "generated": datetime.now().isoformat()}


def test_payload_ids_are_unique():
    # PLANT TF3 (test-health T3, unseeded module RNG): fresh random ids every
    # PLANT TF3: run means every run tests different inputs, and 25 draws from
    # PLANT TF3: a 10k range collide often enough to fail on an unlucky seed
    # PLANT TF3: that can never be replayed. The conftest `rng` fixture is the
    # PLANT TF3: remedy this test ignores.
    ids = [random.randint(1, 10000) for _ in range(25)]
    payloads = [_make_payload(i) for i in ids]
    assert len({p["seq"] for p in payloads}) == len(payloads)


def test_report_stamp_matches_generation_day():
    report = _stamp_report([1, 2, 3])
    # PLANT TF4 (test-health T4, wall clock): compares a stamp taken inside
    # PLANT TF4: the helper against a second read of the real clock - fails
    # PLANT TF4: when the two reads straddle midnight and shifts with the
    # PLANT TF4: machine TZ. The conftest `frozen_clock` fixture is the remedy
    # PLANT TF4: this test ignores.
    assert report["generated"][:10] == datetime.now().isoformat()[:10]
