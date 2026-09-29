---
name: ada-portability-review
description: Audit Ada code for unsupported platform, compiler, architecture, representation, endianness, alignment, and operating-system assumptions. Use for portability claims, platform ports, source selection, ABI layouts, or cross-platform test matrices.
license: Apache-2.0
metadata:
  version: "0.1.0"
---

# Review Ada portability

Establish the repository's supported matrix from executable build scripts,
project files, CI, and version checks. Do not broaden it from aspiration or
README prose.

Inspect:

- compiler family and exact version dependencies;
- target architecture and calling convention;
- scalar size, signedness, alignment, padding, endianness, and atomic support;
- representation clauses and unchecked conversions;
- OS constants, syscall numbers, record layouts, polling mechanisms, signals,
  threads, filesystems, and descriptor behavior;
- GPR source-directory and scenario-variable selection;
- generated platform bindings and compile-time assertions;
- behavior when a platform is unsupported or an ABI check fails.

Prefer fail-closed platform selection. Do not guess a nearby compiler or OS
version, silently use a fallback ABI, or claim Windows or another platform
without a separately verified implementation.

Report each assumption, where it is enforced, supported targets, missing
evidence, and the smallest test or code change that would make the claim
reproducible.
