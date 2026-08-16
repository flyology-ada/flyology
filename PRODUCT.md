# Product

## Register

brand

## Users

Experienced Ada and GNAT developers are the primary audience. Systems
programmers who are new to Ada should still be able to understand the execution
model, evaluate its boundaries, and reach a working first build without reading
the entire repository.

## Product Purpose

Flyology is an experimental systems software project for Ada. Flyology Runtime
is its core GNAT runtime extension for ordinary Ada tasking. Some libraries use
the runtime's task-aware I/O, while standalone libraries can be adopted without
it. The public site should make those dependency boundaries visible, help a
visitor choose the relevant component, and explain how to evaluate each
component responsibly.

## Brand Personality

Precise, mechanical, and quietly curious. The voice is modest and factual,
with the confidence of a well-annotated engineering drawing. Ada Lovelace's
early study of flight supplies historical meaning, but the presentation stays
contemporary.

## Anti-references

Do not use neon-terminal developer-tool cliches, a generic startup card wall,
or faux-Victorian ornament. Avoid inflated claims, theatrical futurism,
glassmorphism, and decorative complexity that obscures runtime behavior.

## Design Principles

- Show the project topology before describing individual components at length.
- Present Flyology Runtime as a core component, not as the umbrella brand.
- State whether each library requires the runtime or has no runtime dependency.
- Show the runtime execution model before describing it at length.
- Pair every capability with its operational boundary.
- Keep ordinary Ada syntax at the center of the story.
- Use GNAT when the compiler or runtime boundary matters. Reserve GNARL for the
  exact implementation boundary where naming that subsystem adds information.
- Let the flight identity add curiosity without turning history into costume.
- Make the shortest path to a working evaluation obvious.

## Accessibility & Inclusion

Target WCAG 2.2 AA. Preserve full keyboard navigation, visible focus states,
semantic headings, color-independent meaning, readable code at narrow widths,
and a complete reduced-motion experience.
