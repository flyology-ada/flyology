with Ada.Directories;
with Ada.Streams;
with Ada.Text_IO;
with Interfaces.C;
with Flyology;
with Flyology.IO.Files;

procedure Lightweight_File_IO is
   use Ada.Streams;
   use Ada.Text_IO;
   use type Interfaces.C.int;
   use type Flyology.IO.Files.File_Descriptor;

   package C renames Interfaces.C;

   Task_Count : constant Positive := 256;
   File_Path  : constant String := "/tmp/flyology-lightweight-file-io.dat";

   function Thread_Count return C.int;
   pragma Import (C, Thread_Count, "flyology_thread_count");

   protected Progress is
      procedure Arrived;
      entry Wait_Until_Parked;
      procedure Release;
      entry Start;
      procedure Finished (Passed : Boolean);
      entry Wait_Until_Done;
      function Passed return Boolean;
   private
      Ready     : Natural := 0;
      Completed : Natural := 0;
      Released  : Boolean := False;
      All_OK    : Boolean := True;
   end Progress;

   protected body Progress is
      procedure Arrived is
      begin
         Ready := Ready + 1;
      end Arrived;

      entry Wait_Until_Parked when Ready = Task_Count is
      begin
         null;
      end Wait_Until_Parked;

      procedure Release is
      begin
         Released := True;
      end Release;

      entry Start when Released is
      begin
         null;
      end Start;

      procedure Finished (Passed : Boolean) is
      begin
         Completed := Completed + 1;
         All_OK := All_OK and Passed;
      end Finished;

      entry Wait_Until_Done when Completed = Task_Count is
      begin
         null;
      end Wait_Until_Done;

      function Passed return Boolean is (All_OK);
   end Progress;

   File : Flyology.IO.Files.File_Descriptor :=
     Flyology.IO.Files.Invalid_File;

   task type Writer (Index : Positive) is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Writer;

   task body Writer is
      Item : constant Stream_Element_Array :=
        [1 => Stream_Element (Index mod 251)];
      Last : Stream_Element_Offset;
   begin
      Progress.Arrived;
      Progress.Start;
      Flyology.IO.Files.Write_At
        (File,
         Flyology.IO.Files.File_Offset (Index - 1),
         Item,
         Last);
      Progress.Finished (Last = Item'Last);
   exception
      when others =>
         Progress.Finished (False);
   end Writer;

   type Writer_Access is access Writer;
   Writers : array (1 .. Task_Count) of Writer_Access;
   Baseline_Threads : constant C.int := Thread_Count;
   Threads          : C.int;

   procedure Remove_File is
   begin
      if Ada.Directories.Exists (File_Path) then
         Ada.Directories.Delete_File (File_Path);
      end if;
   end Remove_File;

begin
   Remove_File;
   File :=
     Flyology.IO.Files.Open
       (File_Path,
        Mode     => Flyology.IO.Files.Write_Only,
        Create   => True,
        Truncate => True);

   for Index in Writers'Range loop
      Writers (Index) := new Writer (Index);
   end loop;

   Progress.Wait_Until_Parked;
   Threads := Thread_Count;
   Put_Line ("lightweight file tasks parked:" & Task_Count'Image);
   Put_Line ("process pthreads:" & Threads'Image);
   if Threads /= Baseline_Threads + 1 then
      raise Program_Error with "lightweight file tasks created hidden pthreads";
   end if;

   Progress.Release;
   Progress.Wait_Until_Done;
   Flyology.IO.Files.Close (File);
   Remove_File;

   if not Progress.Passed then
      raise Program_Error with "kernel-completion file writes failed";
   end if;
   Put_Line
     ("all file operations completed through the event loop; worker pthreads: 0");
exception
   when others =>
      if File /= Flyology.IO.Files.Invalid_File then
         begin
            Flyology.IO.Files.Close (File);
         exception
            when others =>
               null;
         end;
      end if;
      Remove_File;
      raise;
end Lightweight_File_IO;
