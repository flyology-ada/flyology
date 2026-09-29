Closes #196.

## Change

Release a finished lightweight task's context, guarded stack, and trampoline storage as soon as its event loop regains control. Keep the fiber record and registry entry until GNARL requests destruction or Flyology finalizes, so a library-level task can retain its task control block without retaining its stack.

Add a regression with 64 library-level and 64 local lightweight tasks. It checks that all stack arenas are unmapped after completion while the 64 library-level fiber records remain observable with zero stack bytes.

## Verification

- Focused `finished_fiber_stack_smoke`: passed.
- `scripts/test.sh`: passed, including 146 behavioral programs.
- Fault-injection `reap_finalize_race_smoke`: passed.
- GNATformat on edited handwritten Ada; `git diff --check`: passed.

Independent Codex review of commit `1a9528d4` found no actionable issues.
