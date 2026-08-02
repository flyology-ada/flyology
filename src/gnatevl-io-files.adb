with System;
with GNAT.OS_Lib;
with Gnatevl.File_Open_Policy;

package body Gnatevl.IO.Files is
   package C renames Interfaces.C;

   use type Ada.Streams.Stream_Element_Offset;
   use type C.int;
   use type C.long;

   Worker_Count : constant := 4;

   function C_Open
     (Path        : System.Address;
      Flags       : C.int;
      Permissions : C.int) return C.int;
   --  open(2)'s third parameter is variadic.  That distinction matters on
   --  AArch64 Darwin, where variadic arguments use a different ABI.
   pragma Import (C_Variadic_2, C_Open, "open");

   function C_Pread
     (FD     : C.int;
      Buffer : System.Address;
      Length : C.size_t;
      Offset : C.long_long) return C.long;
   pragma Import (C, C_Pread, "pread");

   function C_Pwrite
     (FD     : C.int;
      Buffer : System.Address;
      Length : C.size_t;
      Offset : C.long_long) return C.long;
   pragma Import (C, C_Pwrite, "pwrite");

   function Current_Errno return C.int;
   pragma Import (C, Current_Errno, "__get_errno");

   procedure Perform_Open
     (Path       : String;
      Mode       : Open_Mode;
      Create     : Boolean;
      Truncate   : Boolean;
      File       : out File_Descriptor;
      Error_Code : out C.int);

   procedure Perform_Close
     (File : File_Descriptor; Error_Code : out C.int);

   procedure Perform_Read
     (File       : File_Descriptor;
      Offset     : File_Offset;
      Item       : out Ada.Streams.Stream_Element_Array;
      Last       : out Ada.Streams.Stream_Element_Offset;
      Error_Code : out C.int);

   procedure Perform_Write
     (File       : File_Descriptor;
      Offset     : File_Offset;
      Item       : Ada.Streams.Stream_Element_Array;
      Last       : out Ada.Streams.Stream_Element_Offset;
      Error_Code : out C.int);

   task type File_Worker is
      pragma Task_Info (Gnatevl.Native_Thread);

      entry Open
        (Path       : String;
         Mode       : Open_Mode;
         Create     : Boolean;
         Truncate   : Boolean;
         File       : out File_Descriptor;
         Error_Code : out C.int);

      entry Close
        (File : File_Descriptor; Error_Code : out C.int);

      entry Read_At
        (File       : File_Descriptor;
         Offset     : File_Offset;
         Item       : out Ada.Streams.Stream_Element_Array;
         Last       : out Ada.Streams.Stream_Element_Offset;
         Error_Code : out C.int);

      entry Write_At
        (File       : File_Descriptor;
         Offset     : File_Offset;
         Item       : Ada.Streams.Stream_Element_Array;
         Last       : out Ada.Streams.Stream_Element_Offset;
         Error_Code : out C.int);
   end File_Worker;

   task body File_Worker is
   begin
      loop
         select
            accept Open
              (Path       : String;
               Mode       : Open_Mode;
               Create     : Boolean;
               Truncate   : Boolean;
               File       : out File_Descriptor;
               Error_Code : out C.int)
            do
               Perform_Open
                 (Path, Mode, Create, Truncate, File, Error_Code);
            end Open;
         or
            accept Close
              (File : File_Descriptor; Error_Code : out C.int)
            do
               Perform_Close (File, Error_Code);
            end Close;
         or
            accept Read_At
              (File       : File_Descriptor;
               Offset     : File_Offset;
               Item       : out Ada.Streams.Stream_Element_Array;
               Last       : out Ada.Streams.Stream_Element_Offset;
               Error_Code : out C.int)
            do
               Perform_Read (File, Offset, Item, Last, Error_Code);
            end Read_At;
         or
            accept Write_At
              (File       : File_Descriptor;
               Offset     : File_Offset;
               Item       : Ada.Streams.Stream_Element_Array;
               Last       : out Ada.Streams.Stream_Element_Offset;
               Error_Code : out C.int)
            do
               Perform_Write (File, Offset, Item, Last, Error_Code);
            end Write_At;
         or
            terminate;
         end select;
      end loop;
   end File_Worker;

   Workers : array (Positive range 1 .. Worker_Count) of File_Worker;

   protected Router is
      procedure Choose (Index : out Positive);
   private
      Next : Positive := Workers'First;
   end Router;

   protected body Router is
      procedure Choose (Index : out Positive) is
      begin
         Index := Next;
         Next := (if Next = Workers'Last then Workers'First else Next + 1);
      end Choose;
   end Router;

   procedure Perform_Open
     (Path       : String;
      Mode       : Open_Mode;
      Create     : Boolean;
      Truncate   : Boolean;
      File       : out File_Descriptor;
      Error_Code : out C.int)
   is
      C_Path : aliased String (1 .. Path'Length + 1);
      Policy_Mode : constant File_Open_Policy.Access_Mode :=
        (case Mode is
           when Read_Only  => File_Open_Policy.Read_Only,
           when Write_Only => File_Open_Policy.Write_Only,
           when Read_Write => File_Open_Policy.Read_Write);
      Flags  : constant C.int :=
        File_Open_Policy.Compose
          (Policy_Mode, Create, Truncate);
      Result : C.int;
   begin
      C_Path (1 .. Path'Length) := Path;
      C_Path (C_Path'Last) := ASCII.NUL;
      Result := C_Open (C_Path'Address, Flags, 8#666#);
      File := File_Descriptor (Result);
      Error_Code :=
        (if Result < 0 then Current_Errno else 0);
   end Perform_Open;

   procedure Perform_Close
     (File : File_Descriptor; Error_Code : out C.int)
   is
      Status : Boolean;
   begin
      GNAT.OS_Lib.Close (GNAT.OS_Lib.File_Descriptor (File), Status);
      Error_Code := (if Status then 0 else Current_Errno);
   end Perform_Close;

   procedure Perform_Read
     (File       : File_Descriptor;
      Offset     : File_Offset;
      Item       : out Ada.Streams.Stream_Element_Array;
      Last       : out Ada.Streams.Stream_Element_Offset;
      Error_Code : out C.int)
   is
      Result : C.long;
   begin
      if Item'Length = 0 then
         Last := Item'First - 1;
         Error_Code := 0;
         return;
      end if;

      Result := C_Pread
        (C.int (File),
         Item'Address,
         C.size_t (Item'Length),
         C.long_long (Offset));
      if Result < 0 then
         Last := Item'First - 1;
         Error_Code := Current_Errno;
      else
         Last := Item'First + Ada.Streams.Stream_Element_Offset (Result) - 1;
         Error_Code := 0;
      end if;
   end Perform_Read;

   procedure Perform_Write
     (File       : File_Descriptor;
      Offset     : File_Offset;
      Item       : Ada.Streams.Stream_Element_Array;
      Last       : out Ada.Streams.Stream_Element_Offset;
      Error_Code : out C.int)
   is
      Result : C.long;
   begin
      if Item'Length = 0 then
         Last := Item'First - 1;
         Error_Code := 0;
         return;
      end if;

      Result := C_Pwrite
        (C.int (File),
         Item'Address,
         C.size_t (Item'Length),
         C.long_long (Offset));
      if Result < 0 then
         Last := Item'First - 1;
         Error_Code := Current_Errno;
      else
         Last := Item'First + Ada.Streams.Stream_Element_Offset (Result) - 1;
         Error_Code := 0;
      end if;
   end Perform_Write;

   procedure Raise_IO_Error (Operation : String; Error_Code : C.int) is
   begin
      raise Device_Error with Operation & " failed, errno=" & Error_Code'Image;
   end Raise_IO_Error;

   function Open
     (Path     : String;
      Mode     : Open_Mode := Read_Only;
      Create   : Boolean := False;
      Truncate : Boolean := False) return File_Descriptor
   is
      File       : File_Descriptor;
      Error_Code : C.int;
      Worker     : Positive;
   begin
      if not File_Open_Policy.Valid
        ((case Mode is
            when Read_Only  => File_Open_Policy.Read_Only,
            when Write_Only => File_Open_Policy.Write_Only,
            when Read_Write => File_Open_Policy.Read_Write),
         Truncate)
      then
         raise Device_Error with
           "open failed: Truncate requires Write_Only or Read_Write mode";
      end if;

      if Is_Evented_Task then
         Router.Choose (Worker);
         Workers (Worker).Open
           (Path, Mode, Create, Truncate, File, Error_Code);
      else
         Perform_Open (Path, Mode, Create, Truncate, File, Error_Code);
      end if;
      if Error_Code /= 0 then
         Raise_IO_Error ("open", Error_Code);
      end if;
      return File;
   end Open;

   procedure Close (File : in out File_Descriptor) is
      Error_Code : C.int;
      Worker     : Positive;
   begin
      if File = Invalid_File then
         return;
      end if;
      if Is_Evented_Task then
         Router.Choose (Worker);
         Workers (Worker).Close (File, Error_Code);
      else
         Perform_Close (File, Error_Code);
      end if;
      File := Invalid_File;
      if Error_Code /= 0 then
         Raise_IO_Error ("close", Error_Code);
      end if;
   end Close;

   procedure Read_At
     (File   : File_Descriptor;
      Offset : File_Offset;
      Item   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset)
   is
      Error_Code : C.int;
      Worker     : Positive;
   begin
      if Is_Evented_Task then
         Router.Choose (Worker);
         Workers (Worker).Read_At (File, Offset, Item, Last, Error_Code);
      else
         Perform_Read (File, Offset, Item, Last, Error_Code);
      end if;
      if Error_Code /= 0 then
         Raise_IO_Error ("pread", Error_Code);
      end if;
   end Read_At;

   procedure Write_At
     (File   : File_Descriptor;
      Offset : File_Offset;
      Item   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset)
   is
      Error_Code : C.int;
      Worker     : Positive;
   begin
      if Is_Evented_Task then
         Router.Choose (Worker);
         Workers (Worker).Write_At (File, Offset, Item, Last, Error_Code);
      else
         Perform_Write (File, Offset, Item, Last, Error_Code);
      end if;
      if Error_Code /= 0 then
         Raise_IO_Error ("pwrite", Error_Code);
      end if;
   end Write_At;

end Gnatevl.IO.Files;
