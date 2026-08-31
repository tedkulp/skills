# Non-credential disclosure

A repository can be free of live credentials and still be the wrong thing to
publish. Nothing here is detected by gitleaks or trufflehog, because none of it
has a credential shape. Read this before the final verdict, and report what you
find as a decision for the user rather than as a blocker you decide alone.

Publishing is irreversible in the same way a leaked key is. The difference is
that a key can be rotated and a customer's name cannot.

## Identity carried by every commit

Author and committer identity is baked into each commit object and survives any
rewrite that does not deliberately target it.

```bash
git log --all --format='%an <%ae>' | sort | uniq -c | sort -rn
git log --all --format='%cn <%ce>' | sort | uniq -c | sort -rn
```

Ask whether the address should be public. A personal address on a work project,
or a work address on a personal one, is the common surprise. Rewriting it later
means rewriting every commit, so raise it before the first push, not after.

Commits signed with SSH carry the signer's **public** key in the `gpgsig`
header. That is not a secret and needs no action; note it so nobody raises it
as one on a later read.

## Machine and filesystem detail

Absolute paths leak usernames, directory layout, and sometimes the names of
unrelated private projects.

```bash
git grep -nIE '/(Users|home)/[A-Za-z0-9._-]+' -- . | head -20
git log --all -p | grep -oE '/(Users|home)/[A-Za-z0-9._-]+' | sort | uniq -c | sort -rn | head
```

Check the same for internal hostnames, private IP ranges, S3 bucket names, and
internal URLs. These have no credential value on their own and considerable
reconnaissance value together.

```bash
git grep -nIE '\.(internal|corp|local|lan)\b|10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.' -- . | head -20
```

## Personal data in fixtures and dumps

Test fixtures accumulate real data because real data is convenient. Look for
real names, addresses, phone numbers and email addresses in seed files, test
fixtures, and any `.sql` or `.dump` committed for convenience.

```bash
git grep -nIE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' -- . \
  | grep -viE 'example\.(com|org|net)|@test|\.invalid|noreply|localhost|git@(github|gitlab)\.com' \
  | head -20
```

Filter out the obvious placeholder domains first, then read what is left. A
single real customer address in a fixture is a privacy problem that a secret
scanner will never report.

## Content you may not have the right to publish

- Vendored third-party code under a license incompatible with the one you are
  about to apply.
- Code written under a different employer's IP assignment.
- Screenshots, logos, or sample documents belonging to a customer.

```bash
git log --all --diff-filter=A --name-only --pretty=format: | sort -u \
  | grep -Ei 'vendor/|third_party/|LICENSE|COPYING|NOTICE'
```

## Intent visible in history

History narrates decisions. Commit messages, reverted commits, and abandoned
branches can disclose unshipped plans, security incidents, customer names, or
frank assessments of people and vendors.

```bash
git log --all --format='%s' | sort -u | head -50
git log --all -i --grep='revert\|incident\|outage\|customer\|lawsuit\|hack' --oneline
```

Squashing to a single initial commit removes all of it at once, and is the
right call whenever the history is not itself the point of publishing.

## How to report this

Keep it separate from the credential findings and do not merge it into the
verdict. Credentials are a safety gate; this is a judgment call that belongs to
the user. List what is publishable, say plainly that none of it is a
credential, and let them decide.
