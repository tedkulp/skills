# skills

Claude Code skills I've written.

## Install

Clone anywhere, then symlink each skill you want into `~/.claude/skills/`:

```sh
git clone https://github.com/tedkulp/skills.git ~/src/skills
ln -s ~/src/skills/git-secret-audit ~/.claude/skills/git-secret-audit
```

## Skills

| Skill | What it does |
| --- | --- |
| [git-secret-audit](git-secret-audit/) | Scans a git repo's whole object database for leaked credentials, including dangling and unreachable commits that ref-walking scanners miss. Run it before you make a private repo public. Uses gitleaks and trufflehog when installed, and says what coverage is lost when they are not. |
| [token-audit](token-audit/) | Audits a Claude Code setup for token waste: CLAUDE.md size, MCP tool surface and deferral, proxy vars that kill deferral, model and effort source, output-filtering hooks, subagent model inheritance, scheduled jobs against cache lifetime, and per-turn cache split. Reports only, changes nothing. |
| [file-idea](file-idea/) | Turns a one-line idea into a GitHub issue: checks the code for redundancy and duplicates, labels it, then hands it straight to `/triage`. Relies on the mattpocock skills' `docs/agents/` setup. Never implements. |
| [implement-next](implement-next/) | Picks the next unblocked `ready-for-agent` ticket (or the one you name), claims it, branches, and runs the mattpocock `/implement` flow on it through tests, code review and commit. Relies on the mattpocock skills' `docs/agents/` setup. Offers to push and open a PR; never does it unasked. |
| [implement-batch](implement-batch/) | Runs the mattpocock `/implement` flow on several tickets at once, one background subagent and worktree each, merging every finished ticket onto one integration branch. Blocked tickets start once their blockers are merged. Code-reviews the result, then offers one PR; never pushes unasked. Relies on the mattpocock skills' `docs/agents/` setup. |
