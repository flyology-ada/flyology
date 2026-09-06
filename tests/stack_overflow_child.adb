with Ada.Command_Line;
with Ada.Text_IO;
with Flyology;
with Flyology.Observability;
with Interfaces;
with Interfaces.C;

--  Run alternate-signal-stack and stack-size observations plus real task-stack
--  overflows in a child process. A missing loop-thread signal stack kills the
--  process before the lightweight task can enter its Storage_Error handler.

procedure Stack_Overflow_Child is
   package C renames Interfaces.C;
   package Observation renames Flyology.Observability;

   use type C.int;
   use type Observation.Counter;

   --  Regression contract: the reported overflow used a 256 KiB task stack,
   --  which leaves ordinary task frames ample room before bounded recursion
   --  reaches the guard page.
   Requested_Stack_Bytes : constant := 256 * 1_024;

   Scenario : constant String :=
     (if Ada.Command_Line.Argument_Count = 1
      then Ada.Command_Line.Argument (1)
      else "");

   procedure Immediate_Exit (Status : C.int);
   pragma Import (C, Immediate_Exit, "_exit");

   function Alternate_Stack_Is_Installed return C.int;
   pragma
     Import
       (C,
        Alternate_Stack_Is_Installed,
        "flyology_test_alt_stack_is_installed");

   function Get_Page_Size return C.int;
   pragma Import (C, Get_Page_Size, "getpagesize");

   function Rounded_Stack_Bytes return Observation.Counter is
      Page_Size : constant Observation.Counter :=
        Observation.Counter (Get_Page_Size);
   begin
      return
        (Observation.Counter (Requested_Stack_Bytes) + Page_Size - 1)
        / Page_Size
        * Page_Size;
   end Rounded_Stack_Bytes;

   procedure Recurse (Depth : Natural);

   procedure Recurse (Depth : Natural) is
      Frame : array (1 .. 4_096) of Interfaces.Unsigned_8 := (others => 0);
      pragma Volatile (Frame);
   begin
      Frame (1) := Interfaces.Unsigned_8 (Depth mod 256);
      Recurse (Depth + 1);
      Frame (Frame'Last) := Frame (1);
   end Recurse;
   pragma No_Inline (Recurse);

   task Lightweight_Worker is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma Storage_Size (Requested_Stack_Bytes);
   end Lightweight_Worker;

   task body Lightweight_Worker is
   begin
      if Scenario = "observe-lightweight" then
         Immediate_Exit (if Alternate_Stack_Is_Installed = 1 then 0 else 11);
      elsif Scenario = "observe-lightweight-size" then
         declare
            Pool : constant Observation.Stack_Pool_Snapshot :=
              Observation.Stack_Pool;
         begin
            Immediate_Exit
              (if Pool.Live_Stacks = 1
                 and then Pool.Live_Usable_Bytes = Rounded_Stack_Bytes
               then 0
               else 14);
         end;
      elsif Scenario = "overflow-lightweight" then
         Recurse (0);
         Immediate_Exit (12);
      end if;
   exception
      when Storage_Error =>
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error, Scenario & ": Storage_Error");
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
         Immediate_Exit (0);
      when others =>
         Immediate_Exit (13);
   end Lightweight_Worker;

   task Native_Worker is
      pragma Task_Info (Flyology.Native_Task);
      pragma Storage_Size (Requested_Stack_Bytes);
   end Native_Worker;

   task body Native_Worker is
   begin
      if Scenario = "observe-native" then
         Immediate_Exit (if Alternate_Stack_Is_Installed = 1 then 0 else 21);
      elsif Scenario = "overflow-native" then
         Recurse (0);
         Immediate_Exit (22);
      end if;
   exception
      when Storage_Error =>
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error, Scenario & ": Storage_Error");
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
         Immediate_Exit (0);
      when others =>
         Immediate_Exit (23);
   end Native_Worker;
begin
   if Ada.Command_Line.Argument_Count = 0 then
      return;
   elsif Ada.Command_Line.Argument_Count /= 1 then
      Immediate_Exit (30);
   end if;

   if Scenario
      not in "observe-lightweight"
           | "observe-lightweight-size"
           | "overflow-lightweight"
           | "observe-native"
           | "overflow-native"
   then
      Immediate_Exit (31);
   end if;
end Stack_Overflow_Child;
