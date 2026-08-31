#!/usr/bin/env bash
# assert_scanned.sh — prove a scanner actually did work before trusting its
# empty result.
#
# The failure this exists to catch: a scanner rejects a bad flag, logs the
# error, exits 0 anyway, scans nothing, and writes an empty results file.
# Downstream that is indistinguishable from a clean repository. A wrong flag
# is loud in the terminal and silent in the output file, and the output file
# is what the rest of the audit reads.
#
# Treat a zero-work scan as a FAILED SCAN, never as a clean result.
#
# Usage:
#   assert_scanned.sh trufflehog   <stderr-log>
#   assert_scanned.sh gitleaks-git <stderr-log> [repo]
#   assert_scanned.sh gitleaks-dir <stderr-log> [extracted-dir]
#
# Exit: 0 = work confirmed   1 = zero work, scan is INVALID   2 = usage error

set -uo pipefail

MODE="${1:-}"
LOG="${2:-}"
TARGET="${3:-.}"

[[ -n "$MODE" && -n "$LOG" ]] || { echo "usage: assert_scanned.sh <trufflehog|gitleaks-git|gitleaks-dir> <stderr-log> [target]" >&2; exit 2; }
[[ -r "$LOG" ]] || { echo "FAIL: cannot read scanner log: $LOG" >&2; exit 1; }

fail() { echo; echo "  *** SCAN INVALID — $* ***"; echo "  Do not report this run as clean. Fix and re-run."; exit 1; }

# Pull the first integer following a key, tolerating both logfmt (key=123)
# and JSON ("key": 123) output styles, which differ across versions.
num_after() { grep -oiE "$1[\"']?[[:space:]]*[:=][[:space:]]*[0-9]+" "$LOG" | grep -oE '[0-9]+$' | tail -1; }

case "$MODE" in
  trufflehog)
    CHUNKS="$(num_after 'chunks')"
    if [[ -z "$CHUNKS" ]]; then
      echo "WARN: no chunk count found in trufflehog output."
      echo "      Cannot confirm the scan did work — inspect $LOG by hand."
      grep -iE 'unable to resolve|error|failed' "$LOG" | head -5
      exit 1
    fi
    echo "trufflehog: chunks scanned = $CHUNKS"
    [[ "$CHUNKS" -gt 0 ]] || fail "trufflehog scanned 0 chunks"
    ;;

  gitleaks-git)
    COMMITS="$(num_after 'commits scanned')"
    [[ -n "$COMMITS" ]] || COMMITS="$(grep -oE '[0-9]+ commits scanned' "$LOG" | grep -oE '^[0-9]+' | tail -1)"
    if [[ -z "$COMMITS" ]]; then
      echo "WARN: no commit count found in gitleaks output — inspect $LOG by hand."
      exit 1
    fi
    echo "gitleaks: commits scanned = $COMMITS"
    [[ "$COMMITS" -gt 0 ]] || fail "gitleaks scanned 0 commits"

    # Expected count excludes merges: gitleaks skips merge commits, so its
    # total legitimately runs below `git rev-list --all --count`.
    if git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
      ALL="$(git -C "$TARGET" rev-list --all --remotes --count 2>/dev/null || echo 0)"
      NOMERGE="$(git -C "$TARGET" rev-list --all --remotes --no-merges --count 2>/dev/null || echo 0)"
      echo "  repo total = $ALL   non-merge = $NOMERGE   (merges skipped by design: $((ALL - NOMERGE)))"
      if [[ "$COMMITS" -lt $((NOMERGE / 2)) ]]; then
        fail "gitleaks scanned $COMMITS commits but the repo has $NOMERGE non-merge commits — coverage is not plausible"
      fi
    fi
    ;;

  gitleaks-dir)
    FILES=0
    [[ -d "$TARGET" ]] && FILES="$(find "$TARGET" -type f 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$FILES" -gt 0 ]] || fail "extraction produced no files to scan"

    # An ABSENT byte count means gitleaks died before scanning, which is a
    # failed scan. Never let a missing number read as a passing one.
    BYTES="$(grep -oE 'scanned ~?[0-9]+ bytes' "$LOG" | grep -oE '[0-9]+' | tail -1)"
    if [[ -z "$BYTES" ]]; then
      echo "WARN: no byte count in gitleaks output — it likely died before scanning."
      grep -iE 'FTL|invalid argument|error|failed' "$LOG" | head -5
      exit 1
    fi
    echo "gitleaks: bytes scanned = $BYTES   files present = $FILES"
    [[ "$BYTES" -gt 0 ]] || fail "gitleaks scanned 0 bytes across $FILES extracted files"
    ;;

  *) echo "unknown mode: $MODE" >&2; exit 2 ;;
esac

echo "OK: scan did measurable work."
