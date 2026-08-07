with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with System.Address_To_Access_Conversions;
with System.Atomic_Primitives;
with System.Flyology.Task_Result_Policy;
with System.Tasking.Task_Attributes;

package body System.Flyology.Task_Results is
   package C renames Interfaces.C;

   use type C.int;
   use type C.long_long;
   use type C.size_t;
   use type System.Atomic_Primitives.uint32;
   use type System.Flyology.Task_Result_Policy.Event;
   use type System.Flyology.Task_Result_Policy.Phase;
   use type System.Tasking.Cause_Of_Termination;
   use type System.Tasking.Task_Id;

   ABI_Version : constant C.unsigned := 1;

   type Runtime_Result is record
      Version                  : C.unsigned;
      Cause                    : C.int;
      Exception_Name_Length    : C.unsigned;
      Exception_Name_Truncated : C.int;
      Message_Length           : C.unsigned;
      Message_Truncated        : C.int;
      Exception_Name           : C.char_array (0 .. 95);
      Message                  : C.char_array (0 .. 127);
   end record with Convention => C;

   Empty_Result : constant Runtime_Result :=
     (Version                  => ABI_Version,
      Cause                    => 0,
      Exception_Name_Length    => 0,
      Exception_Name_Truncated => 0,
      Message_Length           => 0,
      Message_Truncated        => 0,
      Exception_Name           => (others => C.nul),
      Message                  => (others => C.nul));

   package Policy renames System.Flyology.Task_Result_Policy;
   package Atomics renames System.Atomic_Primitives;
   package Task_Attributes renames System.Tasking.Task_Attributes;

   protected type Completion_Gate is
      procedure Publish;
      entry Wait;
   private
      Complete : Boolean := False;
   end Completion_Gate;

   protected body Completion_Gate is
      procedure Publish is
      begin
         Complete := True;
      end Publish;

      entry Wait when Complete is
      begin
         null;
      end Wait;
   end Completion_Gate;

   type Owned_Result is limited record
      Gate  : Completion_Gate;
      State : aliased Atomics.uint32 :=
        Atomics.uint32 (Policy.Phase'Pos (Policy.Running));
      Item  : Runtime_Result := Empty_Result;
   end record;

   package Owned_Addresses is new System.Address_To_Access_Conversions
     (Owned_Result);
   subtype Owned_Access is Owned_Addresses.Object_Pointer;
   use type Owned_Access;
   procedure Free_Owned is new Ada.Unchecked_Deallocation
     (Owned_Result, Owned_Access);

   package Result_Addresses is new System.Address_To_Access_Conversions
     (Runtime_Result);
   use type Result_Addresses.Object_Pointer;

   Result_Attribute_Index : constant Integer :=
     Task_Attributes.Next_Index (Require_Finalization => False);

   --  The C bridge forwards Model straight to __atomic_store_n, so the import
   --  must declare all three parameters. Omitting Model leaves the third
   --  argument register holding unrelated caller data, which selects an
   --  arbitrary memory order and breaks the pairing between this store and
   --  Observe_Task's acquire load.
   procedure Release_Store
     (Target : System.Address;
      Value  : Atomics.uint32;
      Model  : Atomics.Mem_Model := Atomics.Release);
   pragma Import
     (C, Release_Store, "flyology_atomic_store_u32");

   function To_Task_Id is new Ada.Unchecked_Conversion
     (System.Address, System.Tasking.Task_Id);

   function Owned (T : System.Tasking.Task_Id) return Owned_Access;

   function Owned (T : System.Tasking.Task_Id) return Owned_Access is
   begin
      if T = null then
         return null;
      end if;
      return Owned_Addresses.To_Pointer
        (T.Attributes (Result_Attribute_Index));
   end Owned;

   procedure Copy_Bounded
     (Source    : String;
      Target    : out C.char_array;
      Length    : out C.unsigned;
      Truncated : out C.int);

   procedure Copy_Bounded
     (Source    : String;
      Target    : out C.char_array;
      Length    : out C.unsigned;
      Truncated : out C.int)
   is
      Count : constant Natural := Natural'Min (Source'Length, Target'Length);
   begin
      Target := (others => C.nul);
      Length := C.unsigned (Count);
      Truncated := (if Source'Length > Target'Length then 1 else 0);
      for Offset in 0 .. Count - 1 loop
         Target (Target'First + C.size_t (Offset)) :=
           C.char'Val (Character'Pos (Source (Source'First + Offset)));
      end loop;
   end Copy_Bounded;

   function Allocate_Task_Result return System.Address is
      Value : constant Owned_Access := new Owned_Result;
   begin
      return Value.all'Address;
   end Allocate_Task_Result;

   procedure Attach_Task_Result
     (T       : System.Tasking.Task_Id;
      Storage : System.Address) is
   begin
      pragma Assert (T /= null);
      pragma Assert (Storage /= System.Null_Address);
      pragma Assert
        (T.Attributes (Result_Attribute_Index) = System.Null_Address);
      T.Attributes (Result_Attribute_Index) := Storage;
   end Attach_Task_Result;

   procedure Release_Task_Result (Storage : System.Address) is
      Value : Owned_Access := Owned_Addresses.To_Pointer (Storage);
   begin
      if Value /= null then
         Free_Owned (Value);
      end if;
   end Release_Task_Result;

   function Detach_Task_Result
     (T : System.Tasking.Task_Id) return System.Address
   is
      Storage : System.Address;
   begin
      pragma Assert (T /= null);
      Storage := T.Attributes (Result_Attribute_Index);
      T.Attributes (Result_Attribute_Index) := System.Null_Address;
      return Storage;
   end Detach_Task_Result;

   procedure Publish
     (Cause : System.Tasking.Cause_Of_Termination;
      T     : System.Tasking.Task_Id;
      X     : Ada.Exceptions.Exception_Occurrence)
   is
      Value      : constant Owned_Access := Owned (T);
      Item       : Runtime_Result := Empty_Result;
      Occurrence : constant Policy.Event :=
        (case Cause is
            when System.Tasking.Normal => Policy.Complete_Normally,
            when System.Tasking.Abnormal => Policy.Complete_Abnormally,
            when System.Tasking.Unhandled_Exception =>
              Policy.Complete_With_Exception);
      Next_State : constant Policy.Phase :=
        Policy.Next (Policy.Running, Occurrence);
   begin
      pragma Assert (Next_State = Policy.Terminal);
      if Value = null then
         return;
      end if;

      Item.Cause := C.int (Policy.Cause_Code (Occurrence));

      if Cause = System.Tasking.Unhandled_Exception then
         Copy_Bounded
           (Ada.Exceptions.Exception_Name (X),
            Item.Exception_Name,
            Item.Exception_Name_Length,
            Item.Exception_Name_Truncated);
         Copy_Bounded
           (Ada.Exceptions.Exception_Message (X),
            Item.Message,
            Item.Message_Length,
            Item.Message_Truncated);
      end if;

      Value.Item := Item;
      Release_Store
        (Value.State'Address,
         Atomics.uint32 (Policy.Phase'Pos (Next_State)));
      Value.Gate.Publish;
   end Publish;

   function Observe_Task
     (T         : System.Address;
      Item      : System.Address;
      Item_Size : C.size_t) return C.int
   is
      ID     : constant System.Tasking.Task_Id := To_Task_Id (T);
      Target : constant Result_Addresses.Object_Pointer :=
        Result_Addresses.To_Pointer (Item);
      Value  : constant Owned_Access := Owned (ID);
      State  : Atomics.uint32;
   begin
      if Target = null or else Item_Size /= Runtime_Result'Size / 8 then
         return -2;
      elsif ID = null or else Value = null then
         return -1;
      end if;
      State := Atomics.Atomic_Load_32 (Value.State'Address, Atomics.Acquire);
      if State /= Atomics.uint32 (Policy.Phase'Pos (Policy.Terminal)) then
         return 0;
      end if;
      Target.all := Value.Item;
      return 1;
   exception
      when others =>
         return -3;
   end Observe_Task;

   function Wait_Task
     (T                   : System.Address;
      Timeout_Nanoseconds : C.long_long) return C.int
   is
      ID    : constant System.Tasking.Task_Id := To_Task_Id (T);
      Value : constant Owned_Access := Owned (ID);
      State : Atomics.uint32;
   begin
      if ID = null or else Value = null then
         return -1;
      end if;
      State := Atomics.Atomic_Load_32 (Value.State'Address, Atomics.Acquire);
      if State = Atomics.uint32 (Policy.Phase'Pos (Policy.Terminal)) then
         return 1;
      elsif Timeout_Nanoseconds = 0 then
         return 0;
      elsif Timeout_Nanoseconds < 0 then
         Value.Gate.Wait;
         return 1;
      else
         select
            Value.Gate.Wait;
            return 1;
         or
            delay
              Duration (Timeout_Nanoseconds / C.long_long (1_000_000_000))
              + Duration (Timeout_Nanoseconds rem C.long_long (1_000_000_000))
                * 0.000_000_001;
            return 0;
         end select;
      end if;
   end Wait_Task;

end System.Flyology.Task_Results;
