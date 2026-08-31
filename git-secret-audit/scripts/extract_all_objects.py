#!/usr/bin/env python3
"""
extract_all_objects.py — materialize every object in a git object database as a
plain file, so a filesystem-mode secret scanner can see all of it.

The problem this solves: gitleaks and trufflehog in git mode walk refs. Objects
that no ref points at are invisible to a ref walk, but they still sit in
.git/objects until gc prunes them, and anyone who gets the repo directory can
recover them. Amended commits, `reset --hard`, deleted branches, abandoned
rebases and dropped stashes all leave objects like this behind.

Each object is classified into one of three tiers, which is what drives triage:

  refs    reachable from any ref a mirror push sends, which is all of refs/
          except refs/stash. Branches and tags, and also refs/notes/*,
          refs/replace/* and custom namespaces.
          THIS IS WHAT A PUSH PUBLISHES. Findings here are the emergency.
  reflog  only reachable via the reflog or stash. Local-only: a normal push
          does not send these, and a fresh clone drops them. Still worth
          knowing about, because the repo directory itself may get shared.
  orphan  reachable from nothing at all. Same local-only exposure as reflog,
          and the strongest sign that someone already tried to bury something.

Usage:
    python3 extract_all_objects.py --out /tmp/audit [--repo PATH] [--max-bytes N]

Output:
    <out>/blobs/<tier>/<oid12>__<path>   file contents, one per blob version
    <out>/messages/<tier>/<type>-<oid12>.txt   commit and annotated-tag messages
    <out>/MANIFEST.tsv                   oid, type, tier, name
    <out>/SUMMARY.txt                    counts per tier
"""

import argparse
import os
import re
import subprocess
import sys

SAFE = re.compile(rb"[^A-Za-z0-9._#=+-]")


def git(args, repo, **kw):
    return subprocess.run(
        ["git", "-C", repo] + args,
        capture_output=True, check=False, **kw
    )


def oid_set(repo, revlist_args):
    """Object ids emitted by a `git rev-list --objects` invocation."""
    out = git(["rev-list", "--objects"] + revlist_args, repo).stdout
    return {line.split(b" ", 1)[0] for line in out.splitlines() if line}


def pushable_refs(repo):
    """
    Every ref a `git push --mirror` would send: all of refs/, minus refs/stash.

    Not `--branches --tags --remotes`. That triple silently omits refs/notes/*,
    refs/replace/* and every custom namespace (Gerrit refs/changes/*, forge
    refs/pull/*, homegrown refs/backup/*), so a secret reachable only from one
    of those gets filed as local-only and reported as harmless. A mirror push
    sends it. Under-stating exposure is the one error this tool must not make.

    refs/stash stays out because a push does not send it and a clone does not
    take it, which is what puts stashed content in the `reflog` tier.
    """
    out = git(["for-each-ref", "--format=%(refname)"], repo).stdout
    return [r for r in out.splitlines() if r and not r.startswith(b"refs/stash")]


def oid_set_refs(repo, refnames):
    """Object ids reachable from an explicit ref list, fed over stdin."""
    if not refnames:
        return set()
    out = subprocess.run(
        ["git", "-C", repo, "rev-list", "--objects", "--stdin"],
        input=b"\n".join(refnames), capture_output=True, check=False,
    ).stdout
    return {line.split(b" ", 1)[0] for line in out.splitlines() if line}


def path_map(repo):
    """
    oid -> last-seen path, covering orphaned blobs too.

    Ordinary `rev-list --objects --all` only names objects reachable from refs.
    To get names for orphaned blobs, feed rev-list every commit in the object
    database, including ones nothing points at.
    """
    check = git(
        ["cat-file", "--batch-all-objects", "--unordered",
         "--batch-check=%(objectname) %(objecttype)"], repo
    ).stdout
    commits = [l.split()[0] for l in check.splitlines() if l.endswith(b" commit")]
    paths = {}
    # chunk so the argument list / stdin stays sane on very large repos
    for i in range(0, len(commits), 5000):
        chunk = b"\n".join(commits[i:i + 5000])
        out = subprocess.run(
            ["git", "-C", repo, "rev-list", "--objects", "--no-walk", "--stdin"],
            input=chunk, capture_output=True, check=False,
        ).stdout
        for line in out.splitlines():
            parts = line.split(b" ", 1)
            if len(parts) == 2 and parts[1]:
                paths.setdefault(parts[0], parts[1])
    return paths


def sanitize(raw: bytes) -> str:
    return SAFE.sub(b"_", raw.replace(b"/", b"#"))[:160].decode("utf-8", "replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=".")
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-bytes", type=int, default=10 * 1024 * 1024)
    args = ap.parse_args()

    repo = args.repo
    if git(["rev-parse", "--git-dir"], repo).returncode != 0:
        sys.exit(f"error: not a git repository: {repo}")

    # Tier membership. `refs` is everything a mirror push would send, which is
    # all of refs/ except refs/stash. See pushable_refs() for why the obvious
    # --branches --tags --remotes is wrong.
    refs = oid_set_refs(repo, pushable_refs(repo))
    recoverable = oid_set(repo, ["--all", "--reflog"])
    paths = path_map(repo)

    for tier in ("refs", "reflog", "orphan"):
        os.makedirs(os.path.join(args.out, "blobs", tier), exist_ok=True)
        os.makedirs(os.path.join(args.out, "messages", tier), exist_ok=True)

    listing = git(
        ["cat-file", "--batch-all-objects", "--unordered",
         "--batch-check=%(objectname) %(objecttype) %(objectsize)"], repo
    ).stdout.splitlines()

    wanted = []
    manifest = ["oid\ttype\ttier\tname"]
    counts = {t: {"blob": 0, "commit": 0, "tag": 0} for t in ("refs", "reflog", "orphan")}
    skipped = 0

    for line in listing:
        oid, otype, osize = line.split()
        if otype == b"tree":
            continue
        tier = "refs" if oid in refs else ("reflog" if oid in recoverable else "orphan")
        short = oid[:12].decode()

        if otype == b"blob":
            if int(osize) > args.max_bytes:
                manifest.append(f"{oid.decode()}\tblob\t{tier}\tSKIPPED-oversize({int(osize)}B)")
                skipped += 1
                continue
            p = paths.get(oid)
            name = f"{short}__{sanitize(p)}" if p else f"{short}__NO-PATH"
            dest = os.path.join(args.out, "blobs", tier, name)
            label = p.decode("utf-8", "replace") if p else "<orphaned blob, no path>"
        else:
            kind = otype.decode()
            dest = os.path.join(args.out, "messages", tier, f"{kind}-{short}.txt")
            label = f"{kind} message"

        wanted.append((oid, dest))
        manifest.append(f"{oid.decode()}\t{otype.decode()}\t{tier}\t{label}")
        counts[tier][otype.decode()] += 1

    # Stream every object through a single cat-file process rather than forking
    # once per object — the difference is minutes on a large repository.
    proc = subprocess.Popen(
        ["git", "-C", repo, "cat-file", "--batch"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    )
    for oid, dest in wanted:
        proc.stdin.write(oid + b"\n")
        proc.stdin.flush()
        header = proc.stdout.readline()          # "<oid> <type> <size>\n"
        size = int(header.split()[2])
        body = proc.stdout.read(size)
        proc.stdout.read(1)                      # trailing newline
        with open(dest, "wb") as fh:
            fh.write(body)
    proc.stdin.close()
    proc.wait()

    with open(os.path.join(args.out, "MANIFEST.tsv"), "w") as fh:
        fh.write("\n".join(manifest) + "\n")

    lines = [f"repo: {os.path.abspath(repo)}", f"extracted to: {os.path.abspath(args.out)}", ""]
    for tier, note in (
        ("refs", "PUBLISHED BY A PUSH — treat findings here as live exposure"),
        ("reflog", "local-only: not pushed, dropped by a fresh clone"),
        ("orphan", "local-only, unreachable from any ref — someone buried this"),
    ):
        c = counts[tier]
        lines.append(f"{tier:<8} blobs={c['blob']:<6} commits={c['commit']:<6} tags={c['tag']:<4} {note}")
    lines += ["", f"skipped (oversize): {skipped}"]
    summary = "\n".join(lines)
    print(summary)
    with open(os.path.join(args.out, "SUMMARY.txt"), "w") as fh:
        fh.write(summary + "\n")


if __name__ == "__main__":
    main()
