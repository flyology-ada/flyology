with GNAT.OS_Lib;
with System;

package body Flyology.Wake_Sources is
   package C renames Interfaces.C;
   use type C.int;
   use type C.long;

   O_CLOEXEC  : constant C.int := 16#8_0000#;
   O_NONBLOCK : constant C.int := 16#800#;

   type Descriptor_Pair is array (Natural range 0 .. 1) of aliased C.int
     with Convention => C;

   function Pipe_2 (Ends : System.Address; Flags : C.int) return C.int;
   pragma Import (C, Pipe_2, "pipe2");
   function Write
     (FD : C.int; Buffer : System.Address; Length : C.size_t) return C.long;
   pragma Import (C, Write, "write");
   function Close (FD : C.int) return C.int;
   pragma Import (C, Close, "close");

   procedure Ensure (Item : in out Source) is
      Ends : aliased Descriptor_Pair := (others => -1);
   begin
      if Item.Read_End >= 0 then
         return;
      elsif Pipe_2 (Ends'Address, O_CLOEXEC + O_NONBLOCK) /= 0 then
         raise Program_Error with
           "cannot create cancellation wake source, errno="
           & GNAT.OS_Lib.Errno'Image;
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

   overriding procedure Finalize (Item : in out Source) is
   begin
      Release (Item);
   end Finalize;
end Flyology.Wake_Sources;
