with Ada.Text_IO;
with Flyology;
with Interfaces.C;

procedure Unwind_Lightweight is
   use type Interfaces.C.unsigned;

   Panicked : constant Interfaces.C.unsigned := 2;

   function Probe return Interfaces.C.unsigned
   with Import, Convention => C, External_Name => "flyology_rust_unwind_probe";

   protected Result is
      procedure Report (Passed : Boolean);
      entry Wait (Passed : out Boolean);
   private
      Done : Boolean := False;
      OK   : Boolean := False;
   end Result;

   protected body Result is
      procedure Report (Passed : Boolean) is
      begin
         OK := Passed;
         Done := True;
      end Report;

      entry Wait (Passed : out Boolean) when Done is
      begin
         Passed := OK;
      end Wait;
   end Result;

   task Runner
     with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Runner;

   task body Runner is
   begin
      Result.Report (Probe = Panicked);
   end Runner;

   Passed : Boolean;
   pragma Unreferenced (Runner);
begin
   Result.Wait (Passed);
   if not Passed then
      raise Program_Error with "Rust panic was not translated on the lightweight task";
   end if;
   Ada.Text_IO.Put_Line ("lightweight panic translation: PASS");
end Unwind_Lightweight;
