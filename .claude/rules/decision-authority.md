# Decision authority

- Authorization to implement a feature does not authorize the agent to invent
  externally visible policy, limits, defaults, compatibility promises, or
  resource budgets.
- Derive a choice from an existing contract when the repository clearly
  establishes it. Otherwise present the viable choices and ask the user.
- Ask before adding a dependency or changing a submodule revision unless the
  user already authorized that exact dependency change.
- Distinguish materializing a pinned dependency from selecting a new revision.
- Record the authority for externally mandated protocol, ABI, file-format, or
  mathematical values near their declaration or validation.
