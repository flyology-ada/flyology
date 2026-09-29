---
name: ada-generated-source-review
description: Identify and safely change generated Ada, GPR, binding, runtime, test, or documentation sources. Use when generated files appear in a diff, formatting touches generated Ada, or the owning generator and regeneration workflow are unclear.
license: Apache-2.0
metadata:
  version: "0.1.0"
---

# Review generated sources

Determine whether each affected file is handwritten, generated, copied from a
prepared tree, or patched from a versioned upstream source. Use headers,
scripts, build rules, git history, and exact output comparisons.

Do not hand-edit a generated artifact. Locate and change the authoritative
generator, template, platform input, or versioned patch. Regenerate through the
maintained command and avoid independently formatting generated Ada when that
would diverge from its generator.

Check:

- deterministic output and stable ordering;
- source encoding and formatter ownership;
- whether obsolete generated files are removed by the workflow;
- version selection and fail-closed behavior;
- generated tests, symbols, layouts, and documentation links;
- whether the diff contains only expected mechanical consequences.

If no generator can be found, stop and report the evidence instead of treating
the artifact as handwritten. Present any required migration or source-of-truth
decision to the user.
