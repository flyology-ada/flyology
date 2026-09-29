# Ada interface values

- Treat an Ada specification as code and as a contract. Moving a literal from
  a body into an `.ads` file does not validate the choice.
- Do not introduce a visible constant in an `.ads` file without explicit user
  approval of its meaning, value, name, type, and public visibility.
- Feature authorization does not authorize a new constant, default, capacity,
  timeout, retry count, buffer bound, pool size, resource ceiling, or policy
  choice.
- Review specification-level values even when they are not declared with the
  `constant` keyword. This includes subtype and array bounds, discriminant and
  parameter defaults, generic formal defaults, modular ranges, representation
  aspects, and configuration-package values.
- Separate the value decision from the visibility decision. An externally
  fixed ABI or protocol value can still belong in a private body rather than a
  visible interface.
- Before asking for a decision, present the relevant alternatives: a private
  implementation value, caller parameter, generic formal, discriminant, value
  derived from a type or contract, build-time configuration, or deliberately
  public constant.
- Do not replace every literal mechanically with a named constant. Report
  harmless mathematical and test-fixture values separately from unconfirmed
  policy decisions.
