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
    - graphify-out/
    - "*.log"
    - "*.tmp"
    - "*.tsbuildinfo"
context_ingestion:
  enabled: true
  provider: graphify
  command: uvx --from graphifyy graphify
  refresh_policy: on_base_commit_change
  max_ingestion_seconds: 180
  max_context_packet_tokens: 12000
  include:
    - AGENTS.md
    - CLAUDE.md
    - WORKFLOW*.md
    - .github/pull_request_template.md
    - .github/workflows/*.{yml,yaml}
    - docs/**/*.md
    - app/**/*.{js,jsx,ts,tsx,md}
    - src/**/*.{js,jsx,ts,tsx,md}
    - lib/**/*.{js,jsx,ts,tsx,md}
    - config/**/*.{js,json,yml,yaml,toml}
    - Makefile
    - Justfile
    - package.json
    - compose*.yml
    - compose*.yaml
    - docker-compose*.yml
    - docker-compose*.yaml
  exclude:
    - deps/**
    - _build/**
    - node_modules/**
    - .next/**
    - graphify-out/**
    - logs/**
    - tmp/**
  required_for_runner: false
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
  max_concurrent_agents: 3
  max_turns: 4
  max_retry_attempts: 3
  no_progress_timeout_ms: 90000
  no_progress_max_tokens: 150000
  startup_token_window_ms: 15000
  startup_max_total_tokens: 250000
  startup_progress_timeout_ms: 60000
  startup_progress_max_tokens: 150000
  max_total_tokens: 0
  prompt_mode: compact
codex:
  command: SYMPHONY_GIT_BASE_REF=origin/main SYMPHONY_GIT_PUSH_REMOTE=origin SYMPHONY_GITHUB_REPO=BrianSeong99/homelab SYMPHONY_GITHUB_BASE=main SYMPHONY_RUNNER_ENABLED=false SYMPHONY_SERVER_PORT=0 codex --dangerously-bypass-approvals-and-sandbox --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on a GitHub issue in Brian's Homelab repository.

Follow the repo guidance first, but treat injected `AGENTS.md` and `CLAUDE.md` guidance as already loaded. Do not print or re-read full guidance files, workflow docs, package manifests, generated files, or full diffs. Public GitHub text must be under Brian's identity only, with no tool attribution.

Use the current git worktree only. The branch must be based on `main`, and the PR must target `main`. Use local `git` and `gh` commands for branch, commit, push, PR, and merge work.

Reuse the issue's named sessions until terminal state: `GH-### Symphony Builder` for Claude Code and `GH-### Symphony Reviewer` for Codex. Do not start a fresh chat on retry, restart, validation failure, or review feedback when an existing session/thread id exists.

Avoid dependency, cache, build, coverage, and generated-artifact paths during exploration. Do not run package installs in setup. Install dependencies only after you know the validation path requires them.

Keep startup context lean. After the worktree check, run `git diff --stat`; if this worktree already has relevant edits, validate and repair those edits before broad rediscovery. Use targeted `rg` and line-range reads. Keep shell commands single-purpose; avoid chained reads with `&&`, semicolons, or separator `echo` blocks. Optional connectors and MCP tools are not required for Homelab GitHub issue work.

Never ingest full log files, dependency trees, generated assets, build output, cache directories, or coverage artifacts. If validation output is needed, read only the failing lines. If the injected issue context and context packet are enough to identify the target files, edit those files before any broad repository rediscovery.

Finish the issue end-to-end: implement, validate, commit, push, open a PR that closes the issue, and self-merge when checks pass and repository policy allows it.
