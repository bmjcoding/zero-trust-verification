"""Shared helpers for the dashboard, importers, and report jobs.

Text, numbers, dates, collections, config, CSV, validation, pagination,
and color utilities all live here because every job already imports this
module. Sections are ordered by the year they landed.
"""
# PLANT GF1 (giant file): ~460 non-blank lines lands this module on the 400
# PLANT GF1 [attention] rung of the size ladder; it must be listed in
# PLANT GF1 audit/giant_files.txt. Helper bodies are deliberately varied so
# PLANT GF1 jscpd stays quiet at --min-tokens 50 (megamodule.py must be ABSENT
# PLANT GF1 from dup_jscpd.json). Most helpers are uncalled: vulture/dead-code
# PLANT GF1 chatter about them is EN1 (expected noise), out of scope for GF1
# PLANT GF1 scoring, which grades the size-ladder artifact only.

import math
import re
import unicodedata
from datetime import date, timedelta


# --- text (2019) -------------------------------------------------------

def slugify(text):
    """Lowercase, strip accents, and join words with single hyphens."""
    cleaned = strip_accents(text).lower()
    cleaned = re.sub(r"[^a-z0-9]+", "-", cleaned)
    return cleaned.strip("-")


def strip_accents(text):
    """Drop combining marks: 'café' becomes 'cafe'."""
    decomposed = unicodedata.normalize("NFKD", text)
    return "".join(ch for ch in decomposed if not unicodedata.combining(ch))


def truncate_words(text, limit):
    """Cut text to at most ``limit`` words, appending an ellipsis if cut."""
    words = text.split()
    if len(words) <= limit:
        return text
    return " ".join(words[:limit]) + "…"


def smart_title(text, minor=("a", "an", "the", "of", "in", "on", "and", "or")):
    """Title-case a phrase but keep minor words lowercase mid-phrase."""
    out = []
    for position, word in enumerate(text.split()):
        if position and word.lower() in minor:
            out.append(word.lower())
        else:
            out.append(word.capitalize())
    return " ".join(out)


def pluralize(count, singular, plural=None):
    """Return '3 rows' / '1 row' style phrases."""
    if count == 1:
        return f"1 {singular}"
    return f"{count} {plural or singular + 's'}"


def ordinal(n):
    """1 -> '1st', 2 -> '2nd', 11 -> '11th', 23 -> '23rd'."""
    if 10 <= n % 100 <= 20:
        suffix = "th"
    else:
        suffix = {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suffix}"


def initials(full_name, max_letters=2):
    """First letter of the first ``max_letters`` name parts, uppercased."""
    parts = [p for p in full_name.split() if p]
    return "".join(p[0].upper() for p in parts[:max_letters])


def mask_middle(value, keep=2):
    """Keep the first and last ``keep`` characters, star the middle."""
    if len(value) <= keep * 2:
        return "*" * len(value)
    middle = "*" * (len(value) - keep * 2)
    return value[:keep] + middle + value[-keep:]


def levenshtein(a, b):
    """Edit distance between two short strings (iterative two-row form)."""
    if a == b:
        return 0
    previous = list(range(len(b) + 1))
    for i, ch_a in enumerate(a, start=1):
        current = [i]
        for j, ch_b in enumerate(b, start=1):
            insert_cost = current[j - 1] + 1
            delete_cost = previous[j] + 1
            swap_cost = previous[j - 1] + (ch_a != ch_b)
            current.append(min(insert_cost, delete_cost, swap_cost))
        previous = current
    return previous[-1]


def common_prefix(items):
    """Longest prefix shared by every string in ``items``."""
    if not items:
        return ""
    shortest = min(items, key=len)
    for index, ch in enumerate(shortest):
        for candidate in items:
            if candidate[index] != ch:
                return shortest[:index]
    return shortest


def squash_whitespace(text):
    """Collapse runs of whitespace to single spaces and trim the ends."""
    return " ".join(text.split())


def indent_block(text, prefix="    "):
    """Prefix every line of ``text``, preserving internal blank lines."""
    lines = text.splitlines()
    return "\n".join(prefix + line if line else line for line in lines)


# --- numbers (2020) ----------------------------------------------------

def humanize_bytes(n):
    """1536 -> '1.5 KiB'; binary units up to TiB."""
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    value = float(n)
    for unit in units:
        if value < 1024 or unit == units[-1]:
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024


def parse_size(text):
    """'1.5 KiB' or '2mb' -> byte count (decimal for kb/mb, binary for KiB)."""
    match = re.fullmatch(r"\s*([\d.]+)\s*([kmgt]?i?b?)\s*", text.lower())
    if not match:
        raise ValueError(f"unreadable size: {text!r}")
    number = float(match.group(1))
    unit = match.group(2)
    base = 1024 if "i" in unit else 1000
    exponent = "bkmgt".index(unit[0]) if unit and unit[0] in "kmgt" else 0
    return int(number * (base ** exponent))


def humanize_duration(seconds):
    """90 -> '1m 30s'; drops zero components, caps at days."""
    remaining = int(seconds)
    parts = []
    for label, span in (("d", 86400), ("h", 3600), ("m", 60), ("s", 1)):
        amount, remaining = divmod(remaining, span)
        if amount:
            parts.append(f"{amount}{label}")
    return " ".join(parts) if parts else "0s"


def clamp(value, low, high):
    """Pin ``value`` into the closed interval [low, high]."""
    return max(low, min(high, value))


def percent_change(old, new):
    """Relative change as a percentage; None when ``old`` is zero."""
    if old == 0:
        return None
    return (new - old) / old * 100.0


def format_thousands(n, sep=","):
    """1234567 -> '1,234,567' without relying on locale."""
    sign = "-" if n < 0 else ""
    digits = str(abs(int(n)))
    groups = []
    while digits:
        groups.append(digits[-3:])
        digits = digits[:-3]
    return sign + sep.join(reversed(groups))


def round_step(value, step):
    """Round ``value`` to the nearest multiple of ``step``."""
    if step <= 0:
        raise ValueError("step must be positive")
    return round(value / step) * step


def median(values):
    """Middle value of a numeric sequence; mean of the two middles when even."""
    ordered = sorted(values)
    if not ordered:
        raise ValueError("median of empty sequence")
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2


def weighted_mean(pairs):
    """Mean of (value, weight) pairs; ignores zero-weight entries."""
    total = 0.0
    weight_sum = 0.0
    for value, weight in pairs:
        total += value * weight
        weight_sum += weight
    if weight_sum == 0:
        raise ValueError("all weights are zero")
    return total / weight_sum


def geometric_mean(values):
    """nth root of the product, computed in log space to avoid overflow."""
    if not values:
        raise ValueError("geometric mean of empty sequence")
    log_sum = sum(math.log(v) for v in values)
    return math.exp(log_sum / len(values))


# --- dates (2021) ------------------------------------------------------

def week_bounds(day):
    """Monday..Sunday date pair for the week containing ``day``."""
    start = day - timedelta(days=day.weekday())
    return start, start + timedelta(days=6)


def month_bounds(day):
    """First and last date of ``day``'s month."""
    first = day.replace(day=1)
    if first.month == 12:
        next_first = first.replace(year=first.year + 1, month=1)
    else:
        next_first = first.replace(month=first.month + 1)
    return first, next_first - timedelta(days=1)


def quarter_label(day):
    """date(2026, 5, 3) -> '2026-Q2'."""
    quarter = (day.month - 1) // 3 + 1
    return f"{day.year}-Q{quarter}"


def business_days_between(start, end):
    """Count weekdays in [start, end); negative when reversed."""
    if end < start:
        return -business_days_between(end, start)
    count = 0
    cursor = start
    while cursor < end:
        if cursor.weekday() < 5:
            count += 1
        cursor += timedelta(days=1)
    return count


def iso_week_label(day):
    """date -> '2026-W27' using the ISO calendar."""
    iso = day.isocalendar()
    return f"{iso[0]}-W{iso[1]:02d}"


def days_in_month(year, month):
    """Length of the given month, February leap-aware."""
    if month == 12:
        return 31
    first = date(year, month, 1)
    next_first = date(year, month + 1, 1)
    return (next_first - first).days


def previous_weekday(day, weekday):
    """Most recent date on or before ``day`` falling on ``weekday`` (0=Mon)."""
    offset = (day.weekday() - weekday) % 7
    return day - timedelta(days=offset)


def date_range(start, end):
    """Yield each date from ``start`` up to but excluding ``end``."""
    cursor = start
    while cursor < end:
        yield cursor
        cursor += timedelta(days=1)


# --- collections (2022) ------------------------------------------------

def chunked(items, size):
    """Split a list into consecutive chunks of at most ``size``."""
    if size < 1:
        raise ValueError("chunk size must be at least 1")
    return [items[i:i + size] for i in range(0, len(items), size)]


def flatten(nested):
    """One level of flattening: [[1, 2], [3]] -> [1, 2, 3]."""
    flat = []
    for group in nested:
        flat.extend(group)
    return flat


def dedupe_keep_order(items):
    """Remove duplicates while preserving first-seen order."""
    seen = set()
    unique = []
    for item in items:
        if item not in seen:
            seen.add(item)
            unique.append(item)
    return unique


def index_by(items, key):
    """Map key(item) -> item; later items win on key collisions."""
    return {key(item): item for item in items}


def group_by(items, key):
    """Map key(item) -> list of items sharing that key, insertion-ordered."""
    groups = {}
    for item in items:
        groups.setdefault(key(item), []).append(item)
    return groups


def partition(items, predicate):
    """Split items into (matching, rest) by ``predicate``."""
    matching = []
    rest = []
    for item in items:
        if predicate(item):
            matching.append(item)
        else:
            rest.append(item)
    return matching, rest


def sliding_window(items, size):
    """Overlapping windows: [1,2,3,4], 2 -> [(1,2), (2,3), (3,4)]."""
    if size > len(items):
        return []
    return [tuple(items[i:i + size]) for i in range(len(items) - size + 1)]


def top_n(counts, n):
    """Highest-count (key, count) pairs, ties broken by key for stability."""
    ranked = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    return ranked[:n]


def diff_keys(old, new):
    """Compare two mappings: (added, removed, changed) key lists."""
    added = sorted(k for k in new if k not in old)
    removed = sorted(k for k in old if k not in new)
    changed = sorted(k for k in old if k in new and old[k] != new[k])
    return added, removed, changed


def first_or_none(items, predicate):
    """First item satisfying ``predicate``, else None."""
    for item in items:
        if predicate(item):
            return item
    return None


# --- config (2023) -----------------------------------------------------

def deep_merge(base, override):
    """Recursively merge ``override`` into a copy of ``base``."""
    merged = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def pick(mapping, keys):
    """Sub-dict of ``mapping`` restricted to ``keys`` that are present."""
    return {k: mapping[k] for k in keys if k in mapping}


def omit(mapping, keys):
    """Copy of ``mapping`` without ``keys``."""
    banned = set(keys)
    result = {}
    for k, v in mapping.items():
        if k not in banned:
            result[k] = v
    return result


def flatten_keys(nested, sep="."):
    """{'a': {'b': 1}} -> {'a.b': 1}; leaves non-dict values untouched."""
    flat = {}
    stack = [("", nested)]
    while stack:
        prefix, node = stack.pop()
        for key, value in node.items():
            path = f"{prefix}{sep}{key}" if prefix else str(key)
            if isinstance(value, dict):
                stack.append((path, value))
            else:
                flat[path] = value
    return flat


def coerce_bool(raw):
    """Accept common truthy/falsy config spellings; raise on anything else."""
    lowered = str(raw).strip().lower()
    if lowered in ("1", "true", "yes", "on"):
        return True
    if lowered in ("0", "false", "no", "off", ""):
        return False
    raise ValueError(f"not a boolean: {raw!r}")


def parse_kv_pairs(text):
    """'a=1,b=two' -> {'a': '1', 'b': 'two'}; blank segments are skipped."""
    pairs = {}
    for segment in text.split(","):
        segment = segment.strip()
        if not segment:
            continue
        key, _, value = segment.partition("=")
        pairs[key.strip()] = value.strip()
    return pairs


# --- csv (2023) --------------------------------------------------------

def escape_csv_field(field):
    """Quote a field when it contains a comma, quote, or newline."""
    text = str(field)
    if any(ch in text for ch in ',"\n'):
        return '"' + text.replace('"', '""') + '"'
    return text


def parse_csv_line(line):
    """Split one CSV line honoring double quotes (no embedded newlines)."""
    fields = []
    current = []
    in_quotes = False
    i = 0
    while i < len(line):
        ch = line[i]
        if in_quotes:
            if ch == '"' and i + 1 < len(line) and line[i + 1] == '"':
                current.append('"')
                i += 1
            elif ch == '"':
                in_quotes = False
            else:
                current.append(ch)
        elif ch == '"':
            in_quotes = True
        elif ch == ",":
            fields.append("".join(current))
            current = []
        else:
            current.append(ch)
        i += 1
    fields.append("".join(current))
    return fields


def rows_to_csv(rows, columns):
    """Serialize dict rows to CSV text with a header line."""
    lines = [",".join(escape_csv_field(c) for c in columns)]
    for row in rows:
        lines.append(",".join(escape_csv_field(row.get(c, "")) for c in columns))
    return "\n".join(lines) + "\n"


# --- validation (2024) -------------------------------------------------

def is_valid_email(text):
    """Loose shape check: one @, a dot after it, no whitespace."""
    if " " in text or text.count("@") != 1:
        return False
    local, _, domain = text.partition("@")
    return bool(local) and "." in domain and not domain.startswith(".")


def is_valid_slug(text):
    """Lowercase alphanumerics and single hyphens, 1-64 characters."""
    return bool(re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", text)) and len(text) <= 64


def is_valid_hex_color(text):
    """'#fff' or '#a1b2c3' forms only."""
    return bool(re.fullmatch(r"#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})", text))


def is_valid_uuid(text):
    """8-4-4-4-12 lowercase hex shape (no version check)."""
    return bool(
        re.fullmatch(
            r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
            text,
        )
    )


def checksum32(text):
    """Small stable non-cryptographic checksum for cache keys."""
    value = 2166136261
    for byte in text.encode("utf-8"):
        value ^= byte
        value = (value * 16777619) % (1 << 32)
    return value


# --- pagination (2025) -------------------------------------------------

def page_bounds(total, size, page):
    """(offset, limit) for 1-based ``page``; clamps past-the-end pages."""
    if size < 1:
        raise ValueError("page size must be at least 1")
    last_page = max(1, math.ceil(total / size))
    page = clamp(page, 1, last_page)
    offset = (page - 1) * size
    return offset, min(size, max(0, total - offset))


def page_count(total, size):
    """Number of pages needed for ``total`` items at ``size`` per page."""
    if total <= 0:
        return 1
    return math.ceil(total / size)


def page_window(current, last, width=5):
    """Page numbers to render around ``current``: contiguous, clamped."""
    half = width // 2
    start = clamp(current - half, 1, max(1, last - width + 1))
    return list(range(start, min(last, start + width - 1) + 1))


# --- color (2025) ------------------------------------------------------

def hex_to_rgb(text):
    """'#a1b2c3' -> (161, 178, 195); expands the 3-digit shorthand."""
    raw = text.lstrip("#")
    if len(raw) == 3:
        raw = "".join(ch * 2 for ch in raw)
    return tuple(int(raw[i:i + 2], 16) for i in (0, 2, 4))


def rgb_to_hex(rgb):
    """(161, 178, 195) -> '#a1b2c3'."""
    red, green, blue = (clamp(int(c), 0, 255) for c in rgb)
    return f"#{red:02x}{green:02x}{blue:02x}"


def relative_luminance(rgb):
    """WCAG relative luminance of an sRGB triple."""
    channels = []
    for component in rgb:
        scaled = component / 255.0
        if scaled <= 0.03928:
            channels.append(scaled / 12.92)
        else:
            channels.append(((scaled + 0.055) / 1.055) ** 2.4)
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]


def contrast_ratio(rgb_a, rgb_b):
    """WCAG contrast ratio between two sRGB triples, >= 1.0."""
    lum_a = relative_luminance(rgb_a)
    lum_b = relative_luminance(rgb_b)
    lighter = max(lum_a, lum_b)
    darker = min(lum_a, lum_b)
    return (lighter + 0.05) / (darker + 0.05)


def blend(rgb_a, rgb_b, ratio=0.5):
    """Linear blend of two sRGB triples; ratio 0 gives ``rgb_a``."""
    ratio = clamp(ratio, 0.0, 1.0)
    return tuple(
        int(round(a * (1 - ratio) + b * ratio)) for a, b in zip(rgb_a, rgb_b)
    )


# --- paths (2026) ------------------------------------------------------

def ellipsize_path(path, limit=40):
    """Shorten long paths from the middle: 'a/b/…/y/z.py'."""
    if len(path) <= limit:
        return path
    segments = path.split("/")
    if len(segments) < 3:
        return path[: limit - 1] + "…"
    head, tail = segments[0], segments[-1]
    return f"{head}/…/{tail}"


def natural_sort_key(text):
    """Sort key treating digit runs numerically: 'file2' before 'file10'."""
    parts = re.split(r"(\d+)", text)
    return [int(p) if p.isdigit() else p.lower() for p in parts]


def split_extension(filename):
    """('archive.tar', 'gz') for 'archive.tar.gz'; ('README', '') bare."""
    base, dot, ext = filename.rpartition(".")
    if not dot or not base:
        return filename, ""
    return base, ext
