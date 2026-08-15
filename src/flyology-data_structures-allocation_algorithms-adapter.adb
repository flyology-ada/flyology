with Ada.Exceptions;
with Flyology.Data_Structures.Storage;
with Flyology_Allocators;
with Flyology_Allocators.Allocation_Algorithms;
with Interfaces.C;
with System;

package body Flyology.Data_Structures.Allocation_Algorithms.Adapter is
   package FA renames Flyology_Allocators;
   package FAA renames Flyology_Allocators.Allocation_Algorithms;
   package FA_Regions renames Flyology_Allocators.Regions;
   package Bytes renames Flyology.Data_Structures.Storage;
   package C renames Interfaces.C;

   use type Ada.Exceptions.Exception_Id;
   use type FA.Byte_Count;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   Inner_Instance : constant Interfaces.Unsigned_64 := 1;

   procedure Translate (Occurrence : Ada.Exceptions.Exception_Occurrence) is
      Identity : constant Ada.Exceptions.Exception_Id :=
        Ada.Exceptions.Exception_Identity (Occurrence);
      Message : constant String :=
        Ada.Exceptions.Exception_Message (Occurrence);
   begin
      if Identity = FA.Region_Error'Identity then
         raise Region_Error with Message;
      elsif Identity = FA.Layout_Error'Identity then
         raise Layout_Error with Message;
      elsif Identity = FA.Handle_Error'Identity then
         raise Handle_Error with Message;
      elsif Identity = FA.Busy_Error'Identity then
         raise Busy_Error with Message;
      elsif Identity = FA.Timeout_Error'Identity then
         raise Timeout_Error with Message;
      elsif Identity = FA.Poison_Error'Identity then
         raise Poison_Error with Message;
      else
         Ada.Exceptions.Reraise_Occurrence (Occurrence);
      end if;
   end Translate;

   function To_Inner
     (Value : Allocation_Handle) return FAA.Allocation_Handle is
     ((Token => Value.Token, Generation => Value.Generation));

   function From_Inner
     (Value : FAA.Allocation_Handle) return Allocation_Handle is
     ((Token => Value.Token, Generation => Value.Generation));

   function Inner_Offset
     (Configuration : Algorithm.Configuration) return Byte_Count is
     (Layouts.Align_Up
        (Layouts.Header_Size,
         Byte_Count (Algorithm.Minimum_Block_Size (Configuration))));

   function Required_Storage
     (Configuration : Algorithm.Configuration) return Byte_Count is
   begin
      return Layouts.Checked_Add
        (Inner_Offset (Configuration),
         Byte_Count (Algorithm.Required_Storage (Configuration)));
   exception
      when Occurrence : others =>
         Translate (Occurrence);
         raise Program_Error;
   end Required_Storage;

   procedure Clear (Item : in out View) is
   begin
      Algorithm.Detach (Item.Inner);
      FA_Regions.Detach (Item.Inner_Region);
      Layouts.Detach (Item.Core);
      Item.Instance_Value := 0;
      Item.Usable_Value := 0;
      Item.Minimum_Value := 0;
      Item.Inner_Location := 0;
   end Clear;

   procedure Prepare_Inner
     (Item          : in out View;
      Configuration : Algorithm.Configuration;
      Initialize_New : Boolean) is
   begin
      FA_Regions.Attach
        (Item.Inner_Region, Item.Core.Base, FA.Byte_Count (Item.Core.Extent));
      if Initialize_New then
         Algorithm.Initialize
           (Item.Inner, Item.Inner_Region,
            FA.Region_Offset (Item.Inner_Location), Configuration,
            Inner_Instance);
      else
         Algorithm.Attach
           (Item.Inner, Item.Inner_Region,
            FA.Region_Offset (Item.Inner_Location), Configuration,
            Inner_Instance);
      end if;
   end Prepare_Inner;

   procedure Finish_New
     (Item          : in out View;
      Configuration : Algorithm.Configuration;
      Instance_ID   : Interfaces.Unsigned_64) is
   begin
      Item.Instance_Value := Instance_ID;
      Item.Usable_Value := Interfaces.Unsigned_32
        (Algorithm.Usable_Capacity (Configuration));
      Item.Minimum_Value := Interfaces.Unsigned_32
        (Algorithm.Minimum_Block_Size (Configuration));
      Item.Inner_Location := Inner_Offset (Configuration);
      Prepare_Inner (Item, Configuration, Initialize_New => True);
      Layouts.Publish (Item.Core);
   end Finish_New;

   procedure Initialize
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Algorithm.Configuration;
      Instance_ID   : Interfaces.Unsigned_64)
   is
      Extent  : constant Byte_Count := Required_Storage (Configuration);
      Usable  : constant Positive :=
        Algorithm.Usable_Capacity (Configuration);
      Minimum : constant Positive :=
        Algorithm.Minimum_Block_Size (Configuration);
   begin
      if Instance_ID = 0 then
         raise Constraint_Error with "arena instance identity is zero";
      end if;
      Clear (Item);
      Layouts.Begin_Initialize
        (Item.Core, Region, Location, Identity, Extent,
         (Capacity     => Interfaces.Unsigned_32 (Usable),
          Element_Size => Interfaces.Unsigned_32 (Minimum),
          Alignment    => Interfaces.Unsigned_32 (Minimum),
          Auxiliary    => 0,
          Word_1       => Instance_ID,
          Word_2       => Interfaces.Unsigned_64
            (Inner_Offset (Configuration))),
         Byte_Count (Minimum));
      Finish_New (Item, Configuration, Instance_ID);
   exception
      when Occurrence : others =>
         Clear (Item);
         Translate (Occurrence);
   end Initialize;

   procedure Create_Or_Attach
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Algorithm.Configuration;
      Instance_ID   : Interfaces.Unsigned_64;
      Result        : out Open_Result)
   is
      Extent  : constant Byte_Count := Required_Storage (Configuration);
      Usable  : constant Positive :=
        Algorithm.Usable_Capacity (Configuration);
      Minimum : constant Positive :=
        Algorithm.Minimum_Block_Size (Configuration);
      Claim   : Layouts.Initialization_Claim;
   begin
      if Instance_ID = 0 then
         raise Constraint_Error with "arena instance identity is zero";
      end if;
      Clear (Item);
      Layouts.Try_Begin_Initialize
        (Item.Core, Claim, Region, Location, Identity, Extent,
         (Capacity     => Interfaces.Unsigned_32 (Usable),
          Element_Size => Interfaces.Unsigned_32 (Minimum),
          Alignment    => Interfaces.Unsigned_32 (Minimum),
          Auxiliary    => 0,
          Word_1       => Instance_ID,
          Word_2       => Interfaces.Unsigned_64
            (Inner_Offset (Configuration))),
         Byte_Count (Minimum));
      case Claim is
         when Layouts.Claimed_Virgin =>
            Finish_New (Item, Configuration, Instance_ID);
            Result := Initialized_New;
         when Layouts.Existing_Ready =>
            Attach
              (Item, Region, Location, Configuration, Instance_ID);
            Result := Attached_Existing;
         when Layouts.Claim_In_Progress =>
            Result := Initialization_In_Progress;
      end case;
   exception
      when Occurrence : others =>
         Clear (Item);
         Translate (Occurrence);
   end Create_Or_Attach;

   procedure Attach
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Algorithm.Configuration;
      Instance_ID   : Interfaces.Unsigned_64)
   is
      Expected_Extent : constant Byte_Count :=
        Required_Storage (Configuration);
      Expected_Usable : constant Positive :=
        Algorithm.Usable_Capacity (Configuration);
      Expected_Minimum : constant Positive :=
        Algorithm.Minimum_Block_Size (Configuration);
      Expected_Inner : constant Byte_Count := Inner_Offset (Configuration);
      Header : Layouts.Header_Values;
   begin
      if Instance_ID = 0 then
         raise Constraint_Error with "arena instance identity is zero";
      end if;
      Clear (Item);
      Layouts.Attach
        (Item.Core, Header, Region, Location, Identity,
         Byte_Count (Expected_Minimum));
      if Header.Capacity /= Interfaces.Unsigned_32 (Expected_Usable)
        or else Header.Element_Size /=
          Interfaces.Unsigned_32 (Expected_Minimum)
        or else Header.Alignment /= Interfaces.Unsigned_32 (Expected_Minimum)
        or else Header.Auxiliary /= 0
        or else Header.Word_1 /= Instance_ID
        or else Header.Word_2 /= Interfaces.Unsigned_64 (Expected_Inner)
        or else Item.Core.Extent /= Expected_Extent
      then
         raise Layout_Error with "arena creation parameters do not match";
      end if;
      Item.Instance_Value := Instance_ID;
      Item.Usable_Value := Interfaces.Unsigned_32 (Expected_Usable);
      Item.Minimum_Value := Interfaces.Unsigned_32 (Expected_Minimum);
      Item.Inner_Location := Expected_Inner;
      Prepare_Inner (Item, Configuration, Initialize_New => False);
   exception
      when Occurrence : others =>
         Clear (Item);
         Translate (Occurrence);
   end Attach;

   procedure Detach (Item : in out View) is
   begin
      Clear (Item);
   end Detach;

   function Is_Attached (Item : View) return Boolean is
     (Item.Core.Attached and then Algorithm.Is_Attached (Item.Inner));

   function Current_Metadata (Item : View) return Metadata is
   begin
      Layouts.Require_Ready (Item.Core);
      return
        (Usable_Capacity    => Item.Usable_Value,
         Minimum_Block_Size => Item.Minimum_Value,
         Instance_ID        => Item.Instance_Value,
         Incarnation        => Item.Core.Epoch_Value,
         Extent             => Item.Core.Extent);
   end Current_Metadata;

   function Is_Poisoned (Item : View) return Boolean is
   begin
      if Layouts.Is_Poisoned (Item.Core) then
         return True;
      end if;
      return Algorithm.Is_Poisoned (Item.Inner);
   exception
      when Occurrence : others =>
         Translate (Occurrence);
         raise Program_Error;
   end Is_Poisoned;

   procedure Poison (Region : Region_View; Location : Region_Offset) is
   begin
      Layouts.Poison_At (Region, Location, Identity, 8);
   end Poison;

   procedure Try_Allocate
     (Item           : in out View;
      Requested_Size : Positive;
      Value          : out Allocation_Handle;
      Result         : out Allocation_Result)
   is
      Inner_Value  : FAA.Allocation_Handle;
      Inner_Result : FAA.Allocation_Result;
   begin
      Layouts.Require_Ready (Item.Core);
      Algorithm.Try_Allocate
        (Item.Inner, Requested_Size, Inner_Value, Inner_Result);
      Value := From_Inner (Inner_Value);
      Result :=
        (case Inner_Result is
            when FAA.Allocated => Allocated,
            when FAA.Exhausted => Exhausted,
            when FAA.Allocation_Contended => Allocation_Contended);
   exception
      when Occurrence : others =>
         Translate (Occurrence);
   end Try_Allocate;

   procedure Try_Allocate
     (Item           : in out View;
      Requested_Size : Positive;
      Timeout        : Wait_Timeout;
      Value          : out Allocation_Handle;
      Result         : out Allocation_Result)
   is
      Inner_Value  : FAA.Allocation_Handle;
      Inner_Result : FAA.Allocation_Result;
   begin
      Layouts.Require_Ready (Item.Core);
      Algorithm.Try_Allocate
        (Item.Inner, Requested_Size, FA.Wait_Timeout (Timeout),
         Inner_Value, Inner_Result);
      Value := From_Inner (Inner_Value);
      Result :=
        (case Inner_Result is
            when FAA.Allocated => Allocated,
            when FAA.Exhausted => Exhausted,
            when FAA.Allocation_Contended => Allocation_Contended);
   exception
      when Occurrence : others =>
         Translate (Occurrence);
   end Try_Allocate;

   procedure Release (Item : in out View; Value : Allocation_Handle) is
   begin
      Layouts.Require_Ready (Item.Core);
      Algorithm.Release (Item.Inner, To_Inner (Value));
   exception
      when Occurrence : others =>
         Translate (Occurrence);
   end Release;

   procedure Release
     (Item    : in out View;
      Value   : Allocation_Handle;
      Timeout : Wait_Timeout) is
   begin
      Layouts.Require_Ready (Item.Core);
      Algorithm.Release
        (Item.Inner, To_Inner (Value), FA.Wait_Timeout (Timeout));
   exception
      when Occurrence : others =>
         Translate (Occurrence);
   end Release;

   function Block_Capacity
     (Item : View; Value : Allocation_Handle) return Byte_Count is
   begin
      Layouts.Require_Ready (Item.Core);
      return Byte_Count
        (Algorithm.Block_Capacity (Item.Inner, To_Inner (Value)));
   exception
      when Occurrence : others =>
         Translate (Occurrence);
         raise Program_Error;
   end Block_Capacity;

   procedure Attach_Allocation
     (Region : in out Region_View;
      Item   : View;
      Value  : Allocation_Handle)
   is
      Inner_Allocation : FA.Region_View;
   begin
      Region.Base := System.Null_Address;
      Region.Length_Value := 0;
      Region.Attached := False;
      Layouts.Require_Ready (Item.Core);
      Algorithm.Attach_Allocation
        (Inner_Allocation, Item.Inner, To_Inner (Value));
      Region.Base := FA_Regions.Base_Address (Inner_Allocation);
      Region.Length_Value := Byte_Count (FA_Regions.Length (Inner_Allocation));
      Region.Attached := True;
      FA_Regions.Detach (Inner_Allocation);
   exception
      when Occurrence : others =>
         FA_Regions.Detach (Inner_Allocation);
         Region.Base := System.Null_Address;
         Region.Length_Value := 0;
         Region.Attached := False;
         Translate (Occurrence);
   end Attach_Allocation;

   function Bind_Allocation
     (Item      : View;
      Value     : Allocation_Handle;
      Offset    : Byte_Count;
      Extent    : Byte_Count;
      Alignment : Byte_Count;
      Signature : Interfaces.Unsigned_64;
      Version   : Interfaces.Unsigned_32;
      Writable  : Boolean) return Immutable_Storage_View
   is
      Inner_Allocation : FA.Region_View;
      Result : Immutable_Storage_View;
   begin
      if Signature = 0
        or else Version = 0
        or else Alignment not in 1 | 2 | 4 | 8 | 16 | 32 | 64
      then
         raise Constraint_Error with
           "invalid immutable arena binding contract";
      end if;
      Layouts.Require_Ready (Item.Core);
      Algorithm.Attach_Allocation
        (Inner_Allocation, Item.Inner, To_Inner (Value));
      Result :=
        (Base => FA_Regions.Address_At
           (Inner_Allocation, FA.Byte_Count (Offset), FA.Byte_Count (Extent),
            FA.Byte_Count (Alignment)),
         Extent => Extent,
         Signature => Signature,
         Version => Version,
         Writable => Writable);
      FA_Regions.Detach (Inner_Allocation);
      return Result;
   exception
      when Occurrence : others =>
         FA_Regions.Detach (Inner_Allocation);
         Translate (Occurrence);
         raise Program_Error;
   end Bind_Allocation;

   procedure Read
     (Item   : View;
      Value  : Allocation_Handle;
      Offset : Byte_Count;
      Data   : out Ada.Streams.Stream_Element_Array)
   is
      Allocation    : FA.Region_View;
      Length        : constant FA.Byte_Count := FA.Byte_Count (Data'Length);
      Inner_Offset  : constant FA.Byte_Count := FA.Byte_Count (Offset);
      Native_Length : C.size_t;
   begin
      Layouts.Require_Ready (Item.Core);
      Algorithm.Attach_Allocation
        (Allocation, Item.Inner, To_Inner (Value));
      if Inner_Offset > FA_Regions.Length (Allocation)
        or else Length > FA_Regions.Length (Allocation) - Inner_Offset
      then
         raise Constraint_Error with "arena read is out of bounds";
      elsif Length /= 0 then
         Native_Length := C.size_t (Length);
         if FA.Byte_Count (Native_Length) /= Length then
            raise Constraint_Error with
              "arena read is not natively representable";
         end if;
         Bytes.Copy
           (Data'Address,
            FA_Regions.Address_At
              (Allocation, Inner_Offset, Length),
            Native_Length);
      end if;
      FA_Regions.Detach (Allocation);
   exception
      when Occurrence : others =>
         FA_Regions.Detach (Allocation);
         Translate (Occurrence);
   end Read;

   procedure Write
     (Item   : View;
      Value  : Allocation_Handle;
      Offset : Byte_Count;
      Data   : Ada.Streams.Stream_Element_Array)
   is
      Allocation    : FA.Region_View;
      Length        : constant FA.Byte_Count := FA.Byte_Count (Data'Length);
      Inner_Offset  : constant FA.Byte_Count := FA.Byte_Count (Offset);
      Native_Length : C.size_t;
   begin
      Layouts.Require_Ready (Item.Core);
      Algorithm.Attach_Allocation
        (Allocation, Item.Inner, To_Inner (Value));
      if Inner_Offset > FA_Regions.Length (Allocation)
        or else Length > FA_Regions.Length (Allocation) - Inner_Offset
      then
         raise Constraint_Error with "arena write is out of bounds";
      elsif Length /= 0 then
         Native_Length := C.size_t (Length);
         if FA.Byte_Count (Native_Length) /= Length then
            raise Constraint_Error with
              "arena write is not natively representable";
         end if;
         Bytes.Copy
           (FA_Regions.Address_At
              (Allocation, Inner_Offset, Length),
            Data'Address, Native_Length);
      end if;
      FA_Regions.Detach (Allocation);
   exception
      when Occurrence : others =>
         FA_Regions.Detach (Allocation);
         Translate (Occurrence);
   end Write;

   procedure Copy
     (Item          : View;
      Source        : Allocation_Handle;
      Source_Offset : Byte_Count;
      Target        : Allocation_Handle;
      Target_Offset : Byte_Count;
      Length        : Byte_Count) is
   begin
      Layouts.Require_Ready (Item.Core);
      Algorithm.Copy
        (Item.Inner, To_Inner (Source), FA.Byte_Count (Source_Offset),
         To_Inner (Target), FA.Byte_Count (Target_Offset),
         FA.Byte_Count (Length));
   exception
      when Occurrence : others =>
         Translate (Occurrence);
   end Copy;

   procedure Destroy (Item : in out View) is
   begin
      Layouts.Require_Ready (Item.Core);
      Algorithm.Destroy (Item.Inner);
      FA_Regions.Detach (Item.Inner_Region);
      Layouts.Mark_Destroyed (Item.Core);
      Item.Instance_Value := 0;
      Item.Usable_Value := 0;
      Item.Minimum_Value := 0;
      Item.Inner_Location := 0;
   exception
      when Occurrence : others =>
         Translate (Occurrence);
   end Destroy;

end Flyology.Data_Structures.Allocation_Algorithms.Adapter;
