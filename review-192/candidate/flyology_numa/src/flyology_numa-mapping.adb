--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Unchecked_Conversion;
with Interfaces.C;

with Flyology_NUMA.Map_Flags;
with Flyology_NUMA.Placement;

package body Flyology_NUMA.Mapping is

   use type Interfaces.C.int;
   use type Interfaces.C.long;
   use type System.Address;

   --  Readable, writable, and private to this process.  Both hosts this
   --  package maps memory on agree on these values.
   Readable : constant Interfaces.C.int := 1;
   Writable : constant Interfaces.C.int := 2;
   Unshared : constant Interfaces.C.int := 2;

   function Map
     (Address : System.Address;
      Length  : Interfaces.C.size_t;
      Reach   : Interfaces.C.int;
      Flags   : Interfaces.C.int;
      File    : Interfaces.C.int;
      Offset  : Interfaces.C.long) return System.Address
   with Import, Convention => C, External_Name => "mmap";

   function Unmap (Address : System.Address; Length : Interfaces.C.size_t) return Interfaces.C.int
   with Import, Convention => C, External_Name => "munmap";

   function To_Address is new Ada.Unchecked_Conversion (Interfaces.C.long, System.Address);

   --  The host reports refusal by returning this rather than by failing.
   Refused : constant System.Address := To_Address (-1);

   -----------------
   -- Whole_Pages --
   -----------------

   function Whole_Pages (Length : Byte_Count) return Byte_Count is
      Page : constant Byte_Count := Placement.Page_Size;
   begin
      if Length = 0 or else Page = 0 then
         return 0;
      end if;

      if Length > Byte_Count'Last - (Page - 1) then
         return 0;
      end if;

      return ((Length + Page - 1) / Page) * Page;
   end Whole_Pages;

   -------------
   -- Reserve --
   -------------

   function Reserve (Length : Byte_Count) return System.Address is
      Rounded : constant Byte_Count := Whole_Pages (Length);
      Result  : System.Address;
   begin
      if Rounded = 0 then
         return System.Null_Address;
      end if;

      Result :=
        Map
          (Address => System.Null_Address,
           Length  => Interfaces.C.size_t (Rounded),
           Reach   => Readable + Writable,
           Flags   => Unshared + Map_Flags.Anonymous,
           File    => -1,
           Offset  => 0);

      if Result = Refused then
         return System.Null_Address;
      end if;

      return Result;
   exception
      when others =>
         return System.Null_Address;
   end Reserve;

   -------------
   -- Release --
   -------------

   procedure Release (Base : System.Address; Length : Byte_Count) is
      Rounded : constant Byte_Count := Whole_Pages (Length);
      Ignored : Interfaces.C.int;
   begin
      if Base = System.Null_Address or else Rounded = 0 then
         return;
      end if;

      Ignored := Unmap (Base, Interfaces.C.size_t (Rounded));
   exception
      when others =>
         null;
   end Release;

end Flyology_NUMA.Mapping;
