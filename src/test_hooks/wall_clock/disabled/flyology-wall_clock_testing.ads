with Interfaces;

--  Disabled wall-clock test seams selected by the owning project. The
--  imported-only declarations make a missed static guard visible to symbol
--  inspection without supplying any production implementation.
private package Flyology.Wall_Clock_Testing is
   use type Interfaces.Integer_64;

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := False;

   procedure Set_Offset (Value : Duration)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_set_offset";
   function Offset return Duration
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_offset";
   procedure Reset_Samples (Pause_For_Offset : Boolean := True)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_reset_samples";
   procedure Note_Sample
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_note_sample";
   procedure Wait_For_Baseline
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_wait_baseline";
   procedure Set_Sample_Bracket (Value : Duration)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_set_bracket";
   procedure Reset_Sample_Bracket
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_reset_bracket";
   procedure Note_Sample_Attempt
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_note_attempt";
   function Sample_Bracket return Duration
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_bracket";
   function Sample_Attempts return Natural
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_attempts";
   procedure Configure_IO_Retry (Steady_Advance : Duration; Wall_Adjustment : Duration)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_configure_io";
   procedure Reset_IO_Retry
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_reset_io";
   function IO_Retry_Count return Natural
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_io_count";
   procedure Set_Native_Remaining (Value : Duration)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_set_native";
   procedure Reset_Native_Remaining
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_reset_native";
   function Last_Native_Arm return Duration
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_last_arm";
   function Uses_Native_Relative_Timer return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_uses_native";
   procedure Set_Native_Consume_EINTR (Count : Natural)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_set_native_eintr";
   function Native_Consume_EINTR_Remaining return Natural
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_native_eintr_count";
   function Native_Remaining_Nanoseconds return Interfaces.Integer_64
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_native_remaining";
   procedure Note_Native_Arm (Nanoseconds : Interfaces.Integer_64)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_note_native_arm";
   function Take_Native_Consume_EINTR return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_take_native_eintr";
   function Take_IO_EINTR return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_take_io_eintr";
   function IO_Steady_Adjustment return Duration
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_io_adjustment";

end Flyology.Wall_Clock_Testing;
