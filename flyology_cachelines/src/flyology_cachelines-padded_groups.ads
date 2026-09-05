with Ada.Iterator_Interfaces;
with System;

--  Groups a caller-selected number of same-owner values in one isolated
--  destructive-interference region.
--
--  @formal Element_Type The definite element type to store.
--  @formal Group_Length The number of elements in each physical group.

generic
   type Element_Type is private;
   Group_Length : Positive;
package Flyology_Cachelines.Padded_Groups is

   --  Valid index range within one physical group.
   subtype Index is Positive range 1 .. Group_Length;

   --  Compact payload stored inside a physical group.
   type Element_Array is array (Index) of aliased Element_Type;

   --  Payload size in System.Storage_Unit elements before group alignment.
   Payload_Size_In_Storage_Elements : constant Natural :=
     (Element_Array'Object_Size + System.Storage_Unit - 1) / System.Storage_Unit;

   pragma Warnings (Off, "suspiciously large alignment specified for ""Group""");

   --  One isolated group of same-owner elements.
   --
   --  Elements within a group may share cache lines and therefore must have
   --  compatible ownership. Distinct Group objects occupy distinct
   --  destructive-interference regions.
   type Group is new Element_Array with Alignment => Destructive_Interference_Size;
   pragma Warnings (On, "suspiciously large alignment specified for ""Group""");

   --  Array of physically isolated groups.
   type Group_Array is array (Positive range <>) of aliased Group;

   --  Storage stride of Group in System.Storage_Unit elements.
   Group_Size_In_Storage_Elements : constant Positive := Group_Array'Component_Size / System.Storage_Unit;

   --  Construct a physical group from compact element values.
   --  @param Values Values to place in the group.
   --  @return An isolated group containing Values.
   function Create (Values : Element_Array) return Group
   is (Group (Values));

   --  @exclude Iterator protocol cursor.
   type Cursor is private;
   --  @exclude Iterator protocol sentinel.
   No_Element : constant Cursor;
   --  @exclude Iterator protocol operation.
   --  @param Position Cursor to inspect.
   --  @return True when Position identifies an element.
   function Has_Element (Position : Cursor) return Boolean;

   --  @exclude Iterator protocol instantiation.
   package Iterator_Interfaces is new Ada.Iterator_Interfaces (Cursor, Has_Element);

   --  Grouped_Array is physically an array of isolated groups but presents
   --  one logical, flat sequence for indexing and iteration. A final partial
   --  group remains physically isolated, while its unused tail is skipped.
   --  @field Group_Count Number of allocated physical groups.
   --  @field Last_Group_Length Number of logical values in the final group.
   --  @field Groups Physical group storage.
   type Grouped_Array (Group_Count : Positive) is tagged record
      Last_Group_Length : Index := Index'Last;
      Groups            : Group_Array (1 .. Group_Count);
   end record
   with
     Constant_Indexing => Constant_Reference,
     Variable_Indexing => Reference,
     Default_Iterator  => Iterate,
     Iterator_Element  => Element_Type;

   --  @exclude Standard constant-indexing protocol.
   --  @field Element Referenced constant element.
   type Constant_Reference_Type (Element : not null access constant Element_Type) is limited private
   with Implicit_Dereference => Element;
   --  @exclude Standard variable-indexing protocol.
   --  @field Element Referenced mutable element.
   type Reference_Type (Element : not null access Element_Type) is limited private
   with Implicit_Dereference => Element;

   --  @exclude Standard iterator protocol.
   --  @param Container Container being traversed.
   --  @param Position Iterator cursor.
   --  @return A constant reference to the selected element.
   function Constant_Reference
     (Container : aliased Grouped_Array; Position : Cursor) return Constant_Reference_Type;
   --  @exclude Standard iterator protocol.
   --  @param Container Container being traversed.
   --  @param Position Iterator cursor.
   --  @return A mutable reference to the selected element.
   function Reference (Container : aliased in out Grouped_Array; Position : Cursor) return Reference_Type;

   --  @exclude Standard indexing protocol.
   --  @param Container Container being indexed.
   --  @param Position Flat logical index.
   --  @return A constant reference to the selected element.
   function Constant_Reference
     (Container : aliased Grouped_Array; Position : Positive) return Constant_Reference_Type;
   --  @exclude Standard indexing protocol.
   --  @param Container Container being indexed.
   --  @param Position Flat logical index.
   --  @return A mutable reference to the selected element.
   function Reference (Container : aliased in out Grouped_Array; Position : Positive) return Reference_Type;

   --  Fast_View is a GNAT-specific Iterable view for hot mutable traversals.
   --  Its access discriminant keeps the view scoped to its Grouped_Array.
   type Fast_Cursor is private;
   --  Mutable flat view using GNAT's lightweight Iterable protocol.
   --  @field Container The grouped array traversed by the view.
   type Fast_View (Container : not null access Grouped_Array) is limited private
   with
     Iterable =>
       (First => Fast_First, Next => Fast_Next, Has_Element => Fast_Has_Element, Element => Fast_Reference);

   --  @exclude GNAT Iterable protocol.
   --  @param View View to start traversing.
   --  @return The first cursor.
   function Fast_First (View : Fast_View) return Fast_Cursor;
   --  @exclude GNAT Iterable protocol.
   --  @param View View being traversed.
   --  @param Position Current cursor.
   --  @return The next cursor.
   function Fast_Next (View : Fast_View; Position : Fast_Cursor) return Fast_Cursor;
   --  @exclude GNAT Iterable protocol.
   --  @param View View being traversed.
   --  @param Position Cursor to inspect.
   --  @return True when Position identifies an element.
   function Fast_Has_Element (View : Fast_View; Position : Fast_Cursor) return Boolean;
   --  @exclude GNAT Iterable protocol.
   --  @param View View being traversed.
   --  @param Position Cursor to dereference.
   --  @return A mutable reference to the selected element.
   function Fast_Reference (View : Fast_View; Position : Fast_Cursor) return Reference_Type;

   --  @exclude Standard iterator protocol.
   --  @param Container Container to traverse.
   --  @return A forward iterator over logical elements.
   function Iterate (Container : Grouped_Array) return Iterator_Interfaces.Forward_Iterator'Class;

   --  Return the number of logical elements, excluding unused tail storage.
   --  @param Container The grouped array to inspect.
   --  @return The logical element count.
   function Length (Container : Grouped_Array) return Positive
   is ((Container.Group_Count - 1) * Group_Length + Container.Last_Group_Length);

   --  Create a grouped array filled with one initial value.
   --  @param Element_Count Number of logical elements to allocate.
   --  @param Initial_Value Value assigned to every logical element.
   --  @return A grouped array containing Element_Count logical elements.
   function Create (Element_Count : Positive; Initial_Value : Element_Type) return Grouped_Array;

private
   pragma
     Compile_Time_Error
       (Group_Array'Component_Size > Destructive_Interference_Size * System.Storage_Unit,
        "padded group payload exceeds one destructive-interference region");

   pragma
     Compile_Time_Error
       (Group_Array'Component_Size < Destructive_Interference_Size * System.Storage_Unit,
        "padded group must occupy exactly one interference region");

   type Cursor is new Natural;
   No_Element : constant Cursor := 0;

   type Constant_Reference_Type (Element : not null access constant Element_Type) is limited null record;
   type Reference_Type (Element : not null access Element_Type) is limited null record;

   Element_Stride_In_Storage_Elements : constant Positive :=
     Element_Array'Component_Size / System.Storage_Unit;

   type Fast_Cursor is record
      Element_Address : System.Address := System.Null_Address;
      Remaining       : Natural := 0;
      Slot            : Index := Index'First;
   end record;

   type Fast_View (Container : not null access Grouped_Array) is limited null record;
end Flyology_Cachelines.Padded_Groups;
