# Repository workflow

- When the repository contains `apm.yml`, install its documented APM CLI
  version before provisioning agent resources. Flyology repositories currently
  validate APM 0.28.0; install it on macOS or Linux with
  `curl -sSL https://aka.ms/apm-unix | sh -s -- @v0.28.0`, then verify it with
  `apm --version`. Use the repository README and APM's installation guide for
  Windows or alternative installation methods.
- After cloning or creating a worktree with `apm.lock.yaml`, run
  `apm install --frozen` and `apm compile --target codex` before
  starting either client. The install deploys Claude's native rules and both
  clients' skills; the compile generates Codex's `AGENTS.md` without removing
  the Claude rules. Use a non-frozen install only when intentionally updating
  the lockfile.
- Keep rules that are truly specific to this repository in local APM packages
  under `agent-packages/`, with one package per independently selected scope.
  List them as local `path` dependencies in the root `apm.yml`. Depend on
  `flyology-ada/agents` only for rules and skills whose meaning is shared
  across repositories.
- Run `git status --short --branch` before changing anything.
- Preserve unrelated user changes. Do not rewrite, discard, or reformat them.
- Read the relevant implementation and maintained scripts before relying on
  README prose.
- Use `rg` or `rg --files` for discovery and `apply_patch` for hand edits.
- Keep changes focused on the requested problem.
- Run the repository's documented checks and `git diff --check` before
  presenting a change.
- Do not claim behavior, portability, proof, test coverage, or performance
  beyond evidence from maintained code, scripts, proof runs, tests, or
  benchmarks.
- Use `gh` outside a sandbox when GitHub access is required.
