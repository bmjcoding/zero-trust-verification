"""Weekly usage report rendered as a plain-text email."""
# PLANT ND1 (near-duplicate): format_report_rows below is byte-identical to the
# PLANT ND1 copy in report_slack.py (~120 jscpd tokens, well over the
# PLANT ND1 --min-tokens 50 floor) - the pair must appear in dup_jscpd.json.
# PLANT ND1 The dead-code agent's extract-vs-intentional-fork judgment is a
# PLANT ND1 corroborating lens only; EN2 covers dead-code/duplication chatter
# PLANT ND1 beyond the pair itself.


def format_report_rows(rows, columns):
    """Render report rows as aligned text columns.

    Each row is a mapping; ``columns`` picks and orders the fields. Column
    widths default to the widest value seen, capped at 32 characters, and
    over-wide cells are shortened with a trailing tilde.
    """
    widths = {}
    for column in columns:
        widest = len(column)
        for row in rows:
            value = str(row.get(column, ""))
            if len(value) > widest:
                widest = len(value)
        widths[column] = min(widest, 32)
    lines = []
    lines.append("  ".join(column.ljust(widths[column]) for column in columns))
    lines.append("  ".join("-" * widths[column] for column in columns))
    for row in rows:
        cells = []
        for column in columns:
            value = str(row.get(column, ""))
            if len(value) > widths[column]:
                value = value[: widths[column] - 1] + "~"
            cells.append(value.ljust(widths[column]))
        lines.append("  ".join(cells).rstrip())
    return "\n".join(lines)


def build_report_email(rows, columns, recipient, period_label):
    """Assemble the weekly report as a message dict for the mail queue."""
    table = format_report_rows(rows, columns)
    body = (
        f"Usage report for {period_label}\n"
        f"{'=' * (17 + len(period_label))}\n\n"
        f"{table}\n\n"
        "Reply to this address to reach the on-call maintainer.\n"
    )
    return {
        "to": recipient,
        "subject": f"[usage] weekly report — {period_label}",
        "body": body,
        "headers": {"Auto-Submitted": "auto-generated"},
    }
