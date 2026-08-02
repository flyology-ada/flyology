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
   Gnatevl.IO.Files.Close (File);

   File :=
     Gnatevl.IO.Files.Open
       (Path,
        Mode     => Gnatevl.IO.Files.Write_Only,
        Truncate => True);
   Gnatevl.IO.Files.Close (File);

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
