with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Text_IO;
with Flyology;
with Flyology.IO;
with Flyology.IO.File_Watches;

procedure File_Watches_Smoke is
   package Watches renames Flyology.IO.File_Watches;

   pragma Compile_Time_Error
     (Watches.Default_Capacity /= 64,
      "the public default watcher capacity must remain 64");

   use type Flyology.IO.Wait_Outcome;
   use type Watches.Watch_Id;

   Test_Root : constant String :=
     Ada.Environment_Variables.Value
       ("FLYOLOGY_TEST_TEMP_ROOT", "/tmp")
     & "/file-watches-smoke";

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
      Lane_Root : constant String := Test_Root & "/" & Lane;
      Queued_Directory : constant String := Lane_Root & "/queued";
      Delayed_Directory : constant String := Lane_Root & "/delayed";
      Spare_Directory : constant String := Lane_Root & "/spare";
      Original_File : constant String := Lane_Root & "/original.txt";
      Renamed_File  : constant String := Lane_Root & "/renamed.txt";
      Passed : Boolean := False with Atomic;

      task type Observer is
         pragma Task_Info (Kind);
      end Observer;

      task body Observer is
         procedure Require
           (Condition : Boolean; Message : String) is
         begin
            if not Condition then
               raise Program_Error with Lane & ": " & Message;
            end if;
         end Require;

         Result  : Watches.File_Event;
         Outcome : Flyology.IO.Wait_Outcome;
      begin
         --  A capacity discriminant overrides the default without changing
         --  the platform queue or its fixed drain-batch size.
         declare
            Item : Watches.Watcher (Capacity => 1);
            Id   : Watches.Watch_Id;
            Rejected : Boolean := False;
         begin
            Item.Open;
            Id := Item.Add (Queued_Directory);
            begin
               declare
                  Unexpected : constant Watches.Watch_Id :=
                    Item.Add (Spare_Directory);
                  pragma Unreferenced (Unexpected);
               begin
                  null;
               end;
            exception
               when Flyology.IO.Device_Error => Rejected := True;
            end;
            Require (Rejected, "custom capacity did not reject a second path");

            --  Registration is persistent even when no task is waiting.
            Create_File (Queued_Directory & "/queued.txt");
            Item.Next (Result, Outcome, Timeout => 2.0);
            Require (Outcome = Flyology.IO.Ready, "queued event timed out");
            Require (Result.Watch = Id, "queued event used the wrong id");
            Require
              (Result.Changes (Watches.Contents_Changed),
               "queued directory change lacked a contents hint");

            Item.Next (Result, Outcome, Timeout => 0.0);
            Require
              (Outcome = Flyology.IO.Timed_Out,
               "drained watcher remained spuriously ready");
            Item.Remove (Id);
            Item.Close;
            Item.Close;
         end;

         --  Repeated logical registrations may share one Linux inotify watch
         --  descriptor. Each id receives the hint, and removing one must not
         --  remove the remaining registration.
         declare
            Item : Watches.Watcher (Capacity => 2);
            First_Id  : Watches.Watch_Id;
            Second_Id : Watches.Watch_Id;
            Saw_First  : Boolean := False;
            Saw_Second : Boolean := False;
         begin
            Item.Open;
            First_Id := Item.Add (Queued_Directory);
            Second_Id := Item.Add (Queued_Directory);
            Require (First_Id /= Second_Id, "watch ids were reused");
            Create_File (Queued_Directory & "/duplicate-one.txt");
            for Attempt in 1 .. 2 loop
               Item.Next (Result, Outcome, Timeout => 2.0);
               Require
                 (Outcome = Flyology.IO.Ready,
                  "duplicate registration event timed out");
               Saw_First := Saw_First or else Result.Watch = First_Id;
               Saw_Second := Saw_Second or else Result.Watch = Second_Id;
            end loop;
            Require
              (Saw_First and then Saw_Second,
               "duplicate registrations did not both receive the hint");

            Item.Remove (First_Id);
            Create_File (Queued_Directory & "/duplicate-two.txt");
            Item.Next (Result, Outcome, Timeout => 2.0);
            Require
              (Outcome = Flyology.IO.Ready and then Result.Watch = Second_Id,
               "removing one duplicate removed the shared native watch");
            Item.Close;
         end;

         --  Exercise a real wait so a lightweight observer must suspend on
         --  the watcher descriptor while a native observer blocks its pthread.
         declare
            Item : Watches.Watcher;
            Id   : Watches.Watch_Id;

            task Writer is
               entry Start;
            end Writer;
            task body Writer is
            begin
               accept Start;
               delay 0.05;
               Create_File (Delayed_Directory & "/delayed.txt");
            end Writer;
         begin
            Item.Open;
            Require
              (Item.Capacity = Watches.Default_Capacity,
               "default watcher capacity is not 64");
            Id := Item.Add (Delayed_Directory);
            Writer.Start;
            Item.Next (Result, Outcome, Timeout => 2.0);
            Require (Outcome = Flyology.IO.Ready, "delayed event timed out");
            Require (Result.Watch = Id, "delayed event used the wrong id");
            Require
              (Result.Changes (Watches.Contents_Changed),
               "delayed directory change lacked a contents hint");
            Item.Close;
         end;

         --  Moving the watched pathname invalidates the portable association
         --  even though a host may continue observing the same inode/vnode.
         Create_File (Original_File);
         declare
            Item : Watches.Watcher;
            Id   : Watches.Watch_Id;
         begin
            Item.Open;
            Id := Item.Add (Original_File);
            Ada.Directories.Rename (Original_File, Renamed_File);
            Item.Next (Result, Outcome, Timeout => 2.0);
            Require (Outcome = Flyology.IO.Ready, "rename event timed out");
            Require (Result.Watch = Id, "rename event used the wrong id");
            Require
              (Result.Changes (Watches.Identity_Changed),
               "rename lacked an identity hint");
            Require
              (Result.Changes (Watches.Watch_Invalidated),
               "rename did not invalidate the pathname association");
            Item.Remove (Id);
            Item.Close;
         end;
         Passed := True;
      exception
         when Error : others =>
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               Ada.Exceptions.Exception_Information (Error));
            Passed := False;
      end Observer;
   begin
      Reset_Directory (Lane_Root);
      Ada.Directories.Create_Directory (Queued_Directory);
      Ada.Directories.Create_Directory (Delayed_Directory);
      Ada.Directories.Create_Directory (Spare_Directory);
      declare
         Worker : Observer;
      begin
         null;
      end;
      if not Passed then
         raise Program_Error with Lane & " file watcher checks failed";
      end if;
      Ada.Directories.Delete_Tree (Lane_Root);
   end Exercise;
begin
   Reset_Directory (Test_Root);
   Exercise ("native", Flyology.Native_Task);
   Exercise ("lightweight", Flyology.Lightweight_Task);
   Ada.Directories.Delete_Tree (Test_Root);
end File_Watches_Smoke;
