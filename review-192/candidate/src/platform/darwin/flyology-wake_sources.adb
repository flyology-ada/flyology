with GNAT.OS_Lib;
with System;
with System.OS_Constants;

package body Flyology.Wake_Sources is
   package C renames Interfaces.C;
   use type C.int;
   use type C.long;
   use type C.unsigned;

   F_GETFD    : C.int
   with Import, Convention => C, External_Name => "flyology_wake_source_f_getfd";
   F_SETFD    : C.int
   with Import, Convention => C, External_Name => "flyology_wake_source_f_setfd";
   F_GETFL    : C.int
   with Import, Convention => C, External_Name => "flyology_wake_source_f_getfl";
   F_SETFL    : C.int
   with Import, Convention => C, External_Name => "flyology_wake_source_f_setfl";
   FD_CLOEXEC : C.int
   with Import, Convention => C, External_Name => "flyology_wake_source_fd_cloexec";
   O_NONBLOCK : C.int
   with Import, Convention => C, External_Name => "flyology_wake_source_o_nonblock";

   type Descriptor_Pair is array (Natural range 0 .. 1) of aliased C.int with Convention => C;

   function Pipe (Ends : System.Address) return C.int;
   pragma Import (C, Pipe, "pipe");
   function Fcntl_Get (FD : C.int; Command : C.int) return C.int
   with Import, Convention => C_Variadic_2, External_Name => "fcntl";
   function Fcntl_Set (FD : C.int; Command : C.int; Argument : C.int) return C.int
   with Import, Convention => C_Variadic_2, External_Name => "fcntl";
   function Write (FD : C.int; Buffer : System.Address; Length : C.size_t) return C.long;
   pragma Import (C, Write, "write");
   function Read (FD : C.int; Buffer : System.Address; Length : C.size_t) return C.long;
   pragma Import (C, Read, "read");
   function Close (FD : C.int) return C.int;
   pragma Import (C, Close, "close");

   function With_Flag (Flags : C.int; Flag : C.int) return C.int
   is (C.int (C.unsigned (Flags) or C.unsigned (Flag)));

   function Configure (FD : C.int) return C.int is
      Status_Flags     : constant C.int := Fcntl_Get (FD, F_GETFL);
      Descriptor_Flags : C.int;
   begin
      if Status_Flags < 0 or else Fcntl_Set (FD, F_SETFL, With_Flag (Status_Flags, O_NONBLOCK)) < 0 then
         return -1;
      end if;

      Descriptor_Flags := Fcntl_Get (FD, F_GETFD);
      if Descriptor_Flags < 0 or else Fcntl_Set (FD, F_SETFD, With_Flag (Descriptor_Flags, FD_CLOEXEC)) < 0
      then
         return -1;
      end if;

      return 0;
   end Configure;

   procedure Ensure (Item : in out Source) is
      Ends    : aliased Descriptor_Pair := (others => -1);
      Ignored : C.int;
   begin
      if Item.Read_End >= 0 then
         return;
      elsif Pipe (Ends'Address) /= 0 then
         raise Program_Error with "cannot create cancellation wake source, errno=" & GNAT.OS_Lib.Errno'Image;
      end if;

      if Configure (Ends (0)) < 0 or else Configure (Ends (1)) < 0 then
         Ignored := Close (Ends (0));
         Ignored := Close (Ends (1));
         raise Program_Error with "cannot configure cancellation wake source";
      end if;
      Item.Read_End := Ends (0);
      Item.Write_End := Ends (1);
   end Ensure;

   procedure Signal (Item : in out Source) is
   begin
      Ensure (Item);
      Signal_Borrowed (Item.Write_End);
   end Signal;

   procedure Signal_Borrowed (Descriptor : C.int) is
      Result : Signal_Attempt_Result;
   begin
      loop
         Result := Try_Signal_Borrowed (Descriptor);
         exit when Result = Signal_Delivered;
         if Result = Signal_Failed then
            raise Program_Error with "cannot signal borrowed wake source";
         end if;
      end loop;
   end Signal_Borrowed;

   function Try_Signal_Borrowed (Descriptor : C.int) return Signal_Attempt_Result is
      Byte   : aliased C.unsigned_char := 1;
      Result : C.long;
   begin
      if Descriptor < 0 then
         return Signal_Failed;
      end if;
      Result := Write (Descriptor, Byte'Address, 1);
      if Result = 1 then
         return Signal_Delivered;
      elsif Result < 0 and then GNAT.OS_Lib.Errno = System.OS_Constants.EAGAIN then
         return Signal_Delivered;
      elsif Result < 0 and then C.int (GNAT.OS_Lib.Errno) = C.int (System.OS_Constants.EINTR) then
         return Signal_Interrupted;
      else
         return Signal_Failed;
      end if;
   end Try_Signal_Borrowed;

   procedure Consume (Item : in out Source) is
      Byte   : aliased C.unsigned_char;
      Result : C.long;
   begin
      if Item.Read_End < 0 then
         raise Program_Error with "cannot consume absent wake source";
      end if;
      loop
         Result := Read (Item.Read_End, Byte'Address, 1);
         exit when Result = 1;
         if Result >= 0 or else GNAT.OS_Lib.Errno /= 4 then
            raise Program_Error with "cannot consume wake source";
         end if;
      end loop;
   end Consume;

   procedure Consume_All (Item : in out Source) is
      type Byte_Array is array (Positive range <>) of C.unsigned_char;
      Buffer   : aliased Byte_Array (1 .. 256);
      Result   : C.long;
      Consumed : Boolean := False;
   begin
      if Item.Read_End < 0 then
         raise Program_Error with "cannot consume absent wake source";
      end if;
      loop
         Result := Read (Item.Read_End, Buffer'Address, C.size_t (Buffer'Length));
         if Result > 0 then
            Consumed := True;
         elsif Result = 0 then
            raise Program_Error with "cannot consume wake source";
         elsif GNAT.OS_Lib.Errno = 4 then
            null;
         elsif GNAT.OS_Lib.Errno = System.OS_Constants.EAGAIN then
            exit;
         else
            raise Program_Error with "cannot consume wake source";
         end if;
      end loop;
      if not Consumed then
         raise Program_Error with "cannot consume empty wake source";
      end if;
   end Consume_All;

   function Descriptor (Item : Source) return C.int
   is (Item.Read_End);

   function Signal_Descriptor (Item : Source) return C.int
   is (Item.Write_End);

   procedure Release (Item : in out Source) is
      Ignored : C.int;
   begin
      if Item.Read_End >= 0 then
         Ignored := Close (Item.Read_End);
         Item.Read_End := -1;
      end if;
      if Item.Write_End >= 0 then
         Ignored := Close (Item.Write_End);
         Item.Write_End := -1;
      end if;
   end Release;

   overriding
   procedure Finalize (Item : in out Source) is
   begin
      Release (Item);
   end Finalize;
end Flyology.Wake_Sources;
