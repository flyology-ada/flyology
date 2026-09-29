---
name: maintain-agent-instructions
description: Create, extract, package, compile, validate, or migrate shared and repository-specific agent instructions and skills with APM. Use for flyology-ada/agents changes, consumer package adoption, local instruction packages, or cross-agent discovery testing.
license: Apache-2.0
metadata:
  version: "0.3.0"
---

# Maintain shared agent resources

Separate always-on constraints from specialized workflows. Keep reusable rules
in focused instruction packages, project composition in `apm.yml`, and
task-specific procedures in skills.

Keep truly repository-specific instructions in local packages under
`agent-packages/`, one package for each independently selected scope. Keep only
rules and skills with the same meaning across repositories in the shared
`flyology-ada/agents` repository. Reference local packages with APM `path`
dependencies. Reference shared packages through an explicit mutable branch or
semver constraint in `apm.yml`, commit the exact resolved commit and content
hashes in `apm.lock.yaml`, and advance them only with an explicit `apm update`.

Use APM's native deployment layouts for both clients. Run `apm install` to
deploy Claude rules and both skill trees, then run
`apm compile --target codex` to render the committed Codex `AGENTS.md` without
deleting Claude's rules. Do not hand-edit generated files.

Before a consumer pull request:

- install the pinned package graph with `apm install --frozen`;
- validate local packages, shared dependency refs, deployed resources, and
  generated output with `apm audit --ci`;
- start fresh Codex and Claude sessions in the consumer fork;
- test a realistic instruction-dependent task;
- test explicit and implicit activation for selected skills;
- run an unrelated negative-control prompt;
- record client versions, prompts, revisions, observed behavior, and failures;
- fix discovery or adherence failures before opening the pull request.

Keep code-coupled invariants with the repository unless several repositories
share the exact contract. Do not centralize a rule merely because its wording
looks similar.
