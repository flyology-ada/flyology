with Ada.Real_Time;

--  Internal bounded timer-heap state and activation extraction. Task
--  suspension and clock sampling remain in Flyology.IO.Timers.
private package Flyology.Timer_Set_Policy
  with SPARK_Mode
is
   --  @exclude Internal proof policy, not part of the public API.

   use type Ada.Real_Time.Time;

   --  Internal identity of one timer slot.
   subtype Timer_Id is Positive;

   --  Internal bounded sequence of timer identities.
   type Timer_Id_Array is array (Positive range <>) of Timer_Id;

   --  Internal batch produced by one due-set extraction.
   --  @field Capacity Maximum number of identities
   --  @field Count Number of defined identities
   --  @field Ids Defined identities in positions 1 .. Count
   type Due_Batch (Capacity : Positive) is record
      Count : Natural := 0;
      Ids   : Timer_Id_Array (1 .. Capacity) := (others => Timer_Id'First);
   end record;

   --  Internal indexed-heap state.
   --  @field Capacity Number of caller-selected timer slots
   type Timer_State (Capacity : Positive) is private;

   --  Check the indexed heap, reverse positions, and active count together.
   --  @param Item State to validate
   --  @return True when every indexed-heap invariant holds
   function Is_Valid (Item : Timer_State) return Boolean;

   --  Return the number of armed timers.
   --  @param Item Valid state to inspect
   --  @return Number of active heap entries
   function Armed_Count (Item : Timer_State) return Natural
   with Pre  => Is_Valid (Item),
        Post => Armed_Count'Result <= Item.Capacity;

   --  Report whether one timer identity is armed.
   --  @param Item State to inspect
   --  @param Id In-range timer identity
   --  @return True when Id occupies the active heap
   function Is_Armed
     (Item : Timer_State;
      Id   : Timer_Id) return Boolean
   with Pre => Id <= Item.Capacity;

   --  Return one armed timer's monotonic deadline.
   --  @param Item State to inspect
   --  @param Id Armed timer identity
   --  @return Stored deadline for Id
   function Deadline_Of
     (Item : Timer_State;
      Id   : Timer_Id) return Ada.Real_Time.Time
   with Pre => Id <= Item.Capacity and then Is_Armed (Item, Id);

   --  Disarm every timer and restore an empty valid heap.
   --  @param Item Valid state to clear
   procedure Clear (Item : in out Timer_State)
   with Pre  => Is_Valid (Item),
        Post => Is_Valid (Item) and then Armed_Count (Item) = 0;

   --  Insert one new arm or replace one existing deadline.
   --  @param Item Valid state with room for a new Id when needed
   --  @param Id In-range timer identity
   --  @param Deadline Replacement monotonic deadline
   procedure Arm
     (Item     : in out Timer_State;
      Id       : Timer_Id;
      Deadline : Ada.Real_Time.Time)
   with Pre  =>
          Is_Valid (Item)
          and then Id <= Item.Capacity
          and then
            (Is_Armed (Item, Id)
             or else Armed_Count (Item) < Item.Capacity),
        Post =>
          Is_Valid (Item)
          and then Is_Armed (Item, Id)
          and then Deadline_Of (Item, Id) = Deadline
          and then Armed_Count (Item) =
            (if Is_Armed (Item'Old, Id)
             then Armed_Count (Item'Old)
             else Armed_Count (Item'Old) + 1)
          and then
            (for all Other in Timer_Id range 1 .. Item.Capacity =>
               (if Other /= Id then
                   Is_Armed (Item, Other) =
                     Is_Armed (Item'Old, Other)
                   and then
                     (if Is_Armed (Item, Other) then
                         Deadline_Of (Item, Other) =
                           Deadline_Of (Item'Old, Other))));

   --  Idempotently disarm one identity.
   --  @param Item Valid state to update
   --  @param Id In-range timer identity
   procedure Cancel
     (Item : in out Timer_State;
      Id   : Timer_Id)
   with Pre  => Is_Valid (Item) and then Id <= Item.Capacity,
        Post =>
          Is_Valid (Item)
          and then not Is_Armed (Item, Id)
          and then Armed_Count (Item) =
            (if Is_Armed (Item'Old, Id)
             then Armed_Count (Item'Old) - 1
             else Armed_Count (Item'Old))
          and then
            (for all Other in Timer_Id range 1 .. Item.Capacity =>
               (if Other /= Id then
                   Is_Armed (Item, Other) =
                     Is_Armed (Item'Old, Other)
                   and then
                     (if Is_Armed (Item, Other) then
                         Deadline_Of (Item, Other) =
                           Deadline_Of (Item'Old, Other))));

   --  Return the minimum armed deadline.
   --  @param Item Nonempty valid state
   --  @return Deadline no later than every other armed deadline
   function Earliest_Deadline
     (Item : Timer_State) return Ada.Real_Time.Time
   with Pre => Is_Valid (Item) and then Armed_Count (Item) > 0,
        Post =>
          (for all Id in Timer_Id range 1 .. Item.Capacity =>
             (if Is_Armed (Item, Id) then
                 Earliest_Deadline'Result <= Deadline_Of (Item, Id)));

   --  Remove every timer due at the one supplied clock sample. Each returned
   --  id occurs once, every due id is returned, and every later timer retains
   --  its arm and deadline.
   --  @param Item Valid state to extract from
   --  @param Now Monotonic-clock sample used for due classification
   --  @param Activated Complete unique set of identities due at Now
   procedure Collect_Due
     (Item      : in out Timer_State;
      Now       : Ada.Real_Time.Time;
      Activated : out Due_Batch)
   with Pre  => Is_Valid (Item) and then Activated.Capacity = Item.Capacity,
        Post =>
          Is_Valid (Item)
          and then Activated.Count <= Activated.Capacity
          and then Armed_Count (Item) =
            Armed_Count (Item'Old) - Activated.Count
          and then
            (for all Id in Timer_Id range 1 .. Item.Capacity =>
               ((for some Position in 1 .. Activated.Count =>
                    Activated.Ids (Position) = Id)
                =
                  (Is_Armed (Item'Old, Id)
                   and then Deadline_Of (Item'Old, Id) <= Now)))
          and then
            (for all Id in Timer_Id range 1 .. Item.Capacity =>
               Is_Armed (Item, Id) =
                 (Is_Armed (Item'Old, Id)
                  and then Deadline_Of (Item'Old, Id) > Now))
          and then
            (for all Position in 1 .. Activated.Count =>
               Is_Armed (Item'Old, Activated.Ids (Position))
               and then
                 Deadline_Of
                   (Item'Old, Activated.Ids (Position)) <= Now
               and then
                 (for all Earlier in 1 .. Position - 1 =>
                    Activated.Ids (Earlier) /=
                      Activated.Ids (Position)))
          and then
            (for all Id in Timer_Id range 1 .. Item.Capacity =>
               (if Is_Armed (Item, Id) then
                   Deadline_Of (Item, Id) =
                     Deadline_Of (Item'Old, Id)));

private
   type Timer_Entry is record
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Position : Natural := 0;
   end record;
   type Timer_Entry_Array is array (Timer_Id range <>) of Timer_Entry;

   type Timer_State (Capacity : Positive) is record
      Entries : Timer_Entry_Array (1 .. Capacity);
      Heap    : Timer_Id_Array (1 .. Capacity) := (others => Timer_Id'First);
      Count   : Natural := 0;
   end record;
end Flyology.Timer_Set_Policy;
