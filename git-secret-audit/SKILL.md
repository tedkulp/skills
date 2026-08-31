---
name: git-secret-audit
description: Audit a git repository for leaked credentials across its entire object database — every branch, every historical commit, commit and tag messages, stashes, and unreachable or "dangling" commits that ref-walking scanners miss. Use this whenever someone is about to publish, open-source, mirror, or make public a repository that was previously private; whenever they ask whether a secret, API key, token, password, or .env file ever got committed; whenever they mention scanning git history for secrets, gitleaks, trufflehog, or a pre-publish security check; and whenever they are cleaning up a repo after a credential was exposed. Uses gitleaks and trufflehog when they are installed and says plainly what coverage is lost when they are not. Use it even if they only say something like "I'm putting this on GitHub tomorrow, does it look clean?" — the check is cheap and the failure mode is permanent.
---

# Git secret audit

Publishing a repository is irreversible. Once history is public, assume every
object in it has been cloned, indexed and archived within minutes. This skill
finds credentials *before* that, in places a casual scan misses.

## Script paths

The bundled scripts are referenced below relative to this skill's directory,
but the working directory during an audit is the repository being scanned. Set
this once and use it throughout, adjusting for wherever the skill is installed:

```bash
SKILL_DIR=~/.claude/skills/git-secret-audit      # personal install
# SKILL_DIR=.claude/skills/git-secret-audit      # project install
```

Then invoke scripts as `bash "$SKILL_DIR/scripts/preflight.sh"` and
`python3 "$SKILL_DIR/scripts/extract_all_objects.py"`. If a script is not found
at that path, locate the skill directory before continuing rather than skipping
the step — the object sweep is the part that catches what other scanners miss.

What is bundled:

| Path | Purpose |
| --- | --- |
| `scripts/preflight.sh` | which scanners are installed, and what their absence costs |
| `scripts/extract_all_objects.py` | every object on disk, sorted into the three tiers |
| `scripts/assert_scanned.sh` | proves a scan did work before its empty result is believed |
| `scripts/selfcheck.sh` | proves `assert_scanned.sh` still fails on a dead scan |
| `references/remediation.md` | rotate, rewrite, and the already-public playbook |
| `references/disclosure-review.md` | what to check that is not a credential |
| `references/no-scanner-fallback.md` | pattern sweep when neither scanner exists |

## The mental model: what actually gets published

Not everything in `.git/objects` gets pushed, and not everything that gets
pushed is in the working tree. Sort every finding into one of three tiers,
because the tier decides the urgency:

| Tier | Meaning | Exposure if you push |
| --- | --- | --- |
| `refs` | Reachable from any ref a mirror push sends: all of `refs/` except `refs/stash`. Branches and tags, and also `refs/notes/*`, `refs/replace/*`, and custom namespaces | **Published.** This is the real emergency. |
| `reflog` | Only reachable via reflog or stash | Not pushed; a fresh clone drops it. Local risk only. |
| `orphan` | Reachable from nothing — amended away, reset past, abandoned rebase | Not pushed; local risk only. Also the strongest signal someone already tried to bury something. |

Two consequences worth stating to the user, because they usually expect the
opposite:

- A secret deleted in a later commit is still tier `refs`. Deleting a file does
  not remove its blob from history. This is the single most common way secrets
  get published.
- A secret in a dangling commit is usually *not* published by a normal push.
  It still matters — anyone handed the repo directory can recover it, and it
  tells you a rotation may have been skipped — but do not raise the alarm as if
  it were live exposure.
- `refs` is not only branches and tags. A `git note` is a real ref and a mirror
  push sends it, so note content belongs in the published tier even though a
  plain `git clone` does not fetch notes. The same holds for any custom
  namespace someone has invented.

## Workflow

### 1. Establish scope

Confirm before scanning: which repo, where it is being published, and whether
history is being carried over or the project is starting fresh. If the user
does not need the history, the fastest safe answer is to publish a new repo
with a single initial commit — no scan can be as certain as history that never
existed.

Run the audit against the **original working repository**, not a fresh clone.
A clone contains only ref-reachable objects, so scanning a clone silently
discards the reflog and orphan tiers.

### 2. Preflight: detect what is available

Always start here. Do not assume either scanner is present, and do not install
anything without asking:

```bash
bash "$SKILL_DIR/scripts/preflight.sh"
```

It reports which tools are on `PATH` and what coverage that gives you:

| Result | What to do |
| --- | --- |
| `FULL` (both) | Proceed. Run both scanners at every scanning step. |
| `PARTIAL` (one) | Proceed, and carry the named limitation into the report's coverage section. |
| `FALLBACK ONLY` (neither) | Tell the user *before scanning* that the audit will be materially weaker, offer to install, and only proceed with the pattern sweep if they decline or cannot. |

Invocations in this skill were verified against **gitleaks 8.30.1** and
**trufflehog 3.97.1**. Both tools change flag semantics between releases —
`--redact` became a uint in gitleaks, and `--branch` never accepted a
wildcard — so if a command is rejected, check the installed version against
these before assuming the skill is wrong. `preflight.sh` prints the versions
it finds.

The two tools have different strengths, which is why the ideal is both:

- **gitleaks** — rules plus entropy heuristics. Broad recall, more noise.
- **trufflehog** — fewer rules, but *verifies* candidates against live provider
  APIs, so it distinguishes an active credential from a dead example string.
  That verification is what makes triage tractable.

When something is missing, say what it costs in concrete terms rather than as a
generic caveat. Without trufflehog there is no live verification, so every
finding must be treated as potentially active. Without gitleaks the ruleset
narrows and entropy detection disappears, so unusual credential formats slip
through. Without either, only the listed patterns are detectable at all.

`preflight.sh` prints the install commands for whatever is absent. Offer them;
let the user decide. If they decline or the environment is locked down, use the
pattern sweep in `references/no-scanner-fallback.md` — and never report a clean
fallback sweep as a clean audit.

### 2a. Neutralize the repo's own scanner config — do this before any scan

Both scanners read configuration out of the tree they are auditing. A stale,
over-broad, or hostile allowlist therefore steers the audit that is supposed to
be judging it. Measured against a repo with a live-shaped AWS key in plain
sight:

| Suppression planted in the repo | gitleaks reports |
| --- | --- |
| nothing | 2 findings |
| `.gitleaksignore` with one fingerprint | 1 finding |
| `.gitleaks.toml` with `regexes = [".*"]` | **no leaks found** |
| `# gitleaks:allow` on the same line | **no leaks found** |

Report any of these as a finding in its own right. A repo that ships scanner
config is telling you where someone wanted the scanner not to look:

```bash
ls -a .gitleaks.toml gitleaks.toml .gitleaksignore .trufflehogignore 2>/dev/null
git log --all --diff-filter=A --name-only --pretty=format: | sort -u \
  | grep -Ei 'gitleaks|trufflehog|secretsignore|\.baseline'
grep -rn 'gitleaks:allow' . --exclude-dir=.git | head
```

Then take the config out of the scanner's reach. Two rules:

- **`--ignore-gitleaks-allow` cancels inline `# gitleaks:allow` comments.** Pass
  it on every gitleaks run in this skill.
- **`.gitleaks.toml` and `.gitleaksignore` can only be neutralized by absence.**
  Redirecting `--gitleaks-ignore-path` does not work; gitleaks still honours the
  file at the target path. So run step 3 against a scratch clone with the config
  deleted from its worktree:

```bash
git clone --no-local -q . /tmp/scan-copy
rm -f /tmp/scan-copy/.gitleaks.toml /tmp/scan-copy/.gitleaksignore
```

**Never pass `--config /dev/null` to "disable" the repo config.** An empty
config has no rules, so gitleaks detects nothing and reports `no leaks found` —
a total scan failure wearing the exact words of a clean result.

A clone drops `refs/notes`, so the scratch copy covers ordinary history only.
Notes are caught by step 4, which runs against the original repo.

### 3. Ref-reachable scan

This covers ordinary history across all branches and tags. Run whichever of
these preflight reported as available, capturing stderr — the work counts you
need for the next step are logged there, not in the results file:

```bash
# if gitleaks is available — run against the sanitized copy from step 2a
gitleaks git /tmp/scan-copy --log-opts="--all --remotes" -v \
  --ignore-gitleaks-allow --max-archive-depth=8 \
  --report-path=/tmp/gitleaks-refs.json 2>/tmp/gitleaks-refs.err

# if trufflehog is available
trufflehog git file://. --results=verified,unknown,unverified --json \
  > /tmp/th-refs.json 2>/tmp/th-refs.err
```

Four flags that decide how much this scan actually sees:

- **`--branch=all` on trufflehog is wrong.** `--branch` takes one branch name;
  there is no `all` sentinel. Passing it logs `unable to resolve ref` and then
  **exits 0 having scanned nothing**. `trufflehog git` already covers every
  branch by default, so omit the flag entirely.
- **`--redact=false` on gitleaks is a parse error.** `--redact` is a uint
  percentage (0–100), not a boolean, so `=false` kills the command outright.
  Not redacting is already the default, so omit it. Use a bare `--redact` only
  where output is shared, such as CI logs.
- **`--max-archive-depth=8` on gitleaks, because the default is 0.** gitleaks
  does not open archives unless told to. On a repo with the same key in a plain
  file and inside a committed zip and tarball, the default finds 2 and depth 8
  finds 6. Committed `.zip`, `.tar.gz`, `.jar`, `.war` and every Office file
  (`.docx` and `.xlsx` are zips) are otherwise invisible. trufflehog traverses
  archives on its own, so this gap belongs to gitleaks-only runs.
- **`--results` must include `unverified` on trufflehog.** `unverified` means
  trufflehog asked the provider and got a rejection, which covers dead keys and
  revoked-but-real ones alike. Step 6 says not to discard those, so the flag
  must not discard them either. On the archive fixture above,
  `verified,unknown` returned 0 findings and `verified,unknown,unverified`
  returned 5.

### 3a. Confirm the scan did work — do not skip this

A scanner that rejects a flag can still exit 0 and write an empty results file.
Downstream, that is byte-for-byte indistinguishable from a clean repository.
Wrong flags are loud in a terminal and completely silent in the output file,
and the output file is what the rest of the audit reads.

```bash
bash "$SKILL_DIR/scripts/assert_scanned.sh" gitleaks-git /tmp/gitleaks-refs.err .
bash "$SKILL_DIR/scripts/assert_scanned.sh" trufflehog   /tmp/th-refs.err
```

Zero chunks or zero commits is a **failed scan**, not a clean result. Fix the
invocation and re-run; never carry an unverified empty result into the report.

The guard is itself a log-format parser: it greps for `chunks`, `N commits
scanned` and `scanned ~N bytes`. A scanner release that renames any of those
turns it into a no-op that passes everything, silently, in the direction that
hides secrets. `scripts/selfcheck.sh` builds a throwaway repo, runs the real
scanners against it both correctly and with the two broken flags above, and
asserts the guard fails on the dead runs and passes the live ones:

```bash
bash "$SKILL_DIR/scripts/selfcheck.sh"    # exit 0 = guard still works
```

Run it after editing `assert_scanned.sh`, and when a scanner is upgraded. It
skips whichever scanner is absent rather than failing.

**Expect gitleaks to report fewer commits than the repo contains.** It skips
merge commits, so its count tracks `git rev-list --all --remotes --no-merges
--count`, not `--count`. On a repo with 337 commits and 58 merges, 279 is
correct and complete. Merges introduce no new blob content, and step 4's object
sweep walks every commit object regardless, so nothing is lost — but the gap
looks alarming if you are not expecting it. `assert_scanned.sh` prints both
totals so the arithmetic is visible.

If neither is available, run the fallback sweep from
`references/no-scanner-fallback.md` against the extraction output in step 4
instead — it covers ref-reachable history along with everything else.

### 4. Full object-database sweep

The step that catches what ref walks cannot. `scripts/extract_all_objects.py`
materializes every object in the object database — reachable or not — as a
plain file, sorted into the three tiers, then hands the result to the scanners
in filesystem mode:

```bash
python3 "$SKILL_DIR/scripts/extract_all_objects.py" --repo . --out /tmp/audit
cat /tmp/audit/SUMMARY.txt

# then scan the extracted tree with whatever is installed
gitleaks dir /tmp/audit -v --ignore-gitleaks-allow --max-archive-depth=8 \
  --report-path=/tmp/gitleaks-all.json 2>/tmp/gitleaks-all.err
trufflehog filesystem /tmp/audit --results=verified,unknown,unverified --json \
  > /tmp/th-all.json 2>/tmp/th-all.err

# same zero-work guard as step 3a
bash "$SKILL_DIR/scripts/assert_scanned.sh" gitleaks-dir /tmp/gitleaks-all.err /tmp/audit
bash "$SKILL_DIR/scripts/assert_scanned.sh" trufflehog   /tmp/th-all.err
```

Note the omitted `--redact=false` here too, for the reason given in step 3.

The extraction step itself needs nothing but `git` and Python, so the tier
classification is always available even when no scanner is. What changes with
the scanners is detection quality inside the extracted tree, not coverage of
the repository.

Findings arrive with a path like `blobs/orphan/7230b854a6b3__secret.pem` or
`messages/refs/commit-ac81c3e4d555.txt`, so the tier and the original filename
are both readable straight off the finding. `MANIFEST.tsv` maps every extracted
file back to its object id.

This also covers commit and annotated-tag messages, which ref-mode scanners
handle inconsistently. Messages leak more often than people expect — pasted
curl commands, "rotating key to ...", revert notes quoting the thing being
reverted.

One limitation to state honestly: objects already pruned by `git gc` are gone
and unrecoverable by any tool. The sweep covers what still exists on disk.

### 5. Surfaces outside the object database

Check these by hand; no object scan reaches them:

```bash
git config --get-regexp '^remote\..*\.url'   # tokens embedded in remote URLs
cat .git/config                              # and any insteadOf rewrites
git stash list                               # unpushed but locally present
cat .gitmodules 2>/dev/null                  # submodule URLs with credentials
git lfs ls-files 2>/dev/null                 # LFS pointers -> content lives elsewhere
git status --porcelain --ignored             # untracked .env about to be added
```

Also read `.gitignore` critically. A `.env` that is ignored *today* may have
been committed before the ignore rule existed — that shows up in the tier
`refs` results, not here.

**Every linked worktree, not just this one.** `git status` reports on the
current worktree alone, so an untracked `.env` sitting in a sibling worktree is
invisible to the command above. Worktrees share the object database, so their
committed content is already covered; their working files are not.

```bash
git worktree list
git worktree list --porcelain | awk '/^worktree /{print $2}' | while read -r wt; do
  echo "== $wt"
  git -C "$wt" status --porcelain --ignored | head -20
done
```

**Submodules are separate repositories and need their own audit.** Checking
`.gitmodules` for credentials in URLs is not the same as scanning what the
submodule contains. Its objects live in `.git/modules/<name>/`, and publishing
the superproject publishes it too.

```bash
git submodule status --recursive
git submodule foreach --recursive 'echo "== $displaypath"; git rev-list --all --count'
```

Run this whole skill against each submodule before publishing the parent.

**Filename classes the scanners rank poorly.** Rule-based detection is built
around credential *shapes*, so a file that is entirely secret by nature scores
badly. Sweep by name across all history, not just the current tree:

```bash
git log --all --diff-filter=A --name-only --pretty=format: | sort -u | grep -Eif - <<'PATTERNS'
\.tfstate
\.tfvars
kubeconfig
\.npmrc
\.pypirc
\.netrc
\.pgpass
\.my\.cnf
(^|/)\.env
\.pem$
\.key$
\.p12$
\.pfx$
\.jks$
keystore
id_rsa
id_ed25519
dataSources\.xml
google-services\.json
GoogleService-Info\.plist
docker/config\.json
\.dockercfg
credentials$
\.sql$
\.dump$
PATTERNS
```

`*.tfstate` deserves its own mention. Terraform writes provider credentials and
resource attributes into state in plaintext, and it is committed constantly.

**Encrypted-at-rest tooling inverts the usual result.** With git-crypt or
git-secret the worktree shows plaintext while the objects hold ciphertext, so a
worktree scan looks alarming and an object scan looks clean, and neither
answers the question. Check `.gitattributes` for `filter=git-crypt`, confirm the
key file itself was never committed, and state in the report which files are
encrypted and who holds the key.

```bash
grep -rn 'filter=git-crypt\|diff=git-crypt' .gitattributes 2>/dev/null
git log --all --diff-filter=A --name-only --pretty=format: | sort -u \
  | grep -Ei 'git-crypt|\.gitsecret/'
```

### 6. Triage

Order findings by tier, then by verification status. For each one, resolve:
is it live, and was it ever published?

```bash
git log --all --oneline -S 'THE_SECRET_STRING'   # which commits introduced it
git log --all --oneline -G 'PATTERN'             # regex variant
```

Do not silently discard unverified findings. Trufflehog cannot verify internal
services, self-hosted systems, or revoked-but-real credentials — and a revoked
credential still tells you a rotation happened, which is worth confirming.
Report suspected false positives as suspected, with the reasoning, and let the
user decide.

### 6a. Non-credential disclosure

A repo can hold no live credential and still be the wrong thing to publish.
Author identity on every commit, absolute paths naming the user, internal
hostnames, real people's data in test fixtures, and vendored code under an
incompatible license are all invisible to both scanners, because none of them
has a credential shape.

Work through `references/disclosure-review.md` and report what it finds as a
separate section. Keep it out of the verdict. Credentials are a safety gate;
this is the user's judgment call, and a rotation cannot undo a published
customer name.

### 7. Remediate

**Rotate first, rewrite second.** History rewriting removes evidence, not
exposure. If a credential was ever pushed anywhere — including an internal
mirror, a CI cache, or a fork — treat it as compromised and rotate it. A
rewritten history with a live key in a colleague's stale clone is not fixed.

Rewriting steps, `git filter-repo` usage, and the "already public" playbook are
in `references/remediation.md`. Read that file when there is something to fix.

### 8. Publish clean

Once findings are resolved, publish from a fresh clone. A clone copies only
ref-reachable objects, so the reflog and orphan tiers are dropped by
construction rather than by trusting the scan:

```bash
git clone --no-local /path/to/repo /tmp/publish-copy
cd /tmp/publish-copy && git remote set-url origin <public-url>
```

Then re-run step 3 against the clone as a final gate before pushing, with the
same flags used earlier. A gate run with weaker flags than the audit is not a
gate:

```bash
gitleaks git /tmp/publish-copy --log-opts="--all --remotes" -v \
  --ignore-gitleaks-allow --max-archive-depth=8 \
  --report-path=/tmp/gl-gate.json 2>/tmp/gl-gate.err
bash "$SKILL_DIR/scripts/assert_scanned.sh" gitleaks-git /tmp/gl-gate.err /tmp/publish-copy
```

Verify the scan comes back clean rather than assuming it will, and confirm the
guard reported work.

Two things a clone silently drops, which is helpful here and misleading if you
forget it: `refs/notes/*`, and anything in the reflog or orphan tiers. So this
gate does not re-check note content. Step 4 on the original repo is what covers
notes, and a mirror push would carry them — if you intend `git push --mirror`,
re-read the tier `refs` findings for note blobs before pushing.

Enable the host's own push protection too (GitHub secret scanning with push
protection, or the GitLab equivalent) — it is a second net for whatever gets
committed after this audit.

## Reporting

Report in this shape. Lead with what is publishable, because that is the
decision the user is actually making:

```
## Verdict
SAFE TO PUBLISH | DO NOT PUBLISH — <one line why>

## Tier `refs` — would be published
<finding> | <file:line or commit> | <verified?> | <first introduced in>
...

## Tier `reflog` / `orphan` — local only, dropped by a fresh clone
...

## Outside the object database
<remote URLs, stash, linked worktrees, submodules, LFS, untracked files>

## Scanner config found in the repo
<.gitleaks.toml / .gitleaksignore / gitleaks:allow, and what they suppressed>
<"none" is a result worth stating>

## Non-credential disclosure — user's call, not a blocker
<author emails, absolute paths, internal hostnames, PII in fixtures, licensing>

## Required actions
1. Rotate: <credential> at <provider>
2. Rewrite: <path> across <n> commits
3. ...

## Scan coverage
Coverage level: FULL | PARTIAL | FALLBACK ONLY
Tools run (with versions), and for anything missing, what it cost.
Work confirmed: gitleaks N commits scanned, trufflehog N chunks scanned.
  (A report with no work counts is not a completed audit.)
Object counts per tier.
Archive traversal: on (--max-archive-depth) or off, and what that leaves unseen.
Suppression neutralized: --ignore-gitleaks-allow, sanitized clone, or neither.
Anything skipped — oversize blobs (>10 MB by default), pruned objects, LFS
  content, submodules not yet audited — and why.
```

Always include the coverage section, and state the coverage level even when it
is `FULL`. An audit that hides its blind spots is worse than no audit, because
it converts uncertainty into false confidence — and "no findings" from a
degraded scan reads identically to "no findings" from a complete one unless the
report says otherwise.

## Running this in CI

As a merge gate, tier `refs` is the only tier that matters and speed counts:

```bash
set -o pipefail
gitleaks git . --log-opts="--all --remotes" --redact --exit-code 1 2>/tmp/gl.err
bash "$SKILL_DIR/scripts/assert_scanned.sh" gitleaks-git /tmp/gl.err . || exit 1
```

`--redact` is bare here on purpose: it takes a percentage and defaults to full
redaction when passed with no value, which is what you want in shared CI logs.
The guard matters more in CI than anywhere else — a green pipeline from a scan
that silently did nothing is the worst possible outcome.

Add `--ignore-gitleaks-allow` if you do not want a committed `# gitleaks:allow`
comment to be able to wave a secret past the gate. Leave it off if your team
uses those comments deliberately and reviews them. Decide which, rather than
inheriting the default by accident.

`--max-archive-depth=8` costs time proportional to what is archived in the
repo. On a merge gate, enable it only if the repo actually commits archives.

Run the full object sweep on a schedule instead of per-commit — it is
thorough, not fast, and its findings are rarely urgent enough to block a merge.
