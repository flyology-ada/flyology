with Flyology.IO;

package body Flyology.Operations is
   package C renames Interfaces.C;

   use type C.int;
   use type Interfaces.Unsigned_64;
   use type Interfaces.Unsigned_32;
   use type System.Address;

   function Bit (Id : Operation_Id) return Interfaces.Unsigned_32 is
     (Interfaces.Shift_Left
        (Interfaces.Unsigned_32 (1), Natural (Id) - 1));

   function Contains
     (Mask : Interfaces.Unsigned_32;
      Id   : Operation_Id) return Boolean is
     ((Mask and Bit (Id)) /= 0);

   function Population
     (Mask : Interfaces.Unsigned_32) return Natural
   is
      Value : Interfaces.Unsigned_32 := Mask;
      Count : Natural := 0;
   begin
      while Value /= 0 loop
         Value := Value and (Value - 1);
         Count := Count + 1;
      end loop;
      return Count;
   end Population;

   procedure Stabilize_Dependents (Set : in out Completion_Set'Class);

   procedure Notify_Terminal
     (Set : in out Completion_Set'Class;
      Id  : Operation_Id)
   is
   begin
      Set.Dirty_Dependents :=
        Set.Dirty_Dependents or Set.Slots (Id).Dependents;
      if Set.Propagation_Batch_Depth = 0
        and then not Set.Stabilizing_Dependents
      then
         Stabilize_Dependents (Set);
      end if;
   end Notify_Terminal;

   procedure Begin_Propagation_Batch (Set : in out Completion_Set) is
   begin
      Set.Propagation_Batch_Depth := Set.Propagation_Batch_Depth + 1;
   end Begin_Propagation_Batch;

   procedure End_Propagation_Batch (Set : in out Completion_Set) is
   begin
      if Set.Propagation_Batch_Depth = 0 then
         raise Operation_Error with "unbalanced propagation batch";
      end if;
      Set.Propagation_Batch_Depth := Set.Propagation_Batch_Depth - 1;
      if Set.Propagation_Batch_Depth = 0
        and then not Set.Stabilizing_Dependents
      then
         Stabilize_Dependents (Set);
      end if;
   end End_Propagation_Batch;

   type Timespec is record
      Seconds     : C.long;
      Nanoseconds : C.long;
   end record
     with Convention => C;

   function Read_Monotonic (Value : access Timespec) return C.int;
   pragma Import (C, Read_Monotonic, "flyology_monotonic_clock");

   function Clock return Duration is
      Now    : aliased Timespec;
      Result : C.int;
   begin
      Result := Read_Monotonic (Now'Access);
      if Result /= 0 then
         raise Operation_Error with "monotonic clock failed";
      end if;
      return
        Duration (Now.Seconds)
        + Duration (Now.Nanoseconds) / 1_000_000_000;
   end Clock;

   function Current_Slot (Item : Operation'Class) return Slot_Record is
   begin
      if Item.Slot = 0 then
         raise Operation_Error with "operation has not been started";
      end if;
      declare
         Slot : constant Slot_Record :=
           Item.Set.Slots (Operation_Id (Item.Slot));
      begin
         if Slot.State = Vacant or else Slot.Generation /= Item.Generation then
            raise Operation_Error with "operation slot is stale";
         end if;
         return Slot;
      end;
   end Current_Slot;

   procedure Register (Item : in out Operation'Class) is
      Owner : Completion_Set'Class renames Item.Set.all;
   begin
      if Item.Slot /= 0 then
         if Owner.Slots (Operation_Id (Item.Slot)).State /= Idle then
            raise Operation_Error with "operation is already active";
         elsif Owner.Slots (Operation_Id (Item.Slot)).Dependents /= 0 then
            raise Operation_Error with
              "referenced operation cannot be restarted";
         end if;
      else
         for Candidate in Owner.Slots'Range loop
            if Owner.Slots (Candidate).State = Vacant then
               Item.Slot := Natural (Candidate);
               Owner.Slots (Candidate).State := Idle;
               exit;
            end if;
         end loop;
         if Item.Slot = 0 then
            raise Capacity_Error with "completion set capacity exhausted";
         end if;
      end if;

      declare
         Slot : Slot_Record renames Owner.Slots (Operation_Id (Item.Slot));
      begin
         if Slot.Generation = Interfaces.Unsigned_64'Last then
            raise Capacity_Error with "operation generation exhausted";
         end if;
         Slot.Generation := Slot.Generation + 1;
         Item.Generation := Slot.Generation;
         Slot.State := Pending;
         Slot.Source := No_Source;
         Slot.Descriptor := -1;
         Slot.For_Write := False;
         Slot.Deadline := Duration'Last;
         Slot.Has_Deadline := False;
         Slot.Result := Succeeded;
         Slot.Reported := False;
         Slot.Owner := Item'Unchecked_Access;
         Slot.Dependents := 0;
         Slot.Internal := False;
         Slot.Child := 0;
         Slot.Child_Generation := 0;
      end;
   end Register;

   procedure Publish_Terminal
     (Item   : in out Operation'Class;
      Result : Terminal_Outcome)
   is
      Id : Operation_Id;
   begin
      if Item.Slot = 0 then
         raise Operation_Error with "operation has not been started";
      end if;
      Id := Operation_Id (Item.Slot);
      declare
         Slot : Slot_Record renames Item.Set.Slots (Id);
      begin
         if Slot.Generation /= Item.Generation
           or else Slot.State /= Pending
         then
            raise Operation_Error with "operation is not pending";
         elsif Slot.Child /= 0 then
            raise Operation_Error with
              "operation cannot complete while a child remains attached";
         end if;
         Slot.State := Terminal;
         Slot.Source := No_Source;
         Slot.Descriptor := -1;
         Slot.Has_Deadline := False;
         Slot.Deadline := Duration'Last;
         Slot.Result := Result;
         Slot.Reported := False;
      end;
      Notify_Terminal (Item.Set.all, Id);
   end Publish_Terminal;

   function Id (Item : Operation'Class) return Natural is (Item.Slot);

   function Reference
     (Item : Operation'Class) return Operation_Reference
   is
      Slot : Slot_Record;
   begin
      if Item.Slot = 0 then
         raise Operation_Error with "operation has not been started";
      end if;
      Slot := Current_Slot (Item);
      if Slot.State not in Pending | Terminal then
         raise Operation_Error with
           "operation has no active or terminal outcome";
      elsif Slot.Internal then
         raise Operation_Error with
           "internal child operations cannot be referenced";
      end if;
      return
        (Set_Address => Item.Set.all'Address,
         Slot        => Item.Slot,
         Generation  => Item.Generation);
   end Reference;

   function Is_Active (Item : Operation'Class) return Boolean is
     (Item.Slot /= 0 and then Current_Slot (Item).State = Pending);

   function Is_Terminal (Item : Operation'Class) return Boolean is
     (Item.Slot /= 0 and then Current_Slot (Item).State = Terminal);

   function Outcome (Item : Operation'Class) return Terminal_Outcome is
     (Current_Slot (Item).Result);

   function Pending_Count (Set : Completion_Set) return Natural is
      Count : Natural := 0;
   begin
      for Slot of Set.Slots loop
         if Slot.State = Pending and then not Slot.Internal then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Pending_Count;

   function Terminal_Count (Set : Completion_Set) return Natural is
      Count : Natural := 0;
   begin
      for Slot of Set.Slots loop
         if Slot.State = Terminal and then not Slot.Internal then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Terminal_Count;

   procedure Detach (Item : in out Gate_Operation) is
      Gate_Id : constant Operation_Id := Operation_Id (Item.Slot);
   begin
      for Member_Id in Operation_Id loop
         if Contains (Item.Members, Member_Id) then
            declare
               Member : Slot_Record renames Item.Set.Slots (Member_Id);
            begin
               if Member.Generation = Item.Generations (Member_Id) then
                  Member.Dependents :=
                    Member.Dependents and not Bit (Gate_Id);
                  if Member.Dependents = 0
                    and then Member.Owner = null
                    and then Member.State = Terminal
                  then
                     declare
                        Generation : constant Interfaces.Unsigned_64 :=
                          Member.Generation;
                     begin
                        Member := (others => <>);
                        Member.Generation := Generation;
                     end;
                  end if;
               end if;
            end;
         end if;
      end loop;
   end Detach;

   procedure Evaluate (Item : in out Gate_Operation) is
      Terminal_Matches : Natural;
      Success_Matches  : Natural;
      Remaining        : Natural;
   begin
      for Member_Id in Operation_Id loop
         if Contains (Item.Members, Member_Id)
           and then not Contains (Item.Seen, Member_Id)
         then
            declare
               Member : Slot_Record renames Item.Set.Slots (Member_Id);
            begin
               if Member.Generation /= Item.Generations (Member_Id) then
                  raise Operation_Error with
                    "gate member generation changed while observed";
               elsif Member.State = Terminal then
                  Item.Seen := Item.Seen or Bit (Member_Id);
                  if Member.Result = Succeeded then
                     Item.Successful :=
                       Item.Successful or Bit (Member_Id);
                  end if;
               elsif Member.State /= Pending then
                  raise Operation_Error with
                    "gate member stopped without a terminal outcome";
               end if;
            end;
         end if;
      end loop;

      Terminal_Matches := Population (Item.Seen);
      Success_Matches := Population (Item.Successful);
      Remaining := Item.Member_Count - Terminal_Matches;

      if (Item.Mode = Terminal_Members
          and then Terminal_Matches >= Item.Required)
        or else
        (Item.Mode = Successful_Members
         and then Success_Matches >= Item.Required)
      then
         Detach (Item);
         Publish_Terminal (Item, Succeeded);
      elsif Item.Mode = Successful_Members
        and then Success_Matches + Remaining < Item.Required
      then
         Detach (Item);
         Publish_Terminal (Item, Failed);
      else
         Item.Set.Slots (Operation_Id (Item.Slot)).Source :=
           Dependency_Source;
      end if;
   end Evaluate;

   overriding procedure Drive
     (Item  : in out Gate_Operation;
      Event : Driver_Event)
   is
      pragma Unreferenced (Event);
   begin
      Evaluate (Item);
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Gate_Operation) is
   begin
      Detach (Item);
      Publish_Terminal (Item, Cancelled);
   end Request_Cancellation;

   procedure Stabilize_Dependents (Set : in out Completion_Set'Class) is
   begin
      if Set.Stabilizing_Dependents then
         return;
      end if;
      Set.Stabilizing_Dependents := True;
      begin
         while Set.Dirty_Dependents /= 0 loop
            for Id in Set.Slots'Range loop
               if Contains (Set.Dirty_Dependents, Id) then
                  Set.Dirty_Dependents :=
                    Set.Dirty_Dependents and not Bit (Id);
                  if Set.Slots (Id).State = Pending then
                     if Set.Slots (Id).Owner = null then
                        raise Operation_Error with
                          "dependent operation has no owner";
                     end if;
                     Drive
                       (Set.Slots (Id).Owner.all, Dependency_Changed);
                  end if;
                  exit;
               end if;
            end loop;
         end loop;
      exception
         when others =>
            Set.Stabilizing_Dependents := False;
            raise;
      end;
      Set.Stabilizing_Dependents := False;
   end Stabilize_Dependents;

   procedure Configure_Gate
     (Item     : in out Gate_Operation;
      Members  : Operation_Reference_Array;
      Mode     : Gate_Mode;
      Required : Positive)
   is
   begin
      if Members'Length = 0 then
         raise Operation_Error with "a gate requires at least one member";
      elsif Members'Length > Max_Operations then
         raise Operation_Error with "too many gate members";
      elsif Required > Members'Length then
         raise Operation_Error with
           "gate threshold exceeds its member count";
      end if;

      Item.Mode := Mode;
      Item.Required := Required;
      Item.Member_Count := Members'Length;
      Item.Members := 0;
      Item.Seen := 0;
      Item.Successful := 0;
      Item.Generations := (others => 0);

      for Position in Members'Range loop
         declare
            Member : Operation_Reference renames Members (Position);
            Member_Id : Operation_Id;
         begin
            if Member.Set_Address /= Item.Set.all'Address then
               raise Operation_Error with
                 "gate member belongs to another completion set";
            elsif Member.Slot = 0 then
               raise Operation_Error with "gate member has not been started";
            end if;
            Member_Id := Operation_Id (Member.Slot);
            if Contains (Item.Members, Member_Id) then
               raise Operation_Error with "duplicate gate member";
            elsif Item.Set.Slots (Member_Id).Generation /= Member.Generation
              or else
                Item.Set.Slots (Member_Id).State not in Pending | Terminal
            then
               raise Operation_Error with
                 "gate member has no active outcome";
            end if;
            Item.Members := Item.Members or Bit (Member_Id);
            Item.Generations (Member_Id) := Member.Generation;
         end;
      end loop;

      Register (Item);
      declare
         Gate_Id : constant Operation_Id := Operation_Id (Item.Slot);
      begin
         for Member_Id in Operation_Id loop
            if Contains (Item.Members, Member_Id)
            then
               Item.Set.Slots (Member_Id).Dependents :=
                 Item.Set.Slots (Member_Id).Dependents or Bit (Gate_Id);
            end if;
         end loop;
      end;

      begin
         Drive (Item, Start_Operation);
      exception
         when others =>
            if Is_Active (Item) then
               Request_Cancellation (Item);
            end if;
            raise;
      end;
   end Configure_Gate;

   function Wait_Some
     (Set      : not null access Completion_Set'Class;
      Members  : Operation_Reference_Array;
      Required : Positive := 1) return Gate_Operation
   is
   begin
      return Result : Gate_Operation (Set) do
         Configure_Gate (Result, Members, Terminal_Members, Required);
      end return;
   end Wait_Some;

   function Wait_All
     (Set     : not null access Completion_Set'Class;
      Members : Operation_Reference_Array) return Gate_Operation
   is
   begin
      if Members'Length = 0 then
         raise Operation_Error with "a gate requires at least one member";
      end if;
      return Result : Gate_Operation (Set) do
         Configure_Gate
           (Result, Members, Terminal_Members, Members'Length);
      end return;
   end Wait_All;

   function Wait_For_Success
     (Set     : not null access Completion_Set'Class;
      Members : Operation_Reference_Array) return Gate_Operation
   is
   begin
      return Result : Gate_Operation (Set) do
         Configure_Gate (Result, Members, Successful_Members, 1);
      end return;
   end Wait_For_Success;

   function Wait_For_Successes
     (Set      : not null access Completion_Set'Class;
      Members  : Operation_Reference_Array;
      Required : Positive) return Gate_Operation
   is
   begin
      return Result : Gate_Operation (Set) do
         Configure_Gate (Result, Members, Successful_Members, Required);
      end return;
   end Wait_For_Successes;

   procedure Finish
     (Item    : in out Gate_Operation;
      Matched : out Completion_Batch)
   is
      Result : Terminal_Outcome;
   begin
      if Matched.Capacity /= Item.Set.Capacity then
         raise Operation_Error with "gate batch capacity does not match set";
      elsif not Is_Terminal (Item) then
         raise Operation_Error with "gate is not terminal";
      end if;
      Result := Outcome (Item);
      Matched.Count := 0;
      Matched.Ids := (others => Operation_Id'First);
      for Member_Id in Operation_Id loop
         if Contains (Item.Seen, Member_Id) then
            Matched.Count := Matched.Count + 1;
            Matched.Ids (Matched.Count) := Member_Id;
         end if;
      end loop;
      Consume (Item);
      if Result = Cancelled then
         raise Operation_Cancelled with "gate operation cancelled";
      end if;
   end Finish;

   procedure Publish_Unreported
     (Set       : in out Completion_Set;
      Completed : out Completion_Batch)
   is
   begin
      Completed.Count := 0;
      Completed.Ids := (others => Operation_Id'First);
      for Id in Set.Slots'Range loop
         if Set.Slots (Id).State = Terminal
           and then not Set.Slots (Id).Internal
           and then not Set.Slots (Id).Reported
         then
            Completed.Count := Completed.Count + 1;
            Completed.Ids (Completed.Count) := Id;
            Set.Slots (Id).Reported := True;
         end if;
      end loop;
   end Publish_Unreported;

   function Unreported_Count (Set : Completion_Set) return Natural is
      Count : Natural := 0;
   begin
      for Slot of Set.Slots loop
         if Slot.State = Terminal
           and then not Slot.Internal
           and then not Slot.Reported
         then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Unreported_Count;

   function Unreported_Success_Count
     (Set : Completion_Set) return Natural
   is
      Count : Natural := 0;
   begin
      for Slot of Set.Slots loop
         if Slot.State = Terminal
           and then not Slot.Internal
           and then not Slot.Reported
           and then Slot.Result = Succeeded
         then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Unreported_Success_Count;

   procedure Expire_Timers (Set : in out Completion_Set) is
      Now : constant Duration := Clock;
   begin
      for Id in Set.Slots'Range loop
         if Set.Slots (Id).State = Pending
           and then Set.Slots (Id).Has_Deadline
           and then Set.Slots (Id).Deadline <= Now
         then
            Set.Slots (Id).Source := No_Source;
            Set.Slots (Id).Descriptor := -1;
            Set.Slots (Id).Has_Deadline := False;
            Set.Slots (Id).Deadline := Duration'Last;
            if Set.Slots (Id).Owner = null then
               raise Operation_Error with "pending operation has no driver";
            end if;
            Drive
              (Set.Slots (Id).Owner.all,
               Deadline_Reached);
         end if;
      end loop;
   end Expire_Timers;

   procedure Wait_Some
     (Set       : in out Completion_Set;
      Completed : out Completion_Batch)
   is
   begin
      Wait_At_Least (Set, 1, Completed);
   end Wait_Some;

   type Gate_Kind is (Terminal_Gate, Success_Gate);

   procedure Wait_For_Gate
     (Set       : in out Completion_Set;
      Required  : Positive;
      Completed : out Completion_Batch;
      Gate      : Gate_Kind)
   is
   begin
      loop
         Begin_Propagation_Batch (Set);
         begin
            Expire_Timers (Set);
         exception
            when others =>
               End_Propagation_Batch (Set);
               raise;
         end;
         End_Propagation_Batch (Set);
         if (case Gate is
                when Terminal_Gate =>
                  Unreported_Count (Set) >= Required
                    or else Pending_Count (Set) = 0,
                when Success_Gate =>
                  Unreported_Success_Count (Set) >= Required
                    or else Unreported_Success_Count (Set)
                      + Pending_Count (Set) < Required)
         then
            Publish_Unreported (Set, Completed);
            return;
         end if;

         declare
            Requests : Flyology.IO.Wait_Request_Array (1 .. Set.Capacity);
            Slot_Map : array (Positive range 1 .. Set.Capacity) of
              Operation_Id;
            Request_Count : Natural := 0;
            Have_Timer : Boolean := False;
            Earliest : Duration := Duration'Last;
         begin
            for Id in Set.Slots'Range loop
               if Set.Slots (Id).State = Pending then
                  case Set.Slots (Id).Source is
                     when Descriptor_Source =>
                        Request_Count := Request_Count + 1;
                        Requests (Request_Count) :=
                          (FD => Set.Slots (Id).Descriptor,
                           Condition =>
                             (if Set.Slots (Id).For_Write
                              then Flyology.IO.For_Write
                              else Flyology.IO.For_Read));
                        Slot_Map (Request_Count) := Id;
                     when Timer_Source =>
                        null;
                     when Dependency_Source =>
                        null;
                     when No_Source =>
                        if not Set.Slots (Id).Has_Deadline then
                           raise Operation_Error with
                             "pending operation has no wait source";
                        end if;
                  end case;
                  if Set.Slots (Id).Has_Deadline
                    and then
                      (not Have_Timer
                       or else Set.Slots (Id).Deadline < Earliest)
                  then
                     Earliest := Set.Slots (Id).Deadline;
                     Have_Timer := True;
                  end if;
               end if;
            end loop;

            if Request_Count = 0 then
               if not Have_Timer then
                  raise Operation_Error with "completion set cannot progress";
               end if;
               declare
                  Remaining : constant Duration := Earliest - Clock;
               begin
                  delay (if Remaining > 0.0 then Remaining else 0.0);
               end;
            else
               declare
                  Ready : Flyology.IO.Wait_Batch (Request_Count);
                  Wait_For : Duration := Flyology.IO.Infinite;
                  Processed : array (Set.Slots'Range) of Boolean :=
                    (others => False);
               begin
                  if Have_Timer then
                     declare
                        Now : constant Duration := Clock;
                     begin
                        if Earliest <= Now then
                           Wait_For := 0.0;
                        else
                           Wait_For := Earliest - Now;
                        end if;
                     end;
                  end if;
                  Flyology.IO.Wait_Some
                    (Requests (1 .. Request_Count), Ready, Wait_For);
                  Begin_Propagation_Batch (Set);
                  begin
                     for Position in 1 .. Ready.Count loop
                        declare
                           Id : constant Operation_Id :=
                             Slot_Map (Ready.Indexes (Position));
                           Descriptor : constant Interfaces.C.int :=
                             Set.Slots (Id).Descriptor;
                           For_Write : constant Boolean :=
                             Set.Slots (Id).For_Write;
                        begin
                           if not Processed (Id) then
                              if Descriptor =
                                Flyology.Wake_Sources.Descriptor (Set.Wake)
                              then
                                 Flyology.Wake_Sources.Consume_All (Set.Wake);
                              end if;

                              --  Readiness is a source notification, not an
                              --  operation identity. Drive every operation
                              --  that armed the same descriptor and direction.
                              for Candidate in Set.Slots'Range loop
                                 if not Processed (Candidate)
                                   and then Set.Slots (Candidate).State =
                                     Pending
                                   and then Set.Slots (Candidate).Source =
                                     Descriptor_Source
                                   and then Set.Slots (Candidate).Descriptor =
                                     Descriptor
                                   and then Set.Slots (Candidate).For_Write =
                                     For_Write
                                 then
                                    Processed (Candidate) := True;
                                    Set.Slots (Candidate).Source := No_Source;
                                    Set.Slots (Candidate).Descriptor := -1;
                                    if Set.Slots (Candidate).Owner = null then
                                       raise Operation_Error with
                                         "pending operation has no driver";
                                    end if;
                                    Drive
                                      (Set.Slots (Candidate).Owner.all,
                                       Source_Ready);
                                 end if;
                              end loop;
                           end if;
                        end;
                     end loop;
                  exception
                     when others =>
                        End_Propagation_Batch (Set);
                        raise;
                  end;
                  End_Propagation_Batch (Set);
               end;
            end if;
         end;
      end loop;
   end Wait_For_Gate;

   procedure Wait_At_Least
     (Set       : in out Completion_Set;
      Required  : Positive;
      Completed : out Completion_Batch)
   is
   begin
      Wait_For_Gate (Set, Required, Completed, Terminal_Gate);
   end Wait_At_Least;

   procedure Wait_Some
     (Set       : in out Completion_Set;
      Required  : Positive;
      Completed : out Completion_Batch)
   is
   begin
      Wait_At_Least (Set, Required, Completed);
   end Wait_Some;

   procedure Wait_For_Success
     (Set       : in out Completion_Set;
      Completed : out Completion_Batch)
   is
   begin
      Wait_For_Successes (Set, 1, Completed);
   end Wait_For_Success;

   procedure Wait_For_Successes
     (Set       : in out Completion_Set;
      Required  : Positive;
      Completed : out Completion_Batch)
   is
   begin
      Wait_For_Gate (Set, Required, Completed, Success_Gate);
   end Wait_For_Successes;

   procedure Wait_All (Set : in out Completion_Set) is
      Ignored : Completion_Batch (Set.Capacity);
   begin
      while Pending_Count (Set) /= 0 loop
         Wait_Some (Set, Ignored);
      end loop;
   end Wait_All;

   procedure Cancel (Item : in out Operation'Class) is
   begin
      if Item.Slot = 0 then
         return;
      end if;
      declare
         Slot : Slot_Record renames
           Item.Set.Slots (Operation_Id (Item.Slot));
      begin
         if Slot.Generation /= Item.Generation then
            raise Operation_Error with "operation slot is stale";
         elsif Slot.State = Pending then
            Request_Cancellation (Item);
         end if;
      end;
   end Cancel;

   procedure Continue_After
     (Parent : in out Operation'Class;
      Child  : in out Operation'Class)
   is
      Parent_Id : Operation_Id;
      Child_Id  : Operation_Id;
   begin
      if Parent.Set.all'Address /= Child.Set.all'Address then
         raise Operation_Error with
           "parent and child belong to different completion sets";
      elsif Parent.Slot = 0 or else Child.Slot = 0 then
         raise Operation_Error with
           "parent and child must both be started";
      elsif Parent.Slot = Child.Slot then
         raise Operation_Error with "operation cannot await itself";
      end if;

      Parent_Id := Operation_Id (Parent.Slot);
      Child_Id := Operation_Id (Child.Slot);
      declare
         Parent_Slot : Slot_Record renames Parent.Set.Slots (Parent_Id);
         Child_Slot  : Slot_Record renames Parent.Set.Slots (Child_Id);
         Cursor      : Natural := Natural (Child_Id);
      begin
         if Parent_Slot.Generation /= Parent.Generation
           or else Parent_Slot.State /= Pending
         then
            raise Operation_Error with "parent operation is not pending";
         elsif Parent_Slot.Child /= 0
           or else Parent_Slot.Source /= No_Source
         then
            raise Operation_Error with
              "parent operation already awaits a source or child";
         elsif Child_Slot.Generation /= Child.Generation
           or else Child_Slot.State not in Pending | Terminal
         then
            raise Operation_Error with
              "child operation has no active outcome";
         elsif Child_Slot.Internal
           or else Child_Slot.Dependents /= 0
           or else Child_Slot.Reported
         then
            raise Operation_Error with
              "child operation is already observed";
         end if;

         --  Each operation has at most one child. Follow that chain before
         --  linking so nested composite providers cannot create a cycle.
         while Parent.Set.Slots (Operation_Id (Cursor)).Child /= 0 loop
            Cursor :=
              Parent.Set.Slots (Operation_Id (Cursor)).Child;
            if Cursor = Natural (Parent_Id) then
               raise Operation_Error with
                 "operation continuation cycle";
            end if;
         end loop;

         Child_Slot.Internal := True;
         Child_Slot.Dependents := Bit (Parent_Id);
         Parent_Slot.Child := Natural (Child_Id);
         Parent_Slot.Child_Generation := Child.Generation;
         Parent_Slot.Source := Dependency_Source;
         if Child_Slot.State = Terminal then
            Notify_Terminal (Parent.Set.all, Child_Id);
         end if;
      end;
   end Continue_After;

   procedure Consume (Item : in out Operation'Class) is
   begin
      if Item.Slot = 0 then
         raise Operation_Error with "operation has not been started";
      end if;
      declare
         Slot : Slot_Record renames
           Item.Set.Slots (Operation_Id (Item.Slot));
      begin
         if Slot.Generation /= Item.Generation
           or else Slot.State /= Terminal
         then
            raise Operation_Error with "operation is not terminal";
         elsif Slot.Dependents /= 0 then
            if not Slot.Internal or else Population (Slot.Dependents) /= 1 then
               raise Operation_Error with
                 "operation still has dependent observers";
            end if;
            declare
               Parent_Id : Operation_Id := Operation_Id'First;
            begin
               for Candidate in Operation_Id loop
                  if Contains (Slot.Dependents, Candidate) then
                     Parent_Id := Candidate;
                     exit;
                  end if;
               end loop;
               declare
                  Parent_Slot : Slot_Record renames
                    Item.Set.Slots (Parent_Id);
               begin
                  if Parent_Slot.State /= Pending
                    or else Parent_Slot.Child /= Item.Slot
                    or else Parent_Slot.Child_Generation /= Item.Generation
                  then
                     raise Operation_Error with
                       "child continuation relation is stale";
                  end if;
                  Parent_Slot.Child := 0;
                  Parent_Slot.Child_Generation := 0;
                  Parent_Slot.Source := No_Source;
                  Slot.Dependents := 0;
               end;
            end;
         end if;
         Slot.State := Idle;
         Slot.Source := No_Source;
         Slot.Descriptor := -1;
         Slot.Has_Deadline := False;
         Slot.Deadline := Duration'Last;
         Slot.Reported := False;
         Slot.Dependents := 0;
      end;
   end Consume;

   procedure Release (Item : in out Operation'Class) is
   begin
      if Item.Slot = 0 then
         raise Operation_Error with "operation has no slot to release";
      end if;
      declare
         Slot : Slot_Record renames
           Item.Set.Slots (Operation_Id (Item.Slot));
         Generation : constant Interfaces.Unsigned_64 := Slot.Generation;
      begin
         if Slot.Generation /= Item.Generation or else Slot.State /= Idle then
            raise Operation_Error with
              "only a consumed operation can release its slot";
         elsif Slot.Dependents /= 0 or else Slot.Child /= 0 then
            raise Operation_Error with
              "operation still participates in composition";
         end if;
         Slot := (others => <>);
         Slot.Generation := Generation;
         Item.Slot := 0;
         Item.Generation := 0;
      end;
   end Release;

   overriding procedure Finalize (Item : in out Operation) is
   begin
      if Item.Slot /= 0 then
         declare
            Slot : Slot_Record renames
              Item.Set.Slots (Operation_Id (Item.Slot));
            Reported : array (Item.Set.Slots'Range) of Boolean;
            Generation : Interfaces.Unsigned_64;
         begin
            if Slot.Generation = Item.Generation then
               if Slot.State = Pending then
                  for Id in Item.Set.Slots'Range loop
                     Reported (Id) := Item.Set.Slots (Id).Reported;
                  end loop;
                  Request_Cancellation
                    (Operation'Class (Item));
                  while Slot.State = Pending loop
                     declare
                        Ignored : Completion_Batch (Item.Set.Capacity);
                     begin
                        Wait_Some (Item.Set.all, Ignored);
                     end;
                     for Id in Item.Set.Slots'Range loop
                        if Operation_Id (Item.Slot) /= Id then
                           Item.Set.Slots (Id).Reported := Reported (Id);
                        end if;
                     end loop;
                  end loop;
               end if;
               Generation := Slot.Generation;
               if Slot.Dependents = 0 then
                  Slot := (others => <>);
                  Slot.Generation := Generation;
               else
                  --  A gate retains the bounded terminal outcome, not the
                  --  finalized provider object. Detach reclaims this
                  --  tombstone after the last observer terminalizes.
                  Slot.Owner := null;
                  Slot.Source := No_Source;
                  Slot.Descriptor := -1;
                  Slot.Has_Deadline := False;
                  Slot.Deadline := Duration'Last;
               end if;
            end if;
         end;
         Item.Slot := 0;
         Item.Generation := 0;
      end if;
   end Finalize;

end Flyology.Operations;
