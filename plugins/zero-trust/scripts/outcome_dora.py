#!/usr/bin/env python3
"""DORA-family derivation for outcome measurement (ADR 0023; ALL Class-D).

The single deterministic source for the four DORA-family metrics, shared by the
baseline capture (OM-02) and the Marshal `outcome-capture` mode (OM-03):

  deploy_frequency    first-parent landed commits on trunk / week   (pure git)
  lead_time           first-commit -> land timestamp, median hours  (pure git)
  change_failure_rate reverted-within-window OR build-status FAILED  (git [+host])
  mttr_build          red landed build -> next green landed build    (host build-status)

No agent is in the loop: every number is `git log` first-parent / `host build-status`
provable, so honesty_class is `deterministic` (Class-D). On a fixture this is [det];
on a live host it is [drain]. Build-status routes through the SAME host adapter the
Marshal uses (ADR 0013), so Bitbucket DC and GitHub yield the same assertion set;
when no host is reachable the build-derived signals degrade honestly (value null +
a note) rather than fabricate.

This module ONLY reads history and shells to the host adapter for build-status; it
writes nothing, opens no PR, files no finding (ADR 0004/0023).

Output: a JSON object {window, window_short, metrics:[metric_row,...]} on stdout.
Exit 0 on success; 64 usage; 65 not-a-git-repo.
"""
from __future__ import annotations

import json
import subprocess
import sys

EXIT_OK = 0
EXIT_USAGE = 64
EXIT_NOT_REPO = 65

WEEK = 7 * 24 * 3600


def _git(repo, *args):
    p = subprocess.run(
        ["git", "-C", repo, *args],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    return p.returncode, p.stdout.decode("utf-8", "replace")


def _flag(argv, name, default=None):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default


def _median(vals):
    if not vals:
        return None
    s = sorted(vals)
    n = len(s)
    mid = n // 2
    if n % 2:
        return s[mid]
    return (s[mid - 1] + s[mid]) / 2.0


def _first_commit_ts(repo, trunk):
    """Author time of the OLDEST commit reachable from trunk (history start)."""
    rc, out = _git(repo, "log", "--first-parent", "--format=%at", trunk)
    if rc != 0:
        return None
    ats = [int(x) for x in out.split() if x.strip()]
    return min(ats) if ats else None


def _landed_commits(repo, trunk, since, until):
    """First-parent commits on trunk with committer time in [since, until) that
    have >=1 parent (a landed change onto an existing trunk — the root commit is
    the repo genesis, not a deploy)."""
    rc, out = _git(repo, "log", "--first-parent",
                   "--format=%H\t%ct\t%at\t%P\t%s", trunk)
    if rc != 0:
        return None
    commits = []
    for line in out.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t", 4)
        if len(parts) < 5:
            parts += [""] * (5 - len(parts))
        h, ct, at, parents, subject = parts
        parents = [p for p in parents.split() if p]
        if not parents:
            continue  # root commit: not a deploy
        cti = int(ct)
        if cti < since or cti >= until:
            continue
        commits.append({
            "sha": h, "ct": cti, "at": int(at),
            "parents": parents, "subject": subject,
        })
    return commits


def _lead_hours(repo, c):
    """first-commit(author time) -> land(committer time), in hours."""
    if len(c["parents"]) >= 2:
        p1 = c["parents"][0]
        rc, out = _git(repo, "rev-list", "--format=%at", "%s..%s" % (p1, c["sha"]))
        ats = []
        if rc == 0:
            # rev-list --format emits alternating "commit <sha>" / "<at>" lines
            for line in out.splitlines():
                line = line.strip()
                if line.isdigit():
                    ats.append(int(line))
        # exclude the merge commit's own author time (the newest) to find the
        # branch's first commit; fall back to the merge commit if it's alone.
        branch_ats = [a for a in ats if a != c["at"]] or ats
        first_at = min(branch_ats) if branch_ats else c["at"]
    else:
        first_at = c["at"]
    return max(0.0, (c["ct"] - first_at) / 3600.0)


def _reverted_targets(commits):
    """shas marked failed because a revert commit in the window reverts them."""
    failed = set()
    for c in commits:
        if c["subject"].startswith("Revert"):
            # git's revert body carries: 'This reverts commit <full40sha>.'
            for tok in c["subject"].replace(".", " ").split():
                if len(tok) == 40 and all(ch in "0123456789abcdef" for ch in tok):
                    failed.add(tok)
    return failed


def _build_status(host, sha, env_repo, env_state):
    import os
    env = dict(os.environ)
    if env_repo:
        env["MARSHAL_MOCK_REPO"] = env_repo
    if env_state:
        env["MARSHAL_MOCK_STATE"] = env_state
    p = subprocess.run(
        ["bash", host, "build-status", "--sha", sha],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
    )
    if p.returncode != 0:
        return None
    return p.stdout.decode("utf-8", "replace").strip().replace("\r", "")


def derive(repo, trunk, since, until, host, host_repo, host_state):
    commits = _landed_commits(repo, trunk, since, until)
    if commits is None:
        return None, "not a git repo or unknown trunk: %s" % trunk
    weeks = max((until - since) / WEEK, 1e-9)
    n = len(commits)

    metrics = []

    # deploy frequency (pure git)
    metrics.append({
        "name": "deploy_frequency",
        "value": round(n / weeks, 4),
        "unit": "per_week",
        "honesty_class": "deterministic",
        "provenance": "git-log --first-parent landed commits on %s / window" % trunk,
        "detail": {"deploys": n, "weeks": round(weeks, 3)},
    })

    # lead time (pure git)
    leads = [_lead_hours(repo, c) for c in commits]
    metrics.append({
        "name": "lead_time",
        "value": (round(_median(leads), 4) if leads else None),
        "unit": "hours",
        "honesty_class": "deterministic",
        "provenance": "git-log first-commit->land committer time, median",
        "detail": {"n": len(leads)},
    })

    # build-status per landed commit (host, if available)
    have_host = bool(host)
    status_by_sha = {}
    if have_host:
        for c in commits:
            status_by_sha[c["sha"]] = _build_status(host, c["sha"], host_repo, host_state)

    # change failure rate (revert-based always; build-FAILED if host)
    reverted = _reverted_targets(commits)
    failed = set()
    for c in commits:
        if c["sha"] in reverted:
            failed.add(c["sha"])
        if have_host and status_by_sha.get(c["sha"]) == "FAILED":
            failed.add(c["sha"])
    cfr_prov = "git-log revert-of-window-commit"
    if have_host:
        cfr_prov += " + host build-status FAILED"
    metrics.append({
        "name": "change_failure_rate",
        "value": (round(len(failed) / n, 4) if n else None),
        "unit": "ratio",
        "honesty_class": "deterministic",
        "provenance": cfr_prov,
        "detail": {"failed": len(failed), "deploys": n,
                   "build_status_source": have_host},
    })

    # MTTR (build): red landed build -> next green landed build (host only)
    if have_host:
        ordered = sorted(commits, key=lambda c: c["ct"])
        recoveries = []
        reds = 0
        for i, c in enumerate(ordered):
            if status_by_sha.get(c["sha"]) == "FAILED":
                reds += 1
                for later in ordered[i + 1:]:
                    if status_by_sha.get(later["sha"]) == "SUCCESSFUL":
                        recoveries.append((later["ct"] - c["ct"]) / 3600.0)
                        break
        metrics.append({
            "name": "mttr_build",
            "value": (round(_median(recoveries), 4) if recoveries else None),
            "unit": "hours",
            "honesty_class": "deterministic",
            "provenance": "host build-status red-land -> next green-land, median",
            "detail": {"red_lands": reds, "recovered": len(recoveries)},
        })
    else:
        metrics.append({
            "name": "mttr_build",
            "value": None,
            "unit": "hours",
            "honesty_class": "deterministic",
            "provenance": "host build-status (no host reachable at capture)",
            "source_absent": True,
            "note": "no build-status source; MTTR-build not derivable this run",
        })

    first_ts = _first_commit_ts(repo, trunk)
    window_short = bool(first_ts is not None and first_ts > since)
    window = {"weeks": round(weeks, 3), "since": since, "until": until, "merges": n}
    return {"window": window, "window_short": window_short, "metrics": metrics}, None


def main(argv):
    repo = _flag(argv, "--repo", ".")
    trunk = _flag(argv, "--trunk", "main")
    now = _flag(argv, "--now")
    until = _flag(argv, "--until")
    since = _flag(argv, "--since")
    weeks = _flag(argv, "--weeks", "8")
    host = _flag(argv, "--host")
    host_repo = _flag(argv, "--host-repo")
    host_state = _flag(argv, "--host-state")

    rc, _ = _git(repo, "rev-parse", "--git-dir")
    if rc != 0:
        sys.stderr.write("outcome_dora: not a git repo: %s\n" % repo)
        return EXIT_NOT_REPO

    try:
        if until is not None:
            until_i = int(until)
        elif now is not None:
            until_i = int(now)
        else:
            rc2, out2 = _git(repo, "log", "-1", "--format=%ct", trunk)
            until_i = int(out2.strip()) if rc2 == 0 and out2.strip() else 0
        if since is not None:
            since_i = int(since)
        else:
            since_i = until_i - int(float(weeks) * WEEK)
    except ValueError:
        sys.stderr.write("outcome_dora: --since/--until/--now/--weeks must be numeric\n")
        return EXIT_USAGE

    result, err = derive(repo, trunk, since_i, until_i, host, host_repo, host_state)
    if err:
        sys.stderr.write("outcome_dora: %s\n" % err)
        return EXIT_NOT_REPO
    sys.stdout.write(json.dumps(result, sort_keys=True) + "\n")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
