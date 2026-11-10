#!/usr/bin/env python3
"""Says whether a failed `tofu plan` failed only because a service was down.

Usage: transient.py PLAN_LOG
Exit 0: every error in the log is a temporary server-side failure (HTTP 5xx,
429, a timeout or a dropped connection), so the observability sync may retry
or wait for its next run. Exit 1: at least one error is anything else (a bad
config, a 4xx, a state lock), or the log has no errors at all; the sync fails.
Prints nothing from the log, so no secret or URL can leak.
"""
import re
import sys

ERROR = re.compile(r"^Error: (.*)$", re.MULTILINE)

TRANSIENT = re.compile(
    r"\(status (5\d\d|429)\)"
    r"|\b(502 Bad Gateway|503 Service Unavailable|504 Gateway Timeout)\b"
    r"|Client\.Timeout exceeded|context deadline exceeded|i/o timeout"
    r"|connection reset by peer|connection refused|EOF$|TLS handshake timeout",
    re.IGNORECASE,
)


def is_transient(log: str) -> bool:
    errors = ERROR.findall(log)
    return bool(errors) and all(TRANSIENT.search(e) for e in errors)


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    with open(argv[0], encoding="utf-8", errors="replace") as f:
        return 0 if is_transient(f.read()) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
