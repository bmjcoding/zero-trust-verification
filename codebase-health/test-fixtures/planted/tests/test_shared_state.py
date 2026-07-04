"""Settings-cache and status-client tests. PLANTS TF2, TF5, TF6 live here."""

import threading

# PLANT TF5 (facet, post-1.4.0-eval): this module-level import of the HTTP
# PLANT TF5: client exists only to serve the live-network test below, and it
# PLANT TF5: breaks COLLECTION of the whole file (TF2/TF6 included) in any
# PLANT TF5: environment without that dependency - blast-radius evidence
# PLANT TF5: folded into TF5's entry, not a second finding.
import requests

_SETTINGS_CACHE = {}


def _load_settings():
    if "settings" not in _SETTINGS_CACHE:
        _SETTINGS_CACHE["settings"] = {"batch_size": 50, "region": "us-east-1"}
    return _SETTINGS_CACHE["settings"]


def test_settings_load_populates_cache():
    settings = _load_settings()
    assert settings["batch_size"] == 50
    assert settings["region"] == "us-east-1"


def test_settings_cache_serves_repeat_loads():
    # PLANT TF2 (test-health T2, order-dependence): this test never calls
    # PLANT TF2: _load_settings before asserting - it relies on the PREVIOUS
    # PLANT TF2: test having populated the module-level cache, so it fails
    # PLANT TF2: under shuffled order or when run alone. Agent-scored:
    # PLANT TF2: demonstrating it requires an order-shuffled execution probe.
    assert "settings" in _SETTINGS_CACHE
    assert _load_settings()["region"] == "us-east-1"


def test_concurrent_writers_all_land():
    counters = {"written": 0}

    def _writer():
        for _ in range(100):
            counters["written"] += 1

    threads = [threading.Thread(target=_writer) for _ in range(4)]
    for t in threads:
        t.start()
    # PLANT TF6 (test-health T6, unjoined-thread race): asserts while the four
    # PLANT TF6: writer threads may still be running - no join before the read,
    # PLANT TF6: and the unsynchronized increment races itself besides.
    # PLANT TF6: Agent-scored: thread-lifecycle reasoning, not a lexical form.
    assert counters["written"] == 400


def test_status_endpoint_reports_ok():
    # PLANT TF5 (test-health T5, real network in a unit test): a live HTTP call
    # PLANT TF5: to a production endpoint - fails with the network, the DNS,
    # PLANT TF5: and the service's own uptime. A fake transport is the remedy.
    resp = requests.get("https://status.example-sync.io/v1/health", timeout=5)
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"
