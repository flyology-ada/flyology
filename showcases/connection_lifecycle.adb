with Ada.Streams;
with Ada.Text_IO;
with Flyology.IO.Sockets;
with Flyology;
with Flyology.IO.Connections;

procedure Connection_Lifecycle is
   use Ada.Text_IO;
   package Connections renames Flyology.IO.Connections;

   Worker_Count : constant := 5;
   Capacity     : constant := 2;

   type Socket_Array is array (Positive range <>) of Flyology.IO.Sockets.Socket_Type;
   Servers : Socket_Array (1 .. Worker_Count);
   Peers   : Socket_Array (1 .. Worker_Count);
   Manager : aliased Connections.Server (Capacity => Capacity);

   protected State is
      procedure Admitted;
      procedure Cancelled;
      procedure Rejected;
      procedure Finished;
      entry Wait_At_Capacity;
      entry Wait_All;
      function Admitted_Count return Natural;
      function Cancelled_Count return Natural;
      function Rejected_Count return Natural;
   private
      Admissions    : Natural := 0;
      Cancellations : Natural := 0;
      Rejections    : Natural := 0;
      Completions   : Natural := 0;
   end State;

   protected body State is
      procedure Admitted is
      begin
         Admissions := Admissions + 1;
      end Admitted;

      procedure Cancelled is
      begin
         Cancellations := Cancellations + 1;
      end Cancelled;

      procedure Rejected is
      begin
         Rejections := Rejections + 1;
      end Rejected;

      procedure Finished is
      begin
         Completions := Completions + 1;
      end Finished;

      entry Wait_At_Capacity when Admissions = Capacity is
      begin
         null;
      end Wait_At_Capacity;

      entry Wait_All when Completions = Worker_Count is
      begin
         null;
      end Wait_All;

      function Admitted_Count return Natural
      is (Admissions);
      function Cancelled_Count return Natural
      is (Cancellations);
      function Rejected_Count return Natural
      is (Rejections);
   end State;

begin
   for Index in Servers'Range loop
      Flyology.IO.Sockets.Create_Socket_Pair (Servers (Index), Peers (Index));
   end loop;

   declare
      task type Worker (Index : Positive) is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Worker;

      task body Worker is
         Owned    : Connections.Connection;
         Incoming : Ada.Streams.Stream_Element_Array (1 .. 1);
      begin
         begin
            Connections.Take (Manager, Servers (Index), Owned);
            State.Admitted;
            begin
               Owned.Receive_Exactly (Incoming, Cancellation_Quantum => 0.010);
            exception
               when Connections.Operation_Cancelled =>
                  State.Cancelled;
            end;
         exception
            when Connections.Admission_Closed =>
               State.Rejected;
         end;
         State.Finished;
      end Worker;

      type Worker_Access is access Worker;
      type Worker_Array is array (Positive range <>) of Worker_Access;
      Workers : Worker_Array (1 .. Worker_Count);
   begin
      for Index in Workers'Range loop
         Workers (Index) := new Worker (Index);
      end loop;
      State.Wait_At_Capacity;
      delay 0.020;
      Put_Line
        ("bounded server: capacity="
         & Capacity'Image
         & " active="
         & Manager.Active'Image
         & " waiting="
         & Manager.Waiting'Image);

      Manager.Request_Shutdown;
      Manager.Await_Drained;
      State.Wait_All;

      Put_Line
        ("graceful shutdown: admitted="
         & State.Admitted_Count'Image
         & " cancelled="
         & State.Cancelled_Count'Image
         & " rejected_before_accept="
         & State.Rejected_Count'Image);
      Put_Line
        ("drained active="
         & Manager.Active'Image
         & "; limited connection owners closed every admitted socket");
   end;

   for Index in Peers'Range loop
      Flyology.IO.Sockets.Close_Socket (Peers (Index));
      if Flyology.IO.Sockets.Is_Open (Servers (Index)) then
         Flyology.IO.Sockets.Close_Socket (Servers (Index));
      end if;
   end loop;
end Connection_Lifecycle;
