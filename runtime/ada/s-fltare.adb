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
      References : aliased Atomics.uint32 := 1;
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

   --  Every ABI code the exported entry points return comes from the proved
   --  policy kernel, so the negative failure codes stay a closed set.
   function Code (Outcome : Policy.Request_Outcome) return C.int is
     (C.int (Policy.Outcome_Code (Outcome)));

   function Owned (T : System.Tasking.Task_Id) return Owned_Access;

   function Retain (Value : Owned_Access) return Boolean;

   procedure Release (Value : in out Owned_Access);

   function Observe_Owned
     (Value     : Owned_Access;
      Item      : System.Address;
      Item_Size : C.size_t) return C.int;

   function Wait_Owned
     (Value               : Owned_Access;
      Timeout_Nanoseconds : C.long_long) return C.int;

   function Owned (T : System.Tasking.Task_Id) return Owned_Access is
   begin
      if T = null then
         return null;
      end if;
      return Owned_Addresses.To_Pointer
        (T.Attributes (Result_Attribute_Index));
   end Owned;

   function Retain (Value : Owned_Access) return Boolean is
      Expected : aliased Atomics.uint32;
   begin
      if Value = null then
         return False;
      end if;

      Expected := Atomics.Atomic_Load_32
        (Value.References'Address, Atomics.Acquire);
      loop
         if not Policy.Retain_Allowed (Policy.Reference_Count (Expected)) then
            return False;
         end if;
         exit when Atomics.Atomic_Compare_Exchange_32
           (Value.References'Address,
            Expected'Address,
            Atomics.uint32
              (Policy.After_Retain (Policy.Reference_Count (Expected))),
            Weak          => False,
            Success_Model => Atomics.Acq_Rel,
            Failure_Model => Atomics.Acquire);
         --  A failed compare-exchange replaces Expected with the observed
         --  value, so the next iteration revalidates both terminal cases.
      end loop;
      return True;
   end Retain;

   procedure Release (Value : in out Owned_Access) is
      Expected : aliased Atomics.uint32;
      Next     : Atomics.uint32;
   begin
      if Value = null then
         return;
      end if;

      Expected := Atomics.Atomic_Load_32
        (Value.References'Address, Atomics.Acquire);
      loop
         pragma Assert
           (Policy.Release_Allowed (Policy.Reference_Count (Expected)));
         Next := Atomics.uint32
           (Policy.After_Release (Policy.Reference_Count (Expected)));
         exit when Atomics.Atomic_Compare_Exchange_32
           (Value.References'Address,
            Expected'Address,
            Next,
            Weak          => False,
            Success_Model => Atomics.Acq_Rel,
            Failure_Model => Atomics.Acquire);
      end loop;

      if Next = 0 then
         Free_Owned (Value);
      else
         Value := null;
      end if;
   end Release;

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
      Release (Value);
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

   function Observe_Owned
     (Value     : Owned_Access;
      Item      : System.Address;
      Item_Size : C.size_t) return C.int
   is
      Target : constant Result_Addresses.Object_Pointer :=
        Result_Addresses.To_Pointer (Item);
      State  : Atomics.uint32;
   begin
      if Target = null or else Item_Size /= Runtime_Result'Size / 8 then
         return Code (Policy.Malformed_Request);
      elsif Value = null then
         return Code (Policy.Unknown_Task);
      end if;
      State := Atomics.Atomic_Load_32 (Value.State'Address, Atomics.Acquire);
      if State /= Atomics.uint32 (Policy.Phase'Pos (Policy.Terminal)) then
         return Code (Policy.Not_Terminal);
      end if;
      Target.all := Value.Item;
      return Code (Policy.Terminal);
   exception
      when others =>
         return Code (Policy.Runtime_Failure);
   end Observe_Owned;

   function Observe_Task
     (T         : System.Address;
      Item      : System.Address;
      Item_Size : C.size_t) return C.int
   is
      ID : constant System.Tasking.Task_Id := To_Task_Id (T);
   begin
      if ID = null then
         return Code (Policy.Unknown_Task);
      end if;
      return Observe_Owned (Owned (ID), Item, Item_Size);
   exception
      when others =>
         return Code (Policy.Runtime_Failure);
   end Observe_Task;

   function Wait_Owned
     (Value               : Owned_Access;
      Timeout_Nanoseconds : C.long_long) return C.int
   is
      State : Atomics.uint32;
   begin
      if Value = null then
         return Code (Policy.Unknown_Task);
      end if;
      State := Atomics.Atomic_Load_32 (Value.State'Address, Atomics.Acquire);
      if State = Atomics.uint32 (Policy.Phase'Pos (Policy.Terminal)) then
         return Code (Policy.Terminal);
      elsif Timeout_Nanoseconds = 0 then
         return Code (Policy.Not_Terminal);
      elsif Timeout_Nanoseconds < 0 then
         Value.Gate.Wait;
         return Code (Policy.Terminal);
      else
         select
            Value.Gate.Wait;
            return Code (Policy.Terminal);
         or
            delay
              Duration (Timeout_Nanoseconds / C.long_long (1_000_000_000))
              + Duration (Timeout_Nanoseconds rem C.long_long (1_000_000_000))
                * 0.000_000_001;
            return Code (Policy.Not_Terminal);
         end select;
      end if;
   exception
      --  Convention-C exported bodies must not let an Ada exception reach a
      --  foreign frame. A sidecar whose gate is finalized while this caller is
      --  queued raises Program_Error here (RM 9.4), so report the ABI failure
      --  code instead and let the public wrapper raise its documented
      --  Program_Error. Abort is not an exception and still propagates.
      when others =>
         return -3;
   end Wait_Owned;

   function Wait_Task
     (T                   : System.Address;
      Timeout_Nanoseconds : C.long_long) return C.int
   is
      ID : constant System.Tasking.Task_Id := To_Task_Id (T);
   begin
      if ID = null then
         return Code (Policy.Unknown_Task);
      end if;
      return Wait_Owned (Owned (ID), Timeout_Nanoseconds);
   exception
      when others =>
         return Code (Policy.Runtime_Failure);
   end Wait_Task;

   function Attach_Monitor (T : System.Address) return System.Address is
      ID    : constant System.Tasking.Task_Id := To_Task_Id (T);
      Value : constant Owned_Access := Owned (ID);
   begin
      if ID = null or else not Retain (Value) then
         return System.Null_Address;
      end if;
      return Value.all'Address;
   exception
      when others =>
         return System.Null_Address;
   end Attach_Monitor;

   procedure Release_Monitor (Storage : System.Address) is
      Value : Owned_Access := Owned_Addresses.To_Pointer (Storage);
   begin
      Release (Value);
   exception
      when others =>
         null;
   end Release_Monitor;

   function Observe_Monitor
     (Storage   : System.Address;
      Item      : System.Address;
      Item_Size : C.size_t) return C.int is
   begin
      return Observe_Owned
        (Owned_Addresses.To_Pointer (Storage), Item, Item_Size);
   exception
      when others =>
         return Code (Policy.Runtime_Failure);
   end Observe_Monitor;

   function Wait_Monitor
     (Storage             : System.Address;
      Timeout_Nanoseconds : C.long_long) return C.int is
   begin
      return Wait_Owned
        (Owned_Addresses.To_Pointer (Storage), Timeout_Nanoseconds);
   exception
      when others =>
         return Code (Policy.Runtime_Failure);
   end Wait_Monitor;

end System.Flyology.Task_Results;
