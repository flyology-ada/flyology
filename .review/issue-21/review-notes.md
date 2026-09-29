# Issue 21 upstream submission review

As of 2026-09-23, Flyology issue #21 is open. A final public GCC Bugzilla
all-status search in the Ada component found no matching report:

* `fold_convert_loc` returned no bugs;
* `protected Duration` returned only unrelated bug 114065;
* `"lock-free" validity` returned no bugs.

Recheck immediately before filing because a new report may appear.

The source patch and test come unchanged from `flyology-ada/gnat-patches`
commit `80c6bef7405f80f9d6ad864dc629a8493b5dd671` in the sibling checkout.
Recorded SHA-256: patch
`6338408d12909a33b08aacb4e7fed00c3c3c861ef6646192ff640afc1309bc2e`,
fixture `c64d6891008d30b5be8fd57768033c394a79fccd01dcc0de9d8633cff5d1dbe9`.
`PYTHONDONTWRITEBYTECODE=1 python3.13 scripts/manifest.py validate`
passed in the patch repository. The patch and fixture were copied unchanged
into this issue directory. `patch --dry-run --fuzz=0 -p1` succeeded against the single GCC trunk
`exp_ch9.adb` blob from mirror commit
`56de4652dbfc3a79ee4946f0274aba115bd83ccb`. This proves context
applicability only; it does not compile or test GCC trunk. The saved source's
Git blob hash `c2fc6c8a284fae9b7af8079b6b597763578a98de` matches the
mirror API at that exact commit.

The patch and test were originally introduced together in gnat-patches commit
`75f928b63f34b79f95f294d635e9f0b9fe95f497`, recorded with author Yurii
Rashkovskii `<yrashk@gmail.com>` on 2026-08-08. Its commit message includes
`Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`. The
commit does not establish which lines were generated or derived by Claude.
That uncertainty is a submission blocker under GCC's current AI policy for
compiler code and must be resolved by the human contributor.

The proposed `gnat.dg` test is applicable as an executable Ada regression:
it places `dg-do run` and `dg-options "-O2 -gnatVa"` before the source,
tests the read/write round trip, and fails on the demonstrated x86-64 Linux
target before the patch. Its AArch64 success without the patch is a target
control, not evidence of a fixed compiler. The repository runner separately
checks the unpatched `-O0` invalid-data rejection and `-O2` compiler abort.
Set `TMPDIR` to a worktree directory if running that runner locally; its
default temporary directory violates this task's artifact-location rule.

CI run 35117276018, job 104866768180 built GCC 16.2.0 from pristine source
as an unpatched control and recorded:

* `-O0`: expected invalid-data rejection;
* `-O2`: expected compiler abort;
* patched `-O0` and `-O2`: PASS.

A direct raw reproduction is now complete. In an Ubuntu 24.04 x86-64
container, the unpatched distro GCC 13.3.0 command
`gcc-13 -c -O2 -gnatVa protected_duration_validity.adb` exited with status 1
and emitted the complete GNAT bug box naming `fold_convert_loc` at
`fold-const.cc:2505`. The exact source, raw diagnostic, exit status, and full
`gcc-13 -v` output are retained under `reproduction/`. This supplements the
official FSF GCC 16.2.0 CI evidence; it does not replace it.

The proposed code patch is narrower than suppressing all validity checking:
it rewrites generated `N_Raise_Constraint_Error` nodes with reason
`CE_Invalid_Data` during traversal of copied lock-free statements. Direct
source raise statements have a different AST form. A maintainer should still
review whether any generated invalid-data raise in this traversal is needed
for another check; the existing regression covers the observed Duration path.

Bootstrap assessment:

The patch repository's GCC build uses `--disable-bootstrap`, so it cannot
satisfy GCC's full-bootstrap requirement. The local data volume currently has
35 GiB free and is 97% full. A trustworthy before/after comparison needs clean
unpatched and patch-only bootstrap/test runs. Keeping two large build trees is
not reasonable with that headroom; a sequential run would still require a
large temporary build plus deletion between phases and substantial elapsed
time. No GCC source build was started. Run this gate on a host with adequate
space, retaining the configure command, bootstrap logs, exact source revision,
patch hash, and before/after Ada and ACATS summaries.

Remaining upstream gates:

1. Bootstrap GCC with this patch alone in an otherwise pristine source tree,
   and compare `make -C gcc -k check-gnat` and Ada/ACATS results to the
   unpatched tree. GCC's published guidance requires a full Ada bootstrap
   and language testsuite regression testing for Ada front-end changes.
   Existing patchset CI uses `--disable-bootstrap` and other patches.
2. Resolve the provenance of the compiler hunk and test. The recorded Claude
   co-authorship is insufficiently specific for GCC's compiler-code policy.
   If the test used LLM assistance, use the policy's testsuite exception and
   add the required `Assisted-by` trailer after human review.
3. Establish the human contributor's legal basis: an existing FSF copyright
   assignment or a personally certifiable DCO, including any employer or
   school rights that may require a disclaimer or assignment.
4. File Bugzilla first, then add its `PR ada/NNNNN` reference to the patch
   mail. Recheck for duplicates immediately beforehand.
5. Obtain the human user's explicit authorization before filing Bugzilla or
   sending gcc-patches mail. Keep Flyology issue #21 open until the actual
   upstream filing is complete.

Questions the human contributor must answer before submission:

1. Did Claude generate or materially derive the `exp_ch9.adb` compiler hunk,
   or was its role limited to research, review, or packaging?
2. Did Claude generate or materially derive the testsuite source?
3. If the compiler hunk is ineligible, can the contributor provide a fresh,
   independently human-authored fix that does not derive from LLM output?
4. Does the contributor have an FSF copyright assignment, or can they
   personally certify the DCO using the identity and email that will appear
   in the submission?
5. Does an employer, school, or other party hold rights that require a
   disclaimer or assignment?

Sources: https://gcc.gnu.org/bugs/ , https://gcc.gnu.org/contribute.html ,
https://gcc.gnu.org/dco.html , https://gcc.gnu.org/ai-policy.html .
