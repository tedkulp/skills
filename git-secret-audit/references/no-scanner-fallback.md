# Fallback: pattern sweep without gitleaks or trufflehog

Use only when neither scanner can be installed. This is meaningfully weaker —
no entropy analysis, no live verification, and it will miss any credential
format not listed below. Say so explicitly in the report; do not present a
clean fallback sweep as a clean audit.

Run it against the extracted object tree, so it still covers all three tiers:

```bash
python3 "$SKILL_DIR/scripts/extract_all_objects.py" --repo . --out /tmp/audit
grep -rInE  -f "$SKILL_DIR/assets/patterns.txt"          /tmp/audit/blobs /tmp/audit/messages
grep -rInEi -f "$SKILL_DIR/assets/patterns-keywords.txt" /tmp/audit/blobs /tmp/audit/messages
```

Two pattern files ship with the skill. `$SKILL_DIR/assets/patterns.txt` holds case-sensitive
credential formats. `assets/patterns-keywords.txt` holds the generic keyword rule
and must be run case-insensitively — `PGPASSWORD` and `API_KEY` are common and a
case-sensitive pass silently misses them.

Read the current rules rather than trusting a copy pasted here; an embedded
duplicate drifts from the file that actually runs.

```bash
cat "$SKILL_DIR/assets/patterns.txt"
cat "$SKILL_DIR/assets/patterns-keywords.txt"
```

The keyword rule matches JSON as well as shell and YAML assignment, so
`"client_secret":"..."` in a downloaded credentials file is covered. That is
worth checking after any edit, because a quote sitting between the keyword and
the colon is exactly what a naive version of this rule cannot cross.
`scripts/selfcheck.sh` asserts it.


## Manual entropy check

High-entropy strings that match no known format are the main gap. This flags
long random-looking tokens for human review, with heavy false positives —
minified JS, lockfile hashes, base64 test fixtures:

```bash
grep -rIoE "[A-Za-z0-9+/=_-]{32,}" /tmp/audit/blobs \
  | python3 -c '
import sys, math, collections
for line in sys.stdin:
    path, _, s = line.rstrip("\n").partition(":")
    if len(s) < 32: continue
    c = collections.Counter(s)
    H = -sum(n/len(s) * math.log2(n/len(s)) for n in c.values())
    if H > 4.0: print(f"{H:.2f}  {path}  {s[:60]}")
' | sort -rn | head -50
```

Entropy above roughly 4.0 bits per character is worth a look; above 4.5 is
suspicious. Both thresholds produce noise. Exclude lockfiles, `node_modules`,
minified bundles, and binary fixtures before reviewing.
