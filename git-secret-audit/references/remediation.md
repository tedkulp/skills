# Remediation

Read this once the audit has found something. Order matters: rotation first,
rewriting second, publishing third.

## 1. Rotate

Rewriting history changes what a future cloner sees. It does nothing about
copies that already exist. Rotate if the credential ever left the machine it
was created on — pushed to any remote including internal mirrors, present in a
CI cache or build artifact, in a colleague's clone, or in a backup.

Rotate before rewriting, not after. Rewriting can take a while to coordinate
across a team, and the credential is live for that entire window.

For each credential, capture: provider, what it grants, whether it was
verified live, when it was introduced, and whether the repo was ever pushed
anywhere. That set determines whether this is a cleanup or an incident.

If it granted access to production data, treat it as an incident and follow the
organization's incident process — check provider audit logs for use of the
credential between the commit date and the rotation, rather than assuming it
went unnoticed.

## 2. Rewrite

Use `git filter-repo`. `filter-branch` is deprecated, slow, and easy to get
subtly wrong; BFG is fine but narrower.

```bash
pip install git-filter-repo
```

Work on a copy, never the only surviving version of the repo:

```bash
git clone --no-local /path/to/repo /tmp/rewrite && cd /tmp/rewrite
```

Remove a file from all of history:

```bash
git filter-repo --invert-paths --path config/prod.env --path secrets/
```

Redact a literal string wherever it appears, including in commit messages:

```bash
printf 'AKIAIOSFODNN7EXAMPLE==>REDACTED\n' > /tmp/replacements.txt
git filter-repo --replace-text /tmp/replacements.txt
```

Notes that catch people out:

- `filter-repo` rewrites every downstream commit, so all commit hashes change.
  Every existing clone is now incompatible and must be re-cloned. Coordinate
  this — do not surprise the team with it.
- It removes the `origin` remote deliberately, to stop an accidental push of
  half-finished work. Re-add it when you are ready.
- Open pull requests against the old hashes will break.
- Re-run the full audit after rewriting. Verify the secret is gone rather than
  assuming the filter matched — a typo in a path or pattern fails silently.

Then force-push, having warned everyone with a clone:

```bash
git push --force-with-lease --all && git push --force-with-lease --tags
```

## 3. If the repository is already public

The rewrite is no longer the priority; containment is.

1. Rotate immediately. Assume the credential is compromised regardless of how
   briefly it was exposed — public repos are scraped continuously by automated
   crawlers, and minutes are enough.
2. Check provider audit logs for use between exposure and rotation.
3. Rewrite and force-push.
4. Ask the host to purge cached views. On GitHub, rewritten commits can remain
   reachable by direct SHA URL and through forks until support clears them;
   forks are not rewritten by your force-push.
5. Treat any fork as an independent copy that you do not control.

### Why a force-push does not finish the job on GitHub

This is the step people believe is done when it is not.

- **A force-push orphans commits; it does not delete them.** The old commit
  stays in GitHub's object store and remains fetchable by its full SHA through
  the web UI and the API, indefinitely, until GitHub garbage-collects the
  repository. Anyone who saw the SHA — a crawler, a CI log, a notification
  email, a stale browser tab — keeps access.
- **Forks share one object store.** Every fork of a repository lives in the
  same network on GitHub's side, so an object pushed to any one of them can be
  fetched from any other by SHA, including from the parent. A secret pushed to
  a fork of your repo is retrievable from your repo, and your rewrite does not
  touch the fork.
- **Pull request refs persist.** `refs/pull/<n>/head` keeps the commits of a
  PR after the source branch is deleted and after the fork is deleted. A
  rewrite of the default branch leaves them alone.

So the only actions that actually contain it are rotation, and asking GitHub
Support to run garbage collection on the repository and its network. Open a
support ticket naming the repository and stating that a credential was exposed;
this is a routine request. Do the same on GitLab, which keeps unreachable
objects until a housekeeping run.

Until support confirms, assume the credential is still retrievable, and say so
in the report rather than marking the item closed.

## 4. Prevent recurrence

- Enable push protection on the host (GitHub secret scanning push protection,
  GitLab secret push protection). This blocks at push time, before the object
  reaches a public server.
- Add a pre-commit hook running `gitleaks protect --staged`. Local hooks are
  bypassable and not a control on their own, but they catch honest mistakes at
  the cheapest possible moment.
- Move real credentials out of the repo entirely — environment injection, a
  secrets manager, or SOPS/age-encrypted files where the encrypted form is
  what gets committed.
- Commit a `.env.example` with placeholder values and gitignore the real
  `.env`, so the working pattern is the safe one.
