with Ada.Text_IO;
with Flyology;
with Showcase_Support;

procedure Many_Lightweight_Tasks is
   use Ada.Text_IO;

   Worker_Count : constant := 64;

   protected Id_Source is
      procedure Take (Id : out Positive);
   private
      Next_Id : Positive := 1;
   end Id_Source;

   protected body Id_Source is
      procedure Take (Id : out Positive) is
      begin
         Id := Next_Id;
         Next_Id := Next_Id + 1;
      end Take;
   end Id_Source;

   protected Completion is
      procedure Finished (Thread : String);
      entry Wait;
      function Same_Thread return Boolean;
   private
      Count       : Natural := 0;
      First       : String (1 .. 32) := (others => ' ');
      First_Last  : Natural := 0;
      All_Matched : Boolean := True;
   end Completion;

   protected body Completion is
      procedure Finished (Thread : String) is
      begin
         Count := Count + 1;
         if First_Last = 0 then
            First_Last := Thread'Length;
            First (1 .. First_Last) := Thread;
         else
            All_Matched := All_Matched and then Thread = First (1 .. First_Last);
         end if;
      end Finished;

      entry Wait when Count = Worker_Count is
      begin
         null;
      end Wait;

      function Same_Thread return Boolean
      is (All_Matched);
   end Completion;

   task type Worker is
      --  showcases.sh selects the lightweight project default. This task type
      --  deliberately follows it instead of hard-coding a lane.
      pragma Task_Info (Flyology.Project_Default);
   end Worker;

   task body Worker is
      Id : Positive;
   begin
      Id_Source.Take (Id);
      delay Duration (Id mod 11) * 0.002;
      Completion.Finished (Showcase_Support.Thread_Image);
   end Worker;

   Workers : array (1 .. Worker_Count) of Worker;
   pragma Unreferenced (Workers);

begin
   Put_Line
     ("starting"
      & Worker_Count'Image
      & " project-default timed Ada tasks; environment thread="
      & Showcase_Support.Thread_Image);
   Completion.Wait;

   if not Completion.Same_Thread then
      raise Program_Error with "lightweight workers escaped the event thread";
   end if;

   Put_Line ("completed" & Worker_Count'Image & " tasks on one event thread");
end Many_Lightweight_Tasks;
