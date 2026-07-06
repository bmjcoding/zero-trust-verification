"""Shared fixtures: every remedy that keeps this suite deterministic."""

# MUST-NOT-FLAG N3 (see ../../EXPECTED_FINDINGS.yaml): this file is the REMEDIES
# MUST-NOT-FLAG N3: exhibit - seeded RNG, frozen clock, tmp_path isolation, a
# MUST-NOT-FLAG N3: cooperative asyncio yield, canned data consumed by real
# MUST-NOT-FLAG N3: assertions, and a literal reruns=0 retry ban that pins the
# MUST-NOT-FLAG N3: digit anchor in FLAKY_RE. Any line of this file in
# MUST-NOT-FLAG N3: test_flakiness.txt or test_vacuity.txt, or any agent
# MUST-NOT-FLAG N3: test-health finding on it, is a precision failure.
# MUST-NOT-FLAG N3 (QA, post-1.4.0-eval): frozen_clock's original
# MUST-NOT-FLAG N3: dotted-string patch target resolved to a
# MUST-NOT-FLAG N3: namespace-package shadow of the running test module under
# MUST-NOT-FLAG N3: pytest's default prepend import mode, and raising=False
# MUST-NOT-FLAG N3: kept the miss silent; it now patches via sys.modules.
# MUST-NOT-FLAG N3: The precision contract is unchanged.

import asyncio
import random
import sys
from datetime import datetime, timezone

import pytest

FROZEN_NOW = datetime(2026, 1, 15, 12, 0, 0, tzinfo=timezone.utc)


def pytest_configure(config):
    # Retry-based flake masking is banned in this suite: CI pins reruns=0 so
    # nondeterminism fails loudly instead of being retried until green.
    if config.pluginmanager.hasplugin("rerunfailures"):
        config.option.reruns = 0


@pytest.fixture
def rng():
    # A seeded RNG instance is the remedy for unseeded module-level randomness:
    # every run draws the same sequence, so a failure replays exactly.
    return random.Random(1234)


@pytest.fixture
def frozen_clock(monkeypatch):
    # Frozen wall clock: tests that stamp or compare timestamps pin this value
    # instead of reading the real clock mid-run (midnight/TZ safe).
    class _FrozenDatetime(datetime):
        @classmethod
        def now(cls, tz=None):
            return FROZEN_NOW.astimezone(tz) if tz else FROZEN_NOW.replace(tzinfo=None)

    # Patch the module object pytest actually executes. A dotted-string
    # target that names the tests package is import-mode-sensitive: with no
    # tests/__init__.py the running module is top-level test_clock_random,
    # and a package-path import lands on a namespace-package shadow copy the
    # tests never read. sys.modules finds the loaded module under either
    # name.
    for name, module in list(sys.modules.items()):
        if name.rpartition(".")[2] == "test_clock_random" and module is not None:
            monkeypatch.setattr(module, "datetime", _FrozenDatetime, raising=False)
    return FROZEN_NOW


@pytest.fixture
def config_path(tmp_path):
    # tmp_path isolation: state lives in a per-test directory, never in the
    # repo or a shared location a parallel worker could clobber.
    path = tmp_path / "settings.json"
    path.write_text('{"batch_size": 50, "region": "us-east-1"}')
    return path


@pytest.fixture
def sample_records():
    # Canned data is not vacuity: these rows feed real assertions in the tests
    # that consume them (see test_sync_flaky.py's drain round-trip).
    return [
        {"id": 1, "kind": "user", "score": 42},
        {"id": 2, "kind": "org", "score": 7},
        {"id": 3, "kind": "user", "score": 19},
    ]


async def drain_event_loop():
    # A zero-length asyncio sleep is a cooperative yield to the event loop,
    # not a timing wait: pending callbacks run and control returns immediately.
    await asyncio.sleep(0)
