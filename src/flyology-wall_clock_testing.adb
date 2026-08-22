with Flyology.Time_Math;
with Flyology.Wall_Clock_IO_Testing;
with Flyology.Wall_Clock_Native;

package body Flyology.Wall_Clock_Testing is
   protected Control is
      procedure Set_Offset (Value : Duration);
      function Offset return Duration;
      procedure Reset_Samples (Pause_For_Offset : Boolean);
      procedure Note_Sample (Pause : out Boolean);
      procedure Set_Sample_Bracket (Value : Duration);
      procedure Note_Sample_Attempt;
      function Sample_Bracket return Duration;
      function Sample_Attempts return Natural;
      procedure Set_Native_Remaining (Nanoseconds : Interfaces.Integer_64);
      function Native_Remaining return Interfaces.Integer_64;
      procedure Note_Native_Arm (Nanoseconds : Interfaces.Integer_64);
      function Last_Native_Arm return Interfaces.Integer_64;
      procedure Set_Consume_EINTR (Count : Natural);
      procedure Take_Consume_EINTR (Taken : out Boolean);
      function Consume_EINTR_Remaining return Natural;
      entry Wait_For_Baseline;
      entry Wait_For_Offset;
   private
      Current_Offset           : Duration := 0.0;
      Sample_Count             : Natural := 0;
      Offset_Installed         : Boolean := False;
      Pause_On_Baseline        : Boolean := True;
      Current_Sample_Bracket   : Duration := 0.0;
      Current_Sample_Attempts  : Natural := 0;
      Current_Native_Remaining : Interfaces.Integer_64 := -1;
      Current_Last_Native_Arm  : Interfaces.Integer_64 := -1;
      Current_Consume_EINTR    : Natural := 0;
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

      function Offset return Duration
      is (Current_Offset);

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

      function Sample_Bracket return Duration
      is (Current_Sample_Bracket);

      function Sample_Attempts return Natural
      is (Current_Sample_Attempts);

      procedure Set_Native_Remaining (Nanoseconds : Interfaces.Integer_64) is
      begin
         Current_Native_Remaining := Nanoseconds;
      end Set_Native_Remaining;

      function Native_Remaining return Interfaces.Integer_64
      is (Current_Native_Remaining);

      procedure Note_Native_Arm (Nanoseconds : Interfaces.Integer_64) is
      begin
         Current_Last_Native_Arm := Nanoseconds;
      end Note_Native_Arm;

      function Last_Native_Arm return Interfaces.Integer_64
      is (Current_Last_Native_Arm);

      procedure Set_Consume_EINTR (Count : Natural) is
      begin
         Current_Consume_EINTR := Count;
      end Set_Consume_EINTR;

      procedure Take_Consume_EINTR (Taken : out Boolean) is
      begin
         Taken := Current_Consume_EINTR > 0;
         if Taken then
            Current_Consume_EINTR := Current_Consume_EINTR - 1;
         end if;
      end Take_Consume_EINTR;

      function Consume_EINTR_Remaining return Natural
      is (Current_Consume_EINTR);

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
      Nanoseconds : constant Interfaces.Integer_64 := Flyology.Wall_Clock_IO_Testing.Wall_Adjustment;
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

   function Sample_Bracket return Duration
   is (Control.Sample_Bracket);

   function Sample_Attempts return Natural
   is (Control.Sample_Attempts);

   procedure Configure_IO_Retry (Steady_Advance : Duration; Wall_Adjustment : Duration) is
   begin
      Flyology.Wall_Clock_IO_Testing.Configure
        (Interfaces.Integer_64 (Flyology.Time_Math.To_Nanoseconds (Steady_Advance)),
         Interfaces.Integer_64 (Wall_Adjustment / 0.000_000_001));
   end Configure_IO_Retry;

   procedure Reset_IO_Retry is
   begin
      Flyology.Wall_Clock_IO_Testing.Reset;
   end Reset_IO_Retry;

   function IO_Retry_Count return Natural
   is (Flyology.Wall_Clock_IO_Testing.Retry_Count);

   procedure Set_Native_Remaining (Value : Duration) is
   begin
      Control.Set_Native_Remaining (Interfaces.Integer_64 (Flyology.Time_Math.To_Nanoseconds (Value)));
   end Set_Native_Remaining;

   procedure Reset_Native_Remaining is
   begin
      Control.Set_Native_Remaining (-1);
   end Reset_Native_Remaining;

   function Last_Native_Arm return Duration
   is (Duration (Control.Last_Native_Arm) / 1_000_000_000);

   function Uses_Native_Relative_Timer return Boolean
   is (Flyology.Wall_Clock_Native.Uses_Relative_Timer);

   procedure Set_Native_Consume_EINTR (Count : Natural) is
   begin
      Control.Set_Consume_EINTR (Count);
   end Set_Native_Consume_EINTR;

   function Native_Consume_EINTR_Remaining return Natural
   is (Control.Consume_EINTR_Remaining);

   function Native_Remaining_Nanoseconds return Interfaces.Integer_64
   is (Control.Native_Remaining);

   procedure Note_Native_Arm (Nanoseconds : Interfaces.Integer_64) is
   begin
      Control.Note_Native_Arm (Nanoseconds);
   end Note_Native_Arm;

   function Take_Native_Consume_EINTR return Boolean is
      Result : Boolean;
   begin
      Control.Take_Consume_EINTR (Result);
      return Result;
   end Take_Native_Consume_EINTR;

   function Take_IO_EINTR return Boolean is
   begin
      return Flyology.Wall_Clock_IO_Testing.Take_EINTR;
   end Take_IO_EINTR;

   function IO_Steady_Adjustment return Duration is
      Nanoseconds : constant Interfaces.Integer_64 := Flyology.Wall_Clock_IO_Testing.Steady_Adjustment;
   begin
      return
        Duration (Nanoseconds / 1_000_000_000) + Duration (Nanoseconds rem 1_000_000_000) / 1_000_000_000;
   end IO_Steady_Adjustment;
end Flyology.Wall_Clock_Testing;
