with Ada.Real_Time;
with Ada.Streams;
with GNAT.Sockets;
with Gnatevl;
with Gnatevl.IO.Sockets;
with Gnatevl.IO.Timers;

procedure IO_Starvation_Smoke is
   use Ada.Real_Time;
   use Ada.Streams;

   Reader_Socket : GNAT.Sockets.Socket_Type;
   Writer_Socket : GNAT.Sockets.Socket_Type;
   Payload       : constant Stream_Element_Array := [1 => 42];

   protected Results is
      procedure Reader_Finished (Passed : Boolean);
      procedure Writer_Finished (Passed : Boolean);
      entry Wait;
      function Stop_Spinner return Boolean;
      function Passed return Boolean;
   private
      Reader_Done : Boolean := False;
      Writer_Done : Boolean := False;
      Reader_OK   : Boolean := False;
      Writer_OK   : Boolean := False;
   end Results;

   protected body Results is
      procedure Reader_Finished (Passed : Boolean) is
      begin
         Reader_OK := Passed;
         Reader_Done := True;
      end Reader_Finished;

      procedure Writer_Finished (Passed : Boolean) is
      begin
         Writer_OK := Passed;
         Writer_Done := True;
      end Writer_Finished;

      entry Wait when Reader_Done and Writer_Done is
      begin
         null;
      end Wait;

      function Stop_Spinner return Boolean is (Reader_Done);
      function Passed return Boolean is (Reader_OK and Writer_OK);
   end Results;

begin
   GNAT.Sockets.Create_Socket_Pair (Reader_Socket, Writer_Socket);

   declare
      task Spinner is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Spinner;

      task Reader is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Reader;
      task Writer is
         pragma Task_Info (Gnatevl.Native_Thread);
      end Writer;

      task body Spinner is
      begin
         while not Results.Stop_Spinner loop
            delay 0.0;
         end loop;
      end Spinner;

      task body Reader is
         Incoming : Stream_Element_Array (Payload'Range);
         Started  : constant Time := Clock;
         Elapsed  : Duration;
      begin
         Gnatevl.IO.Sockets.Receive_Exactly
           (Reader_Socket, Incoming, Timeout => 1.0);
         Elapsed := To_Duration (Clock - Started);
         Results.Reader_Finished
           (Incoming = Payload and then Elapsed < 0.5);
      exception
         when others =>
            Results.Reader_Finished (False);
      end Reader;

      task body Writer is
      begin
         Gnatevl.IO.Timers.Sleep_For (0.050);
         Gnatevl.IO.Sockets.Send_All
           (Writer_Socket, Payload, Timeout => 1.0);
         Results.Writer_Finished (True);
      exception
         when others =>
            Results.Writer_Finished (False);
      end Writer;
   begin
      Results.Wait;
   end;

   GNAT.Sockets.Close_Socket (Reader_Socket);
   GNAT.Sockets.Close_Socket (Writer_Socket);

   if not Results.Passed then
      raise Program_Error with
        "descriptor readiness was starved by a yielding ready task";
   end if;
end IO_Starvation_Smoke;
