with GNAT.OS_Lib;
with Flyology.File_Open_Policy;
with System;
with System.OS_Constants;

package body Flyology.IO.Files is
   package C renames Interfaces.C;

   use type Ada.Streams.Stream_Element_Offset;
   use type C.int;
   use type C.long;
   use type C.long_long;

   function C_Open
     (Path        : System.Address;
      Flags       : C.int;
      Permissions : C.int) return C.int;
   --  open(2)'s third parameter is variadic. That distinction matters on
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

   function Event_File_IO
     (Descriptor  : C.int;
      Buffer      : System.Address;
      Length      : C.size_t;
      Offset      : C.long_long;
      For_Write   : C.int;
      Cancel_FD   : C.int;
      Transferred : access C.long_long;
      Error_Code  : access C.int;
      Cancelled   : access C.int) return C.int;
   pragma Import (C, Event_File_IO, "flyology_runtime_file_io");

   function Current_Errno return C.int is
     (C.int (GNAT.OS_Lib.Errno));

   procedure Cancellation_Source
     (Token      : access Cancellation_Token;
      Lightweight : Boolean;
      Descriptor : out C.int)
   is
      Already_Requested : Boolean := False;
   begin
      if Token = null then
         Descriptor := -1;
      elsif not Lightweight then
         --  Native file calls cannot be interrupted once inside pread/pwrite.
         --  Observe an already-requested token without allocating an
         --  event-loop wake source that this lane could never wait on.
         Descriptor := -1;
         if Token.Requested then
            raise Operation_Cancelled;
         end if;
      else
         Token.Wait_Source (Descriptor, Already_Requested);
         if Already_Requested then
            raise Operation_Cancelled;
         end if;
      end if;
   end Cancellation_Source;

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
      C_Path : aliased String (1 .. Path'Length + 1);
      Policy_Mode : constant File_Open_Policy.Access_Mode :=
        (case Mode is
           when Read_Only  => File_Open_Policy.Read_Only,
           when Write_Only => File_Open_Policy.Write_Only,
           when Read_Write => File_Open_Policy.Read_Write);
      Flags  : constant C.int :=
        File_Open_Policy.Compose (Policy_Mode, Create, Truncate);
      Result : C.int;
   begin
      if not File_Open_Policy.Valid (Policy_Mode, Truncate) then
         raise Device_Error with
           "open failed: Truncate requires Write_Only or Read_Write mode";
      end if;

      C_Path (1 .. Path'Length) := Path;
      C_Path (C_Path'Last) := ASCII.NUL;
      Result := C_Open (C_Path'Address, Flags, 8#666#);
      if Result < 0 then
         Raise_IO_Error ("open", Current_Errno);
      end if;
      return File_Descriptor (Result);
   end Open;

   procedure Close (File : in out File_Descriptor) is
      Status : Boolean;
   begin
      if File = Invalid_File then
         return;
      end if;
      GNAT.OS_Lib.Close (GNAT.OS_Lib.File_Descriptor (File), Status);
      File := Invalid_File;
      if not Status then
         Raise_IO_Error ("close", Current_Errno);
      end if;
   end Close;

   procedure Native_Read
     (File       : File_Descriptor;
      Offset     : File_Offset;
      Item       : out Ada.Streams.Stream_Element_Array;
      Transferred : out C.long_long;
      Error_Code : out C.int)
   is
      Result : C.long;
   begin
      loop
         Result :=
           C_Pread
             (C.int (File),
              Item'Address,
              C.size_t (Item'Length),
              C.long_long (Offset));
         exit when Result >= 0
           or else Current_Errno /= C.int (System.OS_Constants.EINTR);
      end loop;
      if Result < 0 then
         Transferred := 0;
         Error_Code := Current_Errno;
      else
         Transferred := C.long_long (Result);
         Error_Code := 0;
      end if;
   end Native_Read;

   procedure Native_Write
     (File       : File_Descriptor;
      Offset     : File_Offset;
      Item       : Ada.Streams.Stream_Element_Array;
      Transferred : out C.long_long;
      Error_Code : out C.int)
   is
      Result : C.long;
   begin
      loop
         Result :=
           C_Pwrite
             (C.int (File),
              Item'Address,
              C.size_t (Item'Length),
              C.long_long (Offset));
         exit when Result >= 0
           or else Current_Errno /= C.int (System.OS_Constants.EINTR);
      end loop;
      if Result < 0 then
         Transferred := 0;
         Error_Code := Current_Errno;
      else
         Transferred := C.long_long (Result);
         Error_Code := 0;
      end if;
   end Native_Write;

   procedure Read_At
     (File   : File_Descriptor;
      Offset : File_Offset;
      Item   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Token  : access Cancellation_Token := null)
   is
      Transferred : aliased C.long_long := 0;
      Error_Code  : aliased C.int := 0;
      Cancelled   : aliased C.int := 0;
      Status      : C.int := 0;
      Cancel_FD   : C.int := -1;
   begin
      Last := Item'First - 1;
      if Item'Length = 0 then
         return;
      end if;
      declare
         Lightweight : constant Boolean := Is_Lightweight_Task;
      begin
         Cancellation_Source (Token, Lightweight, Cancel_FD);
         if Lightweight then
            Status :=
              Event_File_IO
                (C.int (File),
                 Item'Address,
                 C.size_t (Item'Length),
                 C.long_long (Offset),
                 0,
                 Cancel_FD,
                 Transferred'Access,
                 Error_Code'Access,
                 Cancelled'Access);
         else
            Native_Read (File, Offset, Item, Transferred, Error_Code);
         end if;
      end;
      if Status /= 0 and then Error_Code = 0 then
         raise Device_Error with "lightweight pread submission failed";
      elsif Cancelled /= 0 then
         raise Operation_Cancelled;
      elsif Error_Code /= 0 then
         Raise_IO_Error ("pread", Error_Code);
      elsif Transferred < 0
        or else Transferred > C.long_long (Item'Length)
      then
         raise Device_Error with "pread returned an invalid length";
      elsif Transferred > 0 then
         Last := Item'First
           + Ada.Streams.Stream_Element_Offset (Transferred) - 1;
      end if;
   end Read_At;

   procedure Read_At
     (File   : File_Descriptor;
      Offset : File_Offset;
      Item   : in out Flyology.Buffers.Unique_Buffer;
      Read   : out Natural;
      Token  : access Cancellation_Token := null)
   is
      procedure Borrow
        (Data   : in out Ada.Streams.Stream_Element_Array;
         Length : in out Natural)
      is
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Read_At (File, Offset, Data, Last, Token);
         Length :=
           (if Last < Data'First
            then 0
            else Natural (Last - Data'First + 1));
         Read := Length;
      end Borrow;
   begin
      Read := 0;
      Flyology.Buffers.With_Writable_Data (Item, Borrow'Access);
   end Read_At;

   procedure Write_At
     (File   : File_Descriptor;
      Offset : File_Offset;
      Item   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Token  : access Cancellation_Token := null)
   is
      Transferred : aliased C.long_long := 0;
      Error_Code  : aliased C.int := 0;
      Cancelled   : aliased C.int := 0;
      Status      : C.int := 0;
      Cancel_FD   : C.int := -1;
   begin
      Last := Item'First - 1;
      if Item'Length = 0 then
         return;
      end if;
      declare
         Lightweight : constant Boolean := Is_Lightweight_Task;
      begin
         Cancellation_Source (Token, Lightweight, Cancel_FD);
         if Lightweight then
            Status :=
              Event_File_IO
                (C.int (File),
                 Item'Address,
                 C.size_t (Item'Length),
                 C.long_long (Offset),
                 1,
                 Cancel_FD,
                 Transferred'Access,
                 Error_Code'Access,
                 Cancelled'Access);
         else
            Native_Write (File, Offset, Item, Transferred, Error_Code);
         end if;
      end;
      if Status /= 0 and then Error_Code = 0 then
         raise Device_Error with "lightweight pwrite submission failed";
      elsif Cancelled /= 0 then
         raise Operation_Cancelled;
      elsif Error_Code /= 0 then
         Raise_IO_Error ("pwrite", Error_Code);
      elsif Transferred < 0
        or else Transferred > C.long_long (Item'Length)
      then
         raise Device_Error with "pwrite returned an invalid length";
      elsif Transferred > 0 then
         Last := Item'First
           + Ada.Streams.Stream_Element_Offset (Transferred) - 1;
      end if;
   end Write_At;

   procedure Write_At
     (File    : File_Descriptor;
      Offset  : File_Offset;
      Item    : Flyology.Buffers.Unique_Buffer;
      Written : out Natural;
      Token   : access Cancellation_Token := null)
   is
      procedure Borrow (Data : Ada.Streams.Stream_Element_Array) is
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Write_At (File, Offset, Data, Last, Token);
         Written :=
           (if Last < Data'First
            then 0
            else Natural (Last - Data'First + 1));
      end Borrow;
   begin
      Written := 0;
      Flyology.Buffers.With_Readable_Data (Item, Borrow'Access);
   end Write_At;

end Flyology.IO.Files;
