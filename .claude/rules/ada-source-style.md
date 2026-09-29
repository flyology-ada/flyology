# Ada source style

- Prefer Ada for implementation. Use a native bridge only for ABI facts or
  mechanisms that direct Ada imports cannot express reliably.
- Keep policy, validation, retry behavior, ownership, and cleanup decisions in
  Ada when Ada can express them.
- Preserve the owning project's formatting and warning configuration.
- Run the owning formatter project after editing handwritten Ada. Change a
  generator instead of formatting generated Ada independently.
- Do not hand-edit generated sources. Identify their generator and regenerate
  them through the maintained workflow.
- Preserve parameter modes, ownership, exceptions, bounds, and representation
  semantics when refactoring an interface.
