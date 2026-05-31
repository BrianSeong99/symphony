---
tracker:
  kind: github
  repository: Whitepaper-Reading-Club/intelligence-stack
  active_labels:
    - agent:symphony
  terminal_states:
    - Closed
    - Done
polling:
  interval_ms: 10000
workspace:
  root: ~/Develop/Labs/worktrees/symphony-wprc-intelligence-stack-github-test
  source_repo: ~/Develop/WPRC/intelligence-stack
  base_ref: origin/main
  branch_prefix: brian/symphony
  context_exclude_patterns:
    - node_modules/
    - .next/
    - dist/
    - out/
    - build/
    - coverage/
    - .turbo/
    - .cache/
    - .parcel-cache/
    - .vite/
    - .pytest_cache/
    - __pycache__/
    - target/
    - .venv/
    - venv/
    - "*.log"
    - "*.tmp"
    - "*.tsbuildinfo"
hooks:
  after_create: |
    if git remote get-url origin >/dev/null 2>&1; then
      git remote set-url origin git@github.com:Whitepaper-Reading-Club/intelligence-stack.git
    else
      git remote add origin git@github.com:Whitepaper-Reading-Club/intelligence-stack.git
    fi
    git fetch origin main
  before_run: |
    git_dir="$(git rev-parse --git-dir)"
    common_dir="$(git rev-parse --git-common-dir)"
    test "$git_dir" != "$common_dir"
agent:
  max_concurrent_agents: 3
  max_turns: 4
  max_retry_attempts: 3
  no_progress_timeout_ms: 90000
  no_progress_max_tokens: 150000
  startup_token_window_ms: 60000
  startup_max_total_tokens: 250000
  startup_progress_timeout_ms: 60000
  startup_progress_max_tokens: 150000
  max_total_tokens: 0
  prompt_mode: compact
codex:
  command: SYMPHONY_GIT_BASE_REF=origin/main SYMPHONY_GIT_PUSH_REMOTE=origin SYMPHONY_GITHUB_REPO=Whitepaper-Reading-Club/intelligence-stack SYMPHONY_GITHUB_BASE=main SYMPHONY_RUNNER_ENABLED=false SYMPHONY_SERVER_PORT=0 codex --dangerously-bypass-approvals-and-sandbox --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on a GitHub issue in the WPRC intelligence stack repository.

Follow the repo guidance first, but treat injected `AGENTS.md` and `CLAUDE.md` guidance as already loaded. Do not print or re-read full guidance files, workflow docs, package manifests, generated files, or full diffs. Public GitHub text must be under Brian's identity only, with no tool attribution.

Use the current git worktree only. The branch must be based on `main`, and the PR must target `main`. Use local `git` and `gh` commands for branch, commit, push, PR, and merge work.

Reuse the issue's named sessions until terminal state: `GH-### Symphony Builder` for Claude Code and `GH-### Symphony Reviewer` for Codex. Do not start a fresh chat on retry, restart, validation failure, or review feedback when an existing session/thread id exists.

Avoid dependency, cache, build, coverage, and generated-artifact paths during exploration. Do not run package installs in setup. Install dependencies only after you know the validation path requires them.

Keep startup context lean. After the worktree check, run `git diff --stat`; if this worktree already has relevant edits, validate and repair those edits before broad rediscovery. Use targeted `rg` and line-range reads. Keep shell commands single-purpose; avoid chained reads with `&&`, semicolons, or separator `echo` blocks. Optional connectors and MCP tools are not required for WPRC GitHub issue work.

Finish the issue end-to-end: implement, validate, commit, push, open a PR that closes the issue, and self-merge when checks pass and repository policy allows it.
