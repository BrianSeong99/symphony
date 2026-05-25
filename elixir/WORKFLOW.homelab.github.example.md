---
tracker:
  kind: github
  repository: BrianSeong99/homelab
  active_labels:
    - agent:symphony
  terminal_states:
    - Closed
    - Done
polling:
  interval_ms: 10000
workspace:
  root: ~/Develop/Labs/worktrees/symphony-homelab-github-test
  source_repo: ~/Develop/Labs/homelab
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
      git remote set-url origin git@github.com:BrianSeong99/homelab.git
    else
      git remote add origin git@github.com:BrianSeong99/homelab.git
    fi
    git fetch origin main
  before_run: |
    git_dir="$(git rev-parse --git-dir)"
    common_dir="$(git rev-parse --git-common-dir)"
    test "$git_dir" != "$common_dir"
agent:
  max_concurrent_agents: 1
  max_turns: 12
  max_retry_attempts: 3
  no_progress_timeout_ms: 90000
  no_progress_max_tokens: 160000
  max_total_tokens: 350000
  prompt_mode: compact
codex:
  command: SYMPHONY_GIT_BASE_REF=origin/main SYMPHONY_GIT_PUSH_REMOTE=origin SYMPHONY_GITHUB_REPO=BrianSeong99/homelab SYMPHONY_GITHUB_BASE=main SYMPHONY_RUNNER_ENABLED=false SYMPHONY_SERVER_PORT=0 codex --dangerously-bypass-approvals-and-sandbox --config shell_environment_policy.inherit=all --config 'model="gpt-5.3-codex-spark"' --config model_reasoning_effort=low app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on a GitHub issue in Brian's Homelab repository.

Follow the repo guidance first: read `AGENTS.md`, `CLAUDE.md`, and any workflow or validation files before creating public artifacts. Public GitHub text must be under Brian's identity only, with no tool attribution.

Use the current git worktree only. The branch must be based on `main`, and the PR must target `main`. Use local `git` and `gh` commands for branch, commit, push, PR, and merge work.

Avoid dependency, cache, build, coverage, and generated-artifact paths during exploration. Do not run package installs in setup. Install dependencies only after you know the validation path requires them.

Finish the issue end-to-end: implement, validate, commit, push, open a PR that closes the issue, and self-merge when checks pass and repository policy allows it.
