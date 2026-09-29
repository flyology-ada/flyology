with Ada.Real_Time;
with Ada.Unchecked_Deallocation;
with Flyology.File_Watch_Native;
with Flyology.File_Watch_Test_Hooks;
with Flyology.Operations.Drivers;
with Flyology.Time_Math;

package body Flyology.IO.File_Watches is
   package Native renames Flyology.File_Watch_Native;

   Native_Batch_Capacity : constant := 256;

   use type Ada.Real_Time.Time;
   use type Interfaces.C.int;
   use type Flyology.Operations.Terminal_Outcome;
   use type Native.Handle;

   procedure Free is new Ada.Unchecked_Deallocation (Watch_Record, Watch_Record_Access);

   function Take_Pending (Item : in out Watcher'Class; Result : out File_Event) return Boolean;
   procedure Pump (Item : in out Watcher'Class);
   procedure Release_All (Item : in out Watcher; Success : out Boolean);

   function Take_Pending (Item : in out Watcher'Class; Result : out File_Event) return Boolean is
      Position : Watch_Record_Access := Item.First;
   begin
      Result := (Watch => No_Watch, Changes => No_Changes);
      while Position /= null loop
         if Position.Pending /= No_Changes then
            Result := (Watch => Position.Id, Changes => Position.Pending);
            Position.Pending := No_Changes;
            return True;
         end if;
         Position := Position.Next;
      end loop;
      return False;
   end Take_Pending;

   procedure Pump (Item : in out Watcher'Class) is
      Events : Native.Raw_Event_Array (1 .. Native_Batch_Capacity);
      Count  : Natural;
   begin
      Native.Read (Item.Native_Source, Events, Count);
      if Flyology.File_Watch_Test_Hooks.Enabled
        and then Flyology.File_Watch_Test_Hooks.Consume_Events_Lost
      then
         if Count < Events'Length then
            Count := Count + 1;
         end if;
         Events (Events'First + Count - 1) :=
           (Subject => Native.Invalid_Handle, Changes => (Events_Lost => True, others => False));
      end if;
      for Index in 1 .. Count loop
         if Events (Index).Subject = Native.Invalid_Handle and then Events (Index).Changes.Events_Lost then
            declare
               Position : Watch_Record_Access := Item.First;
            begin
               while Position /= null loop
                  Position.Pending (Events_Lost) := True;
                  Position := Position.Next;
               end loop;
            end;
         else
            declare
               Position : Watch_Record_Access := Item.First;
            begin
               while Position /= null loop
                  if Position.Subject = Interfaces.C.int (Events (Index).Subject) then
                     Position.Pending (Contents_Changed) :=
                       Position.Pending (Contents_Changed) or else Events (Index).Changes.Contents;
                     Position.Pending (Metadata_Changed) :=
                       Position.Pending (Metadata_Changed) or else Events (Index).Changes.Metadata;
                     Position.Pending (Identity_Changed) :=
                       Position.Pending (Identity_Changed) or else Events (Index).Changes.Identity;
                     Position.Pending (Watch_Invalidated) :=
                       Position.Pending (Watch_Invalidated) or else Events (Index).Changes.Invalidated;
                     Position.Pending (Events_Lost) :=
                       Position.Pending (Events_Lost) or else Events (Index).Changes.Events_Lost;
                  end if;
                  Position := Position.Next;
               end loop;
            end;
         end if;
      end loop;
   end Pump;

   procedure Start_Scoped_Next
     (Item : not null access Watcher'Class; Timeout : Duration; Operation : in out Next_Operation) is
   begin
      Operation.Item := Item.all'Unchecked_Access;
      Operation.Result := (Watch => No_Watch, Changes => No_Changes);
      Operation.Outcome := Timed_Out;
      Operation.Failure := No_Failure;
      Flyology.Operations.Drivers.Start (Operation);

      if not Is_Open (Item.all) or else Item.Count = 0 then
         Operation.Failure := State_Failure;
         Flyology.Operations.Drivers.Complete (Operation, Flyology.Operations.Failed);
      elsif Take_Pending (Item.all, Operation.Result) then
         Operation.Outcome := Ready;
         Flyology.Operations.Drivers.Complete (Operation, Flyology.Operations.Succeeded);
      elsif Timeout = 0.0 then
         Flyology.Operations.Drivers.Complete (Operation, Flyology.Operations.Succeeded);
      else
         if Timeout > 0.0 then
            Flyology.Operations.Drivers.Arm_Deadline (Operation, Timeout);
         end if;
         Flyology.Operations.Drivers.Arm_Readiness (Operation, Item.Native_Source, False);
      end if;
   exception
      when others =>
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Start_Scoped_Next;

   procedure Next
     (Item : not null access Watcher'Class; Timeout : Duration := Infinite; Operation : in out Next_Operation)
   is
   begin
      Start_Scoped_Next (Item, Timeout, Operation);
   end Next;

   function Next
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Watcher'Class;
      Timeout : Duration := Infinite) return Next_Operation is
   begin
      return Result : Next_Operation (Set) do
         Start_Scoped_Next (Item, Timeout, Result);
      end return;
   end Next;

   overriding
   procedure Drive (Item : in out Next_Operation; Event : Flyology.Operations.Driver_Event) is
   begin
      case Event is
         when Flyology.Operations.Start_Operation                                             =>
            raise Program_Error with "watcher operation was already started";

         when Flyology.Operations.Source_Ready                                                =>
            declare
               Available : Boolean;
            begin
               begin
                  Pump (Item.Item.all);
                  Available := Take_Pending (Item.Item.all, Item.Result);
                  if not Available then
                     Flyology.Operations.Drivers.Arm_Readiness (Item, Item.Item.Native_Source, False);
                  end if;
               exception
                  when others =>
                     Item.Failure := Drain_Failure;
                     Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
                     return;
               end;
               if Available then
                  Item.Outcome := Ready;
                  Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Succeeded);
               end if;
            end;

         when Flyology.Operations.Deadline_Reached                                            =>
            Item.Outcome := Timed_Out;
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Succeeded);

         when Flyology.Operations.Dependency_Changed | Flyology.Operations.Continue_Operation =>
            raise Program_Error with "watcher operation received a dependency event";
      end case;
   end Drive;

   overriding
   procedure Request_Cancellation (Item : in out Next_Operation) is
   begin
      Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Cancelled);
   end Request_Cancellation;

   procedure Finish (Operation : in out Next_Operation; Result : out File_Event; Outcome : out Wait_Outcome)
   is
      Terminal      : constant Flyology.Operations.Terminal_Outcome :=
        Flyology.Operations.Outcome (Operation);
      Saved_Result  : constant File_Event := Operation.Result;
      Saved_Outcome : constant Wait_Outcome := Operation.Outcome;
      Failure       : constant Watch_Failure := Operation.Failure;
   begin
      Flyology.Operations.Consume (Operation);
      case Terminal is
         when Flyology.Operations.Succeeded =>
            Result := Saved_Result;
            Outcome := Saved_Outcome;

         when Flyology.Operations.Cancelled =>
            raise Flyology.Operations.Operation_Cancelled;

         when Flyology.Operations.Failed    =>
            case Failure is
               when State_Failure =>
                  raise Device_Error with "cannot wait on a closed or empty file watcher";

               when Drain_Failure =>
                  raise Device_Error with "file watcher event draining failed";

               when No_Failure    =>
                  raise Device_Error with "file watcher operation failed";
            end case;
      end case;
   end Finish;

   procedure Open (Item : in out Watcher) is
   begin
      if not Is_Open (Item) then
         Native.Open (Item.Native_Source);
      end if;
   end Open;

   function Add (Item : in out Watcher; Path : String) return Watch_Id is
      Subject     : Native.Handle;
      Record_Item : Watch_Record_Access;
      Id          : Watch_Id;
   begin
      if not Is_Open (Item) then
         raise Device_Error with "cannot add a path to a closed file watcher";
      elsif Item.Count = Item.Capacity then
         raise Device_Error with "file watcher capacity exhausted";
      elsif Item.Next_Id = No_Watch then
         raise Device_Error with "file watcher identifiers exhausted";
      end if;
      if Path'Length = 0 then
         raise Device_Error with "file watch path is empty";
      end if;
      for Element of Path loop
         if Element = ASCII.NUL then
            raise Device_Error with "file watch path contains NUL";
         end if;
      end loop;

      Id := Item.Next_Id;
      Record_Item :=
        new Watch_Record'
          (Id => Id, Subject => Interfaces.C.int (-1), Pending => No_Changes, Next => Item.First);
      begin
         Subject := Native.Add (Item.Native_Source, Path);
      exception
         when others =>
            Free (Record_Item);
            raise;
      end;
      Record_Item.Subject := Interfaces.C.int (Subject);
      Item.Next_Id := Item.Next_Id + 1;
      Item.First := Record_Item;
      Item.Count := Item.Count + 1;
      return Id;
   end Add;

   procedure Remove (Item : in out Watcher; Id : Watch_Id) is
      Position : Watch_Record_Access := Item.First;
      Previous : Watch_Record_Access := null;
      Other    : Watch_Record_Access;
      Success  : Boolean;
   begin
      if not Is_Open (Item) then
         raise Device_Error with "cannot remove a path from a closed watcher";
      end if;
      while Position /= null and then Position.Id /= Id loop
         Previous := Position;
         Position := Position.Next;
      end loop;
      if Position = null then
         raise Device_Error with "unknown file watch identifier";
      end if;

      Other := Item.First;
      while Other /= null loop
         exit when Other /= Position and then Other.Subject = Position.Subject;
         Other := Other.Next;
      end loop;
      if Other = null then
         Native.Remove (Item.Native_Source, Native.Handle (Position.Subject), Success);
         if Flyology.File_Watch_Test_Hooks.Enabled
           and then Flyology.File_Watch_Test_Hooks.Consume_Remove_Failure
         then
            Success := False;
         end if;
      else
         --  Linux returns the same inotify watch descriptor when aliases or
         --  repeated paths identify one underlying object. Retain it until
         --  the last logical registration is removed.
         Success := True;
      end if;
      if Previous = null then
         Item.First := Position.Next;
      else
         Previous.Next := Position.Next;
      end if;
      Free (Position);
      Item.Count := Item.Count - 1;
      if not Success then
         raise Device_Error with "file watch removal failed";
      end if;
   end Remove;

   procedure Next
     (Item       : in out Watcher;
      Result     : out File_Event;
      Outcome    : out Wait_Outcome;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Waited  : Wait_Outcome;
   begin
      Result := (Watch => No_Watch, Changes => No_Changes);
      if not Is_Open (Item) then
         raise Device_Error with "cannot wait on a closed file watcher";
      elsif Item.Count = 0 then
         raise Device_Error with "cannot wait on a file watcher with no paths";
      elsif Take_Pending (Item, Result) then
         Outcome := Ready;
         return;
      end if;

      loop
         declare
            Elapsed   : constant Duration := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
            Remaining : constant Duration := Flyology.Time_Math.Remaining (Timeout, Elapsed);
         begin
            Waited := Wait_Interruptibly (Item.Native_Source, For_Read, Remaining, Interrupts);
         end;

         if Waited /= Ready then
            Outcome := Waited;
            return;
         end if;
         Pump (Item);
         if Take_Pending (Item, Result) then
            Outcome := Ready;
            return;
         end if;
         --  A removed registration may leave a stale native record. Keep the
         --  caller's original deadline while skipping it.
      end loop;
   end Next;

   procedure Release_All (Item : in out Watcher; Success : out Boolean) is
      Position : Watch_Record_Access := Item.First;
      Victim   : Watch_Record_Access;
      Other    : Watch_Record_Access;
      Removed  : Boolean;
      Closed   : Boolean;
   begin
      Success := True;
      while Position /= null loop
         Victim := Position;
         Position := Position.Next;
         Other := Position;
         while Other /= null loop
            exit when Other.Subject = Victim.Subject;
            Other := Other.Next;
         end loop;
         if Other = null then
            Native.Remove (Item.Native_Source, Native.Handle (Victim.Subject), Removed);
            if Flyology.File_Watch_Test_Hooks.Enabled
              and then Flyology.File_Watch_Test_Hooks.Consume_Remove_Failure
            then
               Removed := False;
            end if;
         else
            --  One Linux inotify registration can back repeated logical
            --  paths. Release the native registration only for its last id.
            Removed := True;
         end if;
         Success := Success and then Removed;
         Free (Victim);
      end loop;
      Item.First := null;
      Item.Count := 0;
      Native.Close (Item.Native_Source, Closed);
      if Flyology.File_Watch_Test_Hooks.Enabled
        and then Flyology.File_Watch_Test_Hooks.Consume_Close_Failure
      then
         Closed := False;
      end if;
      Success := Success and then Closed;
   end Release_All;

   procedure Close (Item : in out Watcher) is
      Success : Boolean;
   begin
      if not Is_Open (Item) then
         return;
      end if;
      Release_All (Item, Success);
      if not Success then
         raise Device_Error with "file watcher close failed";
      end if;
   end Close;

   function Is_Open (Item : Watcher) return Boolean
   is (Item.Native_Source >= 0);

   overriding
   procedure Finalize (Item : in out Watcher) is
      Success : Boolean;
   begin
      if Is_Open (Item) then
         Release_All (Item, Success);
      end if;
   exception
      when others =>
         null;
   end Finalize;
end Flyology.IO.File_Watches;
