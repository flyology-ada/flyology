with Ada.Streams;
with GNAT.Sockets;
with Gnatevl;
with Gnatevl.Execution_Groups;
with Gnatevl.IO;
with Interfaces.C;

procedure Sanitizer_Fiber_Smoke is
   package Groups renames Gnatevl.Execution_Groups;

   use type Ada.Streams.Stream_Element_Offset;
   use type Groups.Group_Id;
   use type Gnatevl.IO.Wait_Outcome;
   use type Interfaces.C.unsigned;

   Worker_Count : constant Positive := 12;
   Result_Count : constant Positive := Worker_Count + 1;

   Primary_Reader, Primary_Writer     : GNAT.Sockets.Socket_Type;
   Interrupt_Reader, Interrupt_Writer : GNAT.Sockets.Socket_Type;

   function Touch_Stack
     (Seed  : Interfaces.C.unsigned;
      Depth : Interfaces.C.unsigned) return Interfaces.C.unsigned;
   pragma Import (C, Touch_Stack, "gnatevl_sanitizer_touch_stack");

   protected Results is
      procedure Finished (Passed : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Count : Natural := 0;
      OK    : Boolean := True;
   end Results;

   protected body Results is
      procedure Finished (Passed : Boolean) is
      begin
         Count := Count + 1;
         OK := OK and Passed;
      end Finished;

      entry Wait when Count = Result_Count is
      begin
         null;
      end Wait;

      function Passed return Boolean is (OK);
   end Results;

   task type Worker (Index : Positive) with CPU => 1 is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
      pragma Storage_Size (64 * 1_024);
   end Worker;

   task body Worker is
      Value : Interfaces.C.unsigned := Interfaces.C.unsigned (Index);
      OK    : Boolean := True;
   begin
      for Round in 1 .. 30 loop
         Value := Touch_Stack (Value, 5);
         delay 0.0;
         Groups.Migrate (2);
         OK := OK and Groups.Current = 2;
         delay 0.001;
         Value := Touch_Stack (Value, 3);
         Groups.Migrate (1);
         OK := OK and Groups.Current = 1;
      end loop;
      Results.Finished (OK and Value /= 0);
   exception
      when others =>
         Results.Finished (False);
   end Worker;

   task type Interruptible_Waiter is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
      pragma Storage_Size (64 * 1_024);
   end Interruptible_Waiter;

   task body Interruptible_Waiter is
      Outcome : Gnatevl.IO.Wait_Outcome;
   begin
      Outcome := Gnatevl.IO.Wait_Interruptibly
        (Gnatevl.IO.Descriptor (GNAT.Sockets.To_C (Primary_Reader)),
         Gnatevl.IO.For_Read,
         Timeout => 5.0,
         Interrupt_1 =>
           Gnatevl.IO.Descriptor (GNAT.Sockets.To_C (Interrupt_Reader)));
      Results.Finished (Outcome = Gnatevl.IO.Interrupted);
   exception
      when others =>
         Results.Finished (False);
   end Interruptible_Waiter;

   type Worker_Access is access Worker;
   type Waiter_Access is access Interruptible_Waiter;
   Workers : array (1 .. Worker_Count) of Worker_Access;
begin
   GNAT.Sockets.Create_Socket_Pair (Primary_Reader, Primary_Writer);
   GNAT.Sockets.Create_Socket_Pair (Interrupt_Reader, Interrupt_Writer);
   for Index in Workers'Range loop
      Workers (Index) := new Worker (Index);
   end loop;
   declare
      Waiter : constant Waiter_Access := new Interruptible_Waiter;
      Data   : constant Ada.Streams.Stream_Element_Array (1 .. 1) :=
        [1 => 42];
      Last   : Ada.Streams.Stream_Element_Offset;
      pragma Unreferenced (Waiter);
   begin
      delay 0.050;
      GNAT.Sockets.Send_Socket (Interrupt_Writer, Data, Last);
      pragma Assert (Last = Data'Last);
   end;
   Results.Wait;
   pragma Assert (Results.Passed, "sanitized fiber migration failed");
   GNAT.Sockets.Close_Socket (Primary_Reader);
   GNAT.Sockets.Close_Socket (Primary_Writer);
   GNAT.Sockets.Close_Socket (Interrupt_Reader);
   GNAT.Sockets.Close_Socket (Interrupt_Writer);
end Sanitizer_Fiber_Smoke;
