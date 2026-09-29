# GCC Bugzilla report draft — Flyology issue 21

**Product:** gcc

**Component:** ada

**Version:** 16.2.0 (also observed on 13.2.0, 13.3.0, 14.1.0, 14.2.0, 15.3.0, and 16.1.0)

**Target:** x86_64-pc-linux-gnu
**Suggested summary:** Ada ICE in fold_convert_loc for protected Duration assignment with -gnatVa and optimization

An automatically selected lock-free protected object containing a `Duration`
component mishandles validity checks. On x86-64 Linux, the source below builds
but rejects a valid negative `Duration` with `CONSTRAINT_ERROR ... invalid data`
at `-O0 -gnatVa`. At `-O2 -gnatVa`, compilation aborts in `fold_convert_loc`.
The original smaller positive-value reproducer also ICEs at `-Og` on GCC 16.1.0.

This is a single, self-contained Ada source file named
`protected_duration_validity.adb`:

```ada
with Ada.Text_IO; use Ada.Text_IO;

procedure Protected_Duration_Validity is
   protected Control is
      procedure Set (Value : Duration);
      function Get return Duration;
   private
      Current : Duration := 0.0;
   end Control;

   protected body Control is
      procedure Set (Value : Duration) is
      begin
         Current := Value;
      end Set;

      function Get return Duration is
      begin
         return Current;
      end Get;
   end Control;
begin
   Control.Set (-1.0);
   if Control.Get /= -1.0 then
      raise Program_Error with "protected Duration round trip failed";
   end if;
   Put_Line ("PASS protected Duration validity");
end Protected_Duration_Validity;
```

Compile and run in a clean directory:

```sh
gnatmake -q -f -O0 -gnatVa protected_duration_validity.adb
./protected_duration_validity
gnatmake -q -f -O2 -gnatVa protected_duration_validity.adb
```

The triggering direct compiler invocation is
`gcc -c -O2 -gnatVa protected_duration_validity.adb`. On the unpatched
GCC 16.2.0 x86-64 Linux CI control, the `-O0` run was rejected as invalid data
and the `-O2` compile aborted; the runner requires `GNAT BUG DETECTED` or
`fold_convert_loc` in the compiler output. After the proposed patch, this exact
fixture builds and prints `PASS protected Duration validity` at both levels.
The complete before/after job is
https://github.com/flyology-ada/gnat-patches/actions/runs/35117276018/job/104866768180 .

The unpatched compiler in that job was built from the GCC 16.2.0 FSF release
source and identified itself as:

```text
Target: x86_64-pc-linux-gnu
Configured with: .../work/source/configure --prefix=.../install/control --enable-languages=c,c++,ada --enable-libada --disable-bootstrap --disable-multilib --disable-nls --disable-libsanitizer --disable-libgomp --disable-libquadmath --disable-libssp --enable-threads=posix --with-system-zlib
Thread model: posix
gcc version 16.2.0 (GCC)
```

A separate direct reproduction used Ubuntu's unpatched GCC 13.3.0 x86-64
package. The exact command was:

```sh
gcc-13 -c -O2 -gnatVa protected_duration_validity.adb
```

It exited with status 1 and printed the complete diagnostic below:

```text
+===========================GNAT BUG DETECTED==============================+
| 13.3.0 (x86_64-linux-gnu) in fold_convert_loc, at fold-const.cc:2505     |
| Error detected at protected_duration_validity.adb:17:21                  |
| Compiling protected_duration_validity.adb                                |
| Please submit a bug report; see https://gcc.gnu.org/bugs/ .              |
| Use a subject line meaningful to you and us to track the bug.            |
| Include the entire contents of this bug box in the report.               |
| Include the exact command that you entered.                              |
| Also include sources listed below.                                       |
+==========================================================================+

Please include these source files with error report
Note that list may not be accurate in some cases,
so please double check that the problem can still
be reproduced with the set of files listed.
Consider also -gnatd.n switch (see debug.adb).

protected_duration_validity.adb

compilation abandoned
```

The complete `gcc-13 -v` output, including the Ubuntu configure line, is in
the proposed `gcc-v.txt` attachment. It identifies the compiler as
`gcc version 13.3.0 (Ubuntu 13.3.0-6ubuntu2~24.04.1)` with target
`x86_64-linux-gnu`. Earlier direct observation with GCC 16.1.0 and
`-Og -gnatVa` was `internal compiler error: in fold_convert_loc, at
fold-const.cc:2672`.

Expected: the valid Ada program compiles and prints the PASS line. A valid
negative `Duration` must not raise `Constraint_Error`.

The equivalent non-protected assignment, and optimized compilation without
`-gnatVa`, succeed. Linux and macOS AArch64 run this fixture successfully
without the patch, so the observed failure is target dependent.

Investigation: the protected body is analyzed before automatic lock-free
selection. Generated invalid-data validity raises remain in the original
statements copied into the lock-free implementation, whereas an explicitly
lock-free body does not receive those checks. The patch proposal and executable
regression are published as the
https://gnat-patches.flyology.org/bundles/protected-duration-validity/ bundle.

This draft is for human review; no Bugzilla report has been filed.
