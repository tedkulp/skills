---
name: implement-next
description: Pick the next unblocked ready-for-agent ticket from this repo's tracker, claim it, and run /implement on it.
disable-model-invocation: true
argument-hint: "[ticket number]"
---

# Implement next

Take one ticket from the **frontier** (open, agent-ready, unblocked, unclaimed) through `/implement`.

## 1. Check the repo is set up

The repo is set up when `CLAUDE.md` or `AGENTS.md` has an `## Agent skills` section and `docs/agents/issue-tracker.md` exists. If not, stop and tell the user to run `/setup-matt-pocock-skills`.

Read `docs/agents/issue-tracker.md` (how to list, read, claim and comment on tickets) and `docs/agents/triage-labels.md` (the label string for the `ready-for-agent` role). Every tracker operation below follows those two files.

## 2. Pick the ticket

**With an argument**, use that ticket. If it is closed, claimed by someone else, or has an open blocker, say so and ask before going on.

**Without one**, first look for an open agent-ready ticket already assigned to the current user: that is an interrupted run. Ask whether to resume it.

Otherwise build the frontier: open tickets with the agent-ready label, no assignee, and no open blocker. A ticket has an open blocker when:

- **GitHub**: `gh api repos/<owner>/<repo>/issues/<n> --jq .issue_dependencies_summary.blocked_by` is above 0 (native dependencies count open blockers only). If the ticket has no native dependencies, use any `#<n>` under its `## Blocked by` heading that is still open.
- **Local markdown**: any ticket named in its "Blocked by" line whose status is not done.

Pick the lowest-numbered frontier ticket. If the frontier is empty, list each open agent-ready ticket with what holds it (e.g. `#27: blocked by #46`, `#31: assigned to @x`), then stop.

Done when: one ticket is chosen and shown to the user as its number, its title, and why it's next.

## 3. Claim and branch

1. The working tree must be clean. If it isn't, stop and ask.
2. Claim the ticket the way `issue-tracker.md` says (on GitHub: `gh issue edit <n> --add-assignee @me`).
3. Update the default branch, then create a branch named `<n>-<short-slug-of-title>` from it.

## 4. Implement

Read the whole ticket: its body, its comments, and every doc it cites (spec sections, `CONTEXT.md`, ADRs per `docs/agents/domain.md`). The ticket is the spec.

Run `/implement` on it. `/implement` is user-invoked, so the Skill tool refuses it. Instead, read the newest copy of its instructions and follow them in full:

```sh
ls -d ~/.claude/plugins/cache/*/mattpocock-skills/*/skills/engineering/implement/SKILL.md | sort -V | tail -1
```

End the final commit message with `Closes #<n>` so that merging the branch closes the ticket.

Done when:

- every acceptance criterion in the ticket is met
- the full test suite is green
- the `/code-review` findings are resolved
- the work is committed on the ticket branch

If a criterion can't be met (it needs a human, or it conflicts with the spec), stop and report it rather than skipping it.

## 5. Report

1. Comment on the ticket: what was built, each acceptance criterion with its status, and anything deferred.
2. Tell the user the ticket, the branch, the commits and the test result.
3. Offer to push and open a PR. Do it only on a yes.
