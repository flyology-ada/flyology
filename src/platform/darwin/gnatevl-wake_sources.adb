with GNAT.OS_Lib;
with System;

package body Gnatevl.Wake_Sources is
   package C renames Interfaces.C;
   use type C.int;
   use type C.long;

   F_SETFD     : constant C.int := 2;
   F_SETFL     : constant C.int := 4;
   FD_CLOEXEC  : constant C.int := 1;
   O_NONBLOCK  : constant C.int := 4;

   type Descriptor_Pair is array (Natural range 0 .. 1) of aliased C.int
     with Convention => C;

   function Pipe (Ends : System.Address) return C.int;
   pragma Import (C, Pipe, "pipe");
   function Fcntl (FD : C.int; Command : C.int; Value : C.int) return C.int;
   pragma Import (C, Fcntl, "fcntl");
   function Write
     (FD : C.int; Buffer : System.Address; Length : C.size_t) return C.long;
   pragma Import (C, Write, "write");
   function Close (FD : C.int) return C.int;
   pragma Import (C, Close, "close");

   procedure Ensure (Item : in out Source) is
      Ends    : aliased Descriptor_Pair := (others => -1);
      Ignored : C.int;
   begin
      if Item.Read_End >= 0 then
         return;
      elsif Pipe (Ends'Address) /= 0 then
         raise Program_Error with
           "cannot create cancellation wake source, errno="
           & GNAT.OS_Lib.Errno'Image;
      end if;

      if Fcntl (Ends (0), F_SETFL, O_NONBLOCK) < 0
        or else Fcntl (Ends (1), F_SETFL, O_NONBLOCK) < 0
        or else Fcntl (Ends (0), F_SETFD, FD_CLOEXEC) < 0
        or else Fcntl (Ends (1), F_SETFD, FD_CLOEXEC) < 0
      then
         Ignored := Close (Ends (0));
         Ignored := Close (Ends (1));
         raise Program_Error with "cannot configure cancellation wake source";
      end if;
      Item.Read_End := Ends (0);
      Item.Write_End := Ends (1);
   end Ensure;

   procedure Signal (Item : in out Source) is
      Byte   : aliased C.unsigned_char := 1;
      Result : C.long;
   begin
      Ensure (Item);
      loop
         Result := Write (Item.Write_End, Byte'Address, 1);
         exit when Result >= 0;
         if GNAT.OS_Lib.Errno /= 4 then
            raise Program_Error with "cannot signal cancellation wake source";
         end if;
      end loop;
   end Signal;

   function Descriptor (Item : Source) return C.int is (Item.Read_End);

   overriding procedure Finalize (Item : in out Source) is
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
   end Finalize;
end Gnatevl.Wake_Sources;
