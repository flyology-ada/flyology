with Ada.Text_IO;
with GNAT.OS_Lib;

package body Flyology_CLI.Processes is
   use Ada.Strings.Unbounded;
   use type GNAT.OS_Lib.File_Descriptor;
   use type GNAT.OS_Lib.String_Access;

   function Locate (Program_Name : String) return GNAT.OS_Lib.String_Access is
   begin
      return GNAT.OS_Lib.Locate_Exec_On_Path (Program_Name);
   end Locate;

   function To_Arguments (Arguments : String_Vectors.Vector) return GNAT.OS_Lib.Argument_List is
      Result : GNAT.OS_Lib.Argument_List (1 .. Natural (Arguments.Length));
   begin
      for Index in Result'Range loop
         Result (Index) := new String'(Arguments (Index));
      end loop;
      return Result;
   end To_Arguments;

   procedure Release (Arguments : in out GNAT.OS_Lib.Argument_List) is
   begin
      for Argument of Arguments loop
         GNAT.OS_Lib.Free (Argument);
      end loop;
   end Release;

   function Is_Available (Program_Name : String) return Boolean is
      Path : GNAT.OS_Lib.String_Access := Locate (Program_Name);
   begin
      if Path = null then
         return False;
      end if;
      GNAT.OS_Lib.Free (Path);
      return True;
   end Is_Available;

   function Run (Program_Name : String; Arguments : String_Vectors.Vector) return Integer is
      Path        : GNAT.OS_Lib.String_Access := Locate (Program_Name);
      Native_Args : GNAT.OS_Lib.Argument_List := To_Arguments (Arguments);
      Status      : Integer;
   begin
      if Path = null then
         Release (Native_Args);
         return 127;
      end if;

      Status := GNAT.OS_Lib.Spawn (Path.all, Native_Args);
      GNAT.OS_Lib.Free (Path);
      Release (Native_Args);
      return Status;
   exception
      when others =>
         if Path /= null then
            GNAT.OS_Lib.Free (Path);
         end if;
         Release (Native_Args);
         return 127;
   end Run;

   function Capture
     (Program_Name : String; Arguments : String_Vectors.Vector; Output : out Unbounded_String) return Integer
   is
      Path        : GNAT.OS_Lib.String_Access := Locate (Program_Name);
      Native_Args : GNAT.OS_Lib.Argument_List := To_Arguments (Arguments);
      Descriptor  : GNAT.OS_Lib.File_Descriptor := GNAT.OS_Lib.Invalid_FD;
      Temp_Name   : GNAT.OS_Lib.String_Access := null;
      Status      : Integer := 127;
      Closed      : Boolean;
      Deleted     : Boolean;
      Input       : Ada.Text_IO.File_Type;
   begin
      Output := Null_Unbounded_String;
      if Path = null then
         Release (Native_Args);
         return Status;
      end if;

      GNAT.OS_Lib.Create_Temp_Output_File (Descriptor, Temp_Name);
      if Descriptor = GNAT.OS_Lib.Invalid_FD or else Temp_Name = null then
         GNAT.OS_Lib.Free (Path);
         Release (Native_Args);
         return Status;
      end if;

      GNAT.OS_Lib.Spawn
        (Program_Name           => Path.all,
         Args                   => Native_Args,
         Output_File_Descriptor => Descriptor,
         Return_Code            => Status,
         Err_To_Out             => True);
      GNAT.OS_Lib.Close (Descriptor, Closed);
      Descriptor := GNAT.OS_Lib.Invalid_FD;

      if Closed then
         Ada.Text_IO.Open (Input, Ada.Text_IO.In_File, Temp_Name.all);
         while not Ada.Text_IO.End_Of_File (Input) loop
            Append (Output, Ada.Text_IO.Get_Line (Input));
            Append (Output, ASCII.LF);
         end loop;
         Ada.Text_IO.Close (Input);
      end if;

      GNAT.OS_Lib.Delete_File (Temp_Name.all, Deleted);
      GNAT.OS_Lib.Free (Temp_Name);
      GNAT.OS_Lib.Free (Path);
      Release (Native_Args);
      return Status;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (Input) then
            Ada.Text_IO.Close (Input);
         end if;
         if Descriptor /= GNAT.OS_Lib.Invalid_FD then
            GNAT.OS_Lib.Close (Descriptor);
         end if;
         if Temp_Name /= null then
            GNAT.OS_Lib.Delete_File (Temp_Name.all, Deleted);
            GNAT.OS_Lib.Free (Temp_Name);
         end if;
         if Path /= null then
            GNAT.OS_Lib.Free (Path);
         end if;
         Release (Native_Args);
         return 127;
   end Capture;
end Flyology_CLI.Processes;
