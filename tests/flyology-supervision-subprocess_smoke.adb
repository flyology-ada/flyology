with Ada.Command_Line;
with Ada.Directories;
with Ada.Streams;
with Flyology.Cancellation;
with Flyology.Subprocesses;
with Flyology.Supervision.Children;
with Interfaces.C;

procedure Flyology.Supervision.Subprocess_Smoke is
   package Subprocesses renames Flyology.Subprocesses;
   package C renames Interfaces.C;

   use type Ada.Streams.Stream_Element_Offset;
   use type C.int;
   function Pid_Exists (Pid : C.int) return C.int;
   pragma Import
     (C, Pid_Exists, "flyology_test_subprocess_pid_exists");

   Fixture : constant String := Ada.Directories.Compose
     (Ada.Directories.Containing_Directory
        (Ada.Directories.Full_Name (Ada.Command_Line.Command_Name)),
      "subprocess_fixture");

   protected type Generation_State is
      procedure Started (Pid : C.int);
      procedure Cleaned;
      function Last_Pid return C.int;
      function Starts return Natural;
      function Cleanups return Natural;
      function Replacement_Order_Valid return Boolean;
   private
      Pid_Value : C.int := -1;
      Count     : Natural := 0;
      Cleanup_Count : Natural := 0;
      Order_Valid   : Boolean := True;
   end Generation_State;

   protected body Generation_State is
      procedure Started (Pid : C.int) is
      begin
         if Cleanup_Count /= Count then
            Order_Valid := False;
         end if;
         Pid_Value := Pid;
         Count := Count + 1;
      end Started;

      procedure Cleaned is
      begin
         Cleanup_Count := Cleanup_Count + 1;
      end Cleaned;

      function Last_Pid return C.int is (Pid_Value);
      function Starts return Natural is (Count);
      function Cleanups return Natural is (Cleanup_Count);
      function Replacement_Order_Valid return Boolean is (Order_Valid);
   end Generation_State;

   type Context is limited record
      State : Generation_State;
   end record;

   procedure Execute
     (State   : in out Context;
      Control : not null access Generation_Control)
   is
      Command : Subprocesses.Command :=
        Subprocesses.To_Command (Fixture);
      Child   : Subprocesses.Process;
      Status  : Subprocesses.Exit_Status;
      Buffer  : Ada.Streams.Stream_Element_Array (1 .. 5);
      Last    : Ada.Streams.Stream_Element_Offset;
   begin
      Subprocesses.Append_Argument (Command, "resistant");
      Subprocesses.Spawn (Command, Child);
      Subprocesses.Read_Standard_Output
        (Child, Buffer, Last, Timeout => 2.0);
      if Last /= Buffer'Last then
         raise Program_Error with "subprocess readiness message incomplete";
      end if;
      State.State.Started (C.int (Subprocesses.Identifier (Child)));
      Mark_Ready (Control.all);
      begin
         Subprocesses.Wait
           (Child, Status, Token => Stopping (Control.all));
      exception
         when Flyology.Cancellation.Operation_Cancelled =>
            Subprocesses.Stop (Child, Grace => 0.020, Status => Status);
            Subprocesses.Close (Child);
            State.State.Cleaned;
            raise;
      end;
      Subprocesses.Close (Child);
   end Execute;

   package Generations is new Flyology.Supervision.Children
     (Application_Context => Context,
      Execute             => Execute,
      Task_Model          => Flyology.Lightweight_Task);

   task type Stopper (Control : not null access Generation_Control);

   task body Stopper is
   begin
      loop
         exit when Is_Ready (Control.all);
         delay 0.001;
      end loop;
      Request_Stop (Control.all, Shutdown => False);
   end Stopper;

   State      : aliased Context;
   Controller : constant Controller_Id := New_Controller;
begin
   for Number in Generation range 1 .. 2 loop
      declare
         Control : aliased Generation_Control;
         Result  : Generation_Result;
      begin
         Open
           (Control,
            (Controller => Controller,
             Id         => 8_001,
             Generation => Number));
         declare
            Requester : Stopper (Control'Access);
         begin
            Generations.Run (State, Control, Result);
         end;
         pragma Assert (Result.Reported_Ready);
         pragma Assert (Result.Termination.Kind = Cancelled);
         pragma Assert (Pid_Exists (State.State.Last_Pid) = 0);
         pragma Assert (State.State.Starts = Natural (Number));
         pragma Assert (State.State.Cleanups = Natural (Number));
         pragma Assert (State.State.Replacement_Order_Valid);
      end;
   end loop;
end Flyology.Supervision.Subprocess_Smoke;
