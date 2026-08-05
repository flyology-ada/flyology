---
name: Flyology Runtime
description: A precise, contemporary guide to an experimental GNAT runtime extension for ordinary Ada tasking.
colors:
  ink: "oklch(27% 0.052 270)"
  ink-soft: "oklch(39% 0.043 270)"
  violet: "oklch(57% 0.19 285)"
  violet-deep: "oklch(47% 0.18 285)"
  teal: "oklch(73% 0.13 185)"
  teal-deep: "oklch(56% 0.11 185)"
  flight-path: "oklch(78% 0.045 270)"
  paper: "oklch(98.5% 0.006 270)"
  surface: "oklch(95.8% 0.015 270)"
  surface-strong: "oklch(92.5% 0.024 270)"
  line: "oklch(86% 0.025 270)"
  code-background: "oklch(23% 0.045 270)"
  code-line: "oklch(36% 0.055 270)"
  inverse: "oklch(97% 0.008 270)"
  focus: "oklch(65% 0.17 285)"
typography:
  display:
    fontFamily: "Geologica, Avenir Next, Segoe UI, sans-serif"
    fontSize: "clamp(3.4rem, 8.2vw, 7.8rem)"
    fontWeight: 620
    lineHeight: 1.08
    letterSpacing: "-0.035em"
  headline:
    fontFamily: "Geologica, Avenir Next, Segoe UI, sans-serif"
    fontSize: "clamp(2.35rem, 5vw, 4.5rem)"
    fontWeight: 590
    lineHeight: 1.08
    letterSpacing: "-0.035em"
  body:
    fontFamily: "Geologica, Avenir Next, Segoe UI, sans-serif"
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.65
    letterSpacing: "normal"
  label:
    fontFamily: "Geologica, Avenir Next, Segoe UI, sans-serif"
    fontSize: "0.78rem"
    fontWeight: 650
    lineHeight: 1.4
    letterSpacing: "0.08em"
  mono:
    fontFamily: "ui-monospace, SFMono-Regular, Cascadia Code, Roboto Mono, monospace"
    fontSize: "0.82rem"
    fontWeight: 400
    lineHeight: 1.75
    letterSpacing: "normal"
rounded:
  control: "0.45rem"
  panel: "0.9rem"
  feature: "1.4rem"
  pill: "999px"
spacing:
  xs: "0.45rem"
  sm: "0.85rem"
  md: "1.25rem"
  lg: "2rem"
  section: "clamp(6rem, 12vw, 11rem)"
components:
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.inverse}"
    rounded: "{rounded.pill}"
    padding: "0.72rem 1.25rem"
  button-secondary:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    rounded: "{rounded.pill}"
    padding: "0.72rem 1.25rem"
  code-panel:
    backgroundColor: "{colors.code-background}"
    textColor: "{colors.inverse}"
    rounded: "{rounded.panel}"
    padding: "1.35rem"
  callout:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink-soft}"
    rounded: "{rounded.panel}"
    padding: "1.15rem 1.25rem"
  search-field:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "0.75rem 1rem"
---

# Design System: Flyology Runtime

## 1. Overview

**Creative North Star: "The Flight Mechanism"**

The visual system is a contemporary working model: precise enough to inspect,
animated only when motion explains a state transition, and curious enough to
reward exploration. A visible technical grid, the existing flight-and-event-
loop mark, ordinary Ada syntax, and runtime topology diagrams make the system
feel engineered without becoming a terminal simulation.

Light mode is designed for a developer reading guides and source-adjacent
material during the day. Dark mode keeps the same hierarchy for late technical
reading, using tonal token overrides rather than a separate aesthetic. The
history of Ada Lovelace's flight study appears as provenance, never period
decoration.

**Key Characteristics:**

- A strict technical grid with varied section rhythm and asymmetric hero layouts.
- A full palette in which violet means task movement and teal means readiness or completion.
- Geologica carries both confident display scale and calm long-form reading.
- System mono is reserved for Ada, shell commands, generated API entities, and compact indices.
- Responsive motion uses transform and opacity, with a complete reduced-motion path.

## 2. Colors

Deep ink provides structure, violet marks task movement, teal marks readiness
and completion, and the flight-path neutral traces relationships. Paper and
surface tokens are subtly hue-tinted so the site never falls into pure black or
white. Dark mode swaps token values while preserving these semantic roles.

### Primary

- **Runtime Ink:** body text, dark bands, primary actions, and the native execution lane.
- **Motion Violet:** lightweight designation, migration paths, active navigation, and focus in light mode.

### Secondary

- **Completion Teal:** readiness, successful handoff, task-aware I/O, and focus in dark mode.
- **Flight Path:** diagrams, dormant paths, quiet nodes, and structural annotation.

### Neutral

- **Paper:** the page canvas and readable inverse text role.
- **Surface / Surface Strong:** layered navigation, inputs, status strips, and hover response.
- **Line:** the visible technical grid, separators, and low-emphasis boundaries.
- **Code Background / Code Line:** a stable dark syntax surface in both themes.

**The Flight Path Rule.** Violet and teal always communicate distinct runtime
states or actions. They are forbidden as interchangeable decoration.

**The Tinted Neutral Rule.** Pure black and pure white are forbidden. Every
neutral remains tied to the identity's blue-violet hue.

## 3. Typography

**Display Font:** Geologica (with Avenir Next and Segoe UI fallbacks)
**Body Font:** Geologica (with Avenir Next and Segoe UI fallbacks)
**Label/Mono Font:** System monospace stack

**Character:** Geologica is engineered, open, and slightly unusual without
looking futuristic. One family supports the site's large mechanical forms and
its long technical guide, while mono remains an executable-material cue.

### Hierarchy

- **Display** (620, fluid 3.4rem to 7.8rem, 1.08): one dominant statement per hero.
- **Headline** (590, fluid 2.35rem to 4.5rem, 1.08): major section and document transitions.
- **Title** (590, fluid 1.4rem to 2rem, 1.08): lane, mechanism, and API group headings.
- **Body** (400, 1rem, 1.65): technical prose capped at 70 to 72 characters.
- **Label** (650, 0.78rem, 0.08em): short structural annotations only.
- **Mono** (400, 0.82rem, 1.75): Ada, shell, API names, and generated source declarations.

**The Ordinary Language Rule.** Headings are direct and sentence-cased. Mono is
for executable material, never a costume for technical credibility.

**The One Dominant Scale Rule.** A viewport gets one oversized statement. Body
copy, diagrams, and navigation remain calm around it.

## 4. Elevation

The system is flat by default. Tonal layering, one-pixel boundaries, and the
technical grid establish depth. A low ambient shadow appears only when a small
annotation floats over a diagram or a primary action responds to hover.

### Shadow Vocabulary

- **Ambient Low** (`0 1rem 3rem oklch(23% 0.045 270 / 0.09)`): diagram notes and elevated interaction only.
- **Code Float** (`0 1.7rem 4rem oklch(10% 0.04 270 / 0.25)`): the hero's source window, which visibly overlaps the runtime model.

**The Mechanical Layer Rule.** A shadow must explain interaction or hierarchy.
If the surface reads correctly without it, remove it.

## 5. Components

Components are precise and lightly tactile. Their boundaries are visible, their
states use short exponential ease-out transitions, and their focus treatment is
never sacrificed for visual quiet.

### Buttons

- **Shape:** fully rounded action control (pill radius) with compact, confident padding.
- **Primary:** Runtime Ink with inverse text and a low ambient response on hover.
- **Hover / Focus:** a two-pixel upward transform on hover and a three-pixel semantic focus ring with four-pixel offset.
- **Secondary:** transparent or Paper background with an Ink boundary; never a filled gray duplicate of the primary action.

### Cards / Containers

- **Corner Style:** panel radius for code and callouts; feature radius only for large narrative surfaces.
- **Background:** Paper for annotations, Surface for callouts, and Code Background for executable material.
- **Shadow Strategy:** flat at rest, with Ambient Low only for overlapping diagram notes.
- **Border:** one-pixel Line or Code Line around the whole surface.
- **Internal Padding:** compact for annotations, medium for code, and fluid for narrative features.

### Inputs / Fields

- **Style:** Surface background, one-pixel Line boundary, and compact control radius.
- **Focus:** Violet boundary in light mode plus the global visible focus ring.
- **Error / Disabled:** no field states are currently shipped; do not invent them without a real workflow.

### Navigation

The primary navigation is sticky, translucent only where backdrop-filter is
supported, and organized around direct links. Active desktop links use a thin
violet underline. Mobile navigation expands inline below the header, keeps
semantic list structure, and reports its state with `aria-expanded`.

### Code Panels

Code panels use the permanent dark code surface in both themes, readable
horizontal scrolling, a compact filename or language label, and an optional
copy action. Generated GNATdoc declarations use the same surface and typography.

### Runtime Diagrams

Violet nodes identify lightweight task movement, teal nodes identify readiness
or completion, and neutral paths preserve topology. Motion is limited to orbit,
path, or dashed-flow transforms that describe runtime behavior.

## 6. Do's and Don'ts

### Do:

- **Do** make runtime relationships visible through diagrams and state changes.
- **Do** pair every capability with explicit experimental and portability limits.
- **Do** keep ordinary Ada syntax at the center of the visual story.
- **Do** preserve keyboard access, visible focus, color-independent meaning, readable mobile code, and reduced-motion behavior.
- **Do** use the full palette according to the Flight Path Rule.

### Don't:

- **Don't** use neon-terminal developer-tool cliches.
- **Don't** build a generic startup card wall.
- **Don't** use faux-Victorian ornament to reference Ada Lovelace.
- **Don't** use glassmorphism, gradient text, decorative colored side stripes, or repeated icon cards.
- **Don't** use violet and teal as decorative substitutes for one another.
- **Don't** imply production qualification, hard real-time behavior, universal portability, or preemptive lightweight scheduling.
