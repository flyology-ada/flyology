with Ada.Directories;
with Ada.Streams;
with Gnatevl.IO;
with Gnatevl.IO.Files;

procedure Files_Smoke is
   use Ada.Streams;
   use type Gnatevl.IO.Files.File_Descriptor;

   Path : constant String := "/tmp/gnatevl-files-smoke.data";
   Data : constant Stream_Element_Array (1 .. 4) := [10, 20, 30, 40];

   File     : Gnatevl.IO.Files.File_Descriptor :=
     Gnatevl.IO.Files.Invalid_File;
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
     Gnatevl.IO.Files.Open
       (Path,
        Mode     => Gnatevl.IO.Files.Read_Write,
        Create   => True,
        Truncate => True);
   Gnatevl.IO.Files.Write_At (File, 0, Data, Last);
   if Last /= Data'Last then
      raise Program_Error with "read/write create wrote a partial record";
   end if;
   Gnatevl.IO.Files.Read_At (File, 0, Incoming, Last);
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

      task type Parallel_Writer (Index : Positive);

      task body Parallel_Writer is
         Item : constant Stream_Element_Array :=
           [1 => Stream_Element (Index mod 251)];
         Written : Stream_Element_Offset;
      begin
         Gnatevl.IO.Files.Write_At
           (File, Gnatevl.IO.Files.File_Offset (Index - 1), Item, Written);
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

      Gnatevl.IO.Files.Read_At (File, 0, Batch, Last);
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
   Gnatevl.IO.Files.Close (File);

   File :=
     Gnatevl.IO.Files.Open
       (Path,
        Mode     => Gnatevl.IO.Files.Write_Only,
        Truncate => True);

   begin
      Gnatevl.IO.Files.Read_At (File, 0, Incoming, Last);
   exception
      when Gnatevl.IO.Device_Error =>
         Rejected := True;
   end;
   if not Rejected then
      raise Program_Error with "read from write-only file was accepted";
   end if;
   Gnatevl.IO.Files.Close (File);

   Rejected := False;
   File := Gnatevl.IO.Files.Open (Path, Mode => Gnatevl.IO.Files.Read_Only);
   Gnatevl.IO.Files.Read_At (File, 0, Incoming, Last);
   if Last >= Incoming'First then
      raise Program_Error with "truncate without create was ignored";
   end if;
   Gnatevl.IO.Files.Close (File);

   Remove_Test_File;
   File :=
     Gnatevl.IO.Files.Open
       (Path, Mode => Gnatevl.IO.Files.Read_Only, Create => True);
   Gnatevl.IO.Files.Read_At (File, 0, Incoming, Last);
   if Last >= Incoming'First then
      raise Program_Error with "read-only create was not empty";
   end if;
   Gnatevl.IO.Files.Close (File);

   begin
      File :=
        Gnatevl.IO.Files.Open
          (Path,
           Mode     => Gnatevl.IO.Files.Read_Only,
           Truncate => True);
   exception
      when Gnatevl.IO.Device_Error =>
         Rejected := True;
   end;
   if not Rejected then
      Gnatevl.IO.Files.Close (File);
      raise Program_Error with "read-only truncate was accepted";
   end if;

   Remove_Test_File;
exception
   when others =>
      if File /= Gnatevl.IO.Files.Invalid_File then
         begin
            Gnatevl.IO.Files.Close (File);
         exception
            when others =>
               null;
         end;
      end if;
      Remove_Test_File;
      raise;
end Files_Smoke;
