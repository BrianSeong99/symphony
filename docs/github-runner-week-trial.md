# GitHub Runner Week Trial

This trial runs Symphony against GitHub issues while Linear is unavailable,
rate-limited, or intentionally bypassed.

Agents joining this repository should also read `../AGENTS.md` first. It
summarizes how to use Symphony from target repos, how to monitor GitHub run-log
comments, and how to file Symphony runner bugs with enough evidence.

## What Starts Work

Symphony does not read GitHub Projects Backlog or Todo columns. A GitHub issue
is eligible when all of these are true:

- the issue is open
- the issue is in the configured `tracker.repository`
- the issue has every label listed in `tracker.active_labels`
- the issue is not already in a terminal state

The current trial label is:

```text
agent:symphony
```

Moving an issue from Backlog to Todo in a GitHub Project is useful for humans,
but it does not trigger Symphony by itself. Add or remove `agent:symphony` to
start or pause pickup.

## Trial Repositories

Each workflow file monitors one GitHub repository. Run one Symphony runner
process per workflow.

| Project | Workflow file | GitHub repo | Local source repo | Worktree root |
|---|---|---|---|---|
| Homelab | `elixir/WORKFLOW.homelab.github.example.md` | `BrianSeong99/homelab` | `~/Develop/Labs/homelab` | `~/Develop/Labs/worktrees/symphony-homelab-github-test` |
| WPRC website | `elixir/WORKFLOW.wprc-website.github.example.md` | `Whitepaper-Reading-Club/wprc-website` | `~/Develop/WPRC/wprc-website` | `~/Develop/Labs/worktrees/symphony-wprc-website-github-test` |
| WPRC intelligence stack | `elixir/WORKFLOW.wprc-intelligence-stack.github.example.md` | `Whitepaper-Reading-Club/intelligence-stack` | `~/Develop/WPRC/intelligence-stack` | `~/Develop/Labs/worktrees/symphony-wprc-intelligence-stack-github-test` |

## Concurrency

The week trial workflows set:

```yaml
agent:
  max_concurrent_agents: 3
```

This is an upper bound per workflow. Symphony should still only pick up open,
labelled issues. Keep the active labelled queue intentionally small during the
first few days so failures are easy to read.

The runner guardrails remain active:

- `max_retry_attempts: 3`
- `startup_token_window_ms: 15000`
- `startup_max_total_tokens: 150000`
- `max_total_tokens: 500000`
- no-progress timeout and token classifiers
- mandatory git worktree check before each run

These budgets are runaway guards, not quality ceilings. The runner should spend
what the task needs for good work, while classifying wasteful patterns such as
full log ingestion, repeated broad context reads, no-progress loops, and
validation retries that do not change the plan.

## Codebase Context Pilot

Homelab is the first repo with bounded codebase context ingestion enabled. The
workflow uses a Graphify provider when available and falls back to Symphony's
internal file map when Graphify is missing or fails. This is intentionally
Homelab-only for the first week.

The context packet is not a replacement for repo guidance. It is a compact,
versioned startup hint that should reduce repeated repo rediscovery:

- guidance inventory: `AGENTS.md`, workflow files, PR templates, validation
  files
- service/runtime hints: compose files, health endpoints, Homelab registration
  paths
- likely relevant files for the issue
- Graphify graph hash/query summary when available
- fallback reason when Symphony used the internal map

Every picked-up issue should log:

- `context_ingestion.started`
- `context_ingestion.cache_hit` or `context_ingestion.cache_miss`
- `context_ingestion.completed`
- `context_ingestion.failed` when the provider falls back
- `context_packet.attached`

Promotion gate: enable context ingestion for more repos only if it reduces
startup context burn without hiding repo guidance, leaking private data, or
causing stale-context mistakes.

## Starting A Runner

Point the runner at one workflow file and enable the runner process:

```bash
export SYMPHONY_WORKFLOW_FILE=/Users/brianseong/Develop/Labs/symphony/elixir/WORKFLOW.homelab.github.example.md
export SYMPHONY_RUNNER_ENABLED=true
export SYMPHONY_REPO_ENABLED=false
```

Use the matching WPRC workflow path for WPRC runners. Keep separate logs and
process names for each repository so stalls and token usage can be attributed
to the right repo.

## Expected Evidence

For every picked-up issue, Symphony should write a marked GitHub run-log comment
with:

- issue identifier and repository
- worktree path and branch
- run start and finish timestamps
- retry count and failure classifier when blocked
- validation commands and results
- PR link and merge result when completed

During this week trial, inspect the run-log comments for:

- time from pickup to PR open
- time from PR open to merge
- context cache hit rate
- context ingestion duration
- context packet token estimate
- time to first implementation diff
- startup token usage
- total token usage
- retry count
- repeated no-output or no-progress classifications
- validation failures that should update the issue before retry

## Operating Rules

- Every implementation branch starts from `main`.
- Every implementation uses a git worktree.
- Public GitHub text uses Brian's identity only.
- GitHub Issues Sync in Linear remains disabled by default.
- Symphony self-work is implemented directly, not through the runner.
- Homelab and WPRC trial issues may self-merge when validation and repository
  policy allow it.

## Pause And Recovery

To pause a single issue, remove the `agent:symphony` label.

To pause a repository lane, disable that runner process or point it at a paused
workflow. Do not delete preserved worktrees until their run-log comment has the
branch, PR, validation, and failure evidence needed for review.

If an issue exceeds three retries, stop broad rollout for that repository lane,
read the run-log comment, classify whether it is a Symphony runner problem or a
repo implementation problem, fix the root cause, then retry with one small
issue before restoring parallel pickup.
