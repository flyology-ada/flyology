---
name: ada-hardcoded-constants
description: Audit Ada specifications and bodies for constants, defaults, bounds, and literals that encode unapproved policy, and document the authority for consequential values in source. Use when reviewing `.ads` or `.adb` values, questioning hard-coded choices, deciding how a value should be represented, or recording why an approved or externally established value exists. Report decisions and alternatives before editing; do not mechanically replace literals.
license: Apache-2.0
metadata:
  version: "0.3.0"
---

# Audit Ada values

Find values that encode design choices the user did not authorize. Begin with
specifications: an accidental value in an `.ads` file can become public API,
representation, or a reusable default.

## Scope

Inspect both explicit constant declarations and values expressed through:

- subtype, array, modular, and discriminant constraints;
- parameter, discriminant, and generic formal defaults;
- representation aspects and clauses;
- capacities, timeouts, retries, pool sizes, buffer sizes, and resource bounds;
- configuration packages, build-generated specifications, and platform units;
- magic values, versions, sentinels, protocol fields, and ABI declarations;
- body literals that control externally visible behavior.

Classify visible declarations, private-part declarations, and body-only values
separately. Exclude generated files from proposed hand edits and locate their
generator.

## Triage inventory before policy findings

Treat search results and literal counts as an inventory, not as findings. Audit
declared constants first, starting with visible and private specification
declarations, then inspect consequential inline defaults, bounds, offsets,
capacities, tags, field widths, allocation sizes, and state encodings.

Exclude routine mechanics from the decision table by default, including:

- ordinary loop ranges, increments, and local array indices;
- arithmetic identity values and short-lived counters;
- conventional zero, false, null, or empty initialization that merely creates
  the type's neutral state;
- fixed test-vector data that is established by the test scenario rather than
  selecting production policy.

This exclusion depends on meaning, not spelling. A site is consequential when
its value is an independently selectable policy or representation choice,
rather than an identity, index, or initialization mechanically required by the
local algorithm or type. Escalate choices that govern public behavior,
state-machine reachability, storage or wire representation, compatibility,
safety, resource use, or caller-observable defaults. In particular, do not
filter a zero or index-like value when it means uninitialized, unknown,
disabled, not found, automatic placement, unlimited, no timeout, a protocol
tag, a version, an epoch, a null offset, or another semantic sentinel. Do not
filter a loop bound when it selects retries, batching, truncation, sampling,
fairness, security, allocation, or another operational limit. Review fixture
capacities and format values when they establish or normalize a policy rather
than merely instantiate an already authorized test case.

Summarize the audit funnel separately: candidate sites scanned, declared
constants, routine sites excluded by category, consequential candidates, and
unresolved decision findings. Do not present raw textual matches as policy
violations.

## Establish authority

For each consequential value, look for authority in maintained requirements,
protocol or ABI documentation, persisted-format definitions, tests, existing
configuration, type derivation, or explicit user direction. Usage alone can
show impact but does not prove the chosen value was intended.

Feature authorization does not authorize a new value or its visibility. Do not
introduce a visible constant in an `.ads` file until the user approves its
meaning, value, name, type, and public visibility.

## Evaluate alternatives

Consider whether the value should instead be:

- a private implementation detail;
- derived from an existing type, object, or external contract;
- supplied by the caller;
- a generic formal or discriminant;
- selected through build-time or runtime configuration;
- represented by an enumeration or stronger domain type;
- deliberately exposed as a public constant;
- retained as a clear mathematical, test-fixture, protocol, or ABI literal.

Do not assume a named constant is better than a literal. A name can hide an
unapproved policy choice while making it appear intentional.

## Report before changing

Present a decision table with the location, current value, visibility,
classification, evidence of authority, behavioral or compatibility impact,
alternatives, recommendation, and user decision required.

Separate findings that need decisions from harmless literals and externally
fixed values. Do not edit consequential values until the user resolves the
open decisions. After approval, implement only the selected representation and
run focused tests for the affected contract.

## Preserve the decision in source

After a consequential value or representation is approved, or retained
because an external or derived contract already establishes it, record the
choice and its authority in a concise source comment adjacent to the
declaration, representation clause, validation, or tightly related group of
values. A decision table or conversation record does not replace this durable
source documentation.

The comment should identify, as relevant:

- what contract or policy the value controls;
- why that value or shape was selected and which stable authority supports it;
- whether it is an external protocol or ABI mandate, persisted-format choice,
  derived arithmetic consequence, project policy, or test/reference capacity;
- the compatibility consequence of changing it.

Keep the comment beside the declaration it documents: visible and private-part
declarations stay documented in the `.ads` file, while body-only values stay
documented in the `.adb` file. One nearby comment may cover a coherent group;
do not add repetitive comments to harmless literals. For a derived value,
document the governing formula or source fields rather than presenting the
result as an independent policy choice. For a generated declaration, change
the generator to emit the authority comment rather than hand-editing generated
output.

Prefer a stable specification, format version, issue, ADR, or maintained
project rule over an ephemeral conversation reference. When explicit user
direction is the only authority, describe the durable project policy that was
authorized instead of naming the conversation or person. Update or remove the
comment whenever the choice or its authority changes.

For example:

```ada
--  Persisted-format v1 contract: the object-kind declarations above assign
--  1 .. 3 to HEAD, batch, and manifest. Kind 4 is therefore the next unused
--  value; changing it is wire-incompatible.
SST_Object_Kind : constant := 4;

--  Reference-codec contract: capacity is exactly the maintained frozen vector
--  set's length; it is not an operational ceiling.
Reference_Capacity : constant := Reference_Vectors'Length;
```
