---
name: implement-batch
description: Run /implement on several tickets or work items at once, each in its own background subagent, merged onto one integration branch.
disable-model-invocation: true
argument-hint: "<ticket numbers or items, e.g. 12 15 18>"
---

# Implement batch

Take every item the user passed through `/implement`, one **implementer subagent** per item, running concurrently. All the work lands on a single **integration branch**, ready for one PR. You are the **coordinator**: you claim, schedule, merge, and report; the subagents build.

Communicate with subagents through **context pointers** (ticket numbers, file paths, branch names), never by pasting ticket bodies or skill text into their prompts.

## 1. Resolve the items

The arguments are ticket references (`12`, `#12`), freeform work descriptions, or a mix. If the split between items is ambiguous, ask.

For ticket references, the repo must be set up: `CLAUDE.md` or `AGENTS.md` has an `## Agent skills` section and `docs/agents/issue-tracker.md` exists. If not, stop and tell the user to run `/setup-matt-pocock-skills`. Read `docs/agents/issue-tracker.md` and `docs/agents/triage-labels.md`; every tracker operation below follows them.

For each ticket, check its state. Flag any that is closed, assigned to someone else, or has an open blocker **outside** the batch, and ask before keeping it.

Build the **task graph** inside the batch: a ticket blocked by another batch ticket waits until its blocker is merged. On GitHub, blockers come from `gh api repos/<owner>/<repo>/issues/<n> --jq .issue_dependencies_summary.blocked_by` or the `## Blocked by` heading.

Done when: the user has seen the integration branch name (`batch-<n>-<n>-...`, or a short slug for freeform items) and one line per item: number or short label, title, and what it waits on, if anything.

## 2. Prepare

1. The working tree must be clean. If it isn't, stop and ask.
2. Update the default branch, create the integration branch from it, and check it out. Worktrees fork from here.
3. Claim each ticket the way `issue-tracker.md` says (on GitHub: `gh issue edit <n> --add-assignee @me`).
4. Find the newest `/implement` instructions and keep the path for the subagent prompts:

```sh
ls -d ~/.claude/plugins/cache/*/mattpocock-skills/*/skills/engineering/implement/SKILL.md | sort -V | tail -1
```

## 3. Dispatch and merge

Launch one Agent call per item on the **frontier** (items with nothing unmerged blocking them), all in a single message, each with `isolation: "worktree"` and `run_in_background: true`. The prompt carries only:

- the item: ticket number, or the user's description verbatim for freeform items;
- the integration branch name, with: "Confirm your worktree is based on the integration branch tip; reset onto it if not. Create branch `<n>-<slug>` there.";
- the path to the `/implement` SKILL.md, with: "`/implement` is user-invoked, so the Skill tool refuses it. Read that file and follow it in full.";
- for tickets: "Read the whole ticket, its comments, and every doc it cites. The ticket is the spec. End the final commit message with `Closes #<n>`.";
- "Before reporting, merge the integration branch tip into your branch and get the full test suite green again. Commit; leave pushing to the coordinator.";
- the report format: branch, commit SHAs, full test-suite result, each acceptance criterion with its status, anything deferred or needing a human.

When an implementer finishes, hand its branch to a **merger subagent** (foreground, one at a time so merges never race): merge the branch into the integration branch, resolve conflicts against both tickets' intent, run the full test suite, commit. Then check whether the merge unblocks a waiting item and dispatch it immediately.

An implementer that reports a criterion it can't meet is done; record it, merge only if its work stands alone, and leave its dependents undispatched.

Done when: every item is merged into the integration branch or has a recorded reason it isn't.

## 4. Review

Call the Skill tool with `code-review` on the integration branch, against the default branch. Fix every finding in a single implementer subagent working directly on the integration branch, then rerun the full test suite.

Done when: every finding is fixed or recorded as deliberately skipped with a reason, and the suite is green.

## 5. Report

1. Comment on each ticket: what was built, each acceptance criterion with its status, anything deferred.
2. Remove the implementer worktrees with `git worktree remove` and delete their per-item branches; the integration branch keeps the history.
3. Show the user the integration branch, the full test result, and one row per item: item, merge commit, status.
4. Offer to push the integration branch and open one PR that closes every merged ticket. Do it only on a yes.
