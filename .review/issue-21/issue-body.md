This issue tracks **submission to GCC** of a compiler defect already fixed in
Flyology's GNAT patchset. The correction and executable regression are in the
[protected Duration validity bundle](https://gnat-patches.flyology.org/bundles/protected-duration-validity/).
Keep this issue open until the GCC Bugzilla report and gcc-patches submission
are complete.

The compiler defect was documented in 4c5e060. Main is green with the scoped
workaround in 7880b4e:
https://github.com/flyology-ada/flyology/actions/runs/30952427894

## GCC bug report (copy verbatim)

Title: Ada ICE in fold_convert_loc for optimized protected Duration assignment with -gnatVa

Component: ada

A valid protected object containing a Duration component causes an internal compiler error on x86-64 Linux when validity checking and optimization are both enabled.

Affected compiler versions tested:
- GCC/GNAT 13.2.0
- GCC/GNAT 14.1.0
- GCC/GNAT 14.2.0
- GCC/GNAT 15.3.0
- GCC/GNAT 16.1.0

Target: x86_64-pc-linux-gnu

Standalone reproducer:

procedure Repro is
   protected Control is
      procedure Set (Value : Duration);
   private
      Current : Duration := 0.0;
   end Control;

   protected body Control is
      procedure Set (Value : Duration) is
      begin
         Current := Value;
      end Set;
   end Control;
begin
   Control.Set (1.0);
end Repro;

Compile with:

  gcc -c -Og -gnatVa repro.adb

Observed result with GCC 16.1.0:

  internal compiler error: in fold_convert_loc, at fold-const.cc:2672

Expected result: the valid Ada unit compiles successfully.

The ICE also occurs with -O1, -O2, -O3, and -Os. Either -O0 -gnatVa or optimized compilation without -gnatVa succeeds. The equivalent non-protected Duration assignment succeeds. GCC/GNAT 16.1.0 on Linux/AArch64 also succeeds. GNAT expanded output shows a generated Duration-to-Long_Long_Integer validity range check before the protected assignment; the optimized conversion reaches the NOP_EXPR path in fold_convert_loc.
