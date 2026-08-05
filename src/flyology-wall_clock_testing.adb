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
   protected Control is
      procedure Set_Offset (Value : Duration);
      function Offset return Duration;
      procedure Reset_Samples;
      procedure Note_Sample (Pause : out Boolean);
      entry Wait_For_Baseline;
      entry Wait_For_Offset;
   private
      Current_Offset   : Duration := 0.0;
      Sample_Count     : Natural := 0;
      Offset_Installed : Boolean := False;
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

      procedure Reset_Samples is
      begin
         Sample_Count := 0;
         Offset_Installed := False;
      end Reset_Samples;

      procedure Note_Sample (Pause : out Boolean) is
      begin
         Sample_Count := Sample_Count + 1;
         Pause := Sample_Count = 2;
      end Note_Sample;

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

   function Offset return Duration is (Control.Offset);

   procedure Reset_Samples is
   begin
      Control.Reset_Samples;
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
end Flyology.Wall_Clock_Testing;
