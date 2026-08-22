--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Flyology_Debug.Internal.Ring_Policy;

package body Flyology_Debug.Tracers is
   package Ring renames Flyology_Debug.Internal.Ring_Policy;

   use type Interfaces.Unsigned_64;

   type Push_Outcome is (Stored, Stored_With_Overwrite, Dropped, Ignored, Store_Closed);

   type Buffer is record
      Traces          : Trace_Array;
      History         : Ring.State := Ring.Initial_State;
      Overwrite_Total : Loss_Count := 0;
      Dropped_Total   : Loss_Count := 0;
   end record;

   subtype Slot_Index is Positive range 1 .. 2;
   type Buffer_Array is array (Slot_Index) of Buffer;
   type Producer_Buffers is array (Producer_Id) of Buffer_Array;

   Buffers : Producer_Buffers;

   procedure Reset_Buffer (Producer : Producer_Id; Slot : Slot_Index);

   procedure Return_Buffer (Result : in out Batch);

   procedure Return_Buffers (Result : in out Merged_Batch);

   function Required_Slot (Result : Batch) return Slot_Index;

   function Required_Producer (Result : Batch) return Producer_Id;

   function Position_Of (History : Ring.State; Index : Positive) return Positive;

   function Automatic_Producer return Producer_Id;

   function Saturating_Add
     (Left : Interfaces.Unsigned_64; Right : Interfaces.Unsigned_64) return Interfaces.Unsigned_64;

   type Capture_State is (Accepting, Paused, Terminal);

   Current_Capture_State    : Capture_State := Accepting
   with Atomic;
   type Capacity_State_Array is array (Producer_Id) of Boolean with Atomic_Components;
   Block_Capacity_Available : Capacity_State_Array := (others => True);

   procedure Push_While_Locked
     (Producer       : Producer_Id;
      Active         : Slot_Index;
      Timestamp      : Flyology_Debug.Timestamp;
      Message        : Message_Type;
      Next_Admission : in out Sequence_Number;
      Outcome        : out Push_Outcome);

   protected type Store_Type is
      procedure Initialize (Producer : Producer_Id);
      procedure Push_Immediate
        (Producer  : Producer_Id;
         Timestamp : Flyology_Debug.Timestamp;
         Message   : Message_Type;
         Outcome   : out Push_Outcome);
      entry Push_Blocking
        (Producer  : Producer_Id;
         Timestamp : Flyology_Debug.Timestamp;
         Message   : Message_Type;
         Outcome   : out Push_Outcome);
      entry Detach (Producer : Producer_Id; Slot : out Natural);
      procedure Release (Slot : in out Natural);
      procedure State_Changed;
   private
      Active         : Slot_Index := 1;
      Spare          : Natural range 0 .. 2 := 2;
      Next_Admission : Sequence_Number := 1;
      Owner          : Natural range 0 .. Producer_Count := 0;
   end Store_Type;

   type Store_Array is array (Producer_Id) of Store_Type;
   Stores : Store_Array;

   type Consumer_Ownership_Array is array (Producer_Id) of Boolean;

   protected Consumer_Reservations is
      entry Acquire (Producer_Id) (Result : in out Batch);
      entry Acquire_All (Result : in out Merged_Batch);
      procedure Release (Producer : Producer_Id; Result : in out Batch);
      procedure Release_All (Result : in out Merged_Batch);
   private
      Owned       : Consumer_Ownership_Array := (others => False);
      Owned_Count : Natural range 0 .. Producer_Count := 0;
   end Consumer_Reservations;

   protected Capture_Control is
      procedure Enable_State;
      procedure Disable_State;
      procedure Close_State;
   end Capture_Control;

   procedure Push_While_Locked
     (Producer       : Producer_Id;
      Active         : Slot_Index;
      Timestamp      : Flyology_Debug.Timestamp;
      Message        : Message_Type;
      Next_Admission : in out Sequence_Number;
      Outcome        : out Push_Outcome)
   is
      Position         : Positive;
      Overwrote        : Boolean;
      Current_Sequence : Sequence_Number;
   begin
      if not Ring.Can_Append
               (Buffers (Producer) (Active).History,
                Capacity,
                Overwrite_When_Full => Overflow = Overwrite_Oldest)
      then
         Buffers (Producer) (Active).Dropped_Total :=
           Ring.Saturating_Increment (Buffers (Producer) (Active).Dropped_Total);
         Outcome := Dropped;
         return;
      end if;

      Position := Ring.Insertion_Index (Buffers (Producer) (Active).History, Capacity);
      Current_Sequence := Next_Admission;
      Buffers (Producer) (Active).Traces (Position) :=
        (Sequence => Current_Sequence, Timestamp => Timestamp, Message => Message);
      Ring.Append (Buffers (Producer) (Active).History, Capacity, Overwrote);
      Next_Admission := Sequence_Number (Ring.Next_Sequence (Next_Admission));
      if Overwrote then
         Buffers (Producer) (Active).Overwrite_Total :=
           Ring.Saturating_Increment (Buffers (Producer) (Active).Overwrite_Total);
         Outcome := Stored_With_Overwrite;
      else
         Outcome := Stored;
      end if;
   end Push_While_Locked;

   protected body Store_Type is
      procedure Initialize (Producer : Producer_Id) is
      begin
         pragma Assert (Owner = 0);
         Owner := Natural (Producer);
      end Initialize;

      procedure Push_Immediate
        (Producer  : Producer_Id;
         Timestamp : Flyology_Debug.Timestamp;
         Message   : Message_Type;
         Outcome   : out Push_Outcome) is
      begin
         if Current_Capture_State = Terminal then
            Outcome := Store_Closed;
            return;
         elsif Current_Capture_State = Paused then
            Outcome := Ignored;
            return;
         end if;

         Push_While_Locked (Producer, Active, Timestamp, Message, Next_Admission, Outcome);
      end Push_Immediate;

      entry Push_Blocking
        (Producer  : Producer_Id;
         Timestamp : Flyology_Debug.Timestamp;
         Message   : Message_Type;
         Outcome   : out Push_Outcome)
        when Owner /= 0
        and then (Current_Capture_State /= Accepting
                  or else not Ring.Is_Full (Buffers (Producer_Id (Owner)) (Active).History, Capacity))
      is
      begin
         if Current_Capture_State = Terminal then
            Outcome := Store_Closed;
            return;
         elsif Current_Capture_State = Paused then
            Outcome := Ignored;
            return;
         end if;

         Push_While_Locked (Producer, Active, Timestamp, Message, Next_Admission, Outcome);
         Block_Capacity_Available (Producer) :=
           not Ring.Is_Full (Buffers (Producer) (Active).History, Capacity);
      end Push_Blocking;

      entry Detach (Producer : Producer_Id; Slot : out Natural) when Spare /= 0 is
      begin
         Slot := Active;
         Active := Slot_Index (Spare);
         Spare := 0;
         Block_Capacity_Available (Producer) := True;
      end Detach;

      procedure Release (Slot : in out Natural) is
      begin
         pragma Assert (Slot in Slot_Index);
         pragma Assert (Spare = 0 or else Spare = Slot);
         Spare := Slot;
         Slot := 0;
      end Release;

      procedure State_Changed is
      begin
         null;
      end State_Changed;
   end Store_Type;

   protected body Capture_Control is
      procedure Enable_State is
      begin
         if Current_Capture_State /= Terminal then
            Current_Capture_State := Accepting;
         end if;
      end Enable_State;

      procedure Disable_State is
      begin
         if Current_Capture_State /= Terminal then
            Current_Capture_State := Paused;
         end if;
      end Disable_State;

      procedure Close_State is
      begin
         Current_Capture_State := Terminal;
      end Close_State;
   end Capture_Control;

   protected body Consumer_Reservations is
      entry Acquire(for Producer in Producer_Id) (Result : in out Batch)
        when not Owned (Producer) and then Acquire_All'Count = 0
      is
      begin
         Owned (Producer) := True;
         Owned_Count := Owned_Count + 1;
         Result.Producer := Natural (Producer);
         Result.Slot := 0;
         Result.Reserved := True;
      end Acquire;

      entry Acquire_All (Result : in out Merged_Batch) when Owned_Count = 0 is
      begin
         Owned := (others => True);
         Owned_Count := Producer_Count;
         Result.Slots := (others => 0);
         Result.Reserved := True;
         Result.Acquired := False;
      end Acquire_All;

      procedure Release (Producer : Producer_Id; Result : in out Batch) is
      begin
         pragma Assert (Owned (Producer));
         Owned (Producer) := False;
         Owned_Count := Owned_Count - 1;
         Result.Producer := 0;
         Result.Reserved := False;
      end Release;

      procedure Release_All (Result : in out Merged_Batch) is
      begin
         pragma Assert (Owned_Count = Producer_Count);
         Owned := (others => False);
         Owned_Count := 0;
         Result.Reserved := False;
         Result.Acquired := False;
      end Release_All;
   end Consumer_Reservations;

   procedure Reset_Buffer (Producer : Producer_Id; Slot : Slot_Index) is
   begin
      Ring.Clear (Buffers (Producer) (Slot).History);
      Buffers (Producer) (Slot).Overwrite_Total := 0;
      Buffers (Producer) (Slot).Dropped_Total := 0;
   end Reset_Buffer;

   procedure Return_Buffer (Result : in out Batch) is
   begin
      if Result.Slot /= 0 then
         declare
            Producer : constant Producer_Id := Required_Producer (Result);
         begin
            Reset_Buffer (Producer, Slot_Index (Result.Slot));
            Stores (Producer).Release (Result.Slot);
         end;
      end if;
      if Result.Reserved then
         Consumer_Reservations.Release (Producer_Id (Result.Producer), Result);
      else
         Result.Producer := 0;
      end if;
   end Return_Buffer;

   procedure Return_Buffers (Result : in out Merged_Batch) is
   begin
      for Producer in Producer_Id loop
         if Result.Slots (Producer) /= 0 then
            Reset_Buffer (Producer, Slot_Index (Result.Slots (Producer)));
            Stores (Producer).Release (Result.Slots (Producer));
         end if;
      end loop;
      if Result.Reserved then
         Consumer_Reservations.Release_All (Result);
      else
         Result.Acquired := False;
      end if;
   end Return_Buffers;

   function Required_Slot (Result : Batch) return Slot_Index is
   begin
      if Result.Slot = 0 then
         raise Constraint_Error with "trace batch is not acquired";
      end if;
      return Slot_Index (Result.Slot);
   end Required_Slot;

   function Required_Producer (Result : Batch) return Producer_Id is
   begin
      if Result.Slot = 0 or else Result.Producer = 0 then
         raise Constraint_Error with "trace batch is not acquired";
      end if;
      return Producer_Id (Result.Producer);
   end Required_Producer;

   function Position_Of (History : Ring.State; Index : Positive) return Positive is
      Offset : constant Natural := Index - 1;
      To_End : constant Natural := Capacity - History.Head;
   begin
      return (if Offset <= To_End then History.Head + Offset else Offset - To_End);
   end Position_Of;

   function Automatic_Producer return Producer_Id is
   begin
      if Producer_Count = 1 then
         return 1;
      end if;

      declare
         Selected : constant Positive := Select_Producer (Producer_Count);
      begin
         if Selected > Producer_Count then
            raise Constraint_Error with "automatic trace producer exceeds Producer_Count";
         end if;
         return Producer_Id (Selected);
      end;
   end Automatic_Producer;

   function Saturating_Add
     (Left : Interfaces.Unsigned_64; Right : Interfaces.Unsigned_64) return Interfaces.Unsigned_64 is
   begin
      if Interfaces.Unsigned_64'Last - Left < Right then
         return Interfaces.Unsigned_64'Last;
      end if;
      return Left + Right;
   end Saturating_Add;

   overriding
   procedure Finalize (Result : in out Batch) is
   begin
      Return_Buffer (Result);
   end Finalize;

   overriding
   procedure Finalize (Result : in out Merged_Batch) is
   begin
      Return_Buffers (Result);
   end Finalize;

   procedure Trace (Message : Message_Type) is
   begin
      case Current_Capture_State is
         when Terminal  =>
            raise Closed_Error with "tracer is closed";

         when Paused    =>
            return;

         when Accepting =>
            null;
      end case;
      Trace (Message, Automatic_Producer);
   end Trace;

   procedure Trace (Message : Message_Type; Producer : Producer_Id) is
      Outcome  : Push_Outcome;
      Observed : constant Capture_State := Current_Capture_State;
   begin
      case Observed is
         when Terminal  =>
            raise Closed_Error with "tracer is closed";

         when Paused    =>
            return;

         when Accepting =>
            null;
      end case;

      if Overflow = Block_Producer then
         Stores (Producer).Push_Blocking (Producer, Now, Message, Outcome);
      else
         Stores (Producer).Push_Immediate (Producer, Now, Message, Outcome);
      end if;
      if Outcome = Store_Closed then
         raise Closed_Error with "tracer is closed";
      end if;
   end Trace;

   procedure Try_Trace (Message : Message_Type; Accepted : out Boolean) is
   begin
      if Current_Capture_State /= Accepting then
         Accepted := False;
         return;
      end if;
      Try_Trace (Message, Accepted, Automatic_Producer);
   end Try_Trace;

   procedure Try_Trace (Message : Message_Type; Accepted : out Boolean; Producer : Producer_Id) is
      Observed : constant Capture_State := Current_Capture_State;
   begin
      if Observed /= Accepting then
         Accepted := False;
         return;
      end if;

      if Overflow = Block_Producer and then not Block_Capacity_Available (Producer) then
         Accepted := False;
         return;
      end if;

      declare
         Captured : constant Flyology_Debug.Timestamp := Now;
         Outcome  : Push_Outcome;
      begin
         if Overflow = Block_Producer then
            select
               Stores (Producer).Push_Blocking (Producer, Captured, Message, Outcome);
               Accepted := Outcome in Stored | Stored_With_Overwrite;
            else
               Accepted := False;
            end select;
         else
            Stores (Producer).Push_Immediate (Producer, Captured, Message, Outcome);
            Accepted := Outcome in Stored | Stored_With_Overwrite;
         end if;
      end;
   end Try_Trace;

   procedure Enable is
   begin
      Capture_Control.Enable_State;
      for Producer in Producer_Id loop
         Stores (Producer).State_Changed;
      end loop;
   end Enable;

   procedure Disable is
   begin
      Capture_Control.Disable_State;
      for Producer in Producer_Id loop
         Stores (Producer).State_Changed;
      end loop;
   end Disable;

   function Is_Enabled return Boolean
   is (Current_Capture_State = Accepting);

   procedure Take (Result : in out Batch) is
   begin
      Take (Result, 1);
   end Take;

   procedure Take (Result : in out Batch; Producer : Producer_Id) is
   begin
      Return_Buffer (Result);
      Consumer_Reservations.Acquire (Producer) (Result);
      Stores (Producer).Detach (Producer, Result.Slot);
   end Take;

   procedure Take_Merged (Result : in out Merged_Batch) is
   begin
      Return_Buffers (Result);
      Consumer_Reservations.Acquire_All (Result);
      for Producer in Producer_Id loop
         Stores (Producer).Detach (Producer, Result.Slots (Producer));
      end loop;
      Result.Acquired := True;
   end Take_Merged;

   procedure Release (Result : in out Batch) is
   begin
      Return_Buffer (Result);
   end Release;

   procedure Release (Result : in out Merged_Batch) is
   begin
      Return_Buffers (Result);
   end Release;

   function Is_Acquired (Result : Batch) return Boolean
   is (Result.Reserved);

   function Is_Acquired (Result : Merged_Batch) return Boolean
   is (Result.Reserved);

   function Producer_Of (Result : Batch) return Producer_Id
   is (Required_Producer (Result));

   procedure Clear is
   begin
      Clear (1);
   end Clear;

   procedure Clear (Producer : Producer_Id) is
      Detached : Batch;
   begin
      Take (Detached, Producer);
   end Clear;

   procedure Close is
   begin
      Capture_Control.Close_State;
      for Producer in Producer_Id loop
         Stores (Producer).State_Changed;
      end loop;
   end Close;

   function Is_Closed return Boolean
   is (Current_Capture_State = Terminal);

   function Trace_Count (Result : Batch) return Natural
   is (Buffers (Required_Producer (Result)) (Required_Slot (Result)).History.Count);

   function Statistics (Result : Batch) return Batch_Statistics is
      Producer : constant Producer_Id := Required_Producer (Result);
      Slot     : constant Slot_Index := Required_Slot (Result);
      History  : Ring.State renames Buffers (Producer) (Slot).History;
   begin
      if History.Count = 0 then
         return
           (Retained       => 0,
            Overwritten    => Buffers (Producer) (Slot).Overwrite_Total,
            Dropped        => Buffers (Producer) (Slot).Dropped_Total,
            Has_Traces     => False,
            First_Sequence => 0,
            Last_Sequence  => 0);
      end if;

      return
        (Retained       => History.Count,
         Overwritten    => Buffers (Producer) (Slot).Overwrite_Total,
         Dropped        => Buffers (Producer) (Slot).Dropped_Total,
         Has_Traces     => True,
         First_Sequence => Buffers (Producer) (Slot).Traces (Position_Of (History, 1)).Sequence,
         Last_Sequence  => Buffers (Producer) (Slot).Traces (Position_Of (History, History.Count)).Sequence);
   end Statistics;

   function Statistics (Result : Merged_Batch) return Merged_Batch_Statistics is
      Aggregate : Merged_Batch_Statistics := (Retained => 0, Overwritten => 0, Dropped => 0);
   begin
      if not Result.Acquired then
         raise Constraint_Error with "merged trace batch is not acquired";
      end if;

      for Producer in Producer_Id loop
         declare
            Slot : constant Slot_Index := Slot_Index (Result.Slots (Producer));
         begin
            Aggregate.Retained :=
              Saturating_Add
                (Aggregate.Retained, Interfaces.Unsigned_64 (Buffers (Producer) (Slot).History.Count));
            Aggregate.Overwritten :=
              Saturating_Add (Aggregate.Overwritten, Buffers (Producer) (Slot).Overwrite_Total);
            Aggregate.Dropped := Saturating_Add (Aggregate.Dropped, Buffers (Producer) (Slot).Dropped_Total);
         end;
      end loop;
      return Aggregate;
   end Statistics;

   function Trace_At (Result : Batch; Index : Positive) return Trace_Record is
      Producer : constant Producer_Id := Required_Producer (Result);
      Slot     : constant Slot_Index := Required_Slot (Result);
      History  : Ring.State renames Buffers (Producer) (Slot).History;
   begin
      if Index > History.Count then
         raise Constraint_Error with "trace index exceeds batch count";
      end if;

      return Buffers (Producer) (Slot).Traces (Position_Of (History, Index));
   end Trace_At;

   function Timestamp_Of (Record_At : Trace_Record) return Timestamp
   is (Record_At.Timestamp);

   function Sequence_Of (Record_At : Trace_Record) return Sequence_Number
   is (Record_At.Sequence);

   function Message_Of (Record_At : Trace_Record) return Message_Type
   is (Record_At.Message);

   procedure Visit
     (Result  : Batch;
      Process :
        not null access procedure
          (Sequence    : Sequence_Number;
           Captured_At : Flyology_Debug.Timestamp;
           Message     : not null access constant Message_Type))
   is
      Producer : constant Producer_Id := Required_Producer (Result);
      Slot     : constant Slot_Index := Required_Slot (Result);
      History  : Ring.State renames Buffers (Producer) (Slot).History;
   begin
      if History.Count > 0 then
         for Index in Positive range 1 .. History.Count loop
            declare
               Record_At : Trace_Record renames
                 Buffers (Producer) (Slot).Traces (Position_Of (History, Index));
            begin
               Process (Record_At.Sequence, Record_At.Timestamp, Record_At.Message'Access);
            end;
         end loop;
      end if;
   end Visit;

   procedure Visit_Merged
     (Result  : Merged_Batch;
      Process :
        not null access procedure
          (Producer    : Producer_Id;
           Sequence    : Sequence_Number;
           Captured_At : Flyology_Debug.Timestamp;
           Message     : not null access constant Message_Type))
   is
      type Cursor_Array is array (Producer_Id) of Natural range 0 .. Capacity;
      subtype Heap_Index is Positive range 1 .. Producer_Count;
      type Heap_Array is array (Heap_Index) of Producer_Id;

      Cursors    : Cursor_Array := (others => 0);
      Heap       : Heap_Array;
      Heap_Count : Natural range 0 .. Producer_Count := 0;

      function Earlier (Left : Producer_Id; Right : Producer_Id) return Boolean is
         Left_Slot    : constant Slot_Index := Slot_Index (Result.Slots (Left));
         Right_Slot   : constant Slot_Index := Slot_Index (Result.Slots (Right));
         Left_Record  : Trace_Record renames
           Buffers (Left) (Left_Slot).Traces
             (Position_Of (Buffers (Left) (Left_Slot).History, Cursors (Left)));
         Right_Record : Trace_Record renames
           Buffers (Right) (Right_Slot).Traces
             (Position_Of (Buffers (Right) (Right_Slot).History, Cursors (Right)));
      begin
         return
           Left_Record.Timestamp < Right_Record.Timestamp
           or else (Left_Record.Timestamp = Right_Record.Timestamp and then Left < Right);
      end Earlier;

      procedure Sift_Down is
         Root  : Heap_Index := 1;
         Child : Natural;
         Best  : Heap_Index;
         Value : Producer_Id;
      begin
         if Heap_Count = 0 then
            return;
         end if;

         Value := Heap (1);
         loop
            Child := 2 * Natural (Root);
            exit when Child > Heap_Count;
            Best := Heap_Index (Child);
            if Child < Heap_Count and then Earlier (Heap (Heap_Index (Child + 1)), Heap (Best)) then
               Best := Heap_Index (Child + 1);
            end if;
            exit when not Earlier (Heap (Best), Value);
            Heap (Root) := Heap (Best);
            Root := Best;
         end loop;
         Heap (Root) := Value;
      end Sift_Down;
   begin
      if not Result.Acquired then
         raise Constraint_Error with "merged trace batch is not acquired";
      end if;

      for Producer in Producer_Id loop
         declare
            Slot : constant Slot_Index := Slot_Index (Result.Slots (Producer));
         begin
            if Buffers (Producer) (Slot).History.Count > 0 then
               Cursors (Producer) := 1;
               Heap_Count := Heap_Count + 1;
               declare
                  Position : Heap_Index := Heap_Index (Heap_Count);
               begin
                  while Position > 1 loop
                     declare
                        Parent : constant Heap_Index := Heap_Index'Max (1, Natural (Position) / 2);
                     begin
                        exit when not Earlier (Producer, Heap (Parent));
                        Heap (Position) := Heap (Parent);
                        Position := Parent;
                     end;
                  end loop;
                  Heap (Position) := Producer;
               end;
            end if;
         end;
      end loop;

      while Heap_Count > 0 loop
         declare
            Producer  : constant Producer_Id := Heap (1);
            Slot      : constant Slot_Index := Slot_Index (Result.Slots (Producer));
            History   : Ring.State renames Buffers (Producer) (Slot).History;
            Record_At : Trace_Record renames
              Buffers (Producer) (Slot).Traces (Position_Of (History, Cursors (Producer)));
         begin
            Process (Producer, Record_At.Sequence, Record_At.Timestamp, Record_At.Message'Access);
            if Cursors (Producer) < History.Count then
               Cursors (Producer) := Cursors (Producer) + 1;
               Sift_Down;
            elsif Heap_Count = 1 then
               Heap_Count := 0;
            else
               Heap (1) := Heap (Heap_Index (Heap_Count));
               Heap_Count := Heap_Count - 1;
               Sift_Down;
            end if;
         end;
      end loop;
   end Visit_Merged;

   function Overwrites (Result : Batch) return Overwrite_Count
   is (Buffers (Required_Producer (Result)) (Required_Slot (Result)).Overwrite_Total);
begin
   for Producer in Producer_Id loop
      Stores (Producer).Initialize (Producer);
   end loop;
end Flyology_Debug.Tracers;
