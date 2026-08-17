with Ada.Text_IO;
with Flyology_Cachelines;
with Flyology_Cachelines.Fitted_Groups;
with Flyology_Cachelines.Padded;
with Flyology_Cachelines.Padded_Groups;
with Interfaces;
with System.Storage_Elements;
with Tests_Config;

procedure Tests is
   package Padded_Integers is new Flyology_Cachelines.Padded (Integer);

   package Four_Integer_Groups is new Flyology_Cachelines.Padded_Groups
     (Element_Type => Integer,
      Group_Length => 4);
   package Fitted_Bytes is new Flyology_Cachelines.Fitted_Groups
     (Interfaces.Unsigned_8);
   package Fitted_Integers is new Flyology_Cachelines.Fitted_Groups (Integer);

   type Byte_Array is array (1 .. 200) of Interfaces.Unsigned_8;
   package Padded_Byte_Arrays is new Flyology_Cachelines.Padded (Byte_Array);

   use type System.Storage_Elements.Integer_Address;
   use type Interfaces.Unsigned_8;
   use type Flyology_Cachelines.Cache_Query_Result;
   use type Flyology_Cachelines.Class_Ordering;

   type Padded_Array is
     array (Positive range <>) of aliased Padded_Integers.Padded;

   Items : Padded_Array (1 .. 3) :=
     (Padded_Integers.Create (11),
      Padded_Integers.Create (22),
      Padded_Integers.Create (33));

   type Big_Padded_Array is
     array (Positive range <>) of aliased Padded_Byte_Arrays.Padded;

   Big_Items : Big_Padded_Array (1 .. 2) :=
     (others => Padded_Byte_Arrays.Create ((others => 0)));

   type Integer_Group_Array is
     array (Positive range <>) of aliased Four_Integer_Groups.Group;
   Integer_Groups : Integer_Group_Array (1 .. 2) :=
     (others => Four_Integer_Groups.Create ((others => 0)));

   type Fitted_Byte_Group_Array is
     array (Positive range <>) of aliased Fitted_Bytes.Group;
   Fitted_Byte_Groups : Fitted_Byte_Group_Array (1 .. 2) :=
     (others => Fitted_Bytes.Create ((others => 0)));

   Integer_Sequence : Four_Integer_Groups.Grouped_Array (2) :=
     Four_Integer_Groups.Create
       (Element_Count => 8,
        Initial_Value => 0);
   Partial_Integer_Sequence : aliased Four_Integer_Groups.Grouped_Array :=
     Four_Integer_Groups.Create
       (Element_Count => 6,
        Initial_Value => 0);
   Constant_Integer_Sequence : constant Four_Integer_Groups.Grouped_Array :=
     Four_Integer_Groups.Create
       (Element_Count => 5,
        Initial_Value => 7);
   Fitted_Byte_Sequence : aliased Fitted_Bytes.Grouped_Array (2) :=
     Fitted_Bytes.Create
       (Element_Count => 2 * Fitted_Bytes.Elements_Per_Group,
        Initial_Value => 0);

   function Address_Of
     (Item : aliased Padded_Integers.Padded)
      return System.Storage_Elements.Integer_Address is
     (System.Storage_Elements.To_Integer (Item'Address));

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   function Equal (Left, Right : Natural) return Boolean is
     (Left = Right);
   pragma No_Inline (Equal);

   function Less_Or_Equal (Left, Right : Natural) return Boolean is
     (Left <= Right);
   pragma No_Inline (Less_Or_Equal);

   function Greater_Than (Left, Right : Natural) return Boolean is
     (Left > Right);
   pragma No_Inline (Greater_Than);

   function Is_Power_Of_Two (Value : Positive) return Boolean is
      Reduced : Positive := Value;
   begin
      while Reduced mod 2 = 0 loop
         Reduced := Reduced / 2;
      end loop;
      return Reduced = 1;
   end Is_Power_Of_Two;

   function Expected_Interference_Size (Arch : String) return Positive is
   begin
      if Arch = "x86_64"
        or else Arch = "aarch64"
        or else Arch = "arm64ec"
        or else Arch = "powerpc64"
      then
         return 128;
      elsif Arch = "arm"
        or else Arch = "mips"
        or else Arch = "mips32r6"
        or else Arch = "mips64"
        or else Arch = "mips64r6"
        or else Arch = "sparc"
        or else Arch = "hexagon"
      then
         return 32;
      elsif Arch = "m68k" then
         return 16;
      elsif Arch = "s390x" then
         return 256;
      else
         return 64;
      end if;
   end Expected_Interference_Size;

   function Is_Supported_OS (OS : String) return Boolean is
     (OS = "macos" or else OS = "linux");

   function Image_Or_Unavailable
     (Result : Flyology_Cachelines.Cache_Query_Result) return String is
     (if Result.Available
      then Natural'Image (Result.Value)
      else " unavailable");

   Alignment : constant System.Storage_Elements.Integer_Address :=
     System.Storage_Elements.Integer_Address
       (Flyology_Cachelines.Destructive_Interference_Size);

   Hardware_Query : constant Flyology_Cachelines.Cache_Query_Result :=
     Flyology_Cachelines.Hardware_Cache_Line_Size;
   L1_Query       : constant Flyology_Cachelines.Cache_Query_Result :=
     Flyology_Cachelines.L1_Data_Cache_Size;
   Slots_Query    : constant Flyology_Cachelines.Cache_Query_Result :=
     Flyology_Cachelines.L1_Data_Cache_Slots;
   Class_Count    : constant Flyology_Cachelines.Cache_Query_Result :=
     Flyology_Cachelines.Core_Class_Count;
begin
   Check
     (Padded_Integers.Padded'Alignment =
        Flyology_Cachelines.Destructive_Interference_Size,
      "Padded alignment does not match the compiled interference size");
   Check
     (Padded_Integers.Padded_Size_In_Storage_Elements mod
        Flyology_Cachelines.Destructive_Interference_Size = 0,
      "Padded object size is not a whole interference boundary");

   Check
     (Address_Of (Items (1)) mod Alignment = 0,
      "first padded object is misaligned");
   Check
     (Address_Of (Items (2)) mod Alignment = 0,
      "second padded object is misaligned");
   Check
     (Address_Of (Items (3)) mod Alignment = 0,
      "third padded object is misaligned");

   Check
     (Address_Of (Items (2)) - Address_Of (Items (1)) = Alignment,
      "first padded-array stride does not equal its alignment");
   Check
     (Address_Of (Items (3)) - Address_Of (Items (2)) = Alignment,
      "second padded-array stride does not equal its alignment");

   Check
     (Padded_Byte_Arrays.Padded_Size_In_Storage_Elements >= 200,
      "large padded object is smaller than its wrapped value");
   Check
     (Padded_Byte_Arrays.Padded_Size_In_Storage_Elements mod
        Flyology_Cachelines.Destructive_Interference_Size = 0,
      "large padded object was not rounded to an interference boundary");
   Check
     (System.Storage_Elements.To_Integer (Big_Items (2)'Address)
      - System.Storage_Elements.To_Integer (Big_Items (1)'Address)
      = System.Storage_Elements.Integer_Address
          (Padded_Byte_Arrays.Padded_Size_In_Storage_Elements),
      "large padded-array stride does not match its object size");

   Items (1).Value := 42;
   Check
     (Padded_Integers.Unwrap (Items (1)) = 42,
      "wrapped value did not round-trip");

   Check
     (Four_Integer_Groups.Payload_Size_In_Storage_Elements
        <= Flyology_Cachelines.Destructive_Interference_Size,
      "explicit group payload exceeds one interference region");
   Check
     (Four_Integer_Groups.Group_Size_In_Storage_Elements =
        Flyology_Cachelines.Destructive_Interference_Size,
      "explicit group does not occupy exactly one interference region");
   Check
     (System.Storage_Elements.To_Integer (Integer_Groups (2)'Address)
      - System.Storage_Elements.To_Integer (Integer_Groups (1)'Address)
      = Alignment,
      "explicit groups do not occupy distinct interference regions");

   for Item of Integer_Groups (1) loop
      Item := 3;
   end loop;
   declare
      Sum : Integer := 0;
   begin
      for Item of Integer_Groups (1) loop
         Sum := Sum + Item;
      end loop;
      Check (Sum = 12, "Group is not directly iterable as an array");
   end;

   for Position in 1 .. Four_Integer_Groups.Length (Integer_Sequence) loop
      Integer_Sequence (Position) := Position;
   end loop;
   declare
      Sum : Integer := 0;
   begin
      for Item of Integer_Sequence loop
         Sum := Sum + Item;
         Item := Item + 10;
      end loop;
      Check (Sum = 36, "flat explicit-group iteration skipped an element");
   end;
   Check
     (Integer_Sequence (5) = 15,
      "flat explicit-group indexing did not cross a group boundary");
   Check
     (Integer_Sequence.Groups (2) (1) = 15,
      "flat indexing does not map to the underlying physical group");
   Check
     (Four_Integer_Groups.Length (Partial_Integer_Sequence) = 6,
      "partial final group reports the wrong logical length");
   declare
      Count : Natural := 0;
   begin
      for Item of Partial_Integer_Sequence loop
         Item := Item + 1;
         Count := Count + 1;
      end loop;
      Check
        (Count = 6,
         "flat iteration exposed the unused tail of a partial final group");
   end;
   declare
      View : Four_Integer_Groups.Fast_View
        (Partial_Integer_Sequence'Access);
      Count : Natural := 0;
   begin
      for Item of View loop
         Item := Item + 1;
         Count := Count + 1;
      end loop;
      Check
        (Count = 6,
         "Fast_View exposed the unused tail of a partial final group");
      Check
        (Partial_Integer_Sequence.Groups (1) (4) = 2
           and then Partial_Integer_Sequence.Groups (2) (1) = 2,
         "Fast_View did not cross padded group storage correctly");
      Check
        (Partial_Integer_Sequence.Groups (2) (3) = 0,
         "Fast_View modified an unused final-group element");
   end;
   declare
      Sum : Integer := 0;
   begin
      for Item of Constant_Integer_Sequence loop
         Sum := Sum + Item;
      end loop;
      Check
        (Sum = 35 and then Constant_Integer_Sequence (5) = 7,
         "constant flat indexing or iteration returned the wrong elements");
   end;
   Check
     (System.Storage_Elements.To_Integer
        (Integer_Sequence.Groups (1)'Address) mod Alignment = 0,
      "first group in a flat explicit sequence is misaligned");
   Check
     (System.Storage_Elements.To_Integer
        (Integer_Sequence.Groups (2)'Address)
      - System.Storage_Elements.To_Integer
          (Integer_Sequence.Groups (1)'Address) = Alignment,
      "flat explicit sequence does not preserve physical group spacing");

   begin
      Integer_Sequence
        (Four_Integer_Groups.Length (Integer_Sequence) + 1) := 0;
      Check (False, "flat indexing accepted an out-of-bounds position");
   exception
      when Constraint_Error =>
         null;
   end;

   Check
     (Equal
        (Fitted_Bytes.Elements_Per_Group,
         Flyology_Cachelines.Destructive_Interference_Size),
      "automatic byte group did not fill its interference region");
   Check
     (Fitted_Bytes.Payload_Size_In_Storage_Elements =
        Flyology_Cachelines.Destructive_Interference_Size,
      "automatic group payload does not exactly fill its region");
   Check
     (Fitted_Bytes.Group_Size_In_Storage_Elements =
        Flyology_Cachelines.Destructive_Interference_Size,
      "automatic group spills beyond its interference region");
   Check
     (System.Storage_Elements.To_Integer (Fitted_Byte_Groups (2)'Address)
      - System.Storage_Elements.To_Integer (Fitted_Byte_Groups (1)'Address)
      = Alignment,
      "automatic groups do not occupy distinct interference regions");

   for Position in 1 .. Fitted_Bytes.Length (Fitted_Byte_Sequence) loop
      Fitted_Byte_Sequence (Position) :=
        Interfaces.Unsigned_8 (Position mod 251);
   end loop;
   declare
      Count : Natural := 0;
   begin
      for Item of Fitted_Byte_Sequence loop
         Count := Count + 1;
         Item := Item + 1;
      end loop;
      Check
        (Count = Fitted_Bytes.Length (Fitted_Byte_Sequence),
         "flat fitted-group iteration used the wrong logical length");
   end;
   Check
     (Fitted_Byte_Sequence
        (Fitted_Bytes.Elements_Per_Group + 1) =
          Interfaces.Unsigned_8
            ((Fitted_Bytes.Elements_Per_Group + 1) mod 251) + 1,
      "flat fitted-group indexing did not cross a group boundary");
   declare
      View : Fitted_Bytes.Fast_View (Fitted_Byte_Sequence'Access);
      Count : Natural := 0;
   begin
      for Item of View loop
         Item := Item + 1;
         Count := Count + 1;
      end loop;
      Check
        (Count = Fitted_Bytes.Length (Fitted_Byte_Sequence),
         "fitted Fast_View used the wrong logical length");
   end;
   Check
     (Fitted_Byte_Sequence
        (Fitted_Bytes.Elements_Per_Group + 1) =
          Interfaces.Unsigned_8
            ((Fitted_Bytes.Elements_Per_Group + 1) mod 251) + 2,
      "fitted Fast_View did not cross a group boundary");
   Check
     (Less_Or_Equal
        (Fitted_Integers.Elements_Per_Group
           * Fitted_Integers.Element_Size_In_Storage_Elements,
         Flyology_Cachelines.Destructive_Interference_Size),
      "automatic integer group exceeds its interference region");
   Check
     (Greater_Than
        ((Fitted_Integers.Elements_Per_Group + 1)
           * Fitted_Integers.Element_Size_In_Storage_Elements,
         Flyology_Cachelines.Destructive_Interference_Size),
      "automatic integer group did not choose the maximum capacity");

   --  Validate the build-time GPR selection independently from the GPR case
   --  statement, using the native architecture reported by Alire.
   Check
     (Flyology_Cachelines.Destructive_Interference_Size =
        Expected_Interference_Size (Tests_Config.Alire_Host_Arch),
      "compiled interference size does not match the host architecture");

   Check
     (Flyology_Cachelines.Value_Or (Flyology_Cachelines.Unavailable, 64) = 64,
      "explicit fallback was not used for an unavailable query");
   Check
     (Flyology_Cachelines.Value_Or ((Available => True, Value => 64), 128) = 64,
      "a detected 64-byte value was confused with its fallback");

   if Is_Supported_OS (Tests_Config.Alire_Host_OS) then
      Check
        (Hardware_Query.Available,
         Tests_Config.Alire_Host_OS & " cache-line query failed");
      Check
        (L1_Query.Available,
         Tests_Config.Alire_Host_OS & " L1 data-cache query failed");
   end if;

   --  The interference spacing may exceed the physical cache-line size (most
   --  notably 128 versus 64 bytes on x86-64), but it must contain a whole
   --  number of physical lines when detection succeeds.
   if Hardware_Query.Available then
      Check
        (Hardware_Query.Value > 0,
         "available hardware cache-line query returned zero");
      Check
        (Is_Power_Of_Two (Positive (Hardware_Query.Value)),
         "queried hardware cache-line size is not a power of two");
      Check
        (Flyology_Cachelines.Destructive_Interference_Size mod Hardware_Query.Value = 0,
         "compiled interference size is incompatible with the hardware line");
   end if;

   Check
     (Slots_Query.Available = L1_Query.Available,
      "L1 slot-count availability does not match L1 size availability");

   --  The unqualified queries must describe the highest-ranked class, so
   --  they must agree with the same queries named explicitly.
   Check
     (Flyology_Cachelines.L1_Data_Cache_Size
        (Flyology_Cachelines.Fastest_Core_Class) = L1_Query,
      "the default L1 query does not describe the fastest core class");
   Check
     (Class_Count.Available = L1_Query.Available,
      "core-class availability does not match L1 size availability");

   if Class_Count.Available then
      Check
        (Class_Count.Value >= 1
           and then Class_Count.Value <= Flyology_Cachelines.Max_Core_Classes,
         "reported core-class count is outside the representable range");

      --  A single class cannot be ordered, and a host that ranks its classes
      --  must report more than one of them.
      Check
        ((Class_Count.Value = 1) =
           (Flyology_Cachelines.Core_Class_Ordering =
              Flyology_Cachelines.Unordered),
         "core-class ordering does not agree with the class count");

      for Position in 1 .. Class_Count.Value loop
         declare
            Class : constant Flyology_Cachelines.Core_Class :=
              Flyology_Cachelines.Core_Class (Position);
            Size  : constant Flyology_Cachelines.Cache_Query_Result :=
              Flyology_Cachelines.L1_Data_Cache_Size (Class);
            Cores : constant Flyology_Cachelines.Cache_Query_Result :=
              Flyology_Cachelines.Core_Class_Cores (Class);
            CPUs  : constant Flyology_Cachelines.Cache_Query_Result :=
              Flyology_Cachelines.Core_Class_CPUs (Class);
         begin
            Check
              (Size.Available,
               "a counted core class reports no L1 data-cache size");
            Check
              (Size.Value >= 8 * 1_024 and then Size.Value <= 512 * 1_024,
               "a core class L1 capacity is outside the expected range");
            Check
              (not Cores.Available
                 or else not CPUs.Available
                 or else Cores.Value <= CPUs.Value,
               "a core class reports more cores than CPUs");

            --  L2 holds whole lines, is at least as large as L1, and is
            --  shared by no more cores than the class contains.
            declare
               L2      : constant Flyology_Cachelines.Cache_Query_Result :=
                 Flyology_Cachelines.L2_Cache_Size (Class);
               Sharing : constant Flyology_Cachelines.Cache_Query_Result :=
                 Flyology_Cachelines.L2_Sharing_Cores (Class);
            begin
               if L2.Available then
                  Check
                    (L2.Value >= Size.Value,
                     "a core class L2 is smaller than its L1 data cache");
                  Check
                    (not Hardware_Query.Available
                       or else L2.Value mod Hardware_Query.Value = 0,
                     "a core class L2 is not a whole number of lines");
               end if;

               if Sharing.Available then
                  Check
                    (L2.Available,
                     "L2 sharing was reported without an L2 capacity");
                  Check
                    (Sharing.Value >= 1
                       and then
                         (not Cores.Available
                            or else Sharing.Value <= Cores.Value),
                     "more cores share an L2 than the class contains");
               end if;
            end;

            --  Whichever key ordered the classes, a later class may not
            --  report a larger L1 data cache when the order was inferred.
            if Position > 1
              and then Flyology_Cachelines.Core_Class_Ordering =
                         Flyology_Cachelines.Inferred
            then
               Check
                 (Size.Value <=
                    Flyology_Cachelines.L1_Data_Cache_Size
                      (Flyology_Cachelines.Core_Class (Position - 1)).Value,
                  "an inferred class order is not descending by L1 size");
            end if;
         end;
      end loop;

      --  A class the host did not describe is an unanswered question.
      if Class_Count.Value < Flyology_Cachelines.Max_Core_Classes then
         Check
           (not Flyology_Cachelines.L1_Data_Cache_Size
              (Flyology_Cachelines.Core_Class
                 (Class_Count.Value + 1)).Available,
            "a class beyond the reported count returned a value");
      end if;
   end if;

   if L1_Query.Available then
      Check
        (L1_Query.Value > 0,
         "available L1 data-cache query returned zero");
      Check
        (L1_Query.Value >= 8 * 1_024
           and then L1_Query.Value <= 512 * 1_024,
         "queried L1 data-cache capacity is outside the expected range");
      Check
        (Slots_Query.Value =
           L1_Query.Value / Flyology_Cachelines.Destructive_Interference_Size,
         "derived L1 interference-slot count does not match queried capacity");

      if Hardware_Query.Available then
         Check
           (L1_Query.Value mod Hardware_Query.Value = 0,
            "queried L1 capacity is not a whole number of hardware lines");
      end if;
   end if;

   Ada.Text_IO.Put_Line
     ("hardware cache line:" &
      Image_Or_Unavailable (Hardware_Query) &
      (if Hardware_Query.Available then " bytes" else ""));
   Ada.Text_IO.Put_Line
     ("destructive interference:" &
      Flyology_Cachelines.Destructive_Interference_Size'Image & " bytes");
   Ada.Text_IO.Put_Line
     ("L1 data cache:" & Image_Or_Unavailable (L1_Query) &
      (if L1_Query.Available then " bytes" else ""));
   Ada.Text_IO.Put_Line
     ("core classes:" & Image_Or_Unavailable (Class_Count) & " (" &
      Flyology_Cachelines.Core_Class_Ordering'Image & ")");
   if Class_Count.Available then
      for Position in 1 .. Class_Count.Value loop
         declare
            Class : constant Flyology_Cachelines.Core_Class :=
              Flyology_Cachelines.Core_Class (Position);
         begin
            Ada.Text_IO.Put_Line
              ("  class" & Position'Image &
               ": l1d" &
               Image_Or_Unavailable
                 (Flyology_Cachelines.L1_Data_Cache_Size (Class)) &
               " bytes, cores" &
               Image_Or_Unavailable
                 (Flyology_Cachelines.Core_Class_Cores (Class)) &
               ", cpus" &
               Image_Or_Unavailable
                 (Flyology_Cachelines.Core_Class_CPUs (Class)) &
               ", l2" &
               Image_Or_Unavailable
                 (Flyology_Cachelines.L2_Cache_Size (Class)) &
               " bytes across" &
               Image_Or_Unavailable
                 (Flyology_Cachelines.L2_Sharing_Cores (Class)) &
               " cores");
         end;
      end loop;
   end if;
   Ada.Text_IO.Put_Line ("all flyology_cachelines tests passed");
end Tests;
