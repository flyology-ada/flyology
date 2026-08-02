with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with System;
with System.Storage_Elements;

package body Showcase_Support is

   package Long_Float_IO is new Ada.Text_IO.Float_IO (Long_Float);

   function Current_Thread return System.Address;
   pragma Import (C, Current_Thread, "pthread_self");

   function Thread_Image return String is
     (System.Storage_Elements.Integer_Address'Image
        (System.Storage_Elements.To_Integer (Current_Thread)));

   function Fixed_Image
     (Value    : Long_Float;
      Decimals : Natural := 3) return String
   is
      Buffer : String (1 .. 64);
   begin
      Long_Float_IO.Put
        (To   => Buffer,
         Item => Value,
         Aft  => Decimals,
         Exp  => 0);
      return Ada.Strings.Fixed.Trim (Buffer, Ada.Strings.Both);
   end Fixed_Image;

end Showcase_Support;
