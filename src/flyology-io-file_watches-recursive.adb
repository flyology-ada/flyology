with Ada.Directories;
with Ada.Unchecked_Deallocation;
with Flyology.Operations.Drivers;
with GNAT.OS_Lib;

package body Flyology.IO.File_Watches.Recursive is
   use type Ada.Directories.File_Kind;
   use type Flyology.Operations.Driver_Event;
   use type Flyology.Operations.Terminal_Outcome;

   type Candidate_Array is array (Positive range <>) of String_Access;

   procedure Free_String is new Ada.Unchecked_Deallocation
     (String, String_Access);

   procedure Clear_Metadata (Item : in out Recursive_Watcher);
   procedure Discover
     (Root         : String;
      Candidates   : in out Candidate_Array;
      Count        : out Natural;
      Root_Present : out Boolean;
      Complete     : out Boolean);
   procedure Free_Candidates
     (Candidates : in out Candidate_Array);
   function Find_Path
     (Item : Recursive_Watcher'Class; Path : String) return Natural;
   function Has_Candidate
     (Candidates : Candidate_Array;
      Count      : Natural;
      Path       : String) return Boolean;
   procedure Reconcile
     (Item   : in out Recursive_Watcher'Class;
      Result : out Recursive_Event);
   procedure Close_Internal
     (Item           : in out Recursive_Watcher;
      Allow_Borrowed : Boolean);

   procedure Complete_Operation
     (Item   : in out Next_Operation;
      Result : Flyology.Operations.Terminal_Outcome);

   procedure Complete_Operation
     (Item   : in out Next_Operation;
      Result : Flyology.Operations.Terminal_Outcome) is
   begin
      if Item.State.Owns_Borrow and then Item.State.Item /= null then
         Item.State.Item.Scoped_Borrowed := False;
         Item.State.Owns_Borrow := False;
      end if;
      Flyology.Operations.Drivers.Complete (Item, Result);
   end Complete_Operation;

   procedure Finish_Child
     (Item       : in out Next_Operation;
      Raw        : out File_Event;
      Outcome    : out Wait_Outcome;
      Succeeded  : out Boolean;
      Cancelled  : out Boolean)
   is
   begin
      Raw := (Watch => No_Watch, Changes => No_Changes);
      Outcome := Timed_Out;
      Succeeded := False;
      Cancelled := False;
      begin
         File_Watches.Finish (Item.State.Child, Raw, Outcome);
         Succeeded := True;
      exception
         when Flyology.Operations.Operation_Cancelled =>
            Cancelled := True;
         when others =>
            null;
      end;
      Flyology.Operations.Release (Item.State.Child);
      Item.State.Child_Live := False;
   exception
      when others =>
         Item.State.Child_Live := False;
         Succeeded := False;
   end Finish_Child;

   overriding procedure Drive
     (Item  : in out Next_Operation;
      Event : Flyology.Operations.Driver_Event)
   is
      Raw : File_Event;
      Child_Outcome : Wait_Outcome;
      Child_Succeeded : Boolean;
      Child_Cancelled : Boolean;
      Reconciled : Recursive_Event;
   begin
      if Event /= Flyology.Operations.Dependency_Changed
        or else not Item.State.Child_Live
      then
         Item.State.Failure := State_Failure;
         Complete_Operation (Item, Flyology.Operations.Failed);
         return;
      end if;

      Finish_Child
        (Item, Raw, Child_Outcome, Child_Succeeded, Child_Cancelled);
      if Item.State.Cancelling or else Child_Cancelled then
         Complete_Operation (Item, Flyology.Operations.Cancelled);
      elsif not Child_Succeeded then
         Item.State.Failure := Child_Failure;
         Complete_Operation (Item, Flyology.Operations.Failed);
      elsif Child_Outcome = Timed_Out then
         Item.State.Outcome := Timed_Out;
         Complete_Operation (Item, Flyology.Operations.Succeeded);
      else
         begin
            Reconcile (Item.State.Item.all, Reconciled);
            Item.State.Result := Reconciled;
            for Kind in Change_Kind loop
               Item.State.Result.Changes (Kind) :=
                 Item.State.Result.Changes (Kind) or else Raw.Changes (Kind);
            end loop;
            Item.State.Outcome := Ready;
            Complete_Operation (Item, Flyology.Operations.Succeeded);
         exception
            when others =>
               Item.State.Failure := Reconcile_Failure;
               Complete_Operation (Item, Flyology.Operations.Failed);
         end;
      end if;
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Next_Operation) is
   begin
      Item.State.Cancelling := True;
      if Item.State.Child_Live then
         Flyology.Operations.Cancel (Item.State.Child);
      else
         Complete_Operation (Item, Flyology.Operations.Cancelled);
      end if;
   exception
      when others =>
         Item.State.Failure := Child_Failure;
         Complete_Operation (Item, Flyology.Operations.Failed);
   end Request_Cancellation;

   procedure Start_Scoped_Next
     (Item      : not null access Recursive_Watcher'Class;
      Timeout   : Duration;
      Operation : in out Next_Operation)
   is
   begin
      Operation.State.Item := Item.all'Unchecked_Access;
      Operation.State.Result :=
        (Changes               => No_Changes,
         Registrations_Changed => False,
         Directory_Count       => Item.Count,
         Coverage_Complete     => Item.Complete_Coverage);
      Operation.State.Outcome := Timed_Out;
      Operation.State.Failure := No_Failure;
      Operation.State.Child_Live := False;
      Operation.State.Cancelling := False;
      Operation.State.Owns_Borrow := False;
      Flyology.Operations.Drivers.Start (Operation);
      if not Is_Open (Item.all) or else Item.Scoped_Borrowed then
         Operation.State.Failure := State_Failure;
         Complete_Operation (Operation, Flyology.Operations.Failed);
         return;
      end if;

      Item.Scoped_Borrowed := True;
      Operation.State.Owns_Borrow := True;
      File_Watches.Next
        (Item.Source'Unchecked_Access, Timeout, Operation.State.Child);
      Operation.State.Child_Live := True;
      Flyology.Operations.Continue_After (Operation, Operation.State.Child);
   exception
      when others =>
         if Operation.State.Owns_Borrow then
            Item.Scoped_Borrowed := False;
            Operation.State.Owns_Borrow := False;
         end if;
         if Flyology.Operations.Is_Active (Operation.State.Child) then
            Flyology.Operations.Cancel (Operation.State.Child);
         end if;
         if Flyology.Operations.Is_Terminal (Operation.State.Child) then
            declare
               Raw : File_Event;
               Child_Outcome : Wait_Outcome;
            begin
               begin
                  File_Watches.Finish
                    (Operation.State.Child, Raw, Child_Outcome);
               exception
                  when others =>
                     null;
               end;
               if Flyology.Operations.Id (Operation.State.Child) /= 0 then
                  Flyology.Operations.Release (Operation.State.Child);
               end if;
            end;
         end if;
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Start_Scoped_Next;

   function Next
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Recursive_Watcher'Class;
      Timeout : Duration := Infinite) return Next_Operation
   is
   begin
      return Result : Next_Operation (Set) do
         Start_Scoped_Next (Item, Timeout, Result);
      end return;
   end Next;

   procedure Next
     (Item      : not null access Recursive_Watcher'Class;
      Timeout   : Duration := Infinite;
      Operation : in out Next_Operation) is
   begin
      Start_Scoped_Next (Item, Timeout, Operation);
   end Next;

   procedure Finish
     (Operation : in out Next_Operation;
      Result    : out Recursive_Event;
      Outcome   : out Wait_Outcome)
   is
      Terminal : constant Flyology.Operations.Terminal_Outcome :=
        Flyology.Operations.Outcome (Operation);
      Saved_Result : constant Recursive_Event := Operation.State.Result;
      Saved_Outcome : constant Wait_Outcome := Operation.State.Outcome;
      Failure : constant Recursive_Failure := Operation.State.Failure;
   begin
      Flyology.Operations.Consume (Operation);
      case Terminal is
         when Flyology.Operations.Succeeded =>
            Result := Saved_Result;
            Outcome := Saved_Outcome;
         when Flyology.Operations.Cancelled =>
            raise Flyology.Operations.Operation_Cancelled;
         when Flyology.Operations.Failed =>
            case Failure is
               when State_Failure =>
                  raise Device_Error with
                    "recursive watcher is closed or already borrowed";
               when Child_Failure =>
                  raise Device_Error with
                    "recursive watcher readiness wait failed";
               when Reconcile_Failure =>
                  raise Device_Error with
                    "recursive watcher reconciliation failed";
               when No_Failure =>
                  raise Device_Error with
                    "recursive watcher operation failed";
            end case;
      end case;
   end Finish;

   procedure Clear_Metadata (Item : in out Recursive_Watcher) is
   begin
      for Index in Item.Directories'Range loop
         Free_String (Item.Directories (Index).Path);
         Item.Directories (Index).Watch := No_Watch;
      end loop;
      Free_String (Item.Root);
      Item.Count := 0;
      Item.Complete_Coverage := False;
   end Clear_Metadata;

   procedure Free_Candidates
     (Candidates : in out Candidate_Array) is
   begin
      for Candidate of Candidates loop
         Free_String (Candidate);
      end loop;
   end Free_Candidates;

   function Find_Path
     (Item : Recursive_Watcher'Class; Path : String) return Natural is
   begin
      for Index in Item.Directories'Range loop
         if Item.Directories (Index).Path /= null
           and then Item.Directories (Index).Path.all = Path
         then
            return Index;
         end if;
      end loop;
      return 0;
   end Find_Path;

   function Has_Candidate
     (Candidates : Candidate_Array;
      Count      : Natural;
      Path       : String) return Boolean is
   begin
      for Index in Candidates'First .. Candidates'First + Count - 1 loop
         if Candidates (Index) /= null
           and then Candidates (Index).all = Path
         then
            return True;
         end if;
      end loop;
      return False;
   end Has_Candidate;

   procedure Discover
     (Root         : String;
      Candidates   : in out Candidate_Array;
      Count        : out Natural;
      Root_Present : out Boolean;
      Complete     : out Boolean)
   is
      Stop : Boolean := False;

      procedure Visit (Path : String; Is_Root : Boolean := False);

      procedure Visit (Path : String; Is_Root : Boolean := False) is
         Search : Ada.Directories.Search_Type;
         Directory_Entry : Ada.Directories.Directory_Entry_Type;
         Started : Boolean := False;
      begin
         if Stop then
            return;
         elsif not Is_Root and then GNAT.OS_Lib.Is_Symbolic_Link (Path) then
            return;
         end if;

         begin
            if Ada.Directories.Kind (Path) /= Ada.Directories.Directory then
               if Is_Root then
                  Root_Present := False;
               end if;
               return;
            end if;
         exception
            when Ada.Directories.Name_Error =>
               if Is_Root then
                  Root_Present := False;
               else
                  Complete := False;
               end if;
               return;
            when Ada.Directories.Use_Error =>
               Complete := False;
               return;
         end;

         if Count = Candidates'Length then
            Complete := False;
            Stop := True;
            return;
         end if;
         Count := Count + 1;
         Candidates (Candidates'First + Count - 1) := new String'(Path);

         begin
            Ada.Directories.Start_Search
              (Search,
               Directory => Path,
               Pattern   => "",
               Filter    => (Ada.Directories.Directory => True,
                             others => False));
            Started := True;
            while not Stop and then Ada.Directories.More_Entries (Search) loop
               Ada.Directories.Get_Next_Entry (Search, Directory_Entry);
               declare
                  Name : constant String :=
                    Ada.Directories.Simple_Name (Directory_Entry);
               begin
                  if Name /= "." and then Name /= ".." then
                     Visit (Ada.Directories.Full_Name (Directory_Entry));
                  end if;
               end;
            end loop;
            Ada.Directories.End_Search (Search);
         exception
            when Ada.Directories.Name_Error
               | Ada.Directories.Use_Error
               | Ada.Directories.Status_Error =>
               if Started then
                  Ada.Directories.End_Search (Search);
               end if;
               Complete := False;
         end;
      end Visit;
   begin
      Candidates := (others => null);
      Count := 0;
      Root_Present := True;
      Complete := True;
      Visit (Root, Is_Root => True);
   end Discover;

   procedure Open (Item : in out Recursive_Watcher; Root : String) is
      procedure Open_Canonical (Canonical : String);

      procedure Open_Canonical (Canonical : String) is
         Candidates : Candidate_Array (1 .. Item.Capacity) :=
           (others => null);
         Candidate_Count : Natural;
         Root_Present : Boolean;
         Complete : Boolean;
      begin
         if Is_Open (Item) then
            if Item.Root /= null and then Item.Root.all = Canonical then
               return;
            end if;
            raise Device_Error with
              "recursive watcher is already open for another root";
         end if;

         Discover
           (Canonical, Candidates, Candidate_Count, Root_Present, Complete);
         if not Root_Present then
            Free_Candidates (Candidates);
            raise Device_Error with "recursive watch root is not a directory";
         elsif not Complete then
            Free_Candidates (Candidates);
            raise Device_Error with
              "recursive watcher initial discovery is incomplete";
         end if;

         begin
            Item.Source.Open;
            Item.Root := new String'(Canonical);
            for Candidate_Index in
              Candidates'First .. Candidates'First + Candidate_Count - 1
            loop
               declare
                  Slot : Natural := 0;
               begin
                  for Index in Item.Directories'Range loop
                     if Item.Directories (Index).Path = null then
                        Slot := Index;
                        exit;
                     end if;
                  end loop;
                  Item.Directories (Slot).Watch :=
                    Item.Source.Add (Candidates (Candidate_Index).all);
                  Item.Directories (Slot).Path :=
                    Candidates (Candidate_Index);
                  Candidates (Candidate_Index) := null;
                  Item.Count := Item.Count + 1;
               end;
            end loop;
            Item.Complete_Coverage := True;
         exception
            when others =>
               begin
                  Item.Source.Close;
               exception
                  when others =>
                     null;
               end;
               Clear_Metadata (Item);
               Free_Candidates (Candidates);
               raise;
         end;
         Free_Candidates (Candidates);
      exception
         when others =>
            Free_Candidates (Candidates);
            raise;
      end Open_Canonical;
   begin
      if Item.Scoped_Borrowed then
         raise Device_Error with
           "recursive watcher is borrowed by a scoped operation";
      end if;
      Open_Canonical (Ada.Directories.Full_Name (Root));
   exception
      when Ada.Directories.Name_Error | Ada.Directories.Use_Error =>
         raise Device_Error with "recursive watch root is invalid";
   end Open;

   procedure Reconcile
     (Item   : in out Recursive_Watcher'Class;
      Result : out Recursive_Event)
   is
      Candidates : Candidate_Array (1 .. Item.Capacity) := (others => null);
      Candidate_Count : Natural;
      Root_Present : Boolean;
      Complete : Boolean;
      Failed : Boolean := False;
   begin
      Result :=
        (Changes              => No_Changes,
         Registrations_Changed => False,
         Directory_Count       => Item.Count,
         Coverage_Complete     => Item.Complete_Coverage);
      Discover
        (Item.Root.all,
         Candidates,
         Candidate_Count,
         Root_Present,
         Complete);

      if not Root_Present then
         Free_Candidates (Candidates);
         Result.Changes (Identity_Changed) := True;
         Result.Changes (Watch_Invalidated) := True;
         Result.Registrations_Changed := Item.Count > 0;
         Close_Internal
           (Recursive_Watcher (Item), Allow_Borrowed => True);
         Result.Directory_Count := 0;
         Result.Coverage_Complete := False;
         return;
      elsif not Complete then
         Free_Candidates (Candidates);
         Item.Complete_Coverage := False;
         Result.Changes (Events_Lost) := True;
         Result.Directory_Count := Item.Count;
         Result.Coverage_Complete := False;
         return;
      end if;

      for Index in Item.Directories'Range loop
         if Item.Directories (Index).Path /= null
           and then not Has_Candidate
             (Candidates,
              Candidate_Count,
              Item.Directories (Index).Path.all)
         then
            begin
               Item.Source.Remove (Item.Directories (Index).Watch);
            exception
               when Device_Error =>
                  Failed := True;
            end;
            Free_String (Item.Directories (Index).Path);
            Item.Directories (Index).Watch := No_Watch;
            Item.Count := Item.Count - 1;
            Result.Registrations_Changed := True;
         end if;
      end loop;

      for Candidate_Index in
        Candidates'First .. Candidates'First + Candidate_Count - 1
      loop
         if Find_Path (Item, Candidates (Candidate_Index).all) = 0 then
            declare
               Slot : Natural := 0;
            begin
               for Index in Item.Directories'Range loop
                  if Item.Directories (Index).Path = null then
                     Slot := Index;
                     exit;
                  end if;
               end loop;
               begin
                  Item.Directories (Slot).Watch :=
                    Item.Source.Add (Candidates (Candidate_Index).all);
                  Item.Directories (Slot).Path :=
                    Candidates (Candidate_Index);
                  Candidates (Candidate_Index) := null;
                  Item.Count := Item.Count + 1;
                  Result.Registrations_Changed := True;
               exception
                  when Device_Error =>
                     Failed := True;
               end;
            end;
         end if;
      end loop;
      Free_Candidates (Candidates);

      Item.Complete_Coverage := not Failed;
      Result.Directory_Count := Item.Count;
      Result.Coverage_Complete := Item.Complete_Coverage;
      if Failed then
         raise Device_Error with
           "recursive watcher registration reconciliation failed";
      end if;
   exception
      when others =>
         Free_Candidates (Candidates);
         raise;
   end Reconcile;

   procedure Refresh
     (Item   : in out Recursive_Watcher;
      Result : out Recursive_Event) is
   begin
      if Item.Scoped_Borrowed then
         raise Device_Error with
           "recursive watcher is borrowed by a scoped operation";
      elsif not Is_Open (Item) then
         raise Device_Error with "cannot refresh a closed recursive watcher";
      end if;
      Reconcile (Item, Result);
   end Refresh;

   procedure Next
     (Item       : in out Recursive_Watcher;
      Result     : out Recursive_Event;
      Outcome    : out Wait_Outcome;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
   is
      Raw : File_Event;
      Reconciled : Recursive_Event;
   begin
      Result :=
        (Changes              => No_Changes,
         Registrations_Changed => False,
         Directory_Count       => Item.Count,
         Coverage_Complete     => Item.Complete_Coverage);
      if Item.Scoped_Borrowed then
         raise Device_Error with
           "recursive watcher is borrowed by a scoped operation";
      elsif not Is_Open (Item) then
         raise Device_Error with "cannot wait on a closed recursive watcher";
      end if;

      Item.Source.Next (Raw, Outcome, Timeout, Interrupts);
      if Outcome /= Ready then
         return;
      end if;

      Reconcile (Item, Reconciled);
      Result := Reconciled;
      for Kind in Change_Kind loop
         Result.Changes (Kind) :=
           Result.Changes (Kind) or else Raw.Changes (Kind);
      end loop;
   end Next;

   procedure Close_Internal
     (Item           : in out Recursive_Watcher;
      Allow_Borrowed : Boolean)
   is
      Failed : Boolean := False;
   begin
      if Item.Scoped_Borrowed and then not Allow_Borrowed then
         raise Device_Error with
           "recursive watcher is borrowed by a scoped operation";
      end if;
      if not Is_Open (Item) then
         Clear_Metadata (Item);
         return;
      end if;
      begin
         Item.Source.Close;
      exception
         when Device_Error =>
            Failed := True;
      end;
      Clear_Metadata (Item);
      if Failed then
         raise Device_Error with "recursive watcher close failed";
      end if;
   end Close_Internal;

   procedure Close (Item : in out Recursive_Watcher) is
   begin
      Close_Internal (Item, Allow_Borrowed => False);
   end Close;

   function Is_Open (Item : Recursive_Watcher) return Boolean is
     (Item.Source.Is_Open);

   function Directory_Count (Item : Recursive_Watcher) return Natural is
     (Item.Count);

   function Coverage_Is_Complete
     (Item : Recursive_Watcher) return Boolean is
     (Is_Open (Item) and then Item.Complete_Coverage);

   overriding procedure Finalize (Item : in out Recursive_Watcher) is
   begin
      begin
         Close (Item);
      exception
         when others =>
            null;
      end;
   end Finalize;
end Flyology.IO.File_Watches.Recursive;
