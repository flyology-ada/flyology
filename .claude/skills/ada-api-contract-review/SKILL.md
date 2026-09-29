---
name: ada-api-contract-review
description: Design or review Ada package specifications and public API changes. Use for `.ads` interfaces, parameter modes, defaults, exceptions, ownership, limited types, generic contracts, compatibility, and public constants. Distinguish requested behavior from new API policy and surface decisions before editing.
license: Apache-2.0
metadata:
  version: "0.1.0"
---

# Review an Ada API contract

Treat the specification as the contract, not as a declaration header for the
body. Read callers, the body, tests, generated documentation, and compatibility
requirements before changing it.

## Review dimensions

- Confirm that every visible declaration is required by the requested use
  cases rather than merely convenient for the implementation.
- Preserve semantic parameter modes. Use `in` for immutable or borrowed input,
  `out` for produced values whose prior state is irrelevant, and `in out` only
  when the operation reads and mutates established state.
- Check ownership transfer, borrowed lifetimes, limitedness, controlled
  finalization, exception behavior, copy-out behavior, and aliasing.
- Review default expressions, discriminants, generic formals, subtype bounds,
  constants, representation clauses, and aspects as API decisions.
- Check overload resolution, dispatching, visibility, child-package placement,
  and whether a generic or ordinary package is the stable boundary.
- Compare source, binary, and persisted-format compatibility requirements.
- Ensure contracts and comments describe conditions, outcomes, ownership, and
  exceptions without promising behavior the implementation does not provide.

## Decision handling

Do not invent public constants, defaults, resource bounds, or compatibility
promises. When the existing contract does not establish a choice, present the
smallest viable alternatives and ask the user.

Prefer a narrow API that can be extended additively. Do not expose an
implementation mechanism solely to avoid a private helper or internal state.

## Output

For a review, report findings by severity with exact declarations, affected
callers, the contract at risk, and a concrete remedy. For a design request,
present the proposed specification together with unresolved decisions and
compatibility consequences before implementing it.
