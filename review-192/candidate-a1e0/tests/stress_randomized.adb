with Ada.Command_Line;
with Ada.Directories;
with Ada.Dynamic_Priorities;
with Ada.Numerics.Discrete_Random;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Flyology;
with Flyology.Execution_Groups;
with Flyology.IO;
with Flyology.IO.Files;
with Flyology.IO.Sockets;
with System;

procedure Stress_Randomized is
   use Ada.Streams;
   use type Ada.Real_Time.Time;
   use type Flyology.Execution_Groups.Group_Id;
   use type Flyology.IO.Files.File_Descriptor;
   use type Flyology.IO.Wait_Outcome;

   package Groups renames Flyology.Execution_Groups;
   package Files renames Flyology.IO.Files;
   package Random_Natural is new Ada.Numerics.Discrete_Random (Natural);

   function Argument (Position : Positive; Default : Positive) return Positive
   is (if Ada.Command_Line.Argument_Count >= Position
       then Positive'Value (Ada.Command_Line.Argument (Position))
       else Default);

   Seed        : constant Positive := Argument (1, 1);
   Batch_Count : constant Positive := Argument (2, 8);
   Width       : constant Positive := Argument (3, 24);
   Path        : constant String := "/tmp/flyology-stress-" & Seed'Image;

   Generator : Random_Natural.Generator;

   protected type Progress (Expected : Positive) is
      procedure Started;
      procedure Done (OK : Boolean);
      entry Await_Started;
      entry Await_Done;
      function Passed return Boolean;
   private
      Started_Count : Natural := 0;
      Done_Count    : Natural := 0;
      All_OK        : Boolean := True;
   end Progress;

   protected body Progress is
      procedure Started is
      begin
         Started_Count := Started_Count + 1;
      end Started;

      procedure Done (OK : Boolean) is
      begin
         Done_Count := Done_Count + 1;
         All_OK := All_OK and OK;
      end Done;

      entry Await_Started when Started_Count = Expected is
      begin
         null;
      end Await_Started;

      entry Await_Done when Done_Count = Expected is
      begin
         null;
      end Await_Done;

      function Passed return Boolean
      is (All_OK);
   end Progress;

   task Lightweight_Server is
      pragma Task_Info (Flyology.Lightweight_Task);
      entry Ping (Value : Natural; Reply : out Natural);
      entry Stop;
   end Lightweight_Server;

   task Native_Server is
      pragma Task_Info (Flyology.Native_Task);
      entry Ping (Value : Natural; Reply : out Natural);
      entry Stop;
   end Native_Server;

   task body Lightweight_Server is
   begin
      loop
         select
            accept Ping (Value : Natural; Reply : out Natural) do
               Reply := Value + 16#5A5A#;
            end Ping;
         or
            accept Stop;
            exit;
         end select;
      end loop;
   end Lightweight_Server;

   task body Native_Server is
   begin
      loop
         select
            accept Ping (Value : Natural; Reply : out Natural) do
               Reply := Value + 16#A5A5#;
            end Ping;
         or
            accept Stop;
            exit;
         end select;
      end loop;
   end Native_Server;

   procedure Exercise_Abort (Ordinal : Positive) is
      task type Abortee (Kind : Flyology.Execution_Model) is
         pragma Task_Info (Kind);
      end Abortee;

      task body Abortee is
      begin
         loop
            delay 0.050;
         end loop;
      end Abortee;

      type Abortee_Access is access Abortee;
      procedure Free_Abortee is new Ada.Unchecked_Deallocation (Abortee, Abortee_Access);
      Victim : Abortee_Access :=
        new Abortee ((if Ordinal mod 2 = 0 then Flyology.Lightweight_Task else Flyology.Native_Task));
      Limit  : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      delay 0.0;
      abort Victim.all;
      while not Victim.all'Terminated loop
         if Ada.Real_Time.Clock >= Limit then
            raise Program_Error with "aborted task did not terminate";
         end if;
         delay 0.001;
      end loop;
      Free_Abortee (Victim);
   end Exercise_Abort;

   File : Files.File_Descriptor := Files.Invalid_File;

begin
   if Width > 512 then
      raise Constraint_Error with "stress width must be at most 512";
   end if;
   Ada.Text_IO.Put_Line
     ("Flyology stress seed=" & Seed'Image & " batches=" & Batch_Count'Image & " width=" & Width'Image);
   Random_Natural.Reset (Generator, Integer (Seed));

   if Ada.Directories.Exists (Path) then
      Ada.Directories.Delete_File (Path);
   end if;
   File := Files.Open (Path, Mode => Files.Read_Write, Create => True, Truncate => True);

   for Batch in 1 .. Batch_Count loop
      declare
         type Socket_Array is array (Positive range <>) of Flyology.IO.Sockets.Socket_Type;
         Readers           : Socket_Array (1 .. Width);
         Peers             : Socket_Array (1 .. Width);
         Interrupt_Readers : Socket_Array (1 .. Width);
         Interrupt_Peers   : Socket_Array (1 .. Width);
         State             : Progress (Width);

         type Natural_Array is array (Positive range <>) of Natural;
         Plans : Natural_Array (1 .. Width);

         task type Worker
           (Index : Positive;
            Kind  : Flyology.Execution_Model;
            Plan  : Natural)
         is
            pragma Task_Info (Kind);
         end Worker;

         task body Worker is
            Reply          : Natural := 0;
            Last           : Stream_Element_Offset;
            Incoming       : Stream_Element_Array (1 .. 1);
            Data           : constant Stream_Element_Array :=
              [1 => Stream_Element ((Plan + Index + Batch) mod 251)];
            Original       : constant System.Any_Priority := Ada.Dynamic_Priorities.Get_Priority;
            Changed        : constant System.Any_Priority :=
              (if Original < System.Any_Priority'Last then Original + 1 else Original - 1);
            Destination    : constant Groups.Shared_Group_Id := Groups.Shared_Group_Id (1 + Plan mod 4);
            Alternate      : constant Groups.Shared_Group_Id := Groups.Shared_Group_Id (1 + (Plan + 1) mod 4);
            Rejected       : Boolean := False;
            OK             : Boolean := True;
            Outcome        : Flyology.IO.Wait_Outcome;
            Will_Interrupt : constant Boolean := Plan mod 3 = 0;
         begin
            Ada.Dynamic_Priorities.Set_Priority (Changed);
            if Flyology.IO.Is_Lightweight_Task then
               Groups.Migrate (Destination);
               declare
                  Pin : Groups.Thread_Pin := Groups.Pin_To_Current_Thread;
                  pragma Unreferenced (Pin);
               begin
                  begin
                     Groups.Migrate (Alternate);
                  exception
                     when Groups.Migration_Error =>
                        Rejected := True;
                  end;
               end;
               OK := Rejected and then Groups.Current = Destination;
               Groups.Migrate (Alternate);
               delay 0.0;
               Groups.Migrate (Destination);
               OK := OK and then Groups.Current = Destination;
               Native_Server.Ping (Plan, Reply);
               OK := OK and then Reply = Plan + 16#A5A5#;
            else
               Lightweight_Server.Ping (Plan, Reply);
               OK := Reply = Plan + 16#5A5A#;
            end if;

            if Plan mod 3 = 0 then
               delay 0.000_1;
            else
               delay 0.0;
            end if;
            OK :=
              OK
              and then Flyology.IO.Wait_Interruptibly
                         (Flyology.IO.Sockets.Native_Descriptor (Readers (Index)),
                          Flyology.IO.For_Read,
                          Timeout    => 0.0,
                          Interrupts =>
                            (1 => Flyology.IO.Sockets.Native_Descriptor (Interrupt_Readers (Index))))
                       = Flyology.IO.Timed_Out;
            State.Started;
            Outcome :=
              Flyology.IO.Wait_Interruptibly
                (Flyology.IO.Sockets.Native_Descriptor (Readers (Index)),
                 Flyology.IO.For_Read,
                 Timeout    => 2.0,
                 Interrupts => (1 => Flyology.IO.Sockets.Native_Descriptor (Interrupt_Readers (Index))));
            if Will_Interrupt then
               OK := OK and then Outcome = Flyology.IO.Interrupted;
            else
               OK := OK and then Outcome = Flyology.IO.Ready;
               Flyology.IO.Sockets.Receive_Exactly (Readers (Index), Incoming, Timeout => 2.0);
               OK := OK and then Incoming (1) = Stream_Element (Plan mod 251);
            end if;

            Files.Write_At (File, Files.File_Offset ((Batch - 1) * Width + Index - 1), Data, Last);
            OK := OK and then Last = Data'Last;
            Ada.Dynamic_Priorities.Set_Priority (Original);
            State.Done (OK);
         exception
            when others =>
               State.Done (False);
         end Worker;

         type Worker_Access is access Worker;
         procedure Free_Worker is new Ada.Unchecked_Deallocation (Worker, Worker_Access);
         Workers : array (1 .. Width) of Worker_Access;
      begin
         for Index in 1 .. Width loop
            Plans (Index) := Random_Natural.Random (Generator) mod 100_000;
            Flyology.IO.Sockets.Create_Socket_Pair (Readers (Index), Peers (Index));
            Flyology.IO.Sockets.Create_Socket_Pair (Interrupt_Readers (Index), Interrupt_Peers (Index));
            Workers (Index) :=
              new Worker
                    (Index,
                     (if (Plans (Index) + Batch) mod 2 = 0
                      then Flyology.Lightweight_Task
                      else Flyology.Native_Task),
                     Plans (Index));
         end loop;

         State.Await_Started;
         for Index in 1 .. Width loop
            if Plans (Index) mod 3 = 0 then
               Flyology.IO.Sockets.Send_All (Interrupt_Peers (Index), [1 => 1], Timeout => 2.0);
            else
               Flyology.IO.Sockets.Send_All
                 (Peers (Index), [1 => Stream_Element (Plans (Index) mod 251)], Timeout => 2.0);
            end if;
         end loop;
         State.Await_Done;
         if not State.Passed then
            raise Program_Error with "mixed-lane batch failed at" & Batch'Image;
         end if;

         for Index in 1 .. Width loop
            while not Workers (Index).all'Terminated loop
               delay 0.001;
            end loop;
            Free_Worker (Workers (Index));
            Flyology.IO.Sockets.Close_Socket (Readers (Index));
            Flyology.IO.Sockets.Close_Socket (Peers (Index));
            Flyology.IO.Sockets.Close_Socket (Interrupt_Readers (Index));
            Flyology.IO.Sockets.Close_Socket (Interrupt_Peers (Index));
         end loop;
      end;

      --  Alternate lanes and allocation addresses across batches. Deleting
      --  the terminated task object forces Finalize_TCB/Destroy and gives the
      --  allocator repeated opportunities to reuse an old ATCB address.
      Exercise_Abort (Batch);
   end loop;

   Files.Close (File);
   Ada.Directories.Delete_File (Path);
   Lightweight_Server.Stop;
   Native_Server.Stop;
   Ada.Text_IO.Put_Line
     ("Flyology stress passed seed=" & Seed'Image & " operations=" & Positive'Image (Batch_Count * Width));
exception
   when others =>
      if File /= Files.Invalid_File then
         Files.Close (File);
      end if;
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
      raise;
end Stress_Randomized;
