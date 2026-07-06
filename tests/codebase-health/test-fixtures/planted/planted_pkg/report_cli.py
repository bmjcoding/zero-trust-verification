"""Print the weekly fulfillment report; stdout is this command's product output.

MUST-NOT-FLAG N6: print-as-product-output in a CLI main. The deterministic
MUST-NOT-FLAG N6: listing of these lines in stdout_logging.txt is CORRECT
MUST-NOT-FLAG N6: (candidates, not verdicts; self-test asserts presence); an
MUST-NOT-FLAG N6: agent Category LOG finding on this file is the precision
MUST-NOT-FLAG N6: failure. Guardrail: CLI/user-facing output is correct use.
MUST-NOT-FLAG N6 (scope, post-1.4.0-eval): N6 constrains ONLY Category-LOG
MUST-NOT-FLAG N6: findings - the fake windowed report below is plant B4.

Usage:
    python -m planted_pkg.report_cli --window 7
"""

import argparse
from pprint import pprint

# PLANT B4 (incomplete-logic/B, fake windowed report): _ROWS below is a
# PLANT B4: hardcoded constant and main() never applies --window to it - the
# PLANT B4: header echoes the flag, then every window gets the same three
# PLANT B4: rows. MED. Agent-scored. Registered post-1.4.0-eval (blind-eval
# PLANT B4: extra).
_ROWS = [
    ("orders_shipped", 128),
    ("orders_returned", 7),
    ("carriers_active", 4),
]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="fulfillment-report")
    parser.add_argument("--window", type=int, default=7, help="days to cover")
    parser.add_argument(
        "--raw", action="store_true", help="also show rows as a Python literal"
    )
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    print(f"fulfillment report - last {args.window} days")
    print("-" * 40)
    for name, value in _ROWS:
        print(f"{name:<20} {value:>6}")
    if args.raw:
        # MUST-NOT-FLAG N6 (decoy): pprint defeats the \b anchor on print in
        # MUST-NOT-FLAG N6: LOGGING_RE - this line must match nothing.
        pprint(_ROWS)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
