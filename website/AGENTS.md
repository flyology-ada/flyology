# Flyology website documentation guide

## Scope

Apply the technical writing style to hand-written documentation in `guide/**`
and `architecture/**`. Apply the journal register below to `journal/**`. These
rules do not apply to the home page, reports, or generated API reference.

## Technical writing style

Use the useful parts of ASD-STE100 as a house style. Do not claim that the
documentation complies with ASD-STE100.

- Use the project vocabulary in the root `AGENTS.md`. Use one term for one
  concept. Do not add synonyms only for variety.
- Define an unfamiliar term before its first use. Keep Flyology identifiers,
  Ada terms, OS interfaces, and compiler terms exact.
- Put one main idea or one instruction in each sentence. Use a list when three
  or more parallel facts would make a long sentence.
- Keep closely related cause, contrast, sequence, and consequence in the same
  paragraph. Do not turn one connected explanation into a series of abrupt
  statements only to meet a sentence-length target.
- Prefer sentences of 25 words or fewer. Prefer 20 words or fewer for an
  instruction. Treat these limits as review signals, not mechanical rules.
- Use active voice when the actor matters. Name the actor instead of using an
  unclear `it`, `this`, or `they`.
- Preserve modal meaning. Use `must` for a requirement, `can` for capability,
  and `may` for possibility. Do not replace a modal only for variety. Rewrite
  the sentence when capability and possibility would otherwise be ambiguous.
- Use the present tense for current behavior and the imperative for
  instructions. Put a condition before the action when the condition controls
  the action.
- Put a prerequisite or safety condition before its action. Natural explanatory
  forms such as "use X when Y" are acceptable when the condition does not gate
  safety, validity, or ownership.
- Use direct, sentence-case headings. State the subject or action. Do not use a
  clever title in place of information.
- Prefer concrete verbs to noun phrases. Avoid stacked modifiers,
  nominalizations, rhetorical questions, idioms, metaphors, personification,
  filler, and promotional language.
- Keep limits next to the capability that they qualify. Do not remove a
  condition, ownership rule, exception, or timing fact to make prose shorter.
- Use short paragraphs. Start a new paragraph when the subject or task changes.

The result must still read like normal software documentation. Do not imitate
an aircraft maintenance manual, force a restricted dictionary, repeat nouns
when the reference is already clear, or split connected technical reasoning
into unnatural fragments.

Examples and walkthroughs can use a slightly more human cadence. Their setup
may explain why a realistic case matters, and their explanation may vary
sentence length to connect cause and effect. Use this allowance with restraint.
Commands, contracts, warnings, and limits still use the tighter technical
style. Do not add a fictional user, dramatic scenario, metaphor, or extra
personality when it does not improve understanding.

Review an example as a paragraph, not only as a set of sentence-length scores.
If three or more short sentences have the same subject, combine or connect them
when this makes the sequence easier to follow. Retain a short sentence when it
states a warning, result, or important boundary.

Before finishing a documentation edit, check term consistency, sentence
length, HTML syntax, local links, and code examples.

Sentence-length scripts are triage tools, not acceptance gates. Review the
meaning and cadence of every flagged sentence before changing it. Before
normalizing two related terms, confirm whether the project uses them for
different layers or mechanisms.

## API links

On each Guide, Architecture, or Journal page, link the first visible
explanatory mention of a public Flyology API entity to its generated GNATdoc
entry. API entities include packages, generic packages, subprograms, types,
objects, exceptions, enumeration literals, and other documented declarations.

- Follow document reading order. The first mention can occur in a hero,
  callout, paragraph, list, table, or figure caption.
- Use `<a href="..."><code>Entity_Name</code></a>` for an identifier in prose.
- Link a package name to its GNATdoc unit page. Link a declaration to its exact
  entity anchor when that anchor exists.
- For an overloaded subprogram, link the declaration that matches the described
  operation. If the prose refers to the overload family, link the package page.
- If an identifier first appears in a code block, code comment, or SVG text,
  link it in the nearest explanatory prose or caption instead. Do not place an
  HTML link inside a code block or SVG source label only to satisfy this rule.
- Do not guess a generated filename or anchor. Resolve it through the generated
  GNATdoc output or search index, then verify that the target and fragment exist.
- Link only the first explanatory mention of an entity on a page. Repeat a link
  when the same spelling refers to a different entity or when a long page needs
  a deliberate navigation aid.
- Do not link Ada language constructs, GNAT or GNARL internals, OS interfaces,
  environment variables, shell commands, scripts, or external APIs to Flyology
  GNATdoc. Link external documentation only when it is authoritative and useful
  to the task.
- When no generated entry exists for a public Flyology identifier, treat that
  as a review finding. Do not silently link to an unrelated package.

## Journal register

Journal entries use the same exact vocabulary, concrete verbs, factual limits,
and aversion to promotional language. They can use a more personal voice.

- First person is acceptable when it identifies an observation, decision, or
  correction made by the author or project team.
- Use `we` for the project or team. Use `I` only when a named author records a
  direct observation or decision.
- Use the past tense for dated work and observations. Use the present tense for
  a current finding, implementation fact, or limit.
- Vary sentence length enough to keep a natural narrative. Do not apply the
  20-word and 25-word targets mechanically.
- Give the reason for an investigation and explain what changed in the team's
  understanding. Keep the evidence and its limits close to that account.
- A small amount of warmth or dry humor is acceptable. Do not use a conceit,
  extended metaphor, fictional scene, or dramatic claim to carry a technical
  explanation.
- Prefer a candid correction to defensive wording. Preserve the source
  revision, environment, method, result, and limits needed to evaluate a claim.

## Review roles

For a broad rewrite of three or more pages, use three separate read-only review
roles on the settled draft. The reviewers may work in parallel. They report
findings to the editing agent and do not edit the same checkout concurrently.
Run a technical review for any changed capability, limit, ownership, timing, or
lifecycle claim, even when the change affects only one page.

Use one separate subagent for each role when multi-agent support is available.

Do not edit the reviewed files while reviewers are working. Give reviewers a
named commit or other stable snapshot when the checkout must continue changing.

Each finding identifies its severity, exact location, relevant wording,
violated rule, and proposed correction. A technical finding also names the
implementation, script, contract, or invariant that supports it.

### Editorial reviewer

- Review headings, paragraph order, cadence, transitions, and cognitive load.
- Identify mechanical sentence splitting, repeated sentence openings, vague
  headings, and paragraphs that read like a list without list structure.
- Give examples and walkthroughs enough connective prose to explain why a step
  follows another. Keep the tone restrained.
- Review the journal for a candid, personable voice without adding a persona or
  decorative story.

### Technical reviewer

- Compare the rewrite with the earlier text, relevant implementation, runner,
  and root `AGENTS.md` invariants.
- Check that each page links the first explanatory mention of every public
  Flyology API entity to the correct generated GNATdoc entry.
- Check every condition, ownership rule, exception, timing fact, lifecycle
  boundary, concurrency limit, and experimental qualification.
- Check that every `must`, `can`, and `may` retains the intended requirement,
  capability, or possibility.
- Report any fact that became weaker, broader, or ambiguous. Do not approve a
  shorter sentence when it changes the contract.
- Treat executable code and maintained scripts as stronger evidence than the
  earlier prose.

### ASD-STE100-inspired controlled-language reviewer

- Apply the ASD-STE100-inspired rules in this file without claiming compliance.
- Check one term per concept, active voice, clear actors and references,
  condition-before-action order, direct headings, and concrete verbs.
- Flag long or structurally complex sentences, but also flag excessive
  sentence splitting and repeated nouns that make the prose unnatural.
- Distinguish instructions and warnings from explanatory examples. Apply the
  tighter sentence targets to the former, not mechanically to the latter.

The editing agent reconciles all three reviews. Technical fidelity wins when a
style suggestion would remove necessary meaning. The final pass must address
each finding or record why the existing wording is more accurate.

Resolve technical findings first, then editorial and controlled-language
findings. Run a targeted technical review on any factual passage changed during
reconciliation. Review metadata, navigation labels, callouts, figure captions,
SVG titles and descriptions, code comments, and redirect text as well as body
paragraphs.

If separate review agents are unavailable, perform the same three reviews in
sequence and label the notes. Do not collapse them into one generic prose pass.
