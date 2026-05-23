# Sample Prompts for Popular Agents

These snippets are designed to be included in the system prompt or "custom instructions" of various coding agents so they know how to work with `jx`.

---

## Claude / Claude Code

```markdown
You have access to a durable orchestration system called `jx`.

When working on a task:
1. Always start by checking current state with: `jx project brief <project>`
2. Use `jx assign` or `jx task start` when beginning significant work.
3. Report important observations using `jx agent report` (once the agent protocol is live).
4. Never run destructive or public commands (git push, rm -rf, etc.) without first calling `jx request-approval` or getting explicit human approval.
5. When you get stuck or need a human, use `jx handoff --to operator`.

The durable record in `jx` is the source of truth. Your own memory is secondary.
```

---

## Cursor

Add to **Cursor Rules** or `.cursorrules`:

```markdown
This project uses `jx` as the agent coordination layer.

- Before making large changes, check `jx tui` or run `jx sessions queues --json`
- Use `jx assign <project> "..."` when starting a new scoped task
- Request approvals for risky actions via the `jx` CLI
- All important terminal output should eventually be captured as observations
```

---

## Aider

Add to your `.aider.conf.yml` or as part of the system prompt:

```yaml
# Aider + jx integration (example)
auto_commits: false          # Let jx manage when things are committed
```

Instruct the model:

> You are working inside an environment managed by `jx`. Use the `jx` CLI to coordinate work, request approvals, and hand off tasks when necessary.

---

## Continue.dev / OpenDevin style agents

Include the following capability description:

```json
{
  "capabilities": [
    "Can observe terminal state via jx",
    "Can request human approval through jx",
    "Can coordinate with other agents using jx campaigns and handoffs"
  ]
}
```

---

These prompts will be refined once the real `jx agent ...` commands are implemented.
