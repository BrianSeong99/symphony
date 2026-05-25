# Symphony Agent Handoff Prompt

Use this prompt when asking another agent session to use Symphony for Brian's
project work.

```text
You are working in Brian Seong's project environment. Use Symphony as the
process kernel for issue pickup, progress logging, and pipeline monitoring.

First read these files in the Symphony repo:

- /Users/brianseong/Develop/Labs/worktrees/symphony-homelab-deployment/AGENTS.md
- /Users/brianseong/Develop/Labs/worktrees/symphony-homelab-deployment/docs/github-runner-week-trial.md

Current rule:

- GitHub pickup is label-based.
- Moving an issue to GitHub Projects Todo is not enough.
- To let Symphony pick up work, the target GitHub issue must be open and have
  the label `agent:symphony`.
- Homelab is the active runner lane.
- WPRC website and WPRC intelligence stack have workflow examples but should be
  enabled as separate runner lanes when Brian asks.

For Homelab work:

1. Create or identify a GitHub issue in BrianSeong99/homelab.
2. Make sure the issue has enough implementation detail and validation
   requirements.
3. Add the `agent:symphony` label when the issue is ready for Symphony pickup.
4. Watch the marked Symphony run-log comment on that issue.
5. Check for worktree path, branch, retry count, token budget, failure
   classifier, validation evidence, PR link, and merge result.
6. If the issue stalls or exceeds three retries, remove `agent:symphony`,
   inspect the run-log evidence, and decide whether it is a target repo
   implementation problem or a Symphony runner problem.

If you find a likely Symphony bug:

1. File a GitHub issue in BrianSeong99/symphony.
2. Include target repo, target issue link, run-log evidence, classifier lines,
   worktree path, branch, and expected behavior.
3. Add labels when available: `agent:symphony`, `bug`, `area:runner`.
4. Do not route Symphony's own implementation through the Symphony runner.
   Symphony self-work should be implemented directly from a fresh main
   worktree.

Hard rules:

- Every implementation branch starts from main.
- Every implementation uses a git worktree.
- Public GitHub text uses Brian's identity only, with no tool attribution.
- Follow the target repo's AGENTS.md, CLAUDE.md, PR template, validation
  commands, and merge policy.
- GitHub Issues Sync in Linear remains disabled by default.

Useful current files:

- Homelab workflow:
  /Users/brianseong/Develop/Labs/worktrees/symphony-homelab-deployment/elixir/WORKFLOW.homelab.github.example.md
- WPRC website workflow:
  /Users/brianseong/Develop/Labs/worktrees/symphony-homelab-deployment/elixir/WORKFLOW.wprc-website.github.example.md
- WPRC intelligence stack workflow:
  /Users/brianseong/Develop/Labs/worktrees/symphony-homelab-deployment/elixir/WORKFLOW.wprc-intelligence-stack.github.example.md
```
