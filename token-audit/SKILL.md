---
name: token-audit
description: Audit a Claude Code setup for token waste and report it. Measures CLAUDE.md size, MCP tool surface and whether deferral is active, proxy vars that silently kill deferral, model and effort source, output-filtering PreToolUse hooks, subagent model inheritance, scheduled jobs against cache lifetime, and per-turn cache split from the session log. Use on "audit my context", "token waste", "why is my context so big", "what is burning tokens", "cache audit", or /token-audit. Reports only, changes nothing.
---

# Token audit

Measure. Do not estimate. Write UNKNOWN rather than guess. Change no file and no
setting, including when a finding is trivial to fix. The user asked for a report.

Ask the user to run `/context` and paste the output. You cannot invoke it. It is
the only source of real token counts, because no offline Claude tokenizer exists
(`tiktoken` is a GPT tokenizer, `anthropic.count_tokens` needs an API call). Do
everything below first, then ask, then fill in the token column.

## 1. Memory

```bash
for f in "$PWD/CLAUDE.md" "$PWD/AGENTS.md" ~/.claude/CLAUDE.md; do [ -f "$f" ] && wc -c "$f"; done
find "$PWD" -name CLAUDE.md -o -name AGENTS.md
grep -n '^@' ~/.claude/CLAUDE.md   # @imports pull more files in
```

Walk parent directories too. Flag any single file over 5k tokens, any total over 10k.
`/context` reports this as "Memory files".

## 2. Tools

```bash
python3 -c "
import json; d=json.load(open('$HOME/.claude.json'))
print('global:', list(d.get('mcpServers',{})))
p=d['projects'].get('$PWD',{}); print('project:', list(p.get('mcpServers',{})))
print('enabled .mcp.json:', p.get('enabledMcpjsonServers'), 'disabled:', p.get('disabledMcpjsonServers'))"
ls .mcp.json ~/.claude/mcp*.json 2>/dev/null
```

Count tools per server from the deferred-tool system-reminder in your own context.
That list is authoritative for the session. A server configured in `.claude.json`
with zero tools in the list is dead: it pays process startup and returns nothing.

State plainly whether deferral is ACTIVE or NOT. Deferral is ACTIVE when the
reminder says schemas are not loaded and `/context` shows MCP tools at 0 tokens.

Then check for a proxy or gateway, because routing through one turns deferral off
and nothing warns you:

```bash
env | grep -iE 'ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_API_KEY|CLAUDE_CODE_USE_BEDROCK|CLAUDE_CODE_USE_VERTEX|PROXY|GATEWAY'
grep -rniE 'ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_USE_BEDROCK|CLAUDE_CODE_USE_VERTEX' \
  ~/.zshrc ~/.zshenv ~/.zprofile ~/.bashrc ~/.profile 2>/dev/null
```

If you find one, say so loudly. RED, first row of the table.

## 3. Model

Read the model id from your own system prompt. Then find where it is set:

```bash
grep -niE '"model"|effort|"fast"' ~/.claude/settings.json .claude/settings*.json 2>/dev/null
env | grep -iE 'CLAUDE_EFFORT|ANTHROPIC_MODEL'
python3 -c "
import json; d=json.load(open('$HOME/.claude.json'))
print({k:d.get(k) for k in ['hasOpusPlanDefault','orgModelDefaultCache']})"
```

An env var with no file backing it means the source is a runtime `/model` or
`/effort` command. Write UNKNOWN for the source file.

Check the session log for more than one model id. Every switch rebuilds the whole
cache. Small side-model calls (haiku for titles, quota checks) are not switches.

A `[1m]` model id at low window use is a real finding. Report measured window
utilization, not a pricing multiplier you cannot verify.

## 4. Hooks

```bash
grep -rl PreToolUse ~/.claude/settings.json ~/.claude/settings.local.json \
  .claude/settings*.json ~/.claude/plugins/cache/*/*/*/hooks/ 2>/dev/null
```

Look for hooks that rewrite noisy commands into quieter ones. If there are none,
say so. Unfiltered test and build output lands in context verbatim and is re-sent
for the rest of the session.

Read every hook file you find. Plugin hook directories ship templates for other
agents (`qoder-hooks.json`, `copilot-hooks.json`, `hooks-cursor.json`). Only the
file named in `.claude-plugin/plugin.json` is live. A template PreToolUse is not
a PreToolUse.

## 5. Subagents

```bash
ls -la ~/.claude/agents .claude/agents 2>/dev/null
grep -H '^model:' ~/.claude/agents/*.md .claude/agents/*.md 2>/dev/null
```

Report each agent's explicit `model:` or that it inherits the session model. Empty
directories mean every built-in agent type runs the main model, which is the
finding, not the absence of one.

## 6. Scheduled work

```bash
crontab -l 2>&1
ls ~/Library/LaunchAgents 2>/dev/null    # launchd on macOS
ls ~/.claude/jobs 2>/dev/null
systemctl --user list-timers 2>/dev/null # linux
```

Also call `CronList` for in-session jobs. Compare each interval against the prompt
cache lifetime, which this harness states in the `ScheduleWakeup` description.
Flag every interval longer than that: it misses cache on every fire.

## 7. Cache

```bash
python3 - <<'PY'
import json,glob,os
f=max(glob.glob(os.path.expanduser('~/.claude/projects/*/*.jsonl')),key=os.path.getmtime)
print(f)
tot={'cache_read_input_tokens':0,'cache_creation_input_tokens':0,'input_tokens':0,'output_tokens':0}
seen,ctxs=set(),[]
for line in open(f):
    d=json.loads(line)
    if d.get('type')!='assistant': continue
    u=(d.get('message') or {}).get('usage')
    if not u: continue
    key=(d['timestamp'],u.get('output_tokens'))
    if key in seen: continue          # entries repeat once per content block
    seen.add(key)
    for k in tot: tot[k]+=u.get(k,0) or 0
    ctxs.append(sum(u.get(k,0) or 0 for k in
        ('cache_read_input_tokens','cache_creation_input_tokens','input_tokens')))
g=sum(tot.values())
print('turns',len(ctxs))
for k,v in sorted(tot.items(),key=lambda x:-x[1]): print(f'  {k:32}{v:>12,}{100*v/g:>7.1f}%')
print(f'  TOTAL{g:>39,}')
print('first turn ctx',f'{ctxs[0]:,}','last turn ctx',f'{ctxs[-1]:,}')
PY
```

Dedupe before summing. Each assistant turn writes one log entry per content block,
so a raw sum over-counts by 2x to 3x. Verify the turn count against the visible
conversation.

The first-turn context is the floor: the tokens re-sent on every single turn.
It is usually the headline finding.

## Output

One table, sorted by cost, highest first. Nothing above it.

```
FINDING | SEVERITY | EVIDENCE | WHAT IT IS COSTING ME
```

Severity is RED, AMBER or GREEN. Evidence is a number or a file path, never an
adjective. GREEN rows belong in the table: "no proxy found" is a result the user
needs. Give GREEN rows an explicit "Nothing" cost.

Add measurement notes under the table only where a number needs a caveat, such as
log dedup or an unavailable tokenizer.

Then one final line: the single highest-leverage change, one line, nothing else.
Pick it from the largest measured number, not from what is easiest to fix.
