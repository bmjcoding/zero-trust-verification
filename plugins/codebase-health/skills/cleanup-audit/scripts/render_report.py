#!/usr/bin/env python3
"""Render a Codebase Health markdown report into a self-contained HTML view.

Designed for locked-down/offline environments: NO pip dependencies, NO CDN.
All CSS is inlined; a small built-in markdown subset is parsed in pure stdlib.
Reading HTML is nicer than markdown for human review (Pocock improve-arch style).

Usage:
    python render_report.py audit/HEALTH_REPORT.md [-o audit/HEALTH_REPORT.html] [--title "..."]

Supported markdown: headings (#..####), tables (GFM pipe), fenced code blocks,
unordered/ordered lists, bold/italic/inline-code, links, blockquotes, hr, paragraphs.
Severity words (CRITICAL/HIGH/MED/LOW, SAFE/CAUTION/DANGER, Strong/Worth exploring/
Speculative), verify statuses (OPEN/PARTIAL/FIXED/REGRESSED/STALE/WONTFIX) and
journey verdicts (WORKS/BROKEN/DEGRADED) auto-render as colored pills in table
cells and in '### [SEVERITY] title' finding headings.
"""
from __future__ import annotations
import argparse, html, re, sys
from pathlib import Path

SEVERITY = {
    r"\bCRITICAL\b": "crit", r"\bHIGH\b": "high", r"\bMED(?:IUM)?\b": "med",
    r"\bLOW\b": "low", r"\bDANGER\b": "crit", r"\bCAUTION\b": "med",
    r"\bSAFE\b": "safe", r"\bStrong\b": "high", r"\bWorth exploring\b": "med",
    r"\bSpeculative\b": "low", r"\bneeds[- ]verification\b": "med",
    r"\bneeds human review\b": "med",
    # /verify statuses
    r"\bOPEN\b": "high", r"\bPARTIAL\b": "med", r"\bFIXED\b": "safe",
    r"\bREGRESSED\b": "crit", r"\bSTALE\b": "med", r"\bWONTFIX\b": "low",
    # journey verdicts
    r"\bWORKS\b": "safe", r"\bBROKEN\b": "crit", r"\bDEGRADED\b": "med",
}

def esc(s: str) -> str:
    return html.escape(s, quote=False)

def inline(text: str) -> str:
    """Inline markdown -> HTML. Order matters: code first to protect contents."""
    out, i, n = [], 0, len(text)
    # protect inline code spans
    parts = re.split(r"(`[^`]+`)", text)
    for part in parts:
        if part.startswith("`") and part.endswith("`") and len(part) >= 2:
            out.append(f"<code>{esc(part[1:-1])}</code>")
        else:
            s = esc(part)
            s = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)",
                       r'<a href="\2" target="_blank" rel="noopener">\1</a>', s)
            s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
            s = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", s)
            out.append(s)
    return "".join(out)

def sev_class(cell_text: str) -> str | None:
    up = cell_text.strip()
    for pat, cls in SEVERITY.items():
        if re.fullmatch(pat, up, re.I):
            return cls
    return None

# Matches the taxonomy's per-finding heading format: "### [HIGH] title".
# Bracket form only — a bare leading word would false-positive on ordinary
# headings like "Safe Deletion Workflow" or "High-level overview".
HEADING_SEV = re.compile(
    r"^\[(CRITICAL|HIGH|MED(?:IUM)?|LOW|SAFE|CAUTION|DANGER)\]\s+(.+)$", re.I)

def render_heading_text(txt: str) -> str:
    """Pill-ify '[SEVERITY]' at the start of a heading — the per-finding report
    format is a heading + bullets, not a table, so table-cell pills alone would
    miss most findings."""
    m = HEADING_SEV.match(txt.strip())
    if not m:
        return inline(txt)
    cls = sev_class(m.group(1)) or "low"
    return f'<span class="pill {cls}">{esc(m.group(1).upper())}</span> {inline(m.group(2))}'

def render_cell(cell: str) -> str:
    cls = sev_class(cell)
    if cls:
        return f'<td><span class="pill {cls}">{esc(cell.strip())}</span></td>'
    # also pill-ify a leading tag token like "IL-H1" left as plain text — keep plain
    return f"<td>{inline(cell.strip())}</td>"

def parse(md: str) -> tuple[str, str]:
    lines = md.splitlines()
    htmlout: list[str] = []
    i, n = 0, len(lines)
    toc: list[tuple[int, str, str]] = []

    def slug(t: str) -> str:
        return re.sub(r"[^a-z0-9]+", "-", t.lower()).strip("-")

    while i < n:
        line = lines[i]

        # fenced code
        if line.lstrip().startswith("```"):
            i += 1
            buf = []
            while i < n and not lines[i].lstrip().startswith("```"):
                buf.append(lines[i]); i += 1
            i += 1
            htmlout.append(f"<pre><code>{esc(chr(10).join(buf))}</code></pre>")
            continue

        # heading
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            lvl = len(m.group(1)); txt = m.group(2).strip()
            sid = slug(txt)
            if lvl in (1, 2):
                toc.append((lvl, txt, sid))
            htmlout.append(f'<h{lvl} id="{sid}">{render_heading_text(txt)}</h{lvl}>')
            i += 1
            continue

        # hr
        if re.match(r"^\s*---\s*$", line):
            htmlout.append("<hr/>"); i += 1; continue

        # table (header row + separator). Require a real pipe row (>=2 pipes or
        # leading |) so a paragraph merely containing "|" can't be misparsed.
        if (line.count("|") >= 2 or line.lstrip().startswith("|")) and i + 1 < n \
                and re.match(r"^\s*\|?\s*:?-{2,}", lines[i+1].replace(" ", "")):
            def cells(row: str) -> list[str]:
                # split on pipes that are neither escaped nor inside `code spans`
                # (finding evidence routinely contains `a | b` in backticks)
                row = row.strip()
                if row.startswith("|"): row = row[1:]
                if row.endswith("|"): row = row[:-1]
                out, buf, in_code, k = [], [], False, 0
                while k < len(row):
                    ch = row[k]
                    if ch == "`":
                        in_code = not in_code; buf.append(ch)
                    elif ch == "\\" and k + 1 < len(row) and row[k+1] == "|":
                        buf.append("|"); k += 1
                    elif ch == "|" and not in_code:
                        out.append("".join(buf).strip()); buf = []
                    else:
                        buf.append(ch)
                    k += 1
                out.append("".join(buf).strip())
                return out
            header = cells(line); i += 2
            body = []
            # a body row must look like a row (leading | or >=2 pipes) — prose
            # after the table that merely contains one "|" is NOT a row
            while i < n and lines[i].strip() and \
                    (lines[i].lstrip().startswith("|") or lines[i].count("|") >= 2):
                body.append(cells(lines[i])); i += 1
            thead = "".join(f"<th>{inline(c)}</th>" for c in header)
            rows = []
            for r in body:
                if len(r) > len(header):  # never silently drop cell content
                    r = r[:len(header) - 1] + [" | ".join(r[len(header) - 1:])]
                r = r + [""] * (len(header) - len(r))
                rows.append("<tr>" + "".join(render_cell(c) for c in r) + "</tr>")
            htmlout.append(f'<div class="tablewrap"><table><thead><tr>{thead}</tr></thead><tbody>{"".join(rows)}</tbody></table></div>')
            continue

        # blockquote
        if line.startswith(">"):
            buf = []
            while i < n and lines[i].startswith(">"):
                buf.append(lines[i][1:].strip()); i += 1
            htmlout.append(f"<blockquote>{inline(' '.join(buf))}</blockquote>")
            continue

        # lists
        if re.match(r"^\s*[-*]\s+", line):
            buf = []
            while i < n and re.match(r"^\s*[-*]\s+", lines[i]):
                buf.append(re.sub(r"^\s*[-*]\s+", "", lines[i])); i += 1
            htmlout.append("<ul>" + "".join(f"<li>{inline(x)}</li>" for x in buf) + "</ul>")
            continue
        if re.match(r"^\s*\d+\.\s+", line):
            buf = []
            while i < n and re.match(r"^\s*\d+\.\s+", lines[i]):
                buf.append(re.sub(r"^\s*\d+\.\s+", "", lines[i])); i += 1
            htmlout.append("<ol>" + "".join(f"<li>{inline(x)}</li>" for x in buf) + "</ol>")
            continue

        # blank
        if not line.strip():
            i += 1; continue

        # paragraph (gather until blank/structural)
        buf = [line]; i += 1
        while i < n and lines[i].strip() and not re.match(r"^(#{1,6}\s|\s*[-*]\s|\s*\d+\.\s|>|```)", lines[i]) and "|" not in lines[i]:
            buf.append(lines[i]); i += 1
        htmlout.append(f"<p>{inline(' '.join(buf))}</p>")

    # build TOC
    toc_html = ""
    if toc:
        items = "".join(
            f'<a class="toc-l{lvl}" href="#{sid}">{esc(txt)}</a>' for lvl, txt, sid in toc
        )
        toc_html = f'<nav class="toc"><div class="toc-title">Contents</div>{items}</nav>'
    return toc_html, "\n".join(htmlout)

CSS = """
:root{--bg:#fafaf9;--fg:#1e293b;--muted:#64748b;--card:#fff;--line:#e2e8f0;
--accent:#4f46e5;--crit:#b91c1c;--crit-bg:#fee2e2;--high:#c2410c;--high-bg:#ffedd5;
--med:#a16207;--med-bg:#fef9c3;--low:#475569;--low-bg:#f1f5f9;--safe:#15803d;--safe-bg:#dcfce7;}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;}
.layout{display:grid;grid-template-columns:260px minmax(0,1fr);max-width:1180px;margin:0 auto;}
.toc{position:sticky;top:0;align-self:start;height:100vh;overflow:auto;padding:32px 18px;
border-right:1px solid var(--line);font-size:14px;}
.toc-title{font-weight:700;text-transform:uppercase;letter-spacing:.08em;font-size:11px;
color:var(--muted);margin-bottom:12px;}
.toc a{display:block;color:var(--muted);text-decoration:none;padding:3px 0;border-left:2px solid transparent;padding-left:10px;}
.toc a:hover{color:var(--accent);border-left-color:var(--accent);}
.toc-l2{padding-left:22px;font-size:13px;}
main{padding:40px 48px;min-width:0;}
h1{font-size:30px;line-height:1.2;margin:.2em 0 .4em;letter-spacing:-.02em;}
h2{font-size:23px;margin:1.8em 0 .5em;padding-bottom:.25em;border-bottom:2px solid var(--line);letter-spacing:-.01em;}
h3{font-size:18px;margin:1.5em 0 .4em;}
h4{font-size:15px;margin:1.3em 0 .3em;color:var(--muted);text-transform:uppercase;letter-spacing:.05em;}
p{margin:.6em 0;} a{color:var(--accent);}
code{font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
background:#f1f5f9;padding:1px 5px;border-radius:4px;color:#0f172a;}
pre{background:#0f172a;color:#e2e8f0;padding:16px 18px;border-radius:10px;overflow:auto;}
pre code{background:none;color:inherit;padding:0;font-size:12.5px;}
blockquote{margin:1em 0;padding:.4em 1em;border-left:4px solid var(--accent);
background:#eef2ff;color:#3730a3;border-radius:0 8px 8px 0;}
hr{border:0;border-top:1px solid var(--line);margin:2em 0;}
ul,ol{padding-left:1.3em;} li{margin:.2em 0;}
.tablewrap{overflow:auto;margin:1em 0;border:1px solid var(--line);border-radius:10px;}
table{border-collapse:collapse;width:100%;font-size:14px;}
th{background:#f8fafc;text-align:left;font-weight:600;padding:9px 12px;border-bottom:2px solid var(--line);white-space:nowrap;}
td{padding:8px 12px;border-bottom:1px solid var(--line);vertical-align:top;}
tr:last-child td{border-bottom:none;} tbody tr:hover{background:#f8fafc;}
.pill{display:inline-block;padding:2px 9px;border-radius:999px;font-size:12px;font-weight:700;
letter-spacing:.02em;white-space:nowrap;}
.pill.crit{color:var(--crit);background:var(--crit-bg);}
.pill.high{color:var(--high);background:var(--high-bg);}
.pill.med{color:var(--med);background:var(--med-bg);}
.pill.low{color:var(--low);background:var(--low-bg);}
.pill.safe{color:var(--safe);background:var(--safe-bg);}
.meta{color:var(--muted);font-size:13px;margin-top:-.3em;}
.print-note{margin:0 0 1.5em;}
@media(max-width:900px){.layout{grid-template-columns:1fr;}.toc{display:none;}main{padding:24px;}}
@media print{.toc{display:none;}.layout{display:block;}main{padding:0;}
pre{background:#f5f5f5;color:#000;border:1px solid #ccc;}}
"""

TEMPLATE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>{title}</title>
<style>{css}</style></head>
<body><div class="layout">{toc}<main>{body}</main></div></body></html>"""

def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("-o", "--output", default=None)
    ap.add_argument("--title", default=None)
    a = ap.parse_args(argv)
    src = Path(a.input)
    if not src.exists():
        print(f"error: {src} not found", file=sys.stderr); return 2
    md = src.read_text(encoding="utf-8")
    title = a.title or f"Codebase Health — {src.stem}"
    toc, body = parse(md)
    out = Path(a.output) if a.output else src.with_suffix(".html")
    out.write_text(TEMPLATE.format(title=esc(title), css=CSS, toc=toc, body=body), encoding="utf-8")
    print(f"wrote {out}  ({out.stat().st_size} bytes, self-contained, no CDN)")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
