with Interfaces.C;
with Flyology.Time_Math;

package body Flyology.Wall_Clock_Testing is
   package C renames Interfaces.C;
   use type C.int;
   use type C.long_long;

   procedure Native_Set_Remaining (Value : C.long_long);
   pragma Import
     (C, Native_Set_Remaining, "flyology_wall_wait_test_set_remaining");

   function Native_Last_Arm return C.long_long;
   pragma Import (C, Native_Last_Arm, "flyology_wall_wait_test_last_arm");

   function Native_Uses_Relative_Timer return C.int;
   pragma Import
     (C,
      Native_Uses_Relative_Timer,
      "flyology_wall_wait_test_uses_relative_timer");

   procedure Native_Set_Consume_EINTR (Count : C.int);
   pragma Import
     (C,
      Native_Set_Consume_EINTR,
      "flyology_wall_wait_test_set_consume_eintr");

   function Native_Consume_EINTR_Left return C.int;
   pragma Import
     (C,
      Native_Consume_EINTR_Left,
      "flyology_wall_wait_test_consume_eintr_remaining");

   procedure Native_Configure_IO_Retry
     (Steady_Nanoseconds : C.long_long;
      Wall_Nanoseconds   : C.long_long);
   pragma Import
     (C, Native_Configure_IO_Retry, "flyology_io_test_configure_retry");

   procedure Native_Reset_IO_Retry;
   pragma Import (C, Native_Reset_IO_Retry, "flyology_io_test_reset_retry");

   function Native_IO_Wall_Adjustment return C.long_long;
   pragma Import
     (C, Native_IO_Wall_Adjustment, "flyology_io_test_wall_adjustment");

   function Native_IO_Retry_Count return C.int;
   pragma Import (C, Native_IO_Retry_Count, "flyology_io_test_retry_count");

   protected Control is
      procedure Set_Offset (Value : Duration);
      function Offset return Duration;
      procedure Reset_Samples (Pause_For_Offset : Boolean);
      procedure Note_Sample (Pause : out Boolean);
      procedure Set_Sample_Bracket (Value : Duration);
      procedure Note_Sample_Attempt;
      function Sample_Bracket return Duration;
      function Sample_Attempts return Natural;
      entry Wait_For_Baseline;
      entry Wait_For_Offset;
   private
      Current_Offset   : Duration := 0.0;
      Sample_Count     : Natural := 0;
      Offset_Installed : Boolean := False;
      Pause_On_Baseline : Boolean := True;
      Current_Sample_Bracket : Duration := 0.0;
      Current_Sample_Attempts : Natural := 0;
   end Control;

   protected body Control is
      --  GNAT 13 through 16 on Linux/x86-64 mishandle validity checks while
      --  copying Duration values into and out of protected storage: optimized
      --  writes ICE in fold_convert_loc and reads can reject a valid negative
      --  offset as invalid data. Keep the suppression within the protected
      --  body; validity checks remain enabled on the public wrappers.
      pragma Suppress (Validity_Check);

      procedure Set_Offset (Value : Duration) is
      begin
         Current_Offset := Value;
         if Value /= 0.0 then
            Offset_Installed := True;
         end if;
      end Set_Offset;

      function Offset return Duration is (Current_Offset);

      procedure Reset_Samples (Pause_For_Offset : Boolean) is
      begin
         Sample_Count := 0;
         Offset_Installed := False;
         Pause_On_Baseline := Pause_For_Offset;
      end Reset_Samples;

      procedure Note_Sample (Pause : out Boolean) is
      begin
         Sample_Count := Sample_Count + 1;
         Pause := Pause_On_Baseline and then Sample_Count = 2;
      end Note_Sample;

      procedure Set_Sample_Bracket (Value : Duration) is
      begin
         Current_Sample_Bracket := Value;
         Current_Sample_Attempts := 0;
      end Set_Sample_Bracket;

      procedure Note_Sample_Attempt is
      begin
         Current_Sample_Attempts := Current_Sample_Attempts + 1;
      end Note_Sample_Attempt;

      function Sample_Bracket return Duration is
        (Current_Sample_Bracket);

      function Sample_Attempts return Natural is
        (Current_Sample_Attempts);

      entry Wait_For_Baseline when Sample_Count >= 2 is
      begin
         null;
      end Wait_For_Baseline;

      entry Wait_For_Offset when Offset_Installed is
      begin
         null;
      end Wait_For_Offset;
   end Control;

   procedure Set_Offset (Value : Duration) is
   begin
      Control.Set_Offset (Value);
   end Set_Offset;

   function Offset return Duration is
      Nanoseconds : constant C.long_long := Native_IO_Wall_Adjustment;
   begin
      return
        Control.Offset
        + Duration (Nanoseconds / 1_000_000_000)
        + Duration (Nanoseconds rem 1_000_000_000) / 1_000_000_000;
   end Offset;

   procedure Reset_Samples (Pause_For_Offset : Boolean := True) is
   begin
      Control.Reset_Samples (Pause_For_Offset);
   end Reset_Samples;

   procedure Note_Sample is
      Pause : Boolean;
   begin
      Control.Note_Sample (Pause);
      if Pause then
         Control.Wait_For_Offset;
      end if;
   end Note_Sample;

   procedure Wait_For_Baseline is
   begin
      Control.Wait_For_Baseline;
   end Wait_For_Baseline;

   procedure Set_Sample_Bracket (Value : Duration) is
   begin
      Control.Set_Sample_Bracket (Value);
   end Set_Sample_Bracket;

   procedure Reset_Sample_Bracket is
   begin
      Control.Set_Sample_Bracket (0.0);
   end Reset_Sample_Bracket;

   procedure Note_Sample_Attempt is
   begin
      Control.Note_Sample_Attempt;
   end Note_Sample_Attempt;

   function Sample_Bracket return Duration is (Control.Sample_Bracket);

   function Sample_Attempts return Natural is (Control.Sample_Attempts);

   procedure Configure_IO_Retry
     (Steady_Advance  : Duration;
      Wall_Adjustment : Duration)
   is
   begin
      Native_Configure_IO_Retry
        (Flyology.Time_Math.To_Nanoseconds (Steady_Advance),
         C.long_long (Wall_Adjustment / 0.000_000_001));
   end Configure_IO_Retry;

   procedure Reset_IO_Retry is
   begin
      Native_Reset_IO_Retry;
   end Reset_IO_Retry;

   function IO_Retry_Count return Natural is
     (Natural (Native_IO_Retry_Count));

   procedure Set_Native_Remaining (Value : Duration) is
   begin
      Native_Set_Remaining (Flyology.Time_Math.To_Nanoseconds (Value));
   end Set_Native_Remaining;

   procedure Reset_Native_Remaining is
   begin
      Native_Set_Remaining (-1);
   end Reset_Native_Remaining;

   function Last_Native_Arm return Duration is
     (Duration (Native_Last_Arm) / 1_000_000_000);

   function Uses_Native_Relative_Timer return Boolean is
     (Native_Uses_Relative_Timer /= 0);

   procedure Set_Native_Consume_EINTR (Count : Natural) is
   begin
      Native_Set_Consume_EINTR (C.int (Count));
   end Set_Native_Consume_EINTR;

   function Native_Consume_EINTR_Remaining return Natural is
     (Natural (Native_Consume_EINTR_Left));
end Flyology.Wall_Clock_Testing;
