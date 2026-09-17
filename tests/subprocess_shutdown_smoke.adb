with Ada.Command_Line;
with Ada.Streams;
with Ada.Text_IO;
with Flyology.Subprocesses;
with Interfaces.C;

--  This process must exit while its subprocess remains alive. The shell
--  regression releases the child's process group after observing our exit.

procedure Subprocess_Shutdown_Smoke is
   package Subprocesses renames Flyology.Subprocesses;
   package C renames Interfaces.C;

   use type Ada.Streams.Stream_Element_Offset;

   procedure Set_Fail_Group_Signal (Enabled : C.int);
   pragma
     Import
       (C,
        Set_Fail_Group_Signal,
        "flyology_test_subprocess_set_fail_group_signal");

   Buffer : Ada.Streams.Stream_Element_Array (1 .. 5);
   Last   : Ada.Streams.Stream_Element_Offset;
begin
   if Ada.Command_Line.Argument_Count /= 1 then
      raise Program_Error with "expected subprocess fixture path";
   end if;
   declare
      Command : Subprocesses.Command :=
        Subprocesses.To_Command (Ada.Command_Line.Argument (1));
      Child   : Subprocesses.Process;
   begin
      Subprocesses.Append_Argument (Command, "shutdown-hold");
      Subprocesses.Spawn (Command, Child);
      Subprocesses.Read_Standard_Output (Child, Buffer, Last, Timeout => 2.0);
      if Last /= Buffer'Last then
         raise Program_Error with "shutdown child did not become ready";
      end if;
      Ada.Text_IO.Put_Line
        (C.int'Image (C.int (Subprocesses.Identifier (Child))));
      Ada.Text_IO.Flush;
      Set_Fail_Group_Signal (1);
   end;
   Set_Fail_Group_Signal (0);
end Subprocess_Shutdown_Smoke;
