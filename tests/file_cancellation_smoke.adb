with Ada.Directories;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Unchecked_Deallocation;
with Gnatevl;
with Gnatevl.IO.Connections;
with Gnatevl.IO.Files;
with Interfaces.C;

procedure File_Cancellation_Smoke is
   package Connections renames Gnatevl.IO.Connections;
   package Files renames Gnatevl.IO.Files;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.C.int;

   Path : constant String := "/tmp/gnatevl-file-cancellation.data";
   File : Files.File_Descriptor := Files.Invalid_File;

   function Open_FD_Count return Interfaces.C.int;
   pragma Import (C, Open_FD_Count, "gnatevl_test_open_fd_count");

   procedure Wait_Terminated
     (Terminated : not null access function return Boolean)
   is
      Limit : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
   begin
      while not Terminated.all loop
         if Ada.Real_Time.Clock >= Limit then
            raise Program_Error with "file cancellation task did not terminate";
         end if;
         delay 0.001;
      end loop;
   end Wait_Terminated;

   procedure Test_Pre_Cancel (Kind : Gnatevl.Execution_Model) is
      Token : aliased Connections.Cancellation_Token;
      Caught : Boolean := False with Atomic;

      task type Worker is
         pragma Task_Info (Kind);
      end Worker;

      task body Worker is
         Data : constant Ada.Streams.Stream_Element_Array := [1 => 1];
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Files.Write_At (File, 0, Data, Last, Token'Access);
      exception
         --  Prove that the connection-qualified compatibility name catches
         --  the canonical exception raised from Files.
         when Connections.Operation_Cancelled => Caught := True;
      end Worker;

      type Worker_Access is access Worker;
      procedure Free is new Ada.Unchecked_Deallocation
        (Worker, Worker_Access);
      Item : Worker_Access;
   begin
      Token.Request;
      Item := new Worker;
      declare
         function Done return Boolean is (Item.all'Terminated);
      begin
         Wait_Terminated (Done'Access);
      end;
      Free (Item);
      if not Caught then
         raise Program_Error with "pre-submission cancellation was ignored";
      end if;
   end Test_Pre_Cancel;

   procedure Test_No_Spurious_Wake_Source is
      Token  : aliased Files.Cancellation_Token;
      Before : Interfaces.C.int;
      After  : Interfaces.C.int;
      Native_Data : constant Ada.Streams.Stream_Element_Array := [1 => 7];
      Native_Last : Ada.Streams.Stream_Element_Offset;
      Event_Done  : Boolean := False with Atomic;

      task type Event_Worker is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Event_Worker;

      task body Event_Worker is
         Empty : Ada.Streams.Stream_Element_Array (1 .. 0);
         Last  : Ada.Streams.Stream_Element_Offset;
      begin
         Files.Read_At (File, 0, Empty, Last, Token'Access);
         Files.Write_At (File, 0, Empty, Last, Token'Access);
         Event_Done := True;
      end Event_Worker;

      type Event_Worker_Access is access Event_Worker;
      procedure Free is new Ada.Unchecked_Deallocation
        (Event_Worker, Event_Worker_Access);
      Worker : Event_Worker_Access;
   begin
      Before := Open_FD_Count;

      --  The environment task is native under the compatibility default.
      --  A real native operation observes the token but cannot wait on it.
      Files.Write_At (File, 0, Native_Data, Native_Last, Token'Access);
      if Native_Last /= Native_Data'Last then
         raise Program_Error with "native file write was incomplete";
      end if;

      --  Null operations are no-ops in both lanes and must not prepare the
      --  token merely because one was supplied.
      Worker := new Event_Worker;
      declare
         function Done return Boolean is (Worker.all'Terminated);
      begin
         Wait_Terminated (Done'Access);
      end;
      Free (Worker);
      if not Event_Done then
         raise Program_Error with "zero-length evented file operation failed";
      end if;

      After := Open_FD_Count;
      if After /= Before then
         raise Program_Error with
           "non-waiting file operation allocated a cancellation descriptor";
      end if;
   end Test_No_Spurious_Wake_Source;

   procedure Test_Completion_Races (Kind : Gnatevl.Execution_Model) is
      Iterations : constant Positive := 64;
      Completed  : Natural := 0;
      Cancelled  : Natural := 0;
   begin
      for Iteration in 1 .. Iterations loop
         declare
            Token : aliased Files.Cancellation_Token;
            Outcome : Natural := 0 with Atomic;

            task type Worker is
               pragma Task_Info (Kind);
            end Worker;

            task body Worker is
               Data : constant Ada.Streams.Stream_Element_Array
                 (1 .. 64 * 1_024) :=
                 (others => Ada.Streams.Stream_Element (Iteration mod 251));
               Last : Ada.Streams.Stream_Element_Offset;
            begin
               Files.Write_At
                 (File,
                  Files.File_Offset ((Iteration - 1) * Data'Length),
                  Data,
                  Last,
                  Token'Access);
               Outcome := (if Last = Data'Last then 1 else 3);
            exception
               --  Prove the inverse cross-qualified compatibility catch.
               when Connections.Operation_Cancelled => Outcome := 2;
               when others => Outcome := 3;
            end Worker;

            type Worker_Access is access Worker;
            procedure Free is new Ada.Unchecked_Deallocation
              (Worker, Worker_Access);
            Item : Worker_Access := new Worker;
         begin
            delay 0.0;
            Token.Request;
            declare
               function Done return Boolean is (Item.all'Terminated);
            begin
               Wait_Terminated (Done'Access);
            end;
            Free (Item);
            case Outcome is
               when 1 => Completed := Completed + 1;
               when 2 => Cancelled := Cancelled + 1;
               when others =>
                  raise Program_Error with
                    "completion/cancellation race lost terminal ownership";
            end case;
         end;
      end loop;
      if Completed + Cancelled /= Iterations then
         raise Program_Error with "file race result accounting is incomplete";
      end if;
   end Test_Completion_Races;

begin
   if Ada.Directories.Exists (Path) then
      Ada.Directories.Delete_File (Path);
   end if;
   File := Files.Open
     (Path, Mode => Files.Read_Write, Create => True, Truncate => True);

   Test_Pre_Cancel (Gnatevl.Native_Thread);
   Test_Pre_Cancel (Gnatevl.Event_Loop_Task);
   Test_No_Spurious_Wake_Source;
   Test_Completion_Races (Gnatevl.Native_Thread);
   Test_Completion_Races (Gnatevl.Event_Loop_Task);

   --  Closing only after every terminal result and then reusing the likely
   --  descriptor number catches stale kernel completions and request reuse.
   Files.Close (File);
   File := Files.Open
     (Path, Mode => Files.Read_Write, Create => False, Truncate => False);
   Files.Close (File);
   Ada.Directories.Delete_File (Path);
exception
   when others =>
      Files.Close (File);
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
      raise;
end File_Cancellation_Smoke;
