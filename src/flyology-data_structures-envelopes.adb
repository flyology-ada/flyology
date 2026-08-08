with Flyology.Data_Structures.Storage;

package body Flyology.Data_Structures.Envelopes is
   package Bytes renames Flyology.Data_Structures.Storage;

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   Nested_Magic_Offset   : constant Byte_Count := Layouts.Header_Size;
   Nested_Version_Offset : constant Byte_Count := Nested_Magic_Offset + 8;
   Nested_Reserved_Offset : constant Byte_Count := Nested_Version_Offset + 4;
   Nested_Schema_Offset  : constant Byte_Count := Nested_Reserved_Offset + 4;
   Content_Prefix        : constant Byte_Count := Nested_Schema_Offset + 8;

   procedure Geometry
     (Content_Extent    : Byte_Count;
      Content_Alignment : Byte_Count;
      Content_Offset    : out Byte_Count;
      Total_Extent      : out Byte_Count) is
   begin
      if Contract_Signature = 0 or else Contract_Version = 0 then
         raise Constraint_Error with
           "envelope signature and version must be nonzero";
      elsif Nested_Identity.Magic = 0
        or else Nested_Identity.Version = 0
        or else Nested_Identity.Schema = 0
      then
         raise Constraint_Error with
           "nested layout identity fields must be nonzero";
      elsif Content_Extent < Layouts.Header_Size then
         raise Constraint_Error with
           "envelope content is smaller than a nested structure header";
      elsif Content_Alignment >
        Byte_Count (Interfaces.Unsigned_32'Last)
      then
         raise Constraint_Error with "envelope alignment exceeds 32 bits";
      end if;
      Content_Offset :=
        Layouts.Align_Up (Content_Prefix, Content_Alignment);
      Total_Extent := Layouts.Checked_Add (Content_Offset, Content_Extent);
   end Geometry;

   function Required_Storage
     (Content_Extent    : Byte_Count;
      Content_Alignment : Byte_Count := 8) return Byte_Count
   is
      Content_Offset, Total_Extent : Byte_Count;
   begin
      Geometry
        (Content_Extent, Content_Alignment, Content_Offset, Total_Extent);
      return Total_Extent;
   end Required_Storage;

   procedure Set_View
     (Item : out View; Core : Layouts.Local_View;
      Content_Offset, Content_Size, Alignment : Byte_Count) is
   begin
      Item.Core := Core;
      Item.Content_Offset := Content_Offset;
      Item.Content_Size := Content_Size;
      Item.Content_Alignment := Alignment;
   end Set_View;

   procedure Finish_Initialize
     (Item              : out View;
      Core              : Layouts.Local_View;
      Content_Offset    : Byte_Count;
      Content_Extent    : Byte_Count;
      Content_Alignment : Byte_Count) is
   begin
      Set_View
        (Item, Core, Content_Offset, Content_Extent, Content_Alignment);
      Layouts.Invalidate_Nested (Item.Core, Item.Content_Offset);
      Bytes.Write_U64
        (Layouts.Address_At (Item.Core, Nested_Magic_Offset, 8, 8),
         Nested_Identity.Magic);
      Bytes.Write_U32
        (Layouts.Address_At (Item.Core, Nested_Version_Offset, 4, 4),
         Nested_Identity.Version);
      Bytes.Write_U32
        (Layouts.Address_At (Item.Core, Nested_Reserved_Offset, 4, 4), 0);
      Bytes.Write_U64
        (Layouts.Address_At (Item.Core, Nested_Schema_Offset, 8, 8),
         Nested_Identity.Schema);
      Layouts.Publish (Item.Core);
   end Finish_Initialize;

   procedure Initialize
     (Item              : out View;
      Region            : Region_View;
      Location          : Region_Offset;
      Content_Extent    : Byte_Count;
      Content_Alignment : Byte_Count := 8)
   is
      Core : Layouts.Local_View;
      Content_Offset, Total_Extent : Byte_Count;
   begin
      Detach (Item);
      Geometry
        (Content_Extent, Content_Alignment, Content_Offset, Total_Extent);
      Layouts.Begin_Initialize
        (Core, Region, Location, Identity, Total_Extent,
         (Capacity     => 0,
          Element_Size => 0,
          Alignment    => Interfaces.Unsigned_32 (Content_Alignment),
          Auxiliary    => Interfaces.Unsigned_32 (Content_Offset),
          Word_1       => Contract_Signature,
          Word_2       => Contract_Version),
         Byte_Count'Max (8, Content_Alignment));
      Finish_Initialize
        (Item, Core, Content_Offset, Content_Extent, Content_Alignment);
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Initialize;

   procedure Create_Or_Attach
     (Item              : out View;
      Region            : Region_View;
      Location          : Region_Offset;
      Content_Extent    : Byte_Count;
      Content_Alignment : Byte_Count;
      Result            : out Open_Result)
   is
      Core : Layouts.Local_View;
      Claim : Layouts.Initialization_Claim;
      Content_Offset, Total_Extent : Byte_Count;
   begin
      Detach (Item);
      Geometry
        (Content_Extent, Content_Alignment, Content_Offset, Total_Extent);
      Layouts.Try_Begin_Initialize
        (Core, Claim, Region, Location, Identity, Total_Extent,
         (Capacity     => 0,
          Element_Size => 0,
          Alignment    => Interfaces.Unsigned_32 (Content_Alignment),
          Auxiliary    => Interfaces.Unsigned_32 (Content_Offset),
          Word_1       => Contract_Signature,
          Word_2       => Contract_Version),
         Byte_Count'Max (8, Content_Alignment));
      case Claim is
         when Layouts.Claimed_Virgin =>
            Finish_Initialize
              (Item, Core, Content_Offset, Content_Extent,
               Content_Alignment);
            Result := Initialized_New;
         when Layouts.Existing_Ready =>
            Attach
              (Item, Region, Location, Content_Extent, Content_Alignment);
            Result := Attached_Existing;
         when Layouts.Claim_In_Progress =>
            Result := Initialization_In_Progress;
      end case;
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Create_Or_Attach;

   procedure Attach
     (Item              : out View;
      Region            : Region_View;
      Location          : Region_Offset;
      Content_Extent    : Byte_Count;
      Content_Alignment : Byte_Count := 8)
   is
      Core : Layouts.Local_View;
      Header : Layouts.Header_Values;
      Content_Offset, Total_Extent : Byte_Count;
   begin
      Detach (Item);
      Geometry
        (Content_Extent, Content_Alignment, Content_Offset, Total_Extent);
      Layouts.Attach
        (Core, Header, Region, Location, Identity,
         Byte_Count'Max (8, Content_Alignment));
      if Core.Extent /= Total_Extent then
         raise Layout_Error with "envelope extent does not match";
      elsif Header.Capacity /= 0
        or else Header.Element_Size /= 0
        or else Header.Alignment /=
          Interfaces.Unsigned_32 (Content_Alignment)
        or else Header.Auxiliary /= Interfaces.Unsigned_32 (Content_Offset)
        or else Header.Word_1 /= Contract_Signature
        or else Header.Word_2 /= Contract_Version
      then
         raise Layout_Error with
           "envelope contract or geometry does not match";
      elsif Bytes.Read_U64
        (Layouts.Address_At (Core, Nested_Magic_Offset, 8, 8)) /=
          Nested_Identity.Magic
        or else Bytes.Read_U32
          (Layouts.Address_At (Core, Nested_Version_Offset, 4, 4)) /=
            Nested_Identity.Version
        or else Bytes.Read_U32
          (Layouts.Address_At (Core, Nested_Reserved_Offset, 4, 4)) /= 0
        or else Bytes.Read_U64
          (Layouts.Address_At (Core, Nested_Schema_Offset, 8, 8)) /=
            Nested_Identity.Schema
      then
         raise Layout_Error with
           "envelope nested layout identity does not match";
      end if;
      Set_View
        (Item, Core, Content_Offset, Content_Extent,
         Content_Alignment);
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Attach;

   function Content_Location (Item : View) return Region_Offset is
      Result : Byte_Count;
   begin
      Layouts.Require_Ready (Item.Core);
      Result := Layouts.Checked_Add
        (Byte_Count (Item.Core.Location), Item.Content_Offset);
      return Region_Offset (Result);
   end Content_Location;

   function Content_Extent (Item : View) return Byte_Count is
   begin
      Layouts.Require_Ready (Item.Core);
      return Item.Content_Size;
   end Content_Extent;

   procedure Detach (Item : in out View) is
   begin
      Layouts.Detach (Item.Core);
      Item.Content_Offset := 0;
      Item.Content_Size := 0;
      Item.Content_Alignment := 0;
   end Detach;

   function Is_Attached (Item : View) return Boolean is (Item.Core.Attached);

   procedure Destroy (Item : in out View) is
   begin
      Layouts.Mark_Destroyed (Item.Core);
      Detach (Item);
   end Destroy;

end Flyology.Data_Structures.Envelopes;
