with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.IO;
with Flyology.IO.Files;
with Interfaces.C;

procedure Files_Smoke is
   use Ada.Streams;
   use type Flyology.IO.Files.File_Descriptor;
   use type Interfaces.C.int;

   function Selected_Linux_Backend return Interfaces.C.int;
   pragma Import
     (C, Selected_Linux_Backend, "flyology_linux_file_backend");

   Path : constant String := "/tmp/flyology-files-smoke.data";
   Data : constant Stream_Element_Array (1 .. 4) := [10, 20, 30, 40];

   File     : Flyology.IO.Files.File_Descriptor :=
     Flyology.IO.Files.Invalid_File;
   Incoming : Stream_Element_Array (Data'Range);
   Last     : Stream_Element_Offset;
   Rejected : Boolean := False;

   procedure Remove_Test_File is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   end Remove_Test_File;

begin
   Remove_Test_File;

   File :=
     Flyology.IO.Files.Open
       (Path,
        Mode     => Flyology.IO.Files.Read_Write,
        Create   => True,
        Truncate => True);
   Flyology.IO.Files.Write_At (File, 0, Data, Last);
   if Last /= Data'Last then
      raise Program_Error with "read/write create wrote a partial record";
   end if;
   Flyology.IO.Files.Read_At (File, 0, Incoming, Last);
   if Last /= Incoming'Last or else Incoming /= Data then
      raise Program_Error with "read/write create returned a write-only fd";
   end if;

   declare
      Batch_Size : constant Positive := 64;

      protected Progress is
         procedure Finished (Passed : Boolean);
         entry Wait;
         function Passed return Boolean;
      private
         Completed : Natural := 0;
         All_OK    : Boolean := True;
      end Progress;

      protected body Progress is
         procedure Finished (Passed : Boolean) is
         begin
            Completed := Completed + 1;
            All_OK := All_OK and Passed;
         end Finished;

         entry Wait when Completed = Batch_Size is
         begin
            null;
         end Wait;

         function Passed return Boolean is (All_OK);
      end Progress;

      task type Parallel_Writer (Index : Positive) is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Parallel_Writer;

      task body Parallel_Writer is
         Item : constant Stream_Element_Array :=
           [1 => Stream_Element (Index mod 251)];
         Written : Stream_Element_Offset;
      begin
         Flyology.IO.Files.Write_At
           (File, Flyology.IO.Files.File_Offset (Index - 1), Item, Written);
         Progress.Finished (Written = Item'Last);
      exception
         when others =>
            Progress.Finished (False);
      end Parallel_Writer;

      type Writer_Access is access Parallel_Writer;
      Writers : array (1 .. Batch_Size) of Writer_Access;
      Batch   : Stream_Element_Array
        (1 .. Stream_Element_Offset (Batch_Size));
   begin
      for Index in Writers'Range loop
         Writers (Index) := new Parallel_Writer (Index);
      end loop;
      Progress.Wait;
      if not Progress.Passed then
         raise Program_Error with "parallel kernel file write failed";
      end if;

      Flyology.IO.Files.Read_At (File, 0, Batch, Last);
      if Last /= Batch'Last then
         raise Program_Error with "parallel kernel file read was short";
      end if;
      for Index in Writers'Range loop
         if Batch (Stream_Element_Offset (Index)) /=
           Stream_Element (Index mod 251)
         then
            raise Program_Error with "parallel positional write corrupted data";
         end if;
      end loop;
   end;
   Flyology.IO.Files.Close (File);

   File :=
     Flyology.IO.Files.Open
       (Path,
        Mode     => Flyology.IO.Files.Write_Only,
        Truncate => True);

   begin
      Flyology.IO.Files.Read_At (File, 0, Incoming, Last);
   exception
      when Flyology.IO.Device_Error =>
         Rejected := True;
   end;
   if not Rejected then
      raise Program_Error with "read from write-only file was accepted";
   end if;
   Flyology.IO.Files.Close (File);

   Rejected := False;
   File := Flyology.IO.Files.Open (Path, Mode => Flyology.IO.Files.Read_Only);
   Flyology.IO.Files.Read_At (File, 0, Incoming, Last);
   if Last >= Incoming'First then
      raise Program_Error with "truncate without create was ignored";
   end if;
   Flyology.IO.Files.Close (File);

   Remove_Test_File;
   File :=
     Flyology.IO.Files.Open
       (Path, Mode => Flyology.IO.Files.Read_Only, Create => True);
   Flyology.IO.Files.Read_At (File, 0, Incoming, Last);
   if Last >= Incoming'First then
      raise Program_Error with "read-only create was not empty";
   end if;
   Flyology.IO.Files.Close (File);

   begin
      File :=
        Flyology.IO.Files.Open
          (Path,
           Mode     => Flyology.IO.Files.Read_Only,
           Truncate => True);
   exception
      when Flyology.IO.Device_Error =>
         Rejected := True;
   end;
   if not Rejected then
      Flyology.IO.Files.Close (File);
      raise Program_Error with "read-only truncate was accepted";
   end if;

   Remove_Test_File;
   if Ada.Environment_Variables.Value
     ("FLYOLOGY_EXPECT_FILE_BACKEND", "") = "native-aio"
   then
      if Selected_Linux_Backend /= 2 then
         raise Program_Error with
           "expected Linux native-AIO backend, got" &
           Interfaces.C.int'Image (Selected_Linux_Backend);
      end if;
      Ada.Text_IO.Put_Line ("linux file backend: native-aio");
   end if;
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
      Remove_Test_File;
      raise;
end Files_Smoke;
