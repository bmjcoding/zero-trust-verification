#!/usr/bin/env python3
"""Org-Wide Memory (OWM) engine — the deterministic logic behind the thin .sh
wrappers (extract_memory.sh, crawl.sh, index_build.sh, query.sh, coverage.sh).

The index is a DERIVED VIEW over repo-resident memory, never a store of truth
(ADR 0019). Every record carries a {repo, commit_sha, path, source_line} back-
pointer. This module NEVER edits a repo file and NEVER writes back a fact.

Reuse discipline (OWM-01): the `manifest` memory-class is parsed by the
CANONICAL validator toolchain — `import validate_manifest` (the sibling
validate_manifest.py, the single canonical copy since ADR 0025; the V8
byte-identity lint retired with the vendored copies) — honoring its 0/3/4/5 exit
contract VERBATIM. Exit 4 (schema-invalid) / 5 (unsupported version) manifests are
indexed as `unparseable` carrying the validator's error + exit code, NEVER dropped
and NEVER re-parsed by a forked YAML reader. There is no second manifest parser in
this file.

Subcommands:
  extract <file> [--repo S] [--commit SHA] [--kind K]   -> OWM-01 typed extractors
  crawl --config C [--incremental --state S] [--trace-opens F]
        [--max-files N] [--max-bytes N]                 -> OWM-03 / 03a / 04
  index-build <records.jsonl> <out.db>                  -> OWM-05
  dump <db>                                             -> OWM-05 canonical dump
  query lookup|search|resolve|decisions <arg> --db D
        [--allow s,s] [--head SHAMAP]                   -> OWM-06 / 07 / 11 ACL
  coverage --db D                                       -> OWM-08

Portability: pure stdlib (json, sqlite3, re, glob) + the canonical validator's
ruamel.yaml/jsonschema (available via `uv run` against the plugin pyproject; ADR 0015).
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
from pathlib import Path

SCHEMA_VERSION = 1

# Every OWM-emitted artifact stamps this marker in a header so the crawler can
# SELF-EXCLUDE its own derived output — no citation loop can form (OWM-11b).
OWM_SELF_MARKER = "owm:self-emitted"

# ── OWM-03a: the CLOSED allow-list of memory globs. The crawler reads ONLY these
#    fixed relative patterns — never the code tree, never an arbitrary recursive
#    walk. Each pattern has at most one leaf wildcard. Adding a memory-class here
#    is the ONLY way to widen the read surface; there is no fall-through. ──────────
MEMORY_GLOBS = [
    ("adr", "docs/adr/*.md"),
    ("glossary", "CONTEXT.md"),
    ("manifest", "verification-manifest.yaml"),
    ("manifest", "verification-manifest.yml"),
    ("manifest", "docs/verification-manifest.yaml"),
    ("journey", "docs/journeys/*.md"),
    ("as-built", "docs/as-built/*.md"),
    ("decision-log", "docs/decisions/*.md"),
    ("decision-log", "DECISIONS.md"),
]

# Default per-repo read-surface ceiling (OWM-03a). Exceeding it is a loud
# `memory-surface-oversized` crawl_error, never a silent partial-then-hang.
DEFAULT_MAX_FILES = 500
DEFAULT_MAX_BYTES = 5_000_000

BODY_EXCERPT_MAX = 600

# import the CANONICAL manifest validator (single copy since ADR 0025) — never a fork.
_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))


def _kebab(s: str) -> str:
    s = s.strip().lower()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    return s.strip("-") or "unnamed"


def _excerpt(s: str) -> str:
    s = re.sub(r"\s+", " ", (s or "")).strip()
    return s[:BODY_EXCERPT_MAX]


def _org_id(repo: str, kind: str, name: str) -> str:
    return f"{repo}:{kind}:{_kebab(name)}"


def _record(kind, ident, repo, commit, path, title, body, **extra):
    rec = {
        "schema_version": SCHEMA_VERSION,
        "kind": kind,
        "id": ident,
        "org_id": _org_id(repo, kind, extra.pop("name", ident)),
        "repo": repo,
        "commit_sha": commit or "",
        "path": path,
        "title": title or "",
        "body_excerpt": _excerpt(body),
        "aliases": extra.pop("aliases", []),
    }
    for k, v in extra.items():
        if v is not None and v != "":
            rec[k] = v
    return rec


# =============================================================================
# OWM-01 — the typed extractors (one per memory-class; they do NOT share a shape)
# =============================================================================

def infer_kind(path: str) -> str:
    p = path.replace(os.sep, "/")
    base = p.rsplit("/", 1)[-1]
    if re.search(r"/docs/adr/\d+.*\.md$", "/" + p) or re.match(r"^\d{2,}-.*\.md$", base):
        return "adr"
    if base == "CONTEXT.md":
        return "glossary"
    if re.search(r"verification-manifest\.ya?ml$", base):
        return "manifest"
    if "/docs/journeys/" in "/" + p:
        return "journey"
    if "/docs/as-built/" in "/" + p:
        return "as-built"
    if base == "DECISIONS.md" or "/docs/decisions/" in "/" + p:
        return "decision-log"
    return "unknown"


def extract_adr(text, repo, commit, relpath):
    """ADR: H1 title on line 1, then a post-title YAML frontmatter block (--- on
    line 3). Fields: status {accepted, agent-decided}, date, optional
    superseded-by / amended-by. One decision per file; kebab filename = stable id."""
    lines = text.splitlines()
    title = ""
    if lines and lines[0].startswith("#"):
        title = lines[0].lstrip("#").strip()
    # locate the post-title frontmatter block
    fm = {}
    fence = [i for i, ln in enumerate(lines) if ln.strip() == "---"]
    if len(fence) >= 2 and fence[0] >= 1:
        for ln in lines[fence[0] + 1 : fence[1]]:
            m = re.match(r"^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$", ln)
            if m:
                fm[m.group(1).strip().lower()] = m.group(2).strip()
    body = "\n".join(lines[(fence[1] + 1) if len(fence) >= 2 else 1 :])
    base = relpath.rsplit("/", 1)[-1]
    name = re.sub(r"^\d+[-_]?", "", base)
    name = re.sub(r"\.md$", "", name) or base
    ident = _kebab(name)
    return [
        _record(
            "adr", ident, repo, commit, relpath, title, body,
            name=name,
            status=fm.get("status"),
            date=fm.get("date"),
            superseded_by=fm.get("superseded-by"),
            supersedes=fm.get("supersedes"),
            amended_by=fm.get("amended-by"),
        )
    ]


def extract_glossary(text, repo, commit, relpath):
    """CONTEXT.md: `**Term**:` blocks -> one term-definition record each, plus the
    `_Avoid_:` rejected synonyms as aliases (so a query for a rejected synonym
    resolves to the canonical term — the OWM-06 north star)."""
    lines = text.splitlines()
    recs = []
    i = 0
    n = len(lines)
    while i < n:
        m = re.match(r"^\*\*(.+?)\*\*:\s*$", lines[i].strip())
        if not m:
            i += 1
            continue
        term = m.group(1).strip()
        term_line = i + 1  # 1-based
        j = i + 1
        defn_lines = []
        aliases = []
        while j < n and not re.match(r"^\*\*(.+?)\*\*:\s*$", lines[j].strip()):
            av = re.match(r"^_Avoid_:\s*(.+)$", lines[j].strip())
            if av:
                aliases = [a.strip() for a in re.split(r",", av.group(1)) if a.strip()]
            elif lines[j].strip():
                defn_lines.append(lines[j].strip())
            j += 1
        recs.append(
            _record(
                "glossary", _kebab(term), repo, commit, relpath, term,
                " ".join(defn_lines), name=term, aliases=aliases, source_line=term_line,
            )
        )
        i = j
    return recs


def extract_decision_log(text, repo, commit, relpath):
    """Greppable DL-### one-line entries (PR bodies, trackers, DECISIONS.md).
    One append-only event per line, keyed by (repo, sha)."""
    recs = []
    seen = set()
    for idx, ln in enumerate(text.splitlines(), start=1):
        for m in re.finditer(r"\bDL-(\d+)\b", ln):
            dl = "DL-" + m.group(1)
            key = (dl, idx)
            if key in seen:
                continue
            seen.add(key)
            recs.append(
                _record(
                    "decision-log", dl, repo, commit, relpath, dl,
                    ln.strip(), name=f"{dl}-l{idx}", source_line=idx,
                )
            )
    return recs


def extract_prose(kind, text, repo, commit, relpath):
    """journey / as-built docs: indexed as PROSE records (retrieval, not structural
    claims) with their source pointer."""
    lines = text.splitlines()
    title = lines[0].lstrip("#").strip() if lines and lines[0].startswith("#") else relpath.rsplit("/", 1)[-1]
    name = _kebab(re.sub(r"\.md$", "", relpath.rsplit("/", 1)[-1]))
    return [_record(kind, name, repo, commit, relpath, title, text, name=name)]


def extract_manifest(path: Path, repo, commit, relpath):
    """Verification Manifest: parsed by the CANONICAL validate_manifest toolchain
    (never a forked parser). Honors the 0/3/4/5 exit contract verbatim: exit 4/5
    -> the file is indexed as `unparseable` carrying the validator error + code,
    NEVER dropped. Exit 0/3 -> harvest spec/journeys/behaviors + interrogation.log."""
    import validate_manifest as vm  # the canonical validator (single copy, ADR 0025)

    # ONE parse (ADR 0032): load through the public API, validate the mapping in
    # memory — same 0/3/4/5 contract as validate_file, no second read of the file.
    data, err = vm.load_manifest(path)
    if err is not None:
        code, lines = vm.EXIT_SCHEMA_INVALID, [err]
    else:
        code, lines = vm.validate_mapping(data)
    if code in (vm.EXIT_SCHEMA_INVALID, vm.EXIT_UNSUPPORTED):
        ec = "manifest-schema-invalid" if code == vm.EXIT_SCHEMA_INVALID else "manifest-unsupported-version"
        name = _kebab(re.sub(r"\.ya?ml$", "", relpath.rsplit("/", 1)[-1]))
        return [
            _record(
                "unparseable", name, repo, commit, relpath,
                relpath.rsplit("/", 1)[-1], "; ".join(lines),
                name=name, status=ec, error_code=ec,
            )
        ]
    # exit 0/3 guarantees a mapping (validate_mapping returns 4 for non-dicts).

    recs = []
    spec = data.get("spec", {}) or {}
    title = spec.get("title") or relpath
    journeys = data.get("journeys", []) or []
    behaviors = data.get("behaviors", []) or []
    j_summ = ", ".join(f"{j.get('id')}:{j.get('criticality')}" for j in journeys if isinstance(j, dict))
    b_summ = ", ".join(f"{b.get('id')}:{b.get('lifecycle')}" for b in behaviors if isinstance(b, dict))
    body = (
        f"spec={spec.get('path')} title={title} "
        f"schema_version={data.get('schema_version')} manifest_revision={data.get('manifest_revision')} "
        f"journeys=[{j_summ}] behaviors=[{b_summ}]"
    )
    recs.append(
        _record(
            "manifest", _kebab(title), repo, commit, relpath, title, body,
            name=title, status=data.get("completeness"), spec_hash=spec.get("spec_hash"),
        )
    )
    # journeys are first-class retrievable records (id, criticality)
    for j in journeys:
        if not isinstance(j, dict) or not j.get("id"):
            continue
        recs.append(
            _record(
                "journey", j["id"], repo, commit, relpath,
                j.get("name", j["id"]),
                f"{j.get('name','')} criticality={j.get('criticality')} lifecycle={j.get('lifecycle')}",
                name=j["id"], status=j.get("criticality"),
            )
        )
    # interrogation.log DL entries -> decision-log records (ADR 0002 / CONTEXT.md)
    log = ((data.get("interrogation") or {}).get("log")) or []
    for e in log:
        if not isinstance(e, dict) or not e.get("id"):
            continue
        recs.append(
            _record(
                "decision-log", e["id"], repo, commit, relpath,
                e["id"], e.get("summary", ""),
                name=f"{e['id']}", status=e.get("resolved_by"),
            )
        )
    return recs


def extract_file(path, repo="local", commit="", kind=None, relpath=None):
    p = Path(path)
    relpath = relpath or p.name
    kind = kind or infer_kind(str(path))
    if kind == "manifest":
        return extract_manifest(p, repo, commit, relpath)
    text = p.read_text(encoding="utf-8", errors="replace")
    if kind == "adr":
        return extract_adr(text, repo, commit, relpath)
    if kind == "glossary":
        return extract_glossary(text, repo, commit, relpath)
    if kind == "decision-log":
        return extract_decision_log(text, repo, commit, relpath)
    if kind in ("journey", "as-built"):
        return extract_prose(kind, text, repo, commit, relpath)
    # unknown kind: index as prose-ish so nothing is silently dropped
    return extract_prose("as-built", text, repo, commit, relpath)


# =============================================================================
# OWM-03 / 03a / 04 — the crawler (config-first, bounded read surface, incremental)
# =============================================================================

def _load_config(path):
    """Repo-list config: JSON (or the trivial YAML subset the fixtures use).
    { "repos": [ {slug, path, ref?, head_sha?} ... ], "allow"?: [slug...],
      "self_exclude"?: [glob...] }"""
    raw = Path(path).read_text(encoding="utf-8")
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        import validate_manifest as vm  # the public YAML 1.2 load API (ADR 0032)
        data, err = vm.load_manifest(Path(path))
        if err:
            raise SystemExit(f"owm crawl: cannot parse config {path}: {err}")
        return data


def _repo_sha(repo_dir: Path, declared):
    if declared:
        return declared
    marker = repo_dir / ".owm-sha"
    if marker.is_file():
        return marker.read_text(encoding="utf-8").strip()
    # a real git checkout: read the pinned HEAD without walking the tree
    try:
        import subprocess

        out = subprocess.run(
            ["git", "-C", str(repo_dir), "rev-parse", "HEAD"],
            capture_output=True, text=True,
        )
        if out.returncode == 0:
            return out.stdout.strip()
    except Exception:
        pass
    return ""


def _glob_memory_files(repo_dir: Path):
    """Yield (kind, abs_path, relpath) for ONLY the closed memory-glob allow-list.
    Deterministic (LC_ALL=C sort). Never recurses outside the declared patterns."""
    out = []
    for kind, pattern in MEMORY_GLOBS:
        for ap in sorted(repo_dir.glob(pattern)):
            if ap.is_file():
                out.append((kind, ap, str(ap.relative_to(repo_dir)).replace(os.sep, "/")))
    # stable order by (relpath, kind)
    out.sort(key=lambda t: (t[2], t[0]))
    return out


def _is_self_emitted(ap: Path):
    """Self-exclusion (OWM-11b): skip any file OWM itself emitted (carrying the
    owm:self-emitted marker) so no citation loop forms. Scans up to 1MB — the marker
    is a header contract (OWM stamps it as the first line/key of every artifact), but
    the generous bound also catches a marker anywhere in a realistically-sized memory
    doc, not just the first 2KB."""
    try:
        head = ap.read_text(encoding="utf-8", errors="replace")[:1_000_000]
    except Exception:
        return False
    return OWM_SELF_MARKER in head


def crawl(config_path, incremental=False, state_path=None, trace_opens=None,
          max_files=DEFAULT_MAX_FILES, max_bytes=DEFAULT_MAX_BYTES, out=sys.stdout):
    cfg = _load_config(config_path)
    repos = cfg.get("repos", []) or []
    self_exclude = cfg.get("self_exclude", []) or []
    base = Path(config_path).resolve().parent

    prev_state = {}
    if incremental and state_path and Path(state_path).is_file():
        prev_state = json.loads(Path(state_path).read_text(encoding="utf-8"))

    opened = []
    records = []
    new_state = dict(prev_state)

    for r in repos:
        slug = r.get("slug")
        rpath = r.get("path")
        if not slug or not rpath:
            continue
        repo_dir = (base / rpath).resolve() if not os.path.isabs(rpath) else Path(rpath)
        sha = _repo_sha(repo_dir, r.get("ref") or r.get("head_sha"))
        if not repo_dir.is_dir():
            records.append(
                _record("crawl_error", _kebab(slug), slug, sha, rpath, slug,
                        f"repo path not found: {rpath}", name=slug,
                        status="repo-unreachable", error_code="repo-unreachable")
            )
            new_state[slug] = sha
            continue

        # OWM-04: incremental no-op on an unchanged head.
        if incremental and prev_state.get(slug) == sha and sha:
            sys.stderr.write(f"SKIPPED unchanged repo={slug} sha={sha}\n")
            continue
        if incremental:
            sys.stderr.write(f"RECRAWL repo={slug} sha={sha}\n")

        files = _glob_memory_files(repo_dir)
        # apply self-exclusion + explicit config self_exclude globs
        kept = []
        for kind, ap, rel in files:
            if _is_self_emitted(ap):
                continue
            if any(Path(rel).match(g) or Path(rel).match(g.lstrip("./")) for g in self_exclude):
                continue
            kept.append((kind, ap, rel))

        # OWM-03a: HARD per-repo ceiling BEFORE opening file contents.
        total_bytes = 0
        oversized = False
        for _, ap, _rel in kept:
            try:
                total_bytes += ap.stat().st_size
            except OSError:
                pass
        if len(kept) > max_files or total_bytes > max_bytes:
            records.append(
                _record("crawl_error", _kebab(slug), slug, sha, rpath, slug,
                        f"memory surface too large: files={len(kept)} bytes={total_bytes} "
                        f"(ceiling files={max_files} bytes={max_bytes})",
                        name=slug, status="memory-surface-oversized",
                        error_code="memory-surface-oversized")
            )
            new_state[slug] = sha
            oversized = True
        if oversized:
            continue

        for kind, ap, rel in kept:
            opened.append(rel)
            try:
                recs = extract_file(ap, repo=slug, commit=sha, kind=kind, relpath=rel)
            except Exception as exc:  # per-file isolation: one bad file never kills the crawl
                records.append(
                    _record("unparseable", _kebab(rel), slug, sha, rel, rel,
                            f"extractor error: {exc}", name=rel,
                            status="extractor-error", error_code="extractor-error")
                )
                continue
            records.extend(recs)
        new_state[slug] = sha

    # deterministic ordering (LC_ALL=C stable): by org_id then path then id
    records.sort(key=lambda r: (r["org_id"], r["path"], r.get("source_line", 0)))
    for rec in records:
        out.write(json.dumps(rec, sort_keys=True, ensure_ascii=False) + "\n")

    if trace_opens:
        Path(trace_opens).write_text("\n".join(opened) + ("\n" if opened else ""), encoding="utf-8")
    if state_path:
        Path(state_path).write_text(json.dumps(new_state, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return 0


# =============================================================================
# OWM-05 — the index: single-file SQLite + FTS5
# =============================================================================

_COLS = [
    "org_id", "kind", "id", "repo", "commit_sha", "path", "source_line",
    "title", "status", "date", "body_excerpt", "aliases_json",
    "supersedes", "superseded_by", "spec_hash", "error_code",
]


def _connect(db_path):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn


def index_build(records_jsonl, db_path):
    recs = []
    with open(records_jsonl, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                recs.append(json.loads(line))
    # rebuild-from-empty is always correct: drop and recreate.
    if os.path.exists(db_path):
        os.remove(db_path)
    conn = _connect(db_path)
    conn.execute(
        "CREATE TABLE records (rowid INTEGER PRIMARY KEY, "
        + ", ".join(f"{c} TEXT" for c in _COLS if c != "source_line")
        + ", source_line INTEGER, record_json TEXT)"
    )
    conn.execute("CREATE INDEX idx_org ON records(org_id)")
    conn.execute(
        "CREATE VIRTUAL TABLE records_fts USING fts5("
        "org_id UNINDEXED, repo UNINDEXED, kind UNINDEXED, title, body_excerpt, aliases)"
    )
    conn.execute("CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT)")
    conn.execute("INSERT INTO meta(k,v) VALUES('schema_version', ?)", (str(SCHEMA_VERSION),))
    conn.execute("INSERT INTO meta(k,v) VALUES('crawled_at', ?)", (_now_iso(),))

    # deterministic insertion order -> a byte-stable canonical dump on rebuild.
    recs.sort(key=lambda r: (r.get("org_id", ""), r.get("path", ""), r.get("source_line", 0)))
    for r in recs:
        aliases = r.get("aliases", []) or []
        vals = {
            "org_id": r.get("org_id", ""),
            "kind": r.get("kind", ""),
            "id": r.get("id", ""),
            "repo": r.get("repo", ""),
            "commit_sha": r.get("commit_sha", ""),
            "path": r.get("path", ""),
            "source_line": r.get("source_line"),
            "title": r.get("title", ""),
            "status": r.get("status", ""),
            "date": r.get("date", ""),
            "body_excerpt": r.get("body_excerpt", ""),
            "aliases_json": json.dumps(aliases, sort_keys=True),
            "supersedes": r.get("supersedes", ""),
            "superseded_by": r.get("superseded_by", ""),
            "spec_hash": r.get("spec_hash", ""),
            "error_code": r.get("error_code", ""),
        }
        cols = list(vals.keys()) + ["record_json"]
        cur = conn.execute(
            f"INSERT INTO records ({', '.join(cols)}) VALUES ({', '.join('?' for _ in cols)})",
            [vals[c] for c in vals] + [json.dumps(r, sort_keys=True, ensure_ascii=False)],
        )
        # bind the FTS row to THIS record's rowid directly (robust: no reliance on a
        # unique key over (org_id, path, source_line), which duplicate DL lines could break).
        conn.execute(
            "INSERT INTO records_fts (rowid, org_id, repo, kind, title, body_excerpt, aliases) "
            "VALUES (?,?,?,?,?,?,?)",
            (cur.lastrowid, vals["org_id"], vals["repo"], vals["kind"], vals["title"],
             vals["body_excerpt"], " ".join(aliases)),
        )
    conn.commit()
    conn.close()
    return 0


def _now_iso():
    # crawl timestamp for freshness (OWM-07). Excluded from the canonical dump so
    # rebuilds stay byte-comparable.
    import datetime

    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()


def dump(db_path, out=sys.stdout):
    """Canonical, byte-stable dump of the records table (excludes the nondeterministic
    meta timestamps) — two rebuilds from the same input dump identically (OWM-05)."""
    conn = _connect(db_path)
    rows = conn.execute("SELECT record_json FROM records ORDER BY org_id, path, IFNULL(source_line,0)").fetchall()
    for row in rows:
        rec = json.loads(row["record_json"])
        out.write(json.dumps(rec, sort_keys=True, ensure_ascii=False) + "\n")
    conn.close()
    return 0


# =============================================================================
# OWM-06 / 07 / 11 — the query surface (ACL refuse-by-default + freshness)
# =============================================================================

def _row_to_record(row):
    return json.loads(row["record_json"])


def _crawled_at(conn):
    r = conn.execute("SELECT v FROM meta WHERE k='crawled_at'").fetchone()
    return r["v"] if r else None


def _with_freshness(rec, conn, head_map):
    """OWM-07: attach indexed_at_sha + crawl timestamp; possibly_stale ONLY when the
    repo's head is known (UNKNOWN-safe — absent, never a false 'fresh')."""
    rec = dict(rec)
    rec["indexed_at_sha"] = rec.get("commit_sha", "")
    ca = _crawled_at(conn)
    if ca:
        rec["crawled_at"] = ca
    head = head_map.get(rec.get("repo"))
    if head:
        rec["head_sha"] = head
        rec["possibly_stale"] = head != rec.get("commit_sha", "")
    return rec


def _acl_ok(repo, allow):
    # refuse-by-default ACL. allow is None => serve-all (the explicit --all operator
    # escape); allow is a list => only its repos pass ([] => refuse EVERYTHING, the
    # safe default when no scope is granted).
    return allow is None or repo in allow


def _parse_allow(allow_s, all_flag):
    """Resolve the ACL from CLI flags. --all => None (serve-all, explicit opt-in);
    --allow s,s => that list; NEITHER => [] (refuse-by-default: no scope granted, so
    nothing is served — the safe default on the retrieval source of truth)."""
    if all_flag:
        return None
    if allow_s is not None:
        return [x.strip() for x in allow_s.split(",") if x.strip()]
    return []


def _refusal(repo, org_id=None):
    return {
        "refused": True,
        "reason": f"repo '{repo}' is outside the configured allow-list (refuse-by-default, OWM-11 / ADR 0019)",
        "repo": repo,
        "org_id": org_id,
    }


def query(sub, arg, db_path, allow=None, head_map=None):
    head_map = head_map or {}
    conn = _connect(db_path)
    try:
        if sub == "lookup":
            row = conn.execute("SELECT * FROM records WHERE org_id=?", (arg,)).fetchone()
            if not row:
                return {"found": False, "org_id": arg}
            if not _acl_ok(row["repo"], allow):
                return _refusal(row["repo"], arg)
            return {"found": True, "record": _with_freshness(_row_to_record(row), conn, head_map)}

        if sub == "resolve":
            key = _kebab(arg)
            # exact canonical term first, then an _Avoid_ alias -> canonical term.
            row = conn.execute(
                "SELECT * FROM records WHERE kind='glossary' AND id=?", (key,)
            ).fetchone()
            if not row:
                for cand in conn.execute("SELECT * FROM records WHERE kind='glossary'").fetchall():
                    aliases = json.loads(cand["aliases_json"] or "[]")
                    if any(_kebab(a) == key for a in aliases) or _kebab(cand["title"]) == key:
                        row = cand
                        break
            if not row:
                return {"resolved": False, "query": arg}
            if not _acl_ok(row["repo"], allow):
                return _refusal(row["repo"])
            return {"resolved": True, "record": _with_freshness(_row_to_record(row), conn, head_map)}

        if sub in ("search", "decisions"):
            match = _fts_query(arg)
            if sub == "decisions":
                sql = (
                    "SELECT r.* FROM records_fts f JOIN records r ON r.rowid=f.rowid "
                    "WHERE records_fts MATCH ? AND r.kind IN ('adr','decision-log') "
                    "ORDER BY bm25(records_fts)"
                )
            else:
                sql = (
                    "SELECT r.* FROM records_fts f JOIN records r ON r.rowid=f.rowid "
                    "WHERE records_fts MATCH ? ORDER BY bm25(records_fts)"
                )
            results = []
            refused_repos = set()
            for row in conn.execute(sql, (match,)).fetchall():
                if not _acl_ok(row["repo"], allow):
                    refused_repos.add(row["repo"])  # never the record (OWM-11a)
                    continue
                rec = _with_freshness(_row_to_record(row), conn, head_map)
                # supersession-aware (OWM-06): a superseded record is FLAGGED, never live.
                rec["superseded"] = bool(rec.get("superseded_by"))
                results.append(rec)
            resp = {"query": arg, "count": len(results), "results": results}
            if refused_repos:
                resp["refused_repos"] = sorted(refused_repos)
            return resp

        raise SystemExit(f"owm query: unknown subcommand '{sub}'")
    finally:
        conn.close()


def _fts_query(arg):
    # sanitize free text into a safe FTS5 MATCH (OR of bare terms); avoids syntax
    # errors on punctuation while keeping it deterministic.
    terms = re.findall(r"[A-Za-z0-9_]+", arg)
    if not terms:
        return '""'
    return " OR ".join(f'"{t}"' for t in terms)


# =============================================================================
# OWM-08 — coverage / crawl-error report ("what do we NOT know")
# =============================================================================

def coverage(db_path, allow=None, out=sys.stdout):
    """OWM-08. When `allow` is set, the report is SCOPED to the allow-list — repo names,
    kind counts, and error paths from out-of-scope repos are NOT disclosed (the same
    refuse-by-default posture the query tools enforce; the MCP resource always passes it)."""
    conn = _connect(db_path)
    by_kind = {}
    repos = []
    errors = []
    for row in conn.execute("SELECT DISTINCT repo FROM records ORDER BY repo").fetchall():
        if _acl_ok(row["repo"], allow):
            repos.append(row["repo"])
    for row in conn.execute("SELECT kind, repo, COUNT(*) c FROM records GROUP BY kind, repo").fetchall():
        if _acl_ok(row["repo"], allow):
            by_kind[row["kind"]] = by_kind.get(row["kind"], 0) + row["c"]
    for row in conn.execute(
        "SELECT * FROM records WHERE kind IN ('crawl_error','unparseable') "
        "ORDER BY repo, path"
    ).fetchall():
        if not _acl_ok(row["repo"], allow):
            continue
        errors.append({
            "repo": row["repo"], "path": row["path"],
            "error_code": row["error_code"] or row["status"],
            "detail": row["body_excerpt"],
            "commit_sha": row["commit_sha"],
        })
    report = {
        OWM_SELF_MARKER: True,  # self-exclusion: this artifact is never re-ingested
        "schema_version": SCHEMA_VERSION,
        "scoped_to_allow_list": allow is not None,
        "repos_crawled": repos,
        "records_by_kind": by_kind,
        "crawl_errors": errors,
        "crawl_error_count": len(errors),
    }
    out.write(json.dumps(report, sort_keys=True, indent=2, ensure_ascii=False) + "\n")
    conn.close()
    return 0


# =============================================================================
# CLI
# =============================================================================

def _parse_kv_list(s):
    d = {}
    for part in (s or "").split(","):
        part = part.strip()
        if not part:
            continue
        if "=" in part:
            k, v = part.split("=", 1)
            d[k.strip()] = v.strip()
    return d


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 64
    cmd = argv[1]
    args = argv[2:]

    def opt(name, default=None):
        if name in args:
            i = args.index(name)
            return args[i + 1] if i + 1 < len(args) else default
        return default

    def flag(name):
        return name in args

    def positionals():
        out = []
        skip = False
        known_val = {"--repo", "--commit", "--kind", "--config", "--state",
                     "--trace-opens", "--max-files", "--max-bytes", "--db",
                     "--allow", "--head"}
        for i, a in enumerate(args):
            if skip:
                skip = False
                continue
            if a in known_val:
                skip = True
                continue
            if a.startswith("--"):
                continue
            out.append(a)
        return out

    if cmd == "extract":
        pos = positionals()
        if not pos:
            print("usage: owm.py extract <file> [--repo S --commit SHA --kind K]", file=sys.stderr)
            return 64
        recs = extract_file(pos[0], repo=opt("--repo", "local"),
                            commit=opt("--commit", ""), kind=opt("--kind"))
        for r in recs:
            print(json.dumps(r, sort_keys=True, ensure_ascii=False))
        return 0

    if cmd == "crawl":
        cfg = opt("--config")
        if not cfg:
            print("usage: owm.py crawl --config C [--incremental --state S]", file=sys.stderr)
            return 64
        return crawl(
            cfg, incremental=flag("--incremental"), state_path=opt("--state"),
            trace_opens=opt("--trace-opens"),
            max_files=int(opt("--max-files", DEFAULT_MAX_FILES)),
            max_bytes=int(opt("--max-bytes", DEFAULT_MAX_BYTES)),
        )

    if cmd == "index-build":
        pos = positionals()
        if len(pos) < 2:
            print("usage: owm.py index-build <records.jsonl> <out.db>", file=sys.stderr)
            return 64
        return index_build(pos[0], pos[1])

    if cmd == "dump":
        pos = positionals()
        if not pos:
            print("usage: owm.py dump <db>", file=sys.stderr)
            return 64
        return dump(pos[0])

    if cmd == "query":
        pos = positionals()
        if len(pos) < 2:
            print("usage: owm.py query <lookup|search|resolve|decisions> <arg> --db D [--allow s,s | --all] [--head r=sha]", file=sys.stderr)
            return 64
        allow = _parse_allow(opt("--allow"), flag("--all"))
        head_map = _parse_kv_list(opt("--head"))
        res = query(pos[0], pos[1], opt("--db"), allow=allow, head_map=head_map)
        print(json.dumps(res, sort_keys=True, ensure_ascii=False, indent=2))
        # a targeted refusal is a distinct exit so callers can branch (3 = refused).
        if isinstance(res, dict) and res.get("refused"):
            return 3
        return 0

    if cmd == "coverage":
        db = opt("--db")
        if not db:
            print("usage: owm.py coverage --db D [--allow s,s | --all]", file=sys.stderr)
            return 64
        allow = _parse_allow(opt("--allow"), flag("--all"))
        return coverage(db, allow=allow)

    print(f"owm.py: unknown command '{cmd}'", file=sys.stderr)
    return 64


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
