with Flyology;

package body Finished_Library_Tasks is
   Worker_Count : constant := 64;

   protected Completion is
      procedure Note;
      entry Wait_All;
   private
      Count : Natural := 0;
   end Completion;

   protected body Completion is
      procedure Note is
      begin
         Count := Count + 1;
      end Note;

      entry Wait_All when Count = Worker_Count is
      begin
         null;
      end Wait_All;
   end Completion;

   task type Worker with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma Storage_Size (64 * 1_024);
   end Worker;

   task body Worker is
   begin
      Completion.Note;
   end Worker;

   Workers : array (1 .. Worker_Count) of Worker;
   pragma Unreferenced (Workers);

   procedure Wait_All is
   begin
      Completion.Wait_All;
   end Wait_All;
end Finished_Library_Tasks;
