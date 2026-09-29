with Ada.Command_Line;
with Flyology;
with Flyology.Observability;
with Interfaces.C;

procedure Stack_Guard_Violation_Child is
   package C renames Interfaces.C;
   package Observation renames Flyology.Observability;

   use type Observation.Counter;
   use type C.size_t;

   Jump_Distance : C.size_t := 0;

   procedure Sparse_Stack_Write (Distance : C.size_t);
   pragma Import (C, Sparse_Stack_Write, "flyology_test_sparse_stack_write");

   procedure Immediate_Exit (Status : C.int);
   pragma Import (C, Immediate_Exit, "_exit");

   function Get_Page_Size return C.int;
   pragma Import (C, Get_Page_Size, "getpagesize");

   protected Gate is
      procedure Victim_Started;
      entry Wait_For_Victim;
      entry Hold_Victim;
   private
      Victim_Is_Ready : Boolean := False;
   end Gate;

   protected body Gate is
      procedure Victim_Started is
      begin
         Victim_Is_Ready := True;
      end Victim_Started;

      entry Wait_For_Victim when Victim_Is_Ready is
      begin
         null;
      end Wait_For_Victim;

      entry Hold_Victim when False is
      begin
         null;
      end Hold_Victim;
   end Gate;

   task type Victim is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma Storage_Size (16 * 1_024);
   end Victim;

   task body Victim is
   begin
      Gate.Victim_Started;
      Gate.Hold_Victim;
   end Victim;

   task type Attacker is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma Storage_Size (16 * 1_024);
   end Attacker;

   task body Attacker is
   begin
      Sparse_Stack_Write (Jump_Distance);
      Immediate_Exit (101);
   exception
      when Storage_Error =>
         Immediate_Exit (0);
      when others =>
         Immediate_Exit (102);
   end Attacker;

   type Victim_Access is access Victim;
   type Attacker_Access is access Attacker;
begin
   if Ada.Command_Line.Argument_Count = 1 and then Ada.Command_Line.Argument (1) = "violate" then
      declare
         Victim_Task   : constant Victim_Access := new Victim;
         Attacker_Task : Attacker_Access;
         Pool          : Observation.Stack_Pool_Snapshot;
         pragma Unreferenced (Victim_Task);
      begin
         Gate.Wait_For_Victim;
         Pool := Observation.Stack_Pool;
         if Pool.Live_Stacks /= 1 or else Pool.Live_Usable_Bytes = 0 then
            Immediate_Exit (103);
         end if;

         --  The sparse store lands more than one host page below this stack's
         --  lower boundary because the active task frames already consume
         --  space. That crosses the former single-page guard but remains
         --  inside the new guard on both supported hosts.
         Jump_Distance := C.size_t (Pool.Live_Usable_Bytes) + C.size_t (Get_Page_Size);
         Attacker_Task := new Attacker;
         for Attempt in 1 .. 5_000 loop
            if Attacker_Task.all'Terminated then
               --  A translated protection fault can terminate the individual
               --  lightweight task before its exception handler runs. That
               --  is still contained rather than an adjacent-stack write.
               Immediate_Exit (0);
            end if;
            delay 0.001;
         end loop;
         Immediate_Exit (104);
      end;
   end if;
end Stack_Guard_Violation_Child;
