# Symphony Agent Guide

Symphony is Brian's private process kernel for issue pickup, worktree-based
execution, run logging, retry classification, and repo workflow enforcement.

## First Read

Before changing code or creating public artifacts, read:

- `elixir/AGENTS.md` for Elixir implementation rules and validation gates.
- `docs/github-runner-week-trial.md` for GitHub issue pickup, labels,
  monitoring, and pause/recovery rules.
- The target repo's nearest `AGENTS.md`, `CLAUDE.md`, `WORKFLOW.md`, PR
  template, and validation commands before acting on a Symphony-managed issue.

## GitHub Runner Contract

GitHub issue pickup is label-based, not GitHub Projects column-based. A target
repo issue becomes eligible when it is open and has every label in
`tracker.active_labels`. The current trial label is:

```text
agent:symphony
```

For the current trial, use the workflow examples in `elixir/`:

- Homelab: `WORKFLOW.homelab.github.example.md`
- WPRC website: `WORKFLOW.wprc-website.github.example.md`
- WPRC intelligence stack: `WORKFLOW.wprc-intelligence-stack.github.example.md`
- CFO / Finance-OS: `WORKFLOW.cfo.github.example.md`
- CMO / Marketing-OS: `WORKFLOW.cmo.github.example.md`
- Omega interface: `WORKFLOW.omega-interface.github.example.md`
- Omega Zone: `WORKFLOW.omega-zone.github.example.md`

Each workflow monitors one repository. Use one runner process per repository
lane, with separate worktree roots and logs.

Each GitHub issue must have exactly one durable Claude Code builder session and
one durable Codex reviewer session until the issue/PR is terminal. Session names
must be stable and human-readable:

```text
GH-### Symphony Builder
GH-### Symphony Reviewer
```

Retries, restarts, validation failures, and review feedback resume those
sessions. Starting a fresh chat for the same issue while a prior session/thread
exists is a Symphony runner bug. Archive the session record only after merge,
close, cancel, or another terminal state.

GitHub lanes require a host-native runtime, not a container-only runtime. Before
pickup, Symphony checks `gh auth`, `git`, `workspace.source_repo`,
`workspace.root` writability, `codex`, Codex config home, and the
`codex app-server` command shape. If these fail, the issue should stay unpicked
and the failure should be visible in `/api/v1/state`, `/api/v1/refresh`, the
dashboard, and terminal status output.

## Monitoring Expectations

When another agent moves work into Symphony, it should watch the GitHub issue's
marked Symphony run-log comment for:

- worktree path and branch
- latest tracker poll status, candidate count, eligible count, and runtime readiness
- context packet id, cache hit/miss, and provider fallback reason
- pickup, PR-open, and merge timestamps
- retry count
- failure classifier
- token budget blocks
- validation evidence
- PR and merge links

If the run-log shows repeated retries, missing evidence, no-progress stalls,
token budget failures, or unexpected behavior, debug from the run-log first.
Decide whether the failure belongs to the target repo implementation or to
Symphony's runner/orchestration layer.

## Filing Symphony Bugs

If an agent finds a likely Symphony bug while working in another repo, file a
GitHub issue in `BrianSeong99/symphony` with:

- observed behavior
- expected behavior
- target repo and issue link
- run-log link or copied classifier lines
- worktree path and branch if available
- whether the target issue should be paused

Use labels when available:

```text
agent:symphony
bug
area:runner
```

Symphony self-work should be implemented directly in this repository from a
fresh `main` worktree. Do not make a broken Symphony runner debug or repair
itself.

## Hard Rules

- Every implementation branch starts from `main`.
- Every implementation uses a git worktree.
- Public GitHub text uses Brian's identity only, with no tool attribution.
- Do not assume Linear GitHub Issues Sync is enabled.
- For target repos, preserve their local PR, validation, and merge rules.
- For Chainless/Omega repos, preserve existing team labels, milestones,
  projects, issue templates, branch protection, and public-safe boundaries.
- For Symphony itself, run `make -C elixir all` before handoff when feasible.
