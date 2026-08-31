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
