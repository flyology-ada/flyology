with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams;
with Flyology;
with Flyology.IO.Files;
with Flyology.Operations;

procedure Operations_Finalize_Smoke is
   package Files renames Flyology.IO.Files;
   package Operations renames Flyology.Operations;

   use Ada.Streams;

   type Buffer_Access is access all Stream_Element_Array;

   Test_Root : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_TEST_TEMP_ROOT", "build");
   Big       : constant Buffer_Access :=
     new Stream_Element_Array'(1 .. 256 * 1_024 * 1_024 => 42);

   procedure Run (Read_First : Boolean) is
      Suffix : constant String :=
        (if Read_First then "read-first" else "write-first");
      Path   : constant String :=
        Test_Root & "/operations-finalize-" & Suffix & ".data";
      File   : Files.File_Descriptor := Files.Invalid_File;
      Passed : Boolean := False
      with Atomic;

      procedure Remove_Test_File is
      begin
         if Ada.Directories.Exists (Path) then
            Ada.Directories.Delete_File (Path);
         end if;
      end Remove_Test_File;
   begin
      Remove_Test_File;
      File :=
        Files.Open
          (Path, Mode => Files.Read_Write, Create => True, Truncate => True);
      declare
         task Worker is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Worker;

         task body Worker is
            Set   : aliased Operations.Completion_Set (4);
            Small : aliased Stream_Element_Array := (1 .. 16 => 0);
         begin
            if Read_First then
               declare
                  Read_Item  : constant Files.Read_Operation :=
                    Files.Read_At (Set'Access, File, 0, Small'Access);
                  Write_Item : constant Files.Write_Operation :=
                    Files.Write_At (Set'Access, File, 0, Big);
               begin
                  if Operations.Id (Read_Item) /= 1
                    or else Operations.Id (Write_Item) /= 2
                  then
                     raise Program_Error
                       with "read-first operations used unexpected slots";
                  end if;
               end;
            else
               declare
                  Write_Item : constant Files.Write_Operation :=
                    Files.Write_At (Set'Access, File, 0, Big);
                  Read_Item  : constant Files.Read_Operation :=
                    Files.Read_At (Set'Access, File, 0, Small'Access);
               begin
                  if Operations.Id (Write_Item) /= 1
                    or else Operations.Id (Read_Item) /= 2
                  then
                     raise Program_Error
                       with "write-first operations used unexpected slots";
                  end if;
               end;
            end if;
            Passed :=
              Operations.Pending_Count (Set) = 0
              and then Operations.Terminal_Count (Set) = 0;
         exception
            when others =>
               Passed := False;
         end Worker;
      begin
         null;
      end;
      Files.Close (File);
      Remove_Test_File;
      if not Passed then
         raise Program_Error
           with Suffix & " finalization did not drain both operations";
      end if;
   exception
      when others =>
         Files.Close (File);
         Remove_Test_File;
         raise;
   end Run;
begin
   Run (Read_First => False);
   Run (Read_First => True);
end Operations_Finalize_Smoke;
