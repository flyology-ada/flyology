package body Flyology.Timer_Set_Policy
  with SPARK_Mode
is
   function Precedes
     (Item        : Timer_State;
      Left, Right : Timer_Id) return Boolean
   is
     (Item.Entries (Left).Deadline < Item.Entries (Right).Deadline
      or else
        (Item.Entries (Left).Deadline = Item.Entries (Right).Deadline
         and then Left < Right))
   with Pre => Left <= Item.Capacity and then Right <= Item.Capacity;

   function Mapping_Valid (Item : Timer_State) return Boolean is
     (Item.Count <= Item.Capacity
      and then
        (for all Position in 1 .. Item.Count =>
           Item.Heap (Position) <= Item.Capacity
           and then Item.Entries (Item.Heap (Position)).Position = Position)
      and then
        (for all Id in Timer_Id range 1 .. Item.Capacity =>
           Item.Entries (Id).Position = 0
           or else
             (Item.Entries (Id).Position <= Item.Count
              and then Item.Heap (Item.Entries (Id).Position) = Id)));

   function Heap_Ordered (Item : Timer_State) return Boolean is
     (Mapping_Valid (Item)
      and then
        (for all Position in 2 .. Item.Count =>
           not Precedes
             (Item,
              Item.Heap (Position),
              Item.Heap (Position / 2))));

   --  Every heap edge is ordered except possibly Position to its parent.
   --  The extra child relation ensures that moving the parent down into
   --  Position preserves the order below it.
   function Up_Ready
     (Item     : Timer_State;
      Position : Positive) return Boolean
   is
     (Mapping_Valid (Item)
      and then Position <= Item.Count
      and then
        (for all Child in 2 .. Item.Count =>
           Child = Position
           or else
             not Precedes
               (Item, Item.Heap (Child), Item.Heap (Child / 2)))
      and then
        (if Position > 1 then
            (for all Child in 2 .. Item.Count =>
               (if Child / 2 = Position then
                   not Precedes
                     (Item,
                      Item.Heap (Child),
                      Item.Heap (Position / 2))))));

   --  Every heap edge is ordered except possibly the edges from Position to
   --  its children. The extra parent relation ensures that moving either
   --  child up into Position preserves the order above it.
   function Down_Ready
     (Item     : Timer_State;
      Position : Positive) return Boolean
   is
     (Mapping_Valid (Item)
      and then Position <= Item.Count
      and then
        (for all Child in 2 .. Item.Count =>
           Child / 2 = Position
           or else
             not Precedes
               (Item, Item.Heap (Child), Item.Heap (Child / 2)))
      and then
        (if Position > 1 then
            (for all Child in 2 .. Item.Count =>
               (if Child / 2 = Position then
                   not Precedes
                     (Item,
                      Item.Heap (Child),
                      Item.Heap (Position / 2))))));

   function Is_Valid (Item : Timer_State) return Boolean is
     (Mapping_Valid (Item) and then Heap_Ordered (Item));

   --  Lift local parent-child heap order to a root-minimum fact. This ghost
   --  lemma is consumed by deadline observation and complete due extraction.
   procedure Lemma_Root_Minimum (Item : Timer_State)
   with Ghost,
        Pre => Is_Valid (Item) and then Item.Count > 0,
        Post =>
          (for all Position in 1 .. Item.Count =>
             Item.Entries (Item.Heap (1)).Deadline <=
               Item.Entries (Item.Heap (Position)).Deadline)
   is
   begin
      for Position in 1 .. Item.Count loop
         pragma Loop_Invariant
           (for all Processed in 1 .. Position =>
              Item.Entries (Item.Heap (1)).Deadline <=
                Item.Entries (Item.Heap (Processed)).Deadline);
      end loop;
   end Lemma_Root_Minimum;

   function Armed_Count (Item : Timer_State) return Natural is
     (Item.Count);

   function Is_Armed
     (Item : Timer_State;
      Id   : Timer_Id) return Boolean
   is
     (Item.Entries (Id).Position /= 0);

   function Deadline_Of
     (Item : Timer_State;
      Id   : Timer_Id) return Ada.Real_Time.Time
   is
     (Item.Entries (Id).Deadline);

   procedure Swap
     (Item        : in out Timer_State;
      Left, Right : Positive)
   with Pre =>
          Mapping_Valid (Item)
          and then Left <= Item.Count
          and then Right <= Item.Count,
        Post =>
          Mapping_Valid (Item)
          and then Item.Count = Item.Count'Old
          and then
            (for all Position in 1 .. Item.Count =>
               Item.Heap (Position) =
                 (if Position = Left then Item.Heap'Old (Right)
                  elsif Position = Right then Item.Heap'Old (Left)
                  else Item.Heap'Old (Position)))
          and then
            (for all Id in Timer_Id range 1 .. Item.Capacity =>
               Item.Entries (Id).Deadline =
                 Item.Entries'Old (Id).Deadline)
   is
      Left_Id  : constant Timer_Id := Item.Heap (Left);
      Right_Id : constant Timer_Id := Item.Heap (Right);
   begin
      Item.Heap (Left) := Right_Id;
      Item.Heap (Right) := Left_Id;
      Item.Entries (Left_Id).Position := Right;
      Item.Entries (Right_Id).Position := Left;
   end Swap;

   procedure Sift_Up
     (Item     : in out Timer_State;
      Position : Positive)
   with Pre => Up_Ready (Item, Position),
        Post =>
          Is_Valid (Item)
          and then Item.Count = Item.Count'Old
          and then
            (for all Id in Timer_Id range 1 .. Item.Capacity =>
               (Item.Entries (Id).Position = 0) =
                 (Item.Entries'Old (Id).Position = 0)
               and then Item.Entries (Id).Deadline =
                 Item.Entries'Old (Id).Deadline)
   is
      Current : Positive := Position;
   begin
      while Current > 1 loop
         --  Current is the only edge that may remain unordered; swaps move
         --  that edge toward the root without changing arms or deadlines.
         pragma Loop_Invariant (Up_Ready (Item, Current));
         pragma Loop_Invariant (Item.Count = Item.Count'Loop_Entry);
         pragma Loop_Invariant
           (for all Id in Timer_Id range 1 .. Item.Capacity =>
              (Item.Entries (Id).Position = 0) =
                (Item.Entries'Loop_Entry (Id).Position = 0)
              and then Item.Entries (Id).Deadline =
                Item.Entries'Loop_Entry (Id).Deadline);
         pragma Loop_Variant (Decreases => Current);
         declare
            Parent : constant Positive := Current / 2;
         begin
            exit when not Precedes
              (Item, Item.Heap (Current), Item.Heap (Parent));
            Swap (Item, Current, Parent);
            Current := Parent;
         end;
      end loop;
   end Sift_Up;

   procedure Sift_Down
     (Item     : in out Timer_State;
      Position : Positive)
   with Pre => Down_Ready (Item, Position),
        Post =>
          Is_Valid (Item)
          and then Item.Count = Item.Count'Old
          and then
            (for all Id in Timer_Id range 1 .. Item.Capacity =>
               (Item.Entries (Id).Position = 0) =
                 (Item.Entries'Old (Id).Position = 0)
               and then Item.Entries (Id).Deadline =
                 Item.Entries'Old (Id).Deadline)
   is
      Current : Positive := Position;
   begin
      loop
         --  Current is the only node whose child edges may remain unordered;
         --  swaps move that node downward without changing arms or deadlines.
         pragma Loop_Invariant (Down_Ready (Item, Current));
         pragma Loop_Invariant (Item.Count = Item.Count'Loop_Entry);
         pragma Loop_Invariant
           (for all Id in Timer_Id range 1 .. Item.Capacity =>
              (Item.Entries (Id).Position = 0) =
                (Item.Entries'Loop_Entry (Id).Position = 0)
              and then Item.Entries (Id).Deadline =
                Item.Entries'Loop_Entry (Id).Deadline);
         pragma Loop_Variant (Increases => Current);
         exit when Current > Item.Count / 2;
         declare
            Child : Positive := Current * 2;
         begin
            if Child < Item.Count
              and then Precedes
                (Item, Item.Heap (Child + 1), Item.Heap (Child))
            then
               Child := Child + 1;
            end if;
            pragma Assert
              (for all Sibling in 2 .. Item.Count =>
                 (if Sibling / 2 = Current then
                     not Precedes
                       (Item, Item.Heap (Sibling), Item.Heap (Child))));
            exit when not Precedes
              (Item, Item.Heap (Child), Item.Heap (Current));
            Swap (Item, Current, Child);
            Current := Child;
         end;
      end loop;
   end Sift_Down;

   procedure Remove_At
     (Item     : in out Timer_State;
      Position : Positive)
   with Pre => Is_Valid (Item) and then Position <= Item.Count,
        Post =>
          Is_Valid (Item)
          and then Item.Count = Item.Count'Old - 1
          and then
            Item.Entries (Item.Heap'Old (Position)).Position = 0
          and then
            (for all Id in Timer_Id range 1 .. Item.Capacity =>
               (if Id /= Item.Heap'Old (Position) then
                   (Item.Entries (Id).Position = 0) =
                     (Item.Entries'Old (Id).Position = 0)))
          and then
            (for all Id in Timer_Id range 1 .. Item.Capacity =>
               Item.Entries (Id).Deadline =
                 Item.Entries'Old (Id).Deadline)
   is
      Removed : constant Timer_Id := Item.Heap (Position);
      Last    : constant Timer_Id := Item.Heap (Item.Count);
   begin
      Item.Entries (Removed).Position := 0;
      Item.Count := Item.Count - 1;
      if Position <= Item.Count then
         Item.Heap (Position) := Last;
         Item.Entries (Last).Position := Position;
         if Position > 1
           and then Precedes
             (Item, Last, Item.Heap (Position / 2))
         then
            Sift_Up (Item, Position);
         else
            Sift_Down (Item, Position);
         end if;
      end if;
   end Remove_At;

   procedure Clear (Item : in out Timer_State) is
   begin
      for Id in Item.Entries'Range loop
         Item.Entries (Id).Position := 0;
         --  Every entry through Id has been disarmed; at loop completion this
         --  covers the complete reverse-position table.
         pragma Loop_Invariant
           (for all Processed in Item.Entries'First .. Id =>
              Item.Entries (Processed).Position = 0);
      end loop;
      Item.Count := 0;
   end Clear;

   procedure Arm
     (Item     : in out Timer_State;
      Id       : Timer_Id;
      Deadline : Ada.Real_Time.Time)
   is
      Position : Natural := Item.Entries (Id).Position;
   begin
      if Position = 0 then
         Item.Count := Item.Count + 1;
         Position := Item.Count;
         Item.Heap (Position) := Id;
         Item.Entries (Id).Position := Position;
      end if;
      Item.Entries (Id).Deadline := Deadline;

      if Position > 1
        and then Precedes
          (Item, Id, Item.Heap (Position / 2))
      then
         Sift_Up (Item, Position);
      else
         Sift_Down (Item, Position);
      end if;
   end Arm;

   procedure Cancel
     (Item : in out Timer_State;
      Id   : Timer_Id)
   is
      Position : constant Natural := Item.Entries (Id).Position;
   begin
      if Position /= 0 then
         Remove_At (Item, Position);
      end if;
   end Cancel;

   function Earliest_Deadline
     (Item : Timer_State) return Ada.Real_Time.Time
   is
   begin
      Lemma_Root_Minimum (Item);
      return Item.Entries (Item.Heap (1)).Deadline;
   end Earliest_Deadline;

   procedure Collect_Due
     (Item      : in out Timer_State;
      Now       : Ada.Real_Time.Time;
      Activated : out Due_Batch)
   is
   begin
      Activated.Count := 0;
      Activated.Ids := (others => Timer_Id'First);
      while Item.Count > 0
        and then Item.Entries (Item.Heap (1)).Deadline <= Now
      loop
         --  Removed arms are exactly the unique due ids already emitted;
         --  all remaining arms and every deadline retain their entry state.
         pragma Loop_Invariant (Is_Valid (Item));
         pragma Loop_Invariant
           (Activated.Count <= Item.Count'Loop_Entry);
         pragma Loop_Invariant
           (Item.Count = Item.Count'Loop_Entry - Activated.Count);
         pragma Loop_Invariant
           (Activated.Count <= Activated.Capacity);
         pragma Loop_Invariant
           (for all Id in Timer_Id range 1 .. Item.Capacity =>
              Item.Entries (Id).Deadline =
                Item.Entries'Loop_Entry (Id).Deadline);
         pragma Loop_Invariant
           (for all Id in Timer_Id range 1 .. Item.Capacity =>
              (Item.Entries (Id).Position /= 0) =
                (Item.Entries'Loop_Entry (Id).Position /= 0
                 and then
                   (for all Output_Position in 1 .. Activated.Count =>
                      Activated.Ids (Output_Position) /= Id)));
         pragma Loop_Invariant
           (for all Output_Position in 1 .. Activated.Count =>
              Activated.Ids (Output_Position) <= Item.Capacity
              and then
                Item.Entries'Loop_Entry
                  (Activated.Ids (Output_Position)).Position /= 0
              and then
                Item.Entries'Loop_Entry
                  (Activated.Ids (Output_Position)).Deadline <= Now
              and then
                (for all Earlier in 1 .. Output_Position - 1 =>
                   Activated.Ids (Earlier) /=
                     Activated.Ids (Output_Position)));
         pragma Loop_Variant (Decreases => Item.Count);
         Activated.Count := Activated.Count + 1;
         Activated.Ids (Activated.Count) := Item.Heap (1);
         Remove_At (Item, 1);
      end loop;
      if Item.Count > 0 then
         Lemma_Root_Minimum (Item);
      end if;
   end Collect_Due;
end Flyology.Timer_Set_Policy;
