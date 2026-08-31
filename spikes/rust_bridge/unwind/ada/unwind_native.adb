with Ada.Text_IO;
with Interfaces.C;

procedure Unwind_Native is
   use type Interfaces.C.unsigned;

   Panicked : constant Interfaces.C.unsigned := 2;

   function Probe return Interfaces.C.unsigned
   with Import, Convention => C, External_Name => "flyology_rust_unwind_probe";
begin
   if Probe /= Panicked then
      raise Program_Error with "Rust panic was not translated on the native task";
   end if;
   Ada.Text_IO.Put_Line ("native panic translation: PASS");
end Unwind_Native;
