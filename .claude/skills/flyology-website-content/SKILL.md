---
name: flyology-website-content
description: Write, revise, or review Flyology website guides, architecture pages, journals, API links, and shared website-kit integration. Use for authored website content or website builds; initialize pinned submodules without selecting newer revisions.
license: Apache-2.0
metadata:
  version: "0.1.0"
---

# Work on Flyology website content

Read the repository's website instructions, root vocabulary, build script, and
`.gitmodules`. If `vendor/website-kit` is absent or uninitialized, materialize
the pinned dependency with:

```sh
git submodule update --init --recursive vendor/website-kit
```

Do not use `--remote` or change the website-kit gitlink unless the user
explicitly requests a dependency revision change.

For content changes:

- ground technical claims in maintained code and scripts;
- use exact project vocabulary and restrained technical prose;
- preserve conditions, ownership, exceptions, timing, limits, compatibility,
  and experimental qualifications;
- resolve and verify generated GNATdoc targets rather than guessing paths;
- apply the journal voice only to journal content;
- keep shared infrastructure changes in website-kit rather than duplicating
  them in a consumer.

Run the repository's site build and link checks. For factual changes, perform a
technical review against the implementation. For broad rewrites, also perform
separate editorial and controlled-language reviews on a stable draft.

Report the pinned website-kit revision, commands run, generated page or link
evidence, and any claims that remain unverified.
