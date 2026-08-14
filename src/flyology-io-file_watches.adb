with Ada.Real_Time;
with Ada.Unchecked_Deallocation;
with Flyology.File_Watch_Native;
with Flyology.File_Watch_Test_Hooks;
with Flyology.Time_Math;

package body Flyology.IO.File_Watches is
   package Native renames Flyology.File_Watch_Native;

   Native_Batch_Capacity : constant := 256;

   use type Ada.Real_Time.Time;
   use type Interfaces.C.int;
   use type Native.Handle;

   procedure Free is new Ada.Unchecked_Deallocation
     (Watch_Record, Watch_Record_Access);

   function Take_Pending
     (Item : in out Watcher; Result : out File_Event) return Boolean;
   procedure Pump (Item : in out Watcher);
   procedure Release_All (Item : in out Watcher; Success : out Boolean);

   function Take_Pending
     (Item : in out Watcher; Result : out File_Event) return Boolean
   is
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

   procedure Pump (Item : in out Watcher) is
      Events : Native.Raw_Event_Array (1 .. Native_Batch_Capacity);
      Count  : Natural;
   begin
      Native.Read (Item.Native_Source, Events, Count);
      if Flyology.File_Watch_Test_Hooks.Consume_Events_Lost then
         if Count < Events'Length then
            Count := Count + 1;
         end if;
         Events (Events'First + Count - 1) :=
           (Subject => Native.Invalid_Handle,
            Changes => (Events_Lost => True, others => False));
      end if;
      for Index in 1 .. Count loop
         if Events (Index).Subject = Native.Invalid_Handle
           and then Events (Index).Changes.Events_Lost
         then
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
                  if Position.Subject =
                    Interfaces.C.int (Events (Index).Subject)
                  then
                     Position.Pending (Contents_Changed) :=
                       Position.Pending (Contents_Changed)
                       or else Events (Index).Changes.Contents;
                     Position.Pending (Metadata_Changed) :=
                       Position.Pending (Metadata_Changed)
                       or else Events (Index).Changes.Metadata;
                     Position.Pending (Identity_Changed) :=
                       Position.Pending (Identity_Changed)
                       or else Events (Index).Changes.Identity;
                     Position.Pending (Watch_Invalidated) :=
                       Position.Pending (Watch_Invalidated)
                       or else Events (Index).Changes.Invalidated;
                     Position.Pending (Events_Lost) :=
                       Position.Pending (Events_Lost)
                       or else Events (Index).Changes.Events_Lost;
                  end if;
                  Position := Position.Next;
               end loop;
            end;
         end if;
      end loop;
   end Pump;

   procedure Open (Item : in out Watcher) is
   begin
      if not Is_Open (Item) then
         Native.Open (Item.Native_Source);
      end if;
   end Open;

   function Add (Item : in out Watcher; Path : String) return Watch_Id is
      Subject : Native.Handle;
      Record_Item : Watch_Record_Access;
      Id : Watch_Id;
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
          (Id      => Id,
           Subject => Interfaces.C.int (-1),
           Pending => No_Changes,
           Next    => Item.First);
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
         exit when Other /= Position
           and then Other.Subject = Position.Subject;
         Other := Other.Next;
      end loop;
      if Other = null then
         Native.Remove
           (Item.Native_Source, Native.Handle (Position.Subject), Success);
         if Flyology.File_Watch_Test_Hooks.Consume_Remove_Failure then
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
            Elapsed : constant Duration :=
              Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
            Remaining : constant Duration :=
              Flyology.Time_Math.Remaining (Timeout, Elapsed);
         begin
            Waited :=
              Wait_Interruptibly
                (Item.Native_Source,
                 For_Read,
                 Remaining,
                 Interrupts);
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
            Native.Remove
              (Item.Native_Source, Native.Handle (Victim.Subject), Removed);
            if Flyology.File_Watch_Test_Hooks.Consume_Remove_Failure then
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
      if Flyology.File_Watch_Test_Hooks.Consume_Close_Failure then
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

   function Is_Open (Item : Watcher) return Boolean is
     (Item.Native_Source >= 0);

   overriding procedure Finalize (Item : in out Watcher) is
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
