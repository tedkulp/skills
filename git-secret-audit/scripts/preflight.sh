#!/usr/bin/env bash
# preflight.sh — detect which scanners are available and report the coverage
# the audit will actually achieve.
#
# The point is to make degraded coverage loud. A pattern-only sweep finds real
# secrets and looks like a successful run, which is exactly how a partial audit
# gets mistaken for a clean bill of health.
#
# Usage: preflight.sh
# Exit:  0 = full coverage   1 = partial   2 = fallback only

set -uo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

ver() {
  case "$1" in
    gitleaks)        gitleaks version 2>&1 | head -1 ;;
    trufflehog)      trufflehog --version 2>&1 | head -1 ;;
    git-filter-repo) git filter-repo --version 2>&1 | head -1 ;;
  esac
}

GL=0; TH=0; FR=0
have gitleaks && GL=1
have trufflehog && TH=1
{ have git-filter-repo || git filter-repo --version >/dev/null 2>&1; } && FR=1

line() { printf '  %-16s %s\n' "$1" "$2"; }

echo "Scanner preflight"
echo
[[ $GL -eq 1 ]] && line "gitleaks" "available — $(ver gitleaks)" \
                || line "gitleaks" "NOT INSTALLED"
[[ $TH -eq 1 ]] && line "trufflehog" "available — $(ver trufflehog)" \
                || line "trufflehog" "NOT INSTALLED"
[[ $FR -eq 1 ]] && line "git-filter-repo" "available — $(ver git-filter-repo)" \
                || line "git-filter-repo" "not installed (only needed to remediate)"
echo

if [[ $GL -eq 1 && $TH -eq 1 ]]; then
  echo "COVERAGE: FULL"
  echo "  Rule-based and entropy detection (gitleaks) plus live credential"
  echo "  verification (trufflehog). Run both; they miss different things."
  exit 0
fi

if [[ $GL -eq 1 || $TH -eq 1 ]]; then
  echo "COVERAGE: PARTIAL — report this limitation in the audit output."
  if [[ $TH -eq 0 ]]; then
    echo "  Missing trufflehog: no live verification. Every finding will be"
    echo "  'unknown' rather than confirmed active or dead, so triage is manual"
    echo "  and every candidate must be treated as potentially live."
    echo "  Install: curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh | sh -s -- -b /usr/local/bin"
  fi
  if [[ $GL -eq 0 ]]; then
    echo "  Missing gitleaks: narrower ruleset and no entropy heuristics, so"
    echo "  credential formats outside trufflehog's detector set will be missed."
    echo "  Install: https://github.com/gitleaks/gitleaks/releases"
  fi
  exit 1
fi

echo "COVERAGE: FALLBACK ONLY — materially weaker."
echo "  Neither scanner is installed. The pattern sweep in"
echo "  references/no-scanner-fallback.md finds only the credential formats"
echo "  listed in assets/, with no entropy analysis and no live verification."
echo "  It will miss internal token formats, anything unusual, and any secret"
echo "  that does not look like a known provider's key."
echo
echo "  Tell the user this plainly and offer to install:"
echo "    gitleaks   https://github.com/gitleaks/gitleaks/releases"
echo "    trufflehog curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh | sh -s -- -b /usr/local/bin"
echo
echo "  A clean fallback sweep is NOT a clean audit. Do not report it as one."
exit 2
