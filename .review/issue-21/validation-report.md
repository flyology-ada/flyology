# Issue 21 local validation status

Status as of 2026-09-23. This package remains local and nothing has been filed
or sent upstream.

## Complete

- Confirmed issue #21 is open and identifies this work as GCC submission
  tracking, with the published bundle linked at
  https://gnat-patches.flyology.org/bundles/protected-duration-validity/.
- Verified the standalone patch and fixture hashes and passed the patch
  repository manifest validator.
- Applied the patch with `--fuzz=0` in dry-run mode to GCC mirror master commit
  `56de4652dbfc3a79ee4946f0274aba115bd83ccb` from 2026-09-22.
- Preserved published GCC 16.2.0 x86-64 before/after CI evidence: unpatched
  `-O0` rejects valid data, unpatched `-O2` aborts, and both patched cases pass.
- Reproduced the compiler abort directly with unpatched Ubuntu GCC 13.3.0
  x86-64. Retained the complete GNAT bug box, exit status, source, and full
  `gcc-13 -v` output under `reproduction/`.
- Performed the final all-status GCC Bugzilla Ada duplicate searches on
  2026-09-23. No matching report was found.
- Prepared local Bugzilla and gcc-patches drafts with the reproducer, bundle
  URL, testing limits, and submission gates.

## Remaining

- Run a clean full GCC bootstrap with this patch alone and compare the Ada,
  `gnat.dg`, and ACATS results against an unpatched baseline. The published CI
  uses `--disable-bootstrap` and a patchset containing other changes.
- Run that build on a host with adequate disk. This volume has 35 GiB free and
  is 97% full, so no large GCC build was started here.
- Resolve contribution provenance. Commit
  `75f928b63f34b79f95f294d635e9f0b9fe95f497`, which introduced both the
  compiler hunk and test, records Claude Opus 5 as co-author. GCC's current AI
  policy makes the compiler hunk ineligible if it was LLM-generated or derived.
- Establish an FSF assignment or a human-certifiable DCO and resolve any
  employer or school rights.
- After those gates pass, file GCC Bugzilla, add its `PR ada/NNNNN` reference
  to the mail, perform one more duplicate search, obtain explicit authorization,
  and only then send the patch to gcc-patches.

## Required human answers

1. Did Claude generate or materially derive the `exp_ch9.adb` compiler hunk,
   or only assist with research, review, or packaging?
2. Did Claude generate or materially derive the regression test?
3. If the compiler hunk is ineligible, can a fresh independent human-authored
   fix be provided?
4. Is there an existing FSF copyright assignment, or can the contributor
   personally certify the DCO using the submission identity and email?
5. Does an employer, school, or other party have rights that require a
   disclaimer or assignment?
