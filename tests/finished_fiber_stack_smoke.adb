with Finished_Library_Tasks;
with Flyology;
with Flyology.Observability;

procedure Finished_Fiber_Stack_Smoke is
   package Observation renames Flyology.Observability;

   use type Observation.Counter;
   use type Observation.Task_State;

   Worker_Count : constant := 64;
   Expected     : constant Observation.Counter := Worker_Count;

   procedure Wait_For_Empty_Stacks is
      Pool : Observation.Stack_Pool_Snapshot;
   begin
      for Attempt in 1 .. 1_000 loop
         Pool := Observation.Stack_Pool;
         exit when Pool.Live_Stacks = 0 and then Pool.Active_Arenas = 0;
         delay 0.001;
      end loop;
      if Pool.Live_Stacks /= 0
        or else Pool.Active_Arenas /= 0
        or else Pool.Reserved_Bytes /= 0
        or else Pool.Arena_Mappings /= Pool.Arena_Unmappings
      then
         raise Program_Error
           with "finished lightweight task stacks remain mapped";
      end if;
   end Wait_For_Empty_Stacks;

   procedure Check_Library_Records is
      Items : Observation.Task_Snapshot_Array (1 .. Worker_Count);
      Count : Natural;
      Total : Observation.Counter;
      Group : Observation.Group_Snapshot;
   begin
      if not Observation.Snapshot (1, Group)
        or else Group.Finished /= Expected
        or else not Observation.Snapshot_Tasks (1, Items, Count, Total)
        or else Count /= Worker_Count
        or else Total /= Expected
      then
         raise Program_Error
           with "finished library task registry is incomplete";
      end if;
      for Item of Items loop
         if Item.State /= Observation.Task_Finished
           or else Item.Stack_Usable_Bytes /= 0
         then
            raise Program_Error
              with "finished library task retained execution storage";
         end if;
      end loop;
   end Check_Library_Records;

   task type Local_Worker with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma Storage_Size (64 * 1_024);
   end Local_Worker;

   task body Local_Worker is
   begin
      null;
   end Local_Worker;

begin
   Finished_Library_Tasks.Wait_All;
   Wait_For_Empty_Stacks;
   Check_Library_Records;

   declare
      Workers : array (1 .. Worker_Count) of Local_Worker;
      pragma Unreferenced (Workers);
   begin
      null;
   end;

   Wait_For_Empty_Stacks;
   Check_Library_Records;
end Finished_Fiber_Stack_Smoke;
