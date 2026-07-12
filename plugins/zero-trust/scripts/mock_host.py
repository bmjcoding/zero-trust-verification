#!/usr/bin/env python3
"""mock_host.py — a hermetic MOCK host backend for the Merge Marshal self-test.

It stands in for plugins/zero-trust/skills/autopilot/scripts/host.sh: it answers the SAME subcommand
contract the Marshal drives, so marshal.sh needs no test-only branches. There is
no network, no host API, no credentials — every answer is derived deterministically
from (a) a JSON state file seeding the PR set, and (b) a local *bare* git repo
standing in for `origin`.

Why Python-on-uv (ADR 0015): the mock keeps ordered queue state as JSON and shells
to git for sha/build/merge — exactly the "autopilot mock server" role ADR 0015
names as the place a plugin's Python belongs, all invocations routed through
`uv run` by the mock_host.sh wrapper.

Contract implemented (a subset of host.sh — only what the Marshal calls):

  backend
      -> prints "MOCK".

  pr-list-ready
      -> TSV, one ready PR per line:
         "<ready_ts>\t<pr_num>\t<src_branch>\t<head_sha>\t<approval>"
         A PR is "ready" when it is not merged, not declined, targets the trunk,
         and its source branch resolves in the bare repo. head_sha is read LIVE
         from the bare repo, so it reflects any rebase-push the Marshal did.
         approval is APPROVED or PENDING (the Marshal filters to APPROVED itself).

  build-status --sha <sha>
      -> SUCCESSFUL | FAILED | INPROGRESS | UNKNOWN, computed from the *composed
         tree* at <sha> (ADR 0010's "build the composed state"):
           - calls.txt containing a line "__INPROGRESS__"  -> INPROGRESS
           - neither defs.txt nor calls.txt present at sha -> UNKNOWN
           - every symbol in calls.txt is defined in defs.txt -> SUCCESSFUL
           - otherwise (a call to an undefined symbol)        -> FAILED
         This is a real Composition Break model: a branch green at its own fork
         point (it defined what it called) goes red once rebased onto a main that
         removed a symbol it still calls.

  pr-comment --num <n> --body-file <path>
      -> appends {num, body} to state["comments"]; exits 0.

  pr-merge --num <n> [--strategy <s>]
      -> appends {num, strategy} to state["merges"], marks the PR merged, and
         fast-forwards the bare repo's trunk to the PR branch tip (post-rebase
         branches are always descendants of trunk, so this is a real FF merge);
         exits 0. A non-fast-forward merge synthesizes a merge commit so the
         trunk still advances.

  pr-approve --num <n> / pr-decline --num <n>
      -> flip approval / mark declined in state (used by hotfix-pin fixtures).

State JSON shape (all keys optional except "prs"):
  {
    "trunk": "main",
    "prs": [ {"num":1,"branch":"story/a","ready_ts":100,"approval":"APPROVED"} ],
    "comments": [],
    "merges": []
  }

Env:
  MARSHAL_MOCK_STATE  path to the state JSON (read + write).
  MARSHAL_MOCK_REPO   path to the bare `origin` repo (its --git-dir).
"""

import json
import os
import subprocess
import sys


def die(msg, code=1):
    sys.stderr.write("mock_host.py: %s\n" % msg)
    sys.exit(code)


def load_state(path):
    with open(path) as f:
        st = json.load(f)
    st.setdefault("trunk", "main")
    st.setdefault("prs", [])
    st.setdefault("comments", [])
    st.setdefault("merges", [])
    return st


def save_state(path, st):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f, indent=2, sort_keys=True)
    os.replace(tmp, path)


def git(repo, *args):
    """Run a git command against the bare repo; (rc, stdout) with stdout stripped."""
    p = subprocess.run(
        ["git", "--git-dir", repo] + list(args),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    return p.returncode, p.stdout.decode("utf-8", "replace")


def rev_parse(repo, ref):
    rc, out = git(repo, "rev-parse", "--verify", "-q", ref)
    return out.strip() if rc == 0 else ""


def show_blob(repo, sha, path):
    """Content of <path> at <sha>, or None if the path is absent at that sha."""
    rc, out = git(repo, "show", "%s:%s" % (sha, path))
    return out if rc == 0 else None


def parse_flags(argv):
    """--k v pairs and bare --flags into a dict; bare flags map to True."""
    out = {}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--"):
            key = a[2:]
            if i + 1 < len(argv) and not argv[i + 1].startswith("--"):
                out[key] = argv[i + 1]
                i += 2
            else:
                out[key] = True
                i += 1
        else:
            i += 1
    return out


def merged_nums(st):
    return set(m["num"] for m in st["merges"])


# --- subcommands --------------------------------------------------------------

def cmd_backend(st, repo, flags):
    sys.stdout.write("MOCK\n")


def cmd_pr_list_ready(st, repo, flags):
    trunk = st["trunk"]
    done = merged_nums(st)
    rows = []
    for pr in st["prs"]:
        num = pr["num"]
        if num in done:
            continue
        if pr.get("declined"):
            continue
        if pr.get("dest", trunk) != trunk:
            continue
        branch = pr["branch"]
        sha = rev_parse(repo, "refs/heads/%s" % branch)
        if not sha:
            continue  # branch gone -> no longer a live claim
        approval = pr.get("approval", "PENDING")
        ready_ts = pr.get("ready_ts", 0)
        rows.append("%s\t%s\t%s\t%s\t%s" % (ready_ts, num, branch, sha, approval))
    if rows:
        sys.stdout.write("\n".join(rows) + "\n")


def cmd_build_status(st, repo, flags):
    sha = flags.get("sha")
    if not sha or sha is True:
        die("build-status: --sha required", 64)
    defs = show_blob(repo, sha, "defs.txt")
    calls = show_blob(repo, sha, "calls.txt")
    if defs is None and calls is None:
        sys.stdout.write("UNKNOWN\n")
        return

    def symbols(text):
        out = []
        for line in (text or "").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                out.append(line)
        return out

    call_syms = symbols(calls)
    if "__INPROGRESS__" in call_syms:
        sys.stdout.write("INPROGRESS\n")
        return
    if "__NOISY_OK__" in call_syms:
        # Model a well-meaning backend that emits the right token with trailing
        # whitespace / CRLF. The Marshal must still read it as SUCCESSFUL.
        sys.stdout.write("SUCCESSFUL \r\n")
        return
    def_set = set(symbols(defs))
    missing = [s for s in call_syms if s not in def_set]
    sys.stdout.write("FAILED\n" if missing else "SUCCESSFUL\n")


def cmd_pr_comment(st, repo, flags, state_path):
    num = flags.get("num")
    body_file = flags.get("body-file")
    if not num or num is True:
        die("pr-comment: --num required", 64)
    if not body_file or body_file is True:
        die("pr-comment: --body-file required", 64)
    with open(body_file) as f:
        body = f.read()
    st["comments"].append({"num": int(num), "body": body})
    save_state(state_path, st)


def cmd_pr_merge(st, repo, flags, state_path):
    num = flags.get("num")
    if not num or num is True:
        die("pr-merge: --num required", 64)
    num = int(num)
    strategy = flags.get("strategy")
    if strategy is True or not strategy:
        strategy = "merge-commit"
    pr = next((p for p in st["prs"] if p["num"] == num), None)
    if pr is None:
        die("pr-merge: unknown PR %s" % num, 1)
    if pr.get("fail_merge"):
        # Model a host that refuses the merge (branch protection, a race, a
        # transient error) even though the composed build was green.
        die("pr-merge: host refused merge of PR %s" % num, 1)
    trunk = st["trunk"]
    branch_ref = "refs/heads/%s" % pr["branch"]
    tip = rev_parse(repo, branch_ref)
    if not tip:
        die("pr-merge: branch tip missing for %s" % pr["branch"], 1)
    trunk_ref = "refs/heads/%s" % trunk
    trunk_tip = rev_parse(repo, trunk_ref)
    # Fast-forward trunk to the (already-rebased) branch tip when possible.
    rc, _ = git(repo, "merge-base", "--is-ancestor", trunk_ref, branch_ref)
    if trunk_tip == "" or rc == 0:
        git(repo, "update-ref", trunk_ref, tip)
    else:
        # Non-FF: synthesize a merge commit so trunk still advances deterministically.
        tree_rc, tree = git(repo, "rev-parse", "%s^{tree}" % branch_ref)
        if tree_rc == 0:
            env = dict(os.environ)
            env.update(GIT_AUTHOR_NAME="marshal-mock", GIT_AUTHOR_EMAIL="mock@local",
                       GIT_COMMITTER_NAME="marshal-mock", GIT_COMMITTER_EMAIL="mock@local")
            p = subprocess.run(
                ["git", "--git-dir", repo, "commit-tree", tree.strip(),
                 "-p", trunk_tip, "-p", tip, "-m", "merge PR %d" % num],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
            )
            if p.returncode == 0:
                git(repo, "update-ref", trunk_ref, p.stdout.decode().strip())
    st["merges"].append({"num": num, "strategy": strategy})
    save_state(state_path, st)


def cmd_pr_approve(st, repo, flags, state_path):
    num = flags.get("num")
    if not num or num is True:
        die("pr-approve: --num required", 64)
    for pr in st["prs"]:
        if pr["num"] == int(num):
            pr["approval"] = "APPROVED"
    save_state(state_path, st)


def cmd_pr_decline(st, repo, flags, state_path):
    num = flags.get("num")
    if not num or num is True:
        die("pr-decline: --num required", 64)
    for pr in st["prs"]:
        if pr["num"] == int(num):
            pr["declined"] = True
    save_state(state_path, st)


def main(argv):
    if not argv:
        die("usage: mock_host.py <subcommand> [args]", 64)
    sub = argv[0]
    flags = parse_flags(argv[1:])

    state_path = os.environ.get("MARSHAL_MOCK_STATE")
    repo = os.environ.get("MARSHAL_MOCK_REPO")
    if not state_path:
        die("MARSHAL_MOCK_STATE env required", 64)
    if not repo:
        die("MARSHAL_MOCK_REPO env required", 64)
    st = load_state(state_path)

    if sub == "backend":
        cmd_backend(st, repo, flags)
    elif sub == "pr-list-ready":
        cmd_pr_list_ready(st, repo, flags)
    elif sub == "build-status":
        cmd_build_status(st, repo, flags)
    elif sub == "pr-comment":
        cmd_pr_comment(st, repo, flags, state_path)
    elif sub == "pr-merge":
        cmd_pr_merge(st, repo, flags, state_path)
    elif sub == "pr-approve":
        cmd_pr_approve(st, repo, flags, state_path)
    elif sub == "pr-decline":
        cmd_pr_decline(st, repo, flags, state_path)
    else:
        die("unknown subcommand: %s" % sub, 64)


if __name__ == "__main__":
    main(sys.argv[1:])
