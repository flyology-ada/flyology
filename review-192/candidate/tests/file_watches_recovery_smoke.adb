with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Text_IO;
with Flyology;
with Flyology.IO;
with Flyology.IO.File_Watches;
with Flyology.Wake_Sources;
with Interfaces.C;

procedure File_Watches_Recovery_Smoke is
   package Watches renames Flyology.IO.File_Watches;
   package Wake_Sources renames Flyology.Wake_Sources;

   use type Flyology.IO.Wait_Outcome;
   use type Interfaces.C.int;
   use type Watches.Watch_Id;

   Test_Root : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_TEST_TEMP_ROOT", "/tmp") & "/file-watches-recovery-smoke";

   function Open_FD_Count return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_open_fd_count";

   procedure Reset_Faults
   with Import, Convention => C, External_Name => "flyology_test_file_watch_reset";
   procedure Events_Lost_Once
   with Import, Convention => C, External_Name => "flyology_test_file_watch_events_lost_once";
   procedure Remove_Fail_Once
   with Import, Convention => C, External_Name => "flyology_test_file_watch_remove_fail_once";
   procedure Close_Fail_Once
   with Import, Convention => C, External_Name => "flyology_test_file_watch_close_fail_once";

   procedure Reset_Directory (Path : String) is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_Tree (Path);
      end if;
      Ada.Directories.Create_Path (Path);
   end Reset_Directory;

   procedure Create_File (Path : String) is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      Ada.Text_IO.Put_Line (File, "changed");
      Ada.Text_IO.Close (File);
   end Create_File;

   procedure Exercise (Lane : String; Kind : Flyology.Execution_Model) is
      Lane_Root        : constant String := Test_Root & "/" & Lane;
      First_Directory  : constant String := Lane_Root & "/first";
      Second_Directory : constant String := Lane_Root & "/second";
      Passed           : Boolean := False
      with Atomic;

      task type Observer is
         pragma Task_Info (Kind);
      end Observer;

      task body Observer is
         procedure Require (Condition : Boolean; Message : String) is
         begin
            if not Condition then
               raise Program_Error with Lane & ": " & Message;
            end if;
         end Require;

         Result  : Watches.File_Event;
         Outcome : Flyology.IO.Wait_Outcome;
      begin
         Reset_Faults;

         --  A kernel overflow applies to every logical registration because
         --  no individual path can be proved complete after detail is lost.
         declare
            Item      : Watches.Watcher (Capacity => 2);
            First_Id  : Watches.Watch_Id;
            Second_Id : Watches.Watch_Id;
            Seen      : array (1 .. 2) of Watches.Watch_Id := (others => Watches.No_Watch);
         begin
            Item.Open;
            First_Id := Item.Add (First_Directory);
            Second_Id := Item.Add (Second_Directory);
            Events_Lost_Once;
            Create_File (First_Directory & "/lost-trigger.txt");
            for Index in Seen'Range loop
               Item.Next (Result, Outcome, Timeout => 2.0);
               Require (Outcome = Flyology.IO.Ready, "lost event timed out");
               Require (Result.Changes (Watches.Events_Lost), "lost event did not fan out to a registration");
               Seen (Index) := Result.Watch;
            end loop;
            Require (Seen (1) /= Seen (2), "lost event repeated one id");
            Require
              ((Seen (1) = First_Id or else Seen (2) = First_Id)
               and then (Seen (1) = Second_Id or else Seen (2) = Second_Id),
               "lost event did not cover the complete watched set");
            Item.Close;
         end;

         --  Interruption is level-triggered. Next observes but does not
         --  consume the caller-owned source, so it remains interrupted until
         --  the owner consumes the signal.
         declare
            Item : Watches.Watcher;
            Wake : Wake_Sources.Source;
            Id   : Watches.Watch_Id;
         begin
            Item.Open;
            Id := Item.Add (First_Directory);
            Wake_Sources.Ensure (Wake);
            declare
               Interrupts : constant Flyology.IO.Interrupt_Set := [1 => Wake_Sources.Descriptor (Wake)];

               task Signaler;
               task body Signaler is
               begin
                  delay 0.05;
                  Wake_Sources.Signal (Wake);
               end Signaler;
            begin
               Item.Next (Result, Outcome, Timeout => 2.0, Interrupts => Interrupts);
               Require (Outcome = Flyology.IO.Interrupted, "signaled wait was not interrupted");
               Require (Result.Watch = Watches.No_Watch, "interruption returned a file event");
               Item.Next (Result, Outcome, Timeout => 0.0, Interrupts => Interrupts);
               Require (Outcome = Flyology.IO.Interrupted, "unconsumed interruption did not remain readable");
               Wake_Sources.Consume (Wake);
               Item.Next (Result, Outcome, Timeout => 0.0, Interrupts => Interrupts);
               Require (Outcome = Flyology.IO.Timed_Out, "consumed interruption remained readable");
            end;
            Item.Remove (Id);
            Item.Close;
            Wake_Sources.Release (Wake);
         end;

         --  Repeated add/remove cycles retain increasing logical ids and
         --  return every native descriptor to the process baseline.
         declare
            Before   : constant Interfaces.C.int := Open_FD_Count;
            Item     : Watches.Watcher;
            Previous : Watches.Watch_Id := Watches.No_Watch;
            Id       : Watches.Watch_Id;
         begin
            Item.Open;
            for Round in 1 .. 128 loop
               Id := Item.Add (First_Directory);
               Require (Id > Previous, "watch id did not advance during churn");
               Previous := Id;
               if Round mod 32 = 0 then
                  Create_File (First_Directory & "/churn-" & Round'Image & ".txt");
                  Item.Next (Result, Outcome, Timeout => 2.0);
                  Require
                    (Outcome = Flyology.IO.Ready and then Result.Watch = Id,
                     "re-added watch did not receive a change");
               end if;
               Item.Remove (Id);
            end loop;
            Item.Close;
            Require (Open_FD_Count = Before, "add/remove churn leaked a descriptor");
         end;

         --  Repeated Linux paths share one inotify handle. Close must remove
         --  that handle once while retiring both logical registrations.
         declare
            Before    : constant Interfaces.C.int := Open_FD_Count;
            Item      : Watches.Watcher (Capacity => 2);
            First_Id  : Watches.Watch_Id;
            Second_Id : Watches.Watch_Id;
         begin
            Item.Open;
            First_Id := Item.Add (Second_Directory);
            Second_Id := Item.Add (Second_Directory);
            Require (First_Id /= Second_Id, "duplicate ids were reused");
            Item.Close;
            Require (Open_FD_Count = Before, "duplicate-registration close leaked a descriptor");
         end;

         --  A reported removal failure still retires the logical id after the
         --  native cleanup attempt. The owner can continue and close safely.
         declare
            Before         : constant Interfaces.C.int := Open_FD_Count;
            Item           : Watches.Watcher;
            Id             : Watches.Watch_Id;
            Raised         : Boolean := False;
            Unknown_Raised : Boolean := False;
         begin
            Item.Open;
            Id := Item.Add (First_Directory);
            Remove_Fail_Once;
            begin
               Item.Remove (Id);
            exception
               when Flyology.IO.Device_Error =>
                  Raised := True;
            end;
            Require (Raised, "injected remove failure was not reported");
            begin
               Item.Remove (Id);
            exception
               when Flyology.IO.Device_Error =>
                  Unknown_Raised := True;
            end;
            Require (Unknown_Raised, "failed removal retained its logical id");
            Item.Close;
            Require (Open_FD_Count = Before, "reported remove failure leaked a descriptor");
         end;

         --  Close invalidates the watcher and releases resources even when a
         --  native removal or queue close reports failure.
         for Failure in 1 .. 2 loop
            declare
               Before : constant Interfaces.C.int := Open_FD_Count;
               Item   : Watches.Watcher;
               Id     : Watches.Watch_Id;
               Raised : Boolean := False;
            begin
               Item.Open;
               Id := Item.Add (Second_Directory);
               Require (Id /= Watches.No_Watch, "close test add failed");
               if Failure = 1 then
                  Remove_Fail_Once;
               else
                  Close_Fail_Once;
               end if;
               begin
                  Item.Close;
               exception
                  when Flyology.IO.Device_Error =>
                     Raised := True;
               end;
               Require (Raised, "injected close cleanup failure was hidden");
               Require (not Item.Is_Open, "failed close left watcher open");
               Item.Close;
               Require (Open_FD_Count = Before, "reported close cleanup failure leaked a descriptor");
            end;
         end loop;

         --  Controlled finalization remains nonraising while taking the same
         --  cleanup path and consuming both injected failure reports.
         declare
            Before : constant Interfaces.C.int := Open_FD_Count;
         begin
            declare
               Item : Watches.Watcher;
               Id   : Watches.Watch_Id;
            begin
               Item.Open;
               Id := Item.Add (First_Directory);
               Require (Id /= Watches.No_Watch, "finalizer test add failed");
               Remove_Fail_Once;
               Close_Fail_Once;
            end;
            Require (Open_FD_Count = Before, "nonraising finalization leaked a descriptor");
         end;

         Reset_Faults;
         Passed := True;
      exception
         when Error : others =>
            Reset_Faults;
            Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Ada.Exceptions.Exception_Information (Error));
            Passed := False;
      end Observer;
   begin
      Reset_Directory (Lane_Root);
      Ada.Directories.Create_Directory (First_Directory);
      Ada.Directories.Create_Directory (Second_Directory);
      declare
         Worker : Observer;
      begin
         null;
      end;
      if not Passed then
         raise Program_Error with Lane & " file watcher recovery checks failed";
      end if;
      Ada.Directories.Delete_Tree (Lane_Root);
   end Exercise;
begin
   Reset_Directory (Test_Root);
   Exercise ("native", Flyology.Native_Task);
   Exercise ("lightweight", Flyology.Lightweight_Task);
   Ada.Directories.Delete_Tree (Test_Root);
end File_Watches_Recovery_Smoke;
