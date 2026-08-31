#!/usr/bin/env bash
# selfcheck.sh — prove assert_scanned.sh still FAILS on a dead scan.
#
# assert_scanned.sh is the only thing standing between a scanner that died on
# a bad flag and a "SAFE TO PUBLISH" verdict. It is also a log-format parser:
# it greps for "chunks", "N commits scanned" and "scanned ~N bytes". A scanner
# release that renames any of those turns the guard into a no-op that passes
# everything, silently, in the exact direction that hides secrets.
#
# So this runs the REAL scanners against a REAL throwaway repo and feeds their
# REAL stderr to the guard. Hand-written fixture logs would freeze today's
# format and never notice the drift, which is the failure this exists to catch.
#
# Every mode is checked in both directions. A guard that cannot fail is worse
# than no guard, because it converts uncertainty into confidence.
#
# Usage: bash selfcheck.sh
# Exit:  0 = guard behaves correctly   1 = guard is broken, do not trust it

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSERT="$HERE/assert_scanned.sh"
EXTRACT="$HERE/extract_all_objects.py"

[[ -r "$ASSERT" ]] || { echo "cannot find assert_scanned.sh at $ASSERT" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0; SKIP=0

check() { # <want-exit> <label> <assert-args...>
  local want="$1" label="$2"; shift 2
  bash "$ASSERT" "$@" >/dev/null 2>&1
  local got=$?
  if [[ "$got" == "$want" ]]; then
    printf '  ok    %-42s exit=%s\n' "$label" "$got"; PASS=$((PASS+1))
  else
    printf '  FAIL  %-42s exit=%s want=%s\n' "$label" "$got" "$want"; FAIL=$((FAIL+1))
  fi
}

skip() { printf '  skip  %-42s %s\n' "$1" "$2"; SKIP=$((SKIP+1)); }

# ---------------------------------------------------------------- fixture repo
# gpgsign is forced off: signing a throwaway repo with the caller's real key is
# both wrong and a known way to hang on an external signer.
R="$WORK/repo"
git init -q "$R"
git -C "$R" config user.email selfcheck@example.invalid
git -C "$R" config user.name  selfcheck
git -C "$R" config commit.gpgsign false
DEFBR="$(git -C "$R" symbolic-ref --short HEAD)"

mkfile() { mkdir -p "$(dirname "$R/$1")"; printf '%s\n' "$2" > "$R/$1"; }
commit() { git -C "$R" add -A && git -C "$R" commit -qm "$1"; }

# Enough commits that the plausibility threshold (< non-merge/2) is reachable.
# On a 3-commit repo that branch is unreachable by arithmetic, so a smaller
# fixture would silently never test it.
mkfile app.py 'def main(): return "hello"'; commit 'initial'
for i in 1 2 3 4 5 6 7 8 9 10; do
  mkfile "lib/mod$i.py" "VALUE_$i = $i"
  commit "add mod$i"
done

# A merged branch, so the gitleaks merge-skip arithmetic is exercised rather
# than assumed. Without a merge, total == non-merge and that branch is dead.
git -C "$R" checkout -qb merged-side
mkfile side.py 'SIDE = 1'; commit 'side work'
git -C "$R" checkout -q "$DEFBR"
git -C "$R" merge -q --no-ff merged-side -m 'merge side'

# An UNMERGED branch carrying content reachable from no other ref. Without
# this, every branch is an ancestor of the default one and a scanner narrowed
# to a single branch sees exactly as much as a scanner spanning all of them,
# so the branch-coverage assertion below would pass no matter what.
git -C "$R" checkout -q -b unmerged-work "$DEFBR"
for i in 1 2 3; do
  mkfile "unmerged/only$i.py" "ONLY_$i = 'content reachable from no other ref $i'"
  commit "unmerged work $i"
done
git -C "$R" checkout -q "$DEFBR"

# Detectable, non-allowlisted key material. NOT AKIAIOSFODNN7EXAMPLE: gitleaks
# allowlists documentation values, so that one is undetectable by construction
# and would make every check below pass vacuously.
# Split so GitHub push protection does not flag this file as a real leak.
FAKE_ID="AKIA""4RQZ7T2LMWXVN3JD"
FAKE_SEC="wJ9xKq2mNvB7pLdR4tYs""1cFgH6zXeA0iU3oPnM5Q"
# Both halves. TruffleHog's AWS detector needs the id AND the secret to form a
# candidate at all, so an id on its own yields zero findings and would make the
# unverified check below pass against 0 == 0.
mkfile creds.txt "aws_access_key_id = $FAKE_ID
aws_secret_access_key = $FAKE_SEC"
commit 'add creds'

# Same key inside a committed archive, for the archive-depth check.
mkdir -p "$R/pack"; printf 'aws_access_key_id = %s\n' "$FAKE_ID" > "$R/pack/inner.txt"
( cd "$R" && python3 -c "import zipfile;z=zipfile.ZipFile('bundle.zip','w');z.write('pack/inner.txt');z.close()" 2>/dev/null && rm -rf pack )
commit 'add archive'

# A git note: reachable from refs/notes, sent by a mirror push, and the exact
# case the tier logic used to file as local-only.
git -C "$R" notes add -m "deploy key $FAKE_ID" HEAD >/dev/null 2>&1

TOTAL="$(git -C "$R" rev-list --all --count)"
NOMERGE="$(git -C "$R" rev-list --all --no-merges --count)"
ONBRANCH="$(git -C "$R" rev-list "$DEFBR" --count)"
echo "fixture repo: $TOTAL commits ($((TOTAL - NOMERGE)) merge), $NOMERGE non-merge, $ONBRANCH on $DEFBR"
[[ $((TOTAL - NOMERGE)) -gt 0 ]] || { echo "fixture has no merge commit; arithmetic branch untested" >&2; FAIL=$((FAIL+1)); }
[[ "$TOTAL" -gt "$ONBRANCH" ]] || { echo "fixture has no unmerged branch; coverage assertion is vacuous" >&2; FAIL=$((FAIL+1)); }

# ------------------------------------------------------------------- extraction
EXDIR="$WORK/audit"
if [[ -r "$EXTRACT" ]] && command -v python3 >/dev/null 2>&1; then
  python3 "$EXTRACT" --repo "$R" --out "$EXDIR" >/dev/null 2>&1
else
  mkdir -p "$EXDIR/blobs/refs" && cp "$R/app.py" "$EXDIR/blobs/refs/aaaaaaaaaaaa__app.py"
fi
mkdir -p "$WORK/emptydir"

# ------------------------------------------------------------------- gitleaks
echo
echo "gitleaks"
if command -v gitleaks >/dev/null 2>&1; then
  # Real good runs.
  gitleaks git "$R" --log-opts="--all --remotes" -v --no-banner \
    --report-path="$WORK/gl-git-good.json" >/dev/null 2>"$WORK/gl-git-good.err"
  gitleaks dir "$EXDIR" -v --no-banner \
    --report-path="$WORK/gl-dir-good.json" >/dev/null 2>"$WORK/gl-dir-good.err"

  # Real dead runs. --redact=false is a uint parse error, so gitleaks exits
  # before scanning and writes no count line at all. This is the exact bug
  # that shipped, and the one the dir mode used to pass.
  gitleaks git "$R" --log-opts="--all --remotes" -v --no-banner --redact=false \
    --report-path="$WORK/gl-git-dead.json" >/dev/null 2>"$WORK/gl-git-dead.err"
  gitleaks dir "$EXDIR" -v --no-banner --redact=false \
    --report-path="$WORK/gl-dir-dead.json" >/dev/null 2>"$WORK/gl-dir-dead.err"

  check 0 "gitleaks-git  live scan"        gitleaks-git "$WORK/gl-git-good.err" "$R"
  check 1 "gitleaks-git  dead scan"        gitleaks-git "$WORK/gl-git-dead.err" "$R"
  check 0 "gitleaks-dir  live scan"        gitleaks-dir "$WORK/gl-dir-good.err" "$EXDIR"
  check 1 "gitleaks-dir  dead scan"        gitleaks-dir "$WORK/gl-dir-dead.err" "$EXDIR"
  check 1 "gitleaks-dir  nothing extracted" gitleaks-dir "$WORK/gl-dir-good.err" "$WORK/emptydir"

  # Format drift: if a future gitleaks stops printing "N commits scanned", the
  # guard must fail rather than wave the scan through.
  grep -qE '[0-9]+ commits scanned' "$WORK/gl-git-good.err" \
    && printf '  ok    %-42s\n' "gitleaks  commit-count line present" && PASS=$((PASS+1)) \
    || { printf '  FAIL  %-42s guard can no longer parse gitleaks\n' "gitleaks  commit-count line MISSING"; FAIL=$((FAIL+1)); }
  grep -qE 'scanned ~?[0-9]+ bytes' "$WORK/gl-dir-good.err" \
    && printf '  ok    %-42s\n' "gitleaks  byte-count line present" && PASS=$((PASS+1)) \
    || { printf '  FAIL  %-42s guard can no longer parse gitleaks\n' "gitleaks  byte-count line MISSING"; FAIL=$((FAIL+1)); }
else
  skip "gitleaks modes" "gitleaks not installed"
fi

# ----------------------------------------------------------------- trufflehog
echo
echo "trufflehog"
if command -v trufflehog >/dev/null 2>&1; then
  trufflehog git "file://$R" --results=verified,unknown --json \
    >/dev/null 2>"$WORK/th-good.err"
  # --branch takes one branch name; there is no `all` sentinel. This logs an
  # error, exits 0, and scans nothing.
  trufflehog git "file://$R" --branch=all --results=verified,unknown --json \
    >/dev/null 2>"$WORK/th-dead.err"

  check 0 "trufflehog    live scan"        trufflehog "$WORK/th-good.err"
  check 1 "trufflehog    dead scan (--branch=all)" trufflehog "$WORK/th-dead.err"

  grep -qiE 'chunks[\"'"'"']?[[:space:]]*[:=][[:space:]]*[0-9]+' "$WORK/th-good.err" \
    && printf '  ok    %-42s\n' "trufflehog  chunk-count line present" && PASS=$((PASS+1)) \
    || { printf '  FAIL  %-42s guard can no longer parse trufflehog\n' "trufflehog  chunk-count line MISSING"; FAIL=$((FAIL+1)); }

  # Default really must cover more than one branch, or the dropped --branch
  # flag silently narrows every audit to the checked-out tip.
  ALLC="$(grep -oE '\"chunks\":[0-9]+' "$WORK/th-good.err" | grep -oE '[0-9]+$' | tail -1)"
  trufflehog git "file://$R" --branch="$DEFBR" --results=verified,unknown --json \
    >/dev/null 2>"$WORK/th-one.err"
  ONEC="$(grep -oE '\"chunks\":[0-9]+' "$WORK/th-one.err" | grep -oE '[0-9]+$' | tail -1)"
  if [[ -n "${ALLC:-}" && -n "${ONEC:-}" && "$ALLC" -gt "$ONEC" ]]; then
    printf '  ok    %-42s all=%s one-branch=%s\n' "trufflehog  default spans branches" "$ALLC" "$ONEC"; PASS=$((PASS+1))
  else
    printf '  FAIL  %-42s all=%s one-branch=%s\n' "trufflehog  default NARROWED" "${ALLC:-?}" "${ONEC:-?}"; FAIL=$((FAIL+1))
  fi
else
  skip "trufflehog modes" "trufflehog not installed"
fi

# --------------------------------------------------- guard's own logic branches
# Synthesized, not tool-produced: a plausible-looking count that is far too low
# for the repo. No real invocation produces this, but the branch must still work.
echo
echo "guard logic"
printf 'INF 1 commits scanned.\n' > "$WORK/gl-implausible.err"
check 1 "gitleaks-git  implausibly low count" gitleaks-git "$WORK/gl-implausible.err" "$R"
check 1 "missing log file"                    trufflehog "$WORK/does-not-exist.err"
check 2 "usage error"                         bogus-mode

# ------------------------------------------------- tier + tool-behaviour checks
echo
echo "tiering"
if command -v python3 >/dev/null 2>&1 && [[ -r "$EXTRACT" ]]; then
  rm -rf "$WORK/tier"
  python3 "$EXTRACT" --repo "$R" --out "$WORK/tier" >/dev/null 2>&1
  NOTEBLOB="$(git -C "$R" ls-tree -r refs/notes/commits 2>/dev/null | awk '{print $3}' | head -1)"
  if [[ -n "$NOTEBLOB" ]]; then
    NT="$(awk -F'\t' -v o="$NOTEBLOB" '$1==o{print $3}' "$WORK/tier/MANIFEST.tsv" | head -1)"
    if [[ "$NT" == "refs" ]]; then
      printf '  ok    %-42s tier=%s\n' "note blob tiers as published" "$NT"; PASS=$((PASS+1))
    else
      printf '  FAIL  %-42s tier=%s want=refs\n' "note blob MIS-TIERED" "${NT:-absent}"; FAIL=$((FAIL+1))
    fi
  else
    skip "note tiering" "git notes unavailable"
  fi

  # A stash must stay OUT of the published tier, or the fix over-corrected.
  printf 'scratch\n' >> "$R/creds.txt"
  if git -C "$R" stash -q 2>/dev/null; then
    rm -rf "$WORK/tier2"; python3 "$EXTRACT" --repo "$R" --out "$WORK/tier2" >/dev/null 2>&1
    STASHTOP="$(git -C "$R" rev-parse refs/stash 2>/dev/null)"
    ST="$(awk -F'\t' -v o="$STASHTOP" '$1==o{print $3}' "$WORK/tier2/MANIFEST.tsv" | head -1)"
    if [[ "$ST" != "refs" ]]; then
      printf '  ok    %-42s tier=%s\n' "stash stays out of published tier" "${ST:-absent}"; PASS=$((PASS+1))
    else
      printf '  FAIL  %-42s tier=refs\n' "stash LEAKED into published tier"; FAIL=$((FAIL+1))
    fi
    git -C "$R" stash drop -q >/dev/null 2>&1
  else
    skip "stash tiering" "could not create a stash"
  fi
else
  skip "tiering checks" "python3 or extractor unavailable"
fi

echo
echo "scanner behaviour"
if command -v gitleaks >/dev/null 2>&1; then
  cnt() { python3 -c "import json,sys
try: print(len(json.load(open(sys.argv[1]))))
except Exception: print(0)" "$1"; }

  gitleaks dir "$R" --no-banner --report-path="$WORK/ar0.json" >/dev/null 2>&1
  gitleaks dir "$R" --no-banner --max-archive-depth=8 --report-path="$WORK/ar8.json" >/dev/null 2>&1
  A0="$(cnt "$WORK/ar0.json")"; A8="$(cnt "$WORK/ar8.json")"
  if [[ "$A8" -gt "$A0" ]]; then
    printf '  ok    %-42s default=%s depth8=%s\n' "archives need --max-archive-depth" "$A0" "$A8"; PASS=$((PASS+1))
  else
    printf '  FAIL  %-42s default=%s depth8=%s\n' "archive-depth flag had NO effect" "$A0" "$A8"; FAIL=$((FAIL+1))
  fi

  # Inline gitleaks:allow must be defeated by --ignore-gitleaks-allow.
  printf 'key = "%s" # gitleaks:allow\n' "$FAKE_ID" > "$WORK/allow.txt"
  gitleaks dir "$WORK/allow.txt" --no-banner --report-path="$WORK/al0.json" >/dev/null 2>&1
  gitleaks dir "$WORK/allow.txt" --no-banner --ignore-gitleaks-allow --report-path="$WORK/al1.json" >/dev/null 2>&1
  L0="$(cnt "$WORK/al0.json")"; L1="$(cnt "$WORK/al1.json")"
  if [[ "$L0" -eq 0 && "$L1" -gt 0 ]]; then
    printf '  ok    %-42s suppressed=%s defeated=%s\n' "inline allow needs the override" "$L0" "$L1"; PASS=$((PASS+1))
  else
    printf '  FAIL  %-42s suppressed=%s defeated=%s\n' "inline-allow override BROKEN" "$L0" "$L1"; FAIL=$((FAIL+1))
  fi

  # A repo-local blanket allowlist must still blind the scanner. If this ever
  # stops being true, step 2a's sanitized clone is no longer needed; until then
  # it is load-bearing.
  cp "$WORK/allow.txt" "$WORK/cfgdir.txt" 2>/dev/null || true
  mkdir -p "$WORK/hostile" && printf 'aws_access_key_id = %s\n' "$FAKE_ID" > "$WORK/hostile/f.txt"
  gitleaks dir "$WORK/hostile" --no-banner --report-path="$WORK/hb.json" >/dev/null 2>&1
  printf 'title="x"\n[allowlist]\nregexes=[".*"]\n' > "$WORK/hostile/.gitleaks.toml"
  gitleaks dir "$WORK/hostile" --no-banner --report-path="$WORK/ha.json" >/dev/null 2>&1
  H0="$(cnt "$WORK/hb.json")"; H1="$(cnt "$WORK/ha.json")"
  if [[ "$H0" -gt 0 && "$H1" -eq 0 ]]; then
    printf '  ok    %-42s clean=%s hostile=%s\n' "repo config still blinds gitleaks" "$H0" "$H1"; PASS=$((PASS+1))
  else
    printf '  note  %-42s clean=%s hostile=%s (review step 2a)\n' "repo-config suppression changed" "$H0" "$H1"
  fi
else
  skip "scanner behaviour" "gitleaks not installed"
fi

if command -v trufflehog >/dev/null 2>&1; then
  U0="$(trufflehog filesystem "$R" --results=verified,unknown --json 2>/dev/null | grep -c . || true)"
  U1="$(trufflehog filesystem "$R" --results=verified,unknown,unverified --json 2>/dev/null | grep -c . || true)"
  # The fixture key is syntactically valid and definitively rejected by AWS, so
  # it lands in `unverified`. If the wider set is not strictly larger, either
  # the detector stopped firing or `unverified` stopped meaning what step 3
  # claims — both make the flag advice wrong.
  if [[ "$U1" -gt "$U0" ]]; then
    printf '  ok    %-42s v,u=%s v,u,unver=%s\n' "unverified widens trufflehog" "$U0" "$U1"; PASS=$((PASS+1))
  else
    printf '  FAIL  %-42s v,u=%s v,u,unver=%s (vacuous or narrowed)\n' "unverified check INCONCLUSIVE" "$U0" "$U1"; FAIL=$((FAIL+1))
  fi
fi

# --------------------------------------------------------- fallback patterns
# The FALLBACK ONLY path runs when neither scanner is installed. Nothing else
# exercises it, and a pattern file that matches nothing fails exactly like a
# clean repo. Each shape below must be matched by name.
echo
echo "fallback patterns"
PAT="$HERE/../assets/patterns.txt"
KEY="$HERE/../assets/patterns-keywords.txt"
if [[ -r "$PAT" && -r "$KEY" ]]; then
  CORPUS="$WORK/corpus.txt"
  cat > "$CORPUS" <<'CORP'
{"installed":{"client_secret":"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"}}
{"token": "abcdefghij12345"}
github ghp_0123456789abcdefghijklmnopqrstuvwxyz
google_api AIzaSyD-1234567890abcdefghijklmnopqrstu
password=hunter2xyzabc
api_key: abcdefgh12345678
postgres://user:pa55word@db.internal:5432/app
-----BEGIN RSA PRIVATE KEY-----
CORP
  # Appended, not inline: keeps the literal id out of this file. Still 9 lines.
  printf 'aws_key %s\n' "$FAKE_ID" >> "$CORPUS"
  # Prose that must NOT match, or the fallback drowns the auditor in noise.
  cat > "$WORK/prose.txt" <<'PROSE'
The author documented how secrets are rotated and who can authorize it.
We discussed the password policy and token lifetime in the design review.
PROSE

  hits() { grep -cEi -f "$1" "$2" 2>/dev/null || true; }
  P_HITS="$( { grep -cE -f "$PAT" "$CORPUS" 2>/dev/null || true; } )"
  K_HITS="$(hits "$KEY" "$CORPUS")"
  FP="$(hits "$KEY" "$WORK/prose.txt")"

  # 6 of the 9 corpus lines carry a shape patterns.txt names outright.
  if [[ "${P_HITS:-0}" -ge 6 ]]; then
    printf '  ok    %-42s %s/9 lines\n' "patterns.txt matches known shapes" "$P_HITS"; PASS=$((PASS+1))
  else
    printf '  FAIL  %-42s %s/9 lines, want >=6\n' "patterns.txt UNDER-MATCHING" "${P_HITS:-0}"; FAIL=$((FAIL+1))
  fi

  # JSON quoting is the regression that mattered: "client_secret":"..." has a
  # quote between the keyword and the colon, which the original rule could not
  # cross, so no JSON credential file matched at all.
  if grep -qEi -f "$KEY" <<'J'
{"installed":{"client_secret":"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"}}
J
  then
    printf '  ok    %-42s\n' "keyword rule crosses JSON quoting"; PASS=$((PASS+1))
  else
    printf '  FAIL  %-42s JSON credential files match nothing\n' "keyword rule BLIND to JSON"; FAIL=$((FAIL+1))
  fi

  if [[ "${K_HITS:-0}" -ge 4 ]]; then
    printf '  ok    %-42s %s lines\n' "keyword rule matches assignments" "$K_HITS"; PASS=$((PASS+1))
  else
    printf '  FAIL  %-42s %s lines, want >=4\n' "keyword rule UNDER-MATCHING" "${K_HITS:-0}"; FAIL=$((FAIL+1))
  fi

  if [[ "${FP:-0}" -eq 0 ]]; then
    printf '  ok    %-42s\n' "keyword rule ignores prose"; PASS=$((PASS+1))
  else
    printf '  FAIL  %-42s %s prose lines matched\n' "keyword rule TOO NOISY" "$FP"; FAIL=$((FAIL+1))
  fi
else
  skip "fallback patterns" "assets/ not found"
fi

echo
echo "pass=$PASS fail=$FAIL skip=$SKIP"
if [[ "$FAIL" -gt 0 ]]; then
  echo "GUARD IS BROKEN — assert_scanned.sh cannot be trusted to catch a dead scan."
  exit 1
fi
[[ "$SKIP" -gt 0 ]] && echo "note: skipped modes were not verified."
echo "Guard fails on dead scans and passes live ones."
