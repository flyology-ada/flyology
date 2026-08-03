with Ada.Real_Time;
with Ada.Streams;
with Ada.Unchecked_Deallocation;
with GNAT.Sockets;
with Flyology;
with Flyology.Execution_Groups;
with Flyology.IO.Connections;
with Flyology.IO.Connections.Testing;
with Flyology.IO.Sockets;
with Flyology.Observability;
with Interfaces;
with Interfaces.C;

procedure Descriptor_Ownership_Smoke is
   package Connections renames Flyology.IO.Connections;
   package Connection_Testing renames Flyology.IO.Connections.Testing;
   package Sockets renames GNAT.Sockets;

   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Real_Time.Time;
   use type Flyology.Execution_Model;
   use type Connection_Testing.Barrier_Point;
   use type Flyology.Observability.Counter;
   use type Interfaces.C.int;
   use type Sockets.Error_Type;
   use type Sockets.Socket_Type;

   function C_Dup (FD : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "dup";

   procedure Assert_No_Event_Waits is
      Sample : Flyology.Observability.Group_Snapshot;
   begin
      pragma Assert (Flyology.Observability.Snapshot (0, Sample));
      pragma Assert (Sample.Descriptor_Waits = 0);
      pragma Assert (Sample.Interrupt_Waits = 0);
   end Assert_No_Event_Waits;

   procedure Await_Event_Waits
     (Count : Natural;
      Group : Flyology.Execution_Groups.Group_Id := 0)
   is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      Sample : Flyology.Observability.Group_Snapshot;
   begin
      loop
         if Flyology.Observability.Snapshot (Group, Sample) then
            exit when Sample.Descriptor_Waits =
              Flyology.Observability.Counter (Count);
         end if;
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "descriptor wait did not reach poller";
         end if;
         delay 0.001;
      end loop;
   end Await_Event_Waits;

   procedure Await_Bytes
     (Socket : Sockets.Socket_Type;
      Count  : Natural)
   is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      Request : Sockets.Request_Type (Sockets.N_Bytes_To_Read);
   begin
      loop
         Sockets.Control_Socket (Socket, Request);
         exit when Request.Size = Count;
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "socket byte count did not converge";
         end if;
         delay 0.001;
      end loop;
   end Await_Bytes;

   procedure Await_Operation_Waiter (Item : Connections.Connection) is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while Connection_Testing.Waiting_Operations (Item) = 0 loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with
              "connection operation did not queue at Acquire";
         end if;
         delay 0.001;
      end loop;
   end Await_Operation_Waiter;

   procedure Await_Operation_Active
     (Item : Connections.Connection;
      Expected : Boolean := True)
   is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while Connection_Testing.Operation_Active (Item) /= Expected loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with
              "connection active-owner state did not converge";
         end if;
         delay 0.001;
      end loop;
   end Await_Operation_Active;

   procedure Await_No_Operation_Waiters
     (Item : Connections.Connection)
   is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while Connection_Testing.Waiting_Operations (Item) /= 0 loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with
              "connection queued-operation count did not drain";
         end if;
         delay 0.001;
      end loop;
   end Await_No_Operation_Waiters;

   procedure Close_And_Re_Adopt
     (Manager : aliased in out Connections.Server;
      Owned   : in out Connections.Connection;
      Peer    : Sockets.Socket_Type)
   is
      Replacement, Replacement_Peer : Sockets.Socket_Type;
   begin
      Owned.Close;
      pragma Assert (Manager.Active = 0);
      Sockets.Create_Socket_Pair (Replacement, Replacement_Peer);
      Connections.Take (Manager, Replacement, Owned);
      pragma Assert (Replacement = Sockets.No_Socket);
      Owned.Close;
      pragma Assert (Manager.Active = 0);
      Sockets.Close_Socket (Peer);
      Sockets.Close_Socket (Replacement_Peer);
   end Close_And_Re_Adopt;

   procedure Run_Abort_Handoff
     (Model : Flyology.Execution_Model;
      Point : Connection_Testing.Barrier_Point)
   is
      Manager : aliased Connections.Server (Capacity => 1);
      Owned   : Connections.Connection;
      Server, Peer : Sockets.Socket_Type;
   begin
      pragma Assert
        (Point = Connection_Testing.After_Registration
         or else Point = Connection_Testing.After_Acquisition);
      Connection_Testing.Reset_Barriers;
      Connection_Testing.Arm (Point);
      Sockets.Create_Socket_Pair (Server, Peer);
      Connections.Take (Manager, Server, Owned);

      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            Data : Ada.Streams.Stream_Element_Array (1 .. 1);
         begin
            Owned.Receive_Exactly (Data);
         end Worker;
      begin
         Connection_Testing.Wait_Reached (Point);
         if Point = Connection_Testing.After_Registration then
            pragma Assert (not Connection_Testing.Operation_Active (Owned));
            pragma Assert
              (Connection_Testing.Waiting_Operations (Owned) = 1);
         else
            pragma Assert (Connection_Testing.Operation_Active (Owned));
            pragma Assert
              (Connection_Testing.Waiting_Operations (Owned) = 0);
         end if;
         abort Worker;
         Connection_Testing.Release (Point);
      exception
         when others =>
            Connection_Testing.Release (Point);
            raise;
      end;

      Await_Operation_Active (Owned, Expected => False);
      Await_No_Operation_Waiters (Owned);
      Close_And_Re_Adopt (Manager, Owned, Peer);
      Connection_Testing.Reset_Barriers;
      if Model = Flyology.Lightweight_Task then
         Assert_No_Event_Waits;
      end if;
   end Run_Abort_Handoff;

   procedure Run_Abort_Queued (Model : Flyology.Execution_Model) is
      Manager : aliased Connections.Server (Capacity => 1);
      Owned   : Connections.Connection;
      Server, Peer : Sockets.Socket_Type;
      Point : constant Connection_Testing.Barrier_Point :=
        Connection_Testing.Queued_Operation_Park;

      protected Start_Control is
         procedure Start_Queued;
         entry Wait_Start_Queued;
      private
         May_Start : Boolean := False;
      end Start_Control;

      protected body Start_Control is
         procedure Start_Queued is
         begin
            May_Start := True;
         end Start_Queued;

         entry Wait_Start_Queued when May_Start is
         begin
            null;
         end Wait_Start_Queued;
      end Start_Control;
   begin
      Connection_Testing.Reset_Barriers;
      Connection_Testing.Arm (Point);
      Sockets.Create_Socket_Pair (Server, Peer);
      Connections.Take (Manager, Server, Owned);
      declare
         task Holder is
            pragma Task_Info (Model);
         end Holder;

         task Queued is
            pragma Task_Info (Model);
         end Queued;

         task body Holder is
            Data : Ada.Streams.Stream_Element_Array (1 .. 1);
         begin
            begin
               Owned.Receive_Exactly (Data);
            exception
               when Connections.Operation_Cancelled =>
                  null;
            end;
         end Holder;

         task body Queued is
            Data : Ada.Streams.Stream_Element_Array (1 .. 1);
         begin
            Start_Control.Wait_Start_Queued;
            Owned.Receive_Exactly (Data);
         end Queued;
      begin
         Await_Operation_Active (Owned);
         Start_Control.Start_Queued;
         Connection_Testing.Wait_Reached (Point);
         pragma Assert
           (Connection_Testing.Waiting_Operations (Owned) = 1);
         abort Queued;
         Connection_Testing.Release (Point);
         Await_No_Operation_Waiters (Owned);
         Owned.Close;
      exception
         when others =>
            Connection_Testing.Release (Point);
            Owned.Close;
            raise;
      end;

      pragma Assert (Manager.Active = 0);
      Sockets.Close_Socket (Peer);
      Connection_Testing.Reset_Barriers;
      Sockets.Create_Socket_Pair (Server, Peer);
      Connections.Take (Manager, Server, Owned);
      Owned.Close;
      pragma Assert (Manager.Active = 0);
      Sockets.Close_Socket (Peer);
      if Model = Flyology.Lightweight_Task then
         Assert_No_Event_Waits;
      end if;
   end Run_Abort_Queued;

   procedure Run_Abort_Active_Parked (Model : Flyology.Execution_Model) is
      Manager : aliased Connections.Server (Capacity => 1);
      Owned   : Connections.Connection;
      Server, Peer : Sockets.Socket_Type;
      Point : constant Connection_Testing.Barrier_Point :=
        Connection_Testing.Active_Operation_Park;
   begin
      Connection_Testing.Reset_Barriers;
      Connection_Testing.Arm (Point);
      Sockets.Create_Socket_Pair (Server, Peer);
      Connections.Take (Manager, Server, Owned);
      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            Data : Ada.Streams.Stream_Element_Array (1 .. 1);
         begin
            Owned.Receive_Exactly (Data);
         end Worker;
      begin
         Connection_Testing.Wait_Reached (Point);
         pragma Assert (Connection_Testing.Operation_Active (Owned));
         abort Worker;
         Connection_Testing.Release (Point);
      exception
         when others =>
            Connection_Testing.Release (Point);
            raise;
      end;

      Await_Operation_Active (Owned, Expected => False);
      Close_And_Re_Adopt (Manager, Owned, Peer);
      Connection_Testing.Reset_Barriers;
      if Model = Flyology.Lightweight_Task then
         Assert_No_Event_Waits;
      end if;
   end Run_Abort_Active_Parked;

   procedure Run_Partial_Receive_Close
     (Model : Flyology.Execution_Model)
   is
      Manager : aliased Connections.Server (Capacity => 1);
      Owned   : Connections.Connection;
      Server, Peer, Observer : Sockets.Socket_Type;
      Duplicate : Interfaces.C.int;

      type Receive_Result is
        (Not_Finished, Was_Cancelled, Raised_Other_Exception);

      protected Progress is
         procedure Reader_Ready;
         entry Wait_Reader_Ready;
         procedure Start_Reader;
         entry Wait_Start_Reader;
         procedure Contender_Attempting;
         entry Wait_Contender_Attempting;
         procedure Start_Contender;
         entry Wait_Start_Contender;
         procedure Reader_Finished (Result : Receive_Result);
         procedure Contender_Finished (Result : Receive_Result);
         entry Wait_Finished
           (Reader_Result    : out Receive_Result;
            Contender_Result : out Receive_Result);
      private
         Reader_Is_Ready       : Boolean := False;
         Reader_Started        : Boolean := False;
         Contender_Started     : Boolean := False;
         Contender_Is_Attempting : Boolean := False;
         Reader_Outcome        : Receive_Result := Not_Finished;
         Contender_Outcome     : Receive_Result := Not_Finished;
      end Progress;

      protected body Progress is
         procedure Reader_Ready is
         begin
            Reader_Is_Ready := True;
         end Reader_Ready;

         entry Wait_Reader_Ready when Reader_Is_Ready is
         begin
            null;
         end Wait_Reader_Ready;

         procedure Start_Reader is
         begin
            Reader_Started := True;
         end Start_Reader;

         entry Wait_Start_Reader when Reader_Started is
         begin
            null;
         end Wait_Start_Reader;

         procedure Contender_Attempting is
         begin
            Contender_Is_Attempting := True;
         end Contender_Attempting;

         entry Wait_Contender_Attempting when Contender_Is_Attempting is
         begin
            null;
         end Wait_Contender_Attempting;

         procedure Start_Contender is
         begin
            Contender_Started := True;
         end Start_Contender;

         entry Wait_Start_Contender when Contender_Started is
         begin
            null;
         end Wait_Start_Contender;

         procedure Reader_Finished (Result : Receive_Result) is
         begin
            Reader_Outcome := Result;
         end Reader_Finished;

         procedure Contender_Finished (Result : Receive_Result) is
         begin
            Contender_Outcome := Result;
         end Contender_Finished;

         entry Wait_Finished
           (Reader_Result    : out Receive_Result;
            Contender_Result : out Receive_Result)
           when Reader_Outcome /= Not_Finished
             and then Contender_Outcome /= Not_Finished
         is
         begin
            Reader_Result := Reader_Outcome;
            Contender_Result := Contender_Outcome;
         end Wait_Finished;
      end Progress;

      Reader_Outcome    : Receive_Result;
      Contender_Outcome : Receive_Result;
      Sent_Last : Ada.Streams.Stream_Element_Offset;
      Byte      : constant Ada.Streams.Stream_Element_Array (1 .. 1) :=
        (1 => 16#5A#);
   begin
      Sockets.Create_Socket_Pair (Server, Peer);
      Duplicate := C_Dup (Interfaces.C.int (Sockets.To_C (Server)));
      if Duplicate < 0 then
         raise Program_Error with "dup failed in partial receive test";
      end if;
      Observer := Sockets.To_Ada (Integer (Duplicate));
      Connections.Take (Manager, Server, Owned);

      declare
         task Reader is
            pragma Task_Info (Model);
         end Reader;

         task Contender is
            pragma Task_Info (Model);
         end Contender;

         task body Reader is
            Data : Ada.Streams.Stream_Element_Array (1 .. 2);
         begin
            Progress.Reader_Ready;
            Progress.Wait_Start_Reader;
            begin
               Owned.Receive_Exactly (Data);
               Progress.Reader_Finished (Raised_Other_Exception);
            exception
               when Connections.Operation_Cancelled =>
                  Progress.Reader_Finished (Was_Cancelled);
               when others =>
                  Progress.Reader_Finished (Raised_Other_Exception);
            end;
         exception
            when others =>
               Progress.Reader_Finished (Raised_Other_Exception);
         end Reader;

         task body Contender is
            Data : Ada.Streams.Stream_Element_Array (1 .. 1);
         begin
            Progress.Wait_Start_Contender;
            Progress.Contender_Attempting;
            begin
               Owned.Receive_Exactly (Data);
               Progress.Contender_Finished (Raised_Other_Exception);
            exception
               when Connections.Operation_Cancelled =>
                  Progress.Contender_Finished (Was_Cancelled);
               when others =>
                  Progress.Contender_Finished (Raised_Other_Exception);
            end;
         exception
            when others =>
               Progress.Contender_Finished (Raised_Other_Exception);
         end Contender;
      begin
         Progress.Wait_Reader_Ready;
         Progress.Start_Reader;
         if Model = Flyology.Lightweight_Task then
            Await_Event_Waits (1);
         else
            delay 0.050;
         end if;

         --  Queue a second operation behind the active sequence before
         --  providing its first byte. Old per-chunk leasing handed the lease
         --  to this contender after the partial receive, so Close made the
         --  original caller observe Program_Error instead of cancellation.
         Progress.Start_Contender;
         Progress.Wait_Contender_Attempting;
         Await_Operation_Waiter (Owned);

         Sockets.Send_Socket (Peer, Byte, Sent_Last);
         pragma Assert (Sent_Last = Byte'Last);
         Await_Bytes (Observer, 0);

         --  The first byte has been consumed while the two-byte sequence is
         --  still incomplete. Close must cancel both calls that started open.
         Owned.Close;
         Progress.Wait_Finished (Reader_Outcome, Contender_Outcome);
      end;

      pragma Assert (Reader_Outcome = Was_Cancelled);
      pragma Assert (Contender_Outcome = Was_Cancelled);
      pragma Assert (Manager.Active = 0);

      declare
         Data : Ada.Streams.Stream_Element_Array (1 .. 1);
         Rejected_At_Start : Boolean := False;
      begin
         begin
            Owned.Receive_Exactly (Data, Timeout => 0.0);
         exception
            when Program_Error =>
               Rejected_At_Start := True;
         end;
         pragma Assert (Rejected_At_Start);
      end;

      Sockets.Close_Socket (Observer);
      Sockets.Close_Socket (Peer);
      if Model = Flyology.Lightweight_Task then
         Assert_No_Event_Waits;
      end if;
   end Run_Partial_Receive_Close;

   type Queued_Interrupt is (By_Timeout, By_Token, By_Shutdown);

   procedure Run_Queued_Lease_Interrupt
     (Model : Flyology.Execution_Model;
      Cause : Queued_Interrupt)
   is
      Manager : aliased Connections.Server (Capacity => 1);
      Owned   : Connections.Connection;
      Server, Peer, Observer : Sockets.Socket_Type;
      Duplicate : Interfaces.C.int;
      Token : aliased Connections.Cancellation_Token;

      type Operation_Result is
        (Not_Finished, Completed, Timed_Out, Was_Cancelled, Failed);

      protected Progress is
         procedure Start_Waiter;
         entry Wait_Start_Waiter;
         procedure Holder_Finished (Result : Operation_Result);
         procedure Waiter_Finished (Result : Operation_Result);
         entry Wait_Waiter (Result : out Operation_Result);
         entry Wait_Both
           (Holder_Result : out Operation_Result;
            Waiter_Result : out Operation_Result);
      private
         Waiter_Started : Boolean := False;
         Holder_Outcome : Operation_Result := Not_Finished;
         Waiter_Outcome : Operation_Result := Not_Finished;
      end Progress;

      protected body Progress is
         procedure Start_Waiter is
         begin
            Waiter_Started := True;
         end Start_Waiter;

         entry Wait_Start_Waiter when Waiter_Started is
         begin
            null;
         end Wait_Start_Waiter;

         procedure Holder_Finished (Result : Operation_Result) is
         begin
            Holder_Outcome := Result;
         end Holder_Finished;

         procedure Waiter_Finished (Result : Operation_Result) is
         begin
            Waiter_Outcome := Result;
         end Waiter_Finished;

         entry Wait_Waiter (Result : out Operation_Result)
           when Waiter_Outcome /= Not_Finished
         is
         begin
            Result := Waiter_Outcome;
         end Wait_Waiter;

         entry Wait_Both
           (Holder_Result : out Operation_Result;
            Waiter_Result : out Operation_Result)
           when Holder_Outcome /= Not_Finished
             and then Waiter_Outcome /= Not_Finished
         is
         begin
            Holder_Result := Holder_Outcome;
            Waiter_Result := Waiter_Outcome;
         end Wait_Both;
      end Progress;

      Holder_Outcome : Operation_Result;
      Waiter_Outcome : Operation_Result;
      Sent_Last : Ada.Streams.Stream_Element_Offset;
      Byte : constant Ada.Streams.Stream_Element_Array (1 .. 1) :=
        (1 => 16#33#);
   begin
      Sockets.Create_Socket_Pair (Server, Peer);
      Duplicate := C_Dup (Interfaces.C.int (Sockets.To_C (Server)));
      if Duplicate < 0 then
         raise Program_Error with "dup failed in queued lease test";
      end if;
      Observer := Sockets.To_Ada (Integer (Duplicate));
      Connections.Take (Manager, Server, Owned);

      declare
         task Holder is
            pragma Task_Info (Model);
         end Holder;

         task Waiter is
            pragma Task_Info (Model);
         end Waiter;

         task body Holder is
            Data : Ada.Streams.Stream_Element_Array (1 .. 2);
         begin
            begin
               Owned.Receive_Exactly (Data);
               Progress.Holder_Finished (Completed);
            exception
               when Connections.Operation_Cancelled =>
                  Progress.Holder_Finished (Was_Cancelled);
               when others =>
                  Progress.Holder_Finished (Failed);
            end;
         exception
            when others =>
               Progress.Holder_Finished (Failed);
         end Holder;

         task body Waiter is
            Data : Ada.Streams.Stream_Element_Array (1 .. 1);
         begin
            Progress.Wait_Start_Waiter;
            begin
               Owned.Receive_Exactly
                 (Data,
                  Timeout => (if Cause = By_Timeout then 0.050 else -1.0),
                  Token =>
                    (if Cause = By_Token then Token'Access else null));
               Progress.Waiter_Finished (Completed);
            exception
               when Flyology.IO.Timeout_Error =>
                  Progress.Waiter_Finished (Timed_Out);
               when Connections.Operation_Cancelled =>
                  Progress.Waiter_Finished (Was_Cancelled);
               when others =>
                  Progress.Waiter_Finished (Failed);
            end;
         exception
            when others =>
               Progress.Waiter_Finished (Failed);
         end Waiter;
      begin
         --  Consuming one byte of a two-byte receive proves Holder owns the
         --  lease before Waiter starts, in both execution lanes.
         Sockets.Send_Socket (Peer, Byte, Sent_Last);
         pragma Assert (Sent_Last = Byte'Last);
         Await_Bytes (Observer, 0);

         Progress.Start_Waiter;
         Await_Operation_Waiter (Owned);
         case Cause is
            when By_Timeout =>
               null;
            when By_Token =>
               Token.Request;
            when By_Shutdown =>
               Manager.Request_Shutdown;
         end case;

         select
            Progress.Wait_Waiter (Waiter_Outcome);
         or
            delay 2.0;
            raise Program_Error with "queued operation did not terminate";
         end select;

         if Cause /= By_Shutdown then
            --  The queued call must finish while Holder still owns the lease.
            pragma Assert
              (Connection_Testing.Waiting_Operations (Owned) = 0);
            Sockets.Send_Socket (Peer, Byte, Sent_Last);
            pragma Assert (Sent_Last = Byte'Last);
         end if;

         select
            Progress.Wait_Both (Holder_Outcome, Waiter_Outcome);
         or
            delay 2.0;
            raise Program_Error with "queued lease tasks did not terminate";
         end select;
      end;

      case Cause is
         when By_Timeout =>
            pragma Assert (Waiter_Outcome = Timed_Out);
            pragma Assert (Holder_Outcome = Completed);
         when By_Token =>
            pragma Assert (Waiter_Outcome = Was_Cancelled);
            pragma Assert (Holder_Outcome = Completed);
         when By_Shutdown =>
            pragma Assert (Waiter_Outcome = Was_Cancelled);
            pragma Assert (Holder_Outcome = Was_Cancelled);
      end case;

      Owned.Close;
      pragma Assert (Manager.Active = 0);
      Sockets.Close_Socket (Observer);
      Sockets.Close_Socket (Peer);
      if Model = Flyology.Lightweight_Task then
         Assert_No_Event_Waits;
      end if;
   end Run_Queued_Lease_Interrupt;

   procedure Run_Readable_Chunk_Cancellation
     (Model : Flyology.Execution_Model)
   is
      Manager : aliased Connections.Server (Capacity => 1);
      Owned   : Connections.Connection;
      Server, Peer, Observer : Sockets.Socket_Type;
      Duplicate : Interfaces.C.int;
      Token : aliased Connections.Cancellation_Token;
      Point : constant Connection_Testing.Barrier_Point :=
        Connection_Testing.Receive_Chunk_Boundary;

      type Receive_Result is
        (Not_Finished, Was_Cancelled, Raised_Other_Exception);

      protected Progress is
         procedure Add_Packet;
         entry Wait_Prefilled;
         procedure Start_Reader;
         entry Wait_Start_Reader;
         procedure Stop_Writer;
         function Writer_Should_Stop return Boolean;
         procedure Writer_Finished (Succeeded : Boolean);
         entry Wait_Writer (Succeeded : out Boolean);
         procedure Reader_Finished (Result : Receive_Result);
         entry Wait_Reader (Result : out Receive_Result);
      private
         Packets_Sent : Natural := 0;
         Reader_Started : Boolean := False;
         Stop_Requested : Boolean := False;
         Writer_Done : Boolean := False;
         Writer_OK : Boolean := False;
         Reader_Outcome : Receive_Result := Not_Finished;
      end Progress;

      protected body Progress is
         procedure Add_Packet is
         begin
            Packets_Sent := Packets_Sent + 1;
         end Add_Packet;

         entry Wait_Prefilled when Packets_Sent >= 4 or else Writer_Done is
         begin
            if Writer_Done and then Packets_Sent < 4 then
               raise Program_Error with
                 "continuous-readability writer stopped before prefill";
            end if;
         end Wait_Prefilled;

         procedure Start_Reader is
         begin
            Reader_Started := True;
         end Start_Reader;

         entry Wait_Start_Reader when Reader_Started is
         begin
            null;
         end Wait_Start_Reader;

         procedure Stop_Writer is
         begin
            Stop_Requested := True;
         end Stop_Writer;

         function Writer_Should_Stop return Boolean is (Stop_Requested);

         procedure Writer_Finished (Succeeded : Boolean) is
         begin
            Writer_OK := Succeeded;
            Writer_Done := True;
         end Writer_Finished;

         entry Wait_Writer (Succeeded : out Boolean) when Writer_Done is
         begin
            Succeeded := Writer_OK;
         end Wait_Writer;

         procedure Reader_Finished (Result : Receive_Result) is
         begin
            Reader_Outcome := Result;
         end Reader_Finished;

         entry Wait_Reader (Result : out Receive_Result)
           when Reader_Outcome /= Not_Finished
         is
         begin
            Result := Reader_Outcome;
         end Wait_Reader;
      end Progress;

      type Buffer_Access is access Ada.Streams.Stream_Element_Array;
      procedure Free is new Ada.Unchecked_Deallocation
        (Ada.Streams.Stream_Element_Array, Buffer_Access);

      Reader_Outcome : Receive_Result;
      Writer_OK : Boolean;
      Request : Sockets.Request_Type (Sockets.N_Bytes_To_Read);
   begin
      Connection_Testing.Reset_Barriers;
      Connection_Testing.Arm (Point);
      Sockets.Create_Socket_Pair
        (Server, Peer, Mode => Sockets.Socket_Datagram);
      Duplicate := C_Dup (Interfaces.C.int (Sockets.To_C (Server)));
      if Duplicate < 0 then
         raise Program_Error with
           "dup failed in continuous-readability test";
      end if;
      Observer := Sockets.To_Ada (Integer (Duplicate));
      Connections.Take (Manager, Server, Owned);

      declare
         task Writer is
            pragma Task_Info (Flyology.Native_Task);
         end Writer;

         task Reader is
            pragma Task_Info (Model);
         end Reader;

         task body Writer is
            Message : constant Ada.Streams.Stream_Element_Array (1 .. 64) :=
              (others => 16#A5#);
            Length : Ada.Streams.Stream_Element_Offset := Message'First;
            Last : Ada.Streams.Stream_Element_Offset;
         begin
            loop
               exit when Progress.Writer_Should_Stop;
               begin
                  Flyology.IO.Sockets.Send
                    (Peer,
                     Message (Message'First .. Length),
                     Last,
                     Timeout => 0.005);
                  if Last /= Length then
                     raise Program_Error with
                       "datagram writer made partial progress";
                  end if;
                  Progress.Add_Packet;
                  if Length = Message'Last then
                     Length := Message'First;
                  else
                     Length := Length + 1;
                  end if;
               exception
                  when Flyology.IO.Timeout_Error =>
                     null;
                  when Occurrence : Sockets.Socket_Error =>
                     if Sockets.Resolve_Exception (Occurrence) /=
                       Sockets.No_Buffer_Space_Available
                     then
                        raise;
                     end if;
                     delay 0.001;
               end;
            end loop;
            Progress.Writer_Finished (True);
         exception
            when others =>
               Progress.Writer_Finished (False);
         end Writer;

         task body Reader is
            Data : Buffer_Access :=
              new Ada.Streams.Stream_Element_Array (1 .. 64 * 1024 * 1024);
         begin
            Progress.Wait_Start_Reader;
            begin
               Owned.Receive_Exactly
                 (Data.all, Timeout => 5.0, Token => Token'Access);
               Progress.Reader_Finished (Raised_Other_Exception);
            exception
               when Connections.Operation_Cancelled =>
                  Progress.Reader_Finished (Was_Cancelled);
               when others =>
                  Progress.Reader_Finished (Raised_Other_Exception);
            end;
            Free (Data);
         exception
            when others =>
               if Data /= null then
                  Free (Data);
               end if;
               Progress.Reader_Finished (Raised_Other_Exception);
         end Reader;
      begin
         select
            Progress.Wait_Prefilled;
         or
            delay 2.0;
            raise Program_Error with
              "continuous-readability socket did not prefill";
         end select;
         Progress.Start_Reader;
         Connection_Testing.Wait_Reached (Point);

         --  The barrier holds the reader after one completed datagram while at
         --  least three later datagrams remain readable. Cancellation must be
         --  noticed at the next connection-level chunk boundary rather than
         --  only after the socket becomes empty.
         Token.Request;
         Progress.Stop_Writer;
         Connection_Testing.Release (Point);
         select
            Progress.Wait_Reader (Reader_Outcome);
         or
            delay 2.0;
            raise Program_Error with
              "continuously readable receive ignored cancellation";
         end select;
         select
            Progress.Wait_Writer (Writer_OK);
         or
            delay 2.0;
            raise Program_Error with
              "continuous-readability writer did not stop";
         end select;
      exception
         when others =>
            --  Do not let a failed synchronization assertion strand either
            --  task while the enclosing task scope waits for termination.
            Progress.Start_Reader;
            Token.Request;
            Progress.Stop_Writer;
            Connection_Testing.Release (Point);
            raise;
      end;

      pragma Assert (Reader_Outcome = Was_Cancelled);
      pragma Assert (Writer_OK);
      Sockets.Control_Socket (Observer, Request);
      pragma Assert
        (Request.Size > 0,
         "receive drained readable datagrams before noticing cancellation");

      Owned.Close;
      Sockets.Close_Socket (Observer);
      Sockets.Close_Socket (Peer);
      Connection_Testing.Reset_Barriers;
      if Model = Flyology.Lightweight_Task then
         Assert_No_Event_Waits;
      end if;
   end Run_Readable_Chunk_Cancellation;

   procedure Run_Writable_Send_Close (Model : Flyology.Execution_Model) is
      Manager : aliased Connections.Server (Capacity => 1);
      Owned   : Connections.Connection;
      Server, Peer : Sockets.Socket_Type;
      Point : constant Connection_Testing.Barrier_Point :=
        Connection_Testing.Send_Chunk_Boundary;

      type Send_Result is
        (Not_Finished, Completed, Was_Cancelled, Failed);

      protected Progress is
         procedure Start_Close;
         entry Wait_Start_Close;
         procedure Sender_Finished (Result : Send_Result);
         procedure Close_Finished (Passed : Boolean);
         entry Wait_Both
           (Result : out Send_Result;
            Close_Passed : out Boolean);
      private
         Close_Started : Boolean := False;
         Sender_Outcome : Send_Result := Not_Finished;
         Close_Done : Boolean := False;
         Close_OK : Boolean := False;
      end Progress;

      protected body Progress is
         procedure Start_Close is
         begin
            Close_Started := True;
         end Start_Close;

         entry Wait_Start_Close when Close_Started is
         begin
            null;
         end Wait_Start_Close;

         procedure Sender_Finished (Result : Send_Result) is
         begin
            Sender_Outcome := Result;
         end Sender_Finished;

         procedure Close_Finished (Passed : Boolean) is
         begin
            Close_OK := Passed;
            Close_Done := True;
         end Close_Finished;

         entry Wait_Both
           (Result : out Send_Result;
            Close_Passed : out Boolean)
           when Sender_Outcome /= Not_Finished and then Close_Done
         is
         begin
            Result := Sender_Outcome;
            Close_Passed := Close_OK;
         end Wait_Both;
      end Progress;

      Data : constant Ada.Streams.Stream_Element_Array (1 .. 2_048) :=
        (others => 16#C3#);
      Outcome : Send_Result;
      Close_OK : Boolean;
   begin
      Connection_Testing.Reset_Barriers;
      Connection_Testing.Arm (Point);
      Sockets.Create_Socket_Pair (Server, Peer);
      Connections.Take (Manager, Server, Owned);

      declare
         task Sender is
            pragma Task_Info (Model);
         end Sender;

         task Closer is
            pragma Task_Info (Flyology.Native_Task);
         end Closer;

         task body Sender is
         begin
            begin
               Owned.Send_All (Data, Timeout => 5.0);
               Progress.Sender_Finished (Completed);
            exception
               when Connections.Operation_Cancelled =>
                  Progress.Sender_Finished (Was_Cancelled);
               when others =>
                  Progress.Sender_Finished (Failed);
            end;
         exception
            when others =>
               Progress.Sender_Finished (Failed);
         end Sender;

         task body Closer is
         begin
            Progress.Wait_Start_Close;
            Owned.Close;
            Progress.Close_Finished (not Connections.Is_Open (Owned));
         exception
            when others =>
               Progress.Close_Finished (False);
         end Closer;
      begin
         Connection_Testing.Wait_Reached (Point);
         pragma Assert (Connection_Testing.Operation_Active (Owned));
         Progress.Start_Close;
         declare
            Deadline : constant Ada.Real_Time.Time :=
              Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
         begin
            while not Connection_Testing.Close_Requested (Owned) loop
               if Ada.Real_Time.Clock >= Deadline then
                  raise Program_Error with
                    "Close did not publish at the send chunk boundary";
               end if;
               delay 0.001;
            end loop;
         end;
         Connection_Testing.Release (Point);
         Progress.Wait_Both (Outcome, Close_OK);
      exception
         when others =>
            Progress.Start_Close;
            Connection_Testing.Release (Point);
            raise;
      end;

      pragma Assert (Outcome = Was_Cancelled);
      pragma Assert (Close_OK);
      pragma Assert (Manager.Active = 0);
      Sockets.Close_Socket (Peer);
      Connection_Testing.Reset_Barriers;
      if Model = Flyology.Lightweight_Task then
         Assert_No_Event_Waits;
      end if;
   exception
      when others =>
         if Connections.Is_Open (Owned) then
            Owned.Close;
         end if;
         if Peer /= Sockets.No_Socket then
            Sockets.Close_Socket (Peer);
         end if;
         Connection_Testing.Release (Point);
         raise;
   end Run_Writable_Send_Close;

   procedure Run_Close_Reuse (Model : Flyology.Execution_Model) is
      Manager : aliased Connections.Server (Capacity => 1);
      Owned   : Connections.Connection;
      Server, Peer : Sockets.Socket_Type;
      Old_FD : Flyology.IO.Descriptor;

      protected Progress is
         procedure Entering;
         procedure Finished (Cancelled : Boolean);
         entry Wait_Entering;
         entry Wait_Finished;
         function Passed return Boolean;
      private
         Has_Entered : Boolean := False;
         Has_Finished : Boolean := False;
         OK : Boolean := False;
      end Progress;

      protected body Progress is
         procedure Entering is
         begin
            Has_Entered := True;
         end Entering;
         procedure Finished (Cancelled : Boolean) is
         begin
            OK := Cancelled;
            Has_Finished := True;
         end Finished;
         entry Wait_Entering when Has_Entered is begin null; end Wait_Entering;
         entry Wait_Finished when Has_Finished is begin null; end Wait_Finished;
         function Passed return Boolean is (OK);
      end Progress;
   begin
      Sockets.Create_Socket_Pair (Server, Peer);
      Old_FD := Flyology.IO.Sockets.Native_Descriptor (Server);
      Connections.Take (Manager, Server, Owned);
      pragma Assert (Server = Sockets.No_Socket);

      declare
         task Reader is
            pragma Task_Info (Model);
         end Reader;

         task body Reader is
            Data : Ada.Streams.Stream_Element_Array (1 .. 1);
            Cancelled : Boolean := False;
         begin
            Progress.Entering;
            begin
               Owned.Receive_Exactly (Data);
            exception
               when Connections.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Progress.Finished (Cancelled);
         exception
            when others =>
               Progress.Finished (False);
         end Reader;
      begin
         Progress.Wait_Entering;
         if Model = Flyology.Lightweight_Task then
            Await_Event_Waits (1);
         else
            --  The native lane cannot be inspected through group snapshots;
            --  give its newly activated pthread time to enter poll(2).
            delay 0.050;
         end if;
         Owned.Close;
         Progress.Wait_Finished;
      end;

      pragma Assert (Progress.Passed);
      pragma Assert (Manager.Active = 0);

      --  The lowest descriptor is reused immediately. Close could only have
      --  returned after the old generation removed its poller registration.
      declare
         New_Server, New_Peer : Sockets.Socket_Type;
         Sent, Last : Ada.Streams.Stream_Element_Offset;
         Outgoing : constant Ada.Streams.Stream_Element_Array (1 .. 1) :=
           (1 => 73);
         Incoming : Ada.Streams.Stream_Element_Array (1 .. 1);
         Reuse_OK : Boolean := False with Atomic;
      begin
         Sockets.Create_Socket_Pair (New_Server, New_Peer);
         pragma Assert
           (Flyology.IO.Sockets.Native_Descriptor (New_Server) = Old_FD);
         declare
            task Reused_Reader is
               pragma Task_Info (Model);
            end Reused_Reader;
            task body Reused_Reader is
            begin
               if Flyology.IO.Wait (Old_FD, Flyology.IO.For_Read, 0.5) then
                  Sockets.Receive_Socket (New_Server, Incoming, Last);
                  Reuse_OK :=
                    Last = Incoming'Last and then Incoming = Outgoing;
               end if;
            exception
               when others =>
                  Reuse_OK := False;
            end Reused_Reader;
         begin
            if Model = Flyology.Lightweight_Task then
               Await_Event_Waits (1);
            else
               delay 0.050;
            end if;
            Sockets.Send_Socket (New_Peer, Outgoing, Sent);
            pragma Assert (Sent = Outgoing'Last);
         end;
         pragma Assert (Reuse_OK);
         Sockets.Close_Socket (New_Server);
         Sockets.Close_Socket (New_Peer);
      end;
      Sockets.Close_Socket (Peer);
      if Model = Flyology.Lightweight_Task then
         Assert_No_Event_Waits;
      end if;
   end Run_Close_Reuse;

   procedure Run_Cancellation_Close_Race
     (Model : Flyology.Execution_Model)
   is
      Manager : aliased Connections.Server (Capacity => 1);
      Token   : aliased Connections.Cancellation_Token;
      Owned   : Connections.Connection;
      Server, Peer : Sockets.Socket_Type;

      protected Progress is
         procedure Entering;
         procedure Finished (Cancelled : Boolean);
         entry Wait_Entering;
         entry Wait_Finished;
         function Passed return Boolean;
      private
         Entered, Done, OK : Boolean := False;
      end Progress;

      protected body Progress is
         procedure Entering is begin Entered := True; end Entering;
         procedure Finished (Cancelled : Boolean) is
         begin
            OK := Cancelled;
            Done := True;
         end Finished;
         entry Wait_Entering when Entered is begin null; end Wait_Entering;
         entry Wait_Finished when Done is begin null; end Wait_Finished;
         function Passed return Boolean is (OK);
      end Progress;
   begin
      Sockets.Create_Socket_Pair (Server, Peer);
      Connections.Take (Manager, Server, Owned);
      declare
         task Reader is
            pragma Task_Info (Model);
         end Reader;
         task Requester is
            entry Go;
         end Requester;

         task body Reader is
            Data : Ada.Streams.Stream_Element_Array (1 .. 1);
            Cancelled : Boolean := False;
         begin
            Progress.Entering;
            begin
               Owned.Receive_Exactly (Data, Token => Token'Access);
            exception
               when Connections.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Progress.Finished (Cancelled);
         exception
            when others =>
               Progress.Finished (False);
         end Reader;

         task body Requester is
         begin
            accept Go;
            Token.Request;
         end Requester;
      begin
         Progress.Wait_Entering;
         if Model = Flyology.Lightweight_Task then
            Await_Event_Waits (1);
         else
            delay 0.050;
         end if;
         Requester.Go;
         Owned.Close;
         Progress.Wait_Finished;
      end;
      pragma Assert (Progress.Passed);
      pragma Assert (Manager.Active = 0);
      Sockets.Close_Socket (Peer);
      if Model = Flyology.Lightweight_Task then
         Assert_No_Event_Waits;
      end if;
   end Run_Cancellation_Close_Race;

   type Adoption_Path is (Take_Path, Accept_Path);

   procedure Run_Close_In_Progress_Re_Adoption
     (Model : Flyology.Execution_Model;
      Path  : Adoption_Path)
   is
      package Groups renames Flyology.Execution_Groups;

      Original_Manager : aliased Connections.Server (Capacity => 1);
      Candidate_Manager : aliased Connections.Server (Capacity => 1);
      Owned : Connections.Connection;
      Original, Original_Peer : Sockets.Socket_Type;
      Candidate, Candidate_Peer : Sockets.Socket_Type;
      Listener : Sockets.Socket_Type := Sockets.No_Socket;

      type Atomic_Boolean is new Boolean with Atomic;
      Spinning          : aliased Atomic_Boolean := False;
      Stop_Spinning     : Atomic_Boolean := False;
      Reader_Done       : aliased Atomic_Boolean := False;
      Reader_Cancelled  : Atomic_Boolean := False;
      Close_Done        : aliased Atomic_Boolean := False;
      Close_OK          : Atomic_Boolean := False;
      Attempt_Done      : aliased Atomic_Boolean := False;
      Attempt_Rejected  : Atomic_Boolean := False;

      protected Spinner_Control is
         procedure Open;
         entry Wait;
      private
         Opened : Boolean := False;
      end Spinner_Control;

      protected body Spinner_Control is
         procedure Open is
         begin
            Opened := True;
         end Open;

         entry Wait when Opened is
         begin
            null;
         end Wait;
      end Spinner_Control;

      procedure Wait_Until (Flag : not null access Atomic_Boolean) is
         Deadline : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      begin
         while not Flag.all loop
            if Ada.Real_Time.Clock >= Deadline then
               raise Program_Error with "concurrent close test stalled";
            end if;
            delay 0.001;
         end loop;
      end Wait_Until;
   begin
      Sockets.Create_Socket_Pair (Original, Original_Peer);
      if Path = Take_Path then
         Sockets.Create_Socket_Pair (Candidate, Candidate_Peer);
      else
         Candidate := Sockets.No_Socket;
         Sockets.Create_Socket (Listener);
         Sockets.Bind_Socket
           (Listener,
            (Family => Sockets.Family_Inet,
             Addr   => Sockets.Loopback_Inet_Addr,
             Port   => Sockets.Any_Port));
         Sockets.Listen_Socket (Listener);
         Sockets.Create_Socket (Candidate_Peer);
         Sockets.Connect_Socket
           (Candidate_Peer, Sockets.Get_Socket_Name (Listener));
      end if;
      Connections.Take (Original_Manager, Original, Owned);

      declare
         task Reader is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Reader;

         task Spinner is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Spinner;

         task Closer is
            entry Start;
         end Closer;

         task Attempt is
            pragma Task_Info (Model);
            entry Start (Socket : in out Sockets.Socket_Type);
         end Attempt;

         task body Reader is
            Data : Ada.Streams.Stream_Element_Array (1 .. 1);
         begin
            Groups.Migrate (1);
            begin
               Owned.Receive_Exactly (Data);
            exception
               when Connections.Operation_Cancelled =>
                  Reader_Cancelled := True;
            end;
            Reader_Done := True;
         exception
            when others =>
               Reader_Done := True;
         end Reader;

         task body Spinner is
         begin
            Groups.Migrate (1);
            Spinner_Control.Wait;
            Spinning := True;
            while not Stop_Spinning loop
               null;
            end loop;
         end Spinner;

         task body Closer is
         begin
            accept Start;
            begin
               Connections.Close (Owned);
               Close_OK := True;
            exception
               when others =>
                  null;
            end;
            Close_Done := True;
         end Closer;

         task body Attempt is
         begin
            if Model = Flyology.Lightweight_Task then
               Groups.Migrate (2);
            end if;
            accept Start (Socket : in out Sockets.Socket_Type) do
               begin
                  if Path = Take_Path then
                     Connections.Take (Candidate_Manager, Socket, Owned);
                  else
                     declare
                        Peer_Address : Sockets.Sock_Addr_Type;
                     begin
                        Connections.Accept_Connection
                          (Candidate_Manager,
                           Listener,
                           Owned,
                           Peer_Address);
                     end;
                  end if;
               exception
                  when Program_Error =>
                     Attempt_Rejected := True;
                  when others =>
                     null;
               end;
            end Start;
            Attempt_Done := True;
         exception
            when others =>
               Attempt_Done := True;
         end Attempt;
      begin
         Await_Event_Waits (1, 1);
         Spinner_Control.Open;
         Wait_Until (Spinning'Access);

         Closer.Start;
         declare
            Deadline : constant Ada.Real_Time.Time :=
              Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
         begin
            while Connections.Is_Open (Owned) loop
               if Ada.Real_Time.Clock >= Deadline then
                  raise Program_Error with "close did not enter closing state";
               end if;
               delay 0.001;
            end loop;
         end;

         --  Reader cannot release its lease while Spinner monopolizes group 1,
         --  so Is_Open = False above denotes Closing, not a completed close.
         Attempt.Start (Candidate);
         Wait_Until (Attempt_Done'Access);
         Stop_Spinning := True;
         Wait_Until (Reader_Done'Access);
         Wait_Until (Close_Done'Access);
      end;

      pragma Assert (Attempt_Rejected);
      pragma Assert
        ((Path = Take_Path and then Candidate /= Sockets.No_Socket)
         or else (Path = Accept_Path
                  and then Candidate = Sockets.No_Socket));
      pragma Assert (Candidate_Manager.Active = 0);
      pragma Assert (Reader_Cancelled);
      pragma Assert (Close_OK);
      pragma Assert (Original_Manager.Active = 0);
      pragma Assert (not Connections.Is_Open (Owned));

      Sockets.Close_Socket (Original_Peer);
      if Candidate /= Sockets.No_Socket then
         Sockets.Close_Socket (Candidate);
      end if;
      Sockets.Close_Socket (Candidate_Peer);
      if Listener /= Sockets.No_Socket then
         Sockets.Close_Socket (Listener);
      end if;
   end Run_Close_In_Progress_Re_Adoption;

   procedure Run_Competing_Adopters
     (Model : Flyology.Execution_Model)
   is
      package Groups renames Flyology.Execution_Groups;

      First_Manager  : aliased Connections.Server (Capacity => 1);
      Second_Manager : aliased Connections.Server (Capacity => 1);
      Owned : Connections.Connection;
      First, First_Peer : Sockets.Socket_Type;
      Second, Second_Peer : Sockets.Socket_Type;

      protected Control is
         procedure Ready;
         entry Wait_Ready;
         procedure Open;
         entry Gate;
         procedure Finished (Won, Valid : Boolean);
         entry Wait_Finished (Passed : out Boolean);
      private
         Ready_Count    : Natural := 0;
         Opened         : Boolean := False;
         Finished_Count : Natural := 0;
         Winners        : Natural := 0;
         All_Valid      : Boolean := True;
      end Control;

      protected body Control is
         procedure Ready is
         begin
            Ready_Count := Ready_Count + 1;
         end Ready;

         entry Wait_Ready when Ready_Count = 2 is
         begin
            null;
         end Wait_Ready;

         procedure Open is
         begin
            Opened := True;
         end Open;

         entry Gate when Opened is
         begin
            null;
         end Gate;

         procedure Finished (Won, Valid : Boolean) is
         begin
            Finished_Count := Finished_Count + 1;
            if Won then
               Winners := Winners + 1;
            end if;
            All_Valid := All_Valid and Valid;
         end Finished;

         entry Wait_Finished (Passed : out Boolean)
           when Finished_Count = 2
         is
         begin
            Passed := All_Valid and Winners = 1;
         end Wait_Finished;
      end Control;
   begin
      Sockets.Create_Socket_Pair (First, First_Peer);
      Sockets.Create_Socket_Pair (Second, Second_Peer);

      declare
         task First_Adopter is
            pragma Task_Info (Model);
         end First_Adopter;

         task Second_Adopter is
            pragma Task_Info (Model);
         end Second_Adopter;

         task body First_Adopter is
            Won, Valid : Boolean := False;
         begin
            if Model = Flyology.Lightweight_Task then
               Groups.Migrate (1);
            end if;
            Control.Ready;
            Control.Gate;
            begin
               Connections.Take (First_Manager, First, Owned);
               Won := True;
               Valid := True;
            exception
               when Program_Error =>
                  Valid := True;
            end;
            Control.Finished (Won, Valid);
         exception
            when others =>
               Control.Finished (False, False);
         end First_Adopter;

         task body Second_Adopter is
            Won, Valid : Boolean := False;
         begin
            if Model = Flyology.Lightweight_Task then
               Groups.Migrate (2);
            end if;
            Control.Ready;
            Control.Gate;
            begin
               Connections.Take (Second_Manager, Second, Owned);
               Won := True;
               Valid := True;
            exception
               when Program_Error =>
                  Valid := True;
            end;
            Control.Finished (Won, Valid);
         exception
            when others =>
               Control.Finished (False, False);
         end Second_Adopter;

         Passed : Boolean;
      begin
         Control.Wait_Ready;
         Control.Open;
         Control.Wait_Finished (Passed);
         pragma Assert (Passed);
      end;

      if First = Sockets.No_Socket then
         pragma Assert (Second /= Sockets.No_Socket);
         pragma Assert (First_Manager.Active = 1);
         pragma Assert (Second_Manager.Active = 0);
      else
         pragma Assert (Second = Sockets.No_Socket);
         pragma Assert (First_Manager.Active = 0);
         pragma Assert (Second_Manager.Active = 1);
      end if;

      Connections.Close (Owned);
      pragma Assert (First_Manager.Active = 0);
      pragma Assert (Second_Manager.Active = 0);
      if First /= Sockets.No_Socket then
         Sockets.Close_Socket (First);
      end if;
      if Second /= Sockets.No_Socket then
         Sockets.Close_Socket (Second);
      end if;
      Sockets.Close_Socket (First_Peer);
      Sockets.Close_Socket (Second_Peer);
   end Run_Competing_Adopters;

   procedure Run_Exclusive_Waiters is
      Manager : aliased Connections.Server (Capacity => 1);
      Owned   : Connections.Connection;
      Server, Peer : Sockets.Socket_Type;

      protected Progress is
         procedure Finished (Index : Positive; Value : Ada.Streams.Stream_Element);
         entry Wait;
         function Passed return Boolean;
      private
         Count : Natural := 0;
         Seen_First, Seen_Second : Boolean := False;
      end Progress;

      protected body Progress is
         procedure Finished
           (Index : Positive; Value : Ada.Streams.Stream_Element)
         is
         begin
            if Index = 1 then
               Seen_First := Value in 1 | 2;
            else
               Seen_Second := Value in 1 | 2;
            end if;
            Count := Count + 1;
         end Finished;
         entry Wait when Count = 2 is begin null; end Wait;
         function Passed return Boolean is (Seen_First and Seen_Second);
      end Progress;
   begin
      Sockets.Create_Socket_Pair (Server, Peer);
      Connections.Take (Manager, Server, Owned);
      declare
         task type Reader (Index : Positive) is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Reader;
         task body Reader is
            Data : Ada.Streams.Stream_Element_Array (1 .. 1);
         begin
            Owned.Receive_Exactly (Data);
            Progress.Finished (Index, Data (Data'First));
         end Reader;
         First : Reader (1);
         Second : Reader (2);
         pragma Unreferenced (First, Second);
      begin
         Await_Event_Waits (2);
         declare
            Data : constant Ada.Streams.Stream_Element_Array (1 .. 2) :=
              (1, 2);
            Last : Ada.Streams.Stream_Element_Offset;
         begin
            Sockets.Send_Socket (Peer, Data, Last);
            pragma Assert (Last = Data'Last);
         end;
         Progress.Wait;
      end;
      pragma Assert (Progress.Passed);
      Owned.Close;
      Sockets.Close_Socket (Peer);
      Assert_No_Event_Waits;
   end Run_Exclusive_Waiters;

   procedure Run_Timeout_Close_Reuse is
      Server, Peer : Sockets.Socket_Type;
      Old_FD : Flyology.IO.Descriptor;
      Timed_Out : Boolean := False with Atomic;
   begin
      Sockets.Create_Socket_Pair (Server, Peer);
      Old_FD := Flyology.IO.Sockets.Native_Descriptor (Server);
      declare
         task Waiter is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Waiter;
         task body Waiter is
         begin
            Timed_Out := not Flyology.IO.Wait
              (Old_FD, Flyology.IO.For_Read, Timeout => 0.020);
         end Waiter;
      begin
         null;
      end;
      pragma Assert (Timed_Out);
      Assert_No_Event_Waits;
      Sockets.Close_Socket (Server);
      Sockets.Close_Socket (Peer);

      declare
         New_Server, New_Peer : Sockets.Socket_Type;
         Ready : Boolean := False with Atomic;
         Data : constant Ada.Streams.Stream_Element_Array (1 .. 1) :=
           (1 => 42);
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Sockets.Create_Socket_Pair (New_Server, New_Peer);
         pragma Assert
           (Flyology.IO.Sockets.Native_Descriptor (New_Server) = Old_FD);
         declare
            task Reused_Waiter is
               pragma Task_Info (Flyology.Lightweight_Task);
            end Reused_Waiter;
            task body Reused_Waiter is
            begin
               Ready := Flyology.IO.Wait
                 (Old_FD, Flyology.IO.For_Read, Timeout => 0.5);
            end Reused_Waiter;
         begin
            Await_Event_Waits (1);
            Sockets.Send_Socket (New_Peer, Data, Last);
         end;
         pragma Assert (Ready);
         Sockets.Close_Socket (New_Server);
         Sockets.Close_Socket (New_Peer);
      end;
      Assert_No_Event_Waits;
   end Run_Timeout_Close_Reuse;

   procedure Run_Timeout_Readiness_Races
     (Model : Flyology.Execution_Model)
   is
   begin
      for Iteration in 1 .. 12 loop
         declare
            Manager : aliased Connections.Server (Capacity => 1);
            Owned   : Connections.Connection;
            Server, Peer : Sockets.Socket_Type;
            Finished : Boolean := False;
         begin
            Sockets.Create_Socket_Pair (Server, Peer);
            Connections.Take (Manager, Server, Owned);
            declare
               task Reader is
                  pragma Task_Info (Model);
               end Reader;
               task Writer;

               task body Reader is
                  Data : Ada.Streams.Stream_Element_Array (1 .. 1);
               begin
                  begin
                     Owned.Receive_Exactly (Data, Timeout => 0.004);
                  exception
                     when Flyology.IO.Timeout_Error =>
                        null;
                  end;
                  Finished := True;
               end Reader;

               task body Writer is
                  Data : constant Ada.Streams.Stream_Element_Array
                    (1 .. 1) := (1 => 9);
                  Last : Ada.Streams.Stream_Element_Offset;
               begin
                  delay (if Iteration mod 2 = 0 then 0.002 else 0.006);
                  Sockets.Send_Socket (Peer, Data, Last);
               exception
                  when Sockets.Socket_Error =>
                     null;
               end Writer;
               pragma Unreferenced (Reader, Writer);
            begin
               null;
            end;
            pragma Assert (Finished);
            Owned.Close;
            Sockets.Close_Socket (Peer);
         end;
      end loop;
      if Model = Flyology.Lightweight_Task then
         Assert_No_Event_Waits;
      end if;
   end Run_Timeout_Readiness_Races;

begin
   Sockets.Initialize;
   Run_Abort_Handoff
     (Flyology.Lightweight_Task, Connection_Testing.After_Registration);
   Run_Abort_Handoff
     (Flyology.Native_Task, Connection_Testing.After_Registration);
   Run_Abort_Handoff
     (Flyology.Lightweight_Task, Connection_Testing.After_Acquisition);
   Run_Abort_Handoff
     (Flyology.Native_Task, Connection_Testing.After_Acquisition);
   Run_Abort_Queued (Flyology.Lightweight_Task);
   Run_Abort_Queued (Flyology.Native_Task);
   Run_Abort_Active_Parked (Flyology.Lightweight_Task);
   Run_Abort_Active_Parked (Flyology.Native_Task);
   Run_Partial_Receive_Close (Flyology.Lightweight_Task);
   Run_Partial_Receive_Close (Flyology.Native_Task);
   for Cause in Queued_Interrupt loop
      Run_Queued_Lease_Interrupt (Flyology.Lightweight_Task, Cause);
      Run_Queued_Lease_Interrupt (Flyology.Native_Task, Cause);
   end loop;
   Run_Readable_Chunk_Cancellation (Flyology.Lightweight_Task);
   Run_Readable_Chunk_Cancellation (Flyology.Native_Task);
   Run_Writable_Send_Close (Flyology.Lightweight_Task);
   Run_Writable_Send_Close (Flyology.Native_Task);
   Run_Close_Reuse (Flyology.Lightweight_Task);
   Run_Close_Reuse (Flyology.Native_Task);
   Run_Cancellation_Close_Race (Flyology.Lightweight_Task);
   Run_Cancellation_Close_Race (Flyology.Native_Task);
   Run_Close_In_Progress_Re_Adoption
     (Flyology.Lightweight_Task, Take_Path);
   Run_Close_In_Progress_Re_Adoption
     (Flyology.Native_Task, Take_Path);
   Run_Close_In_Progress_Re_Adoption
     (Flyology.Lightweight_Task, Accept_Path);
   Run_Close_In_Progress_Re_Adoption
     (Flyology.Native_Task, Accept_Path);
   Run_Competing_Adopters (Flyology.Lightweight_Task);
   Run_Competing_Adopters (Flyology.Native_Task);
   Run_Exclusive_Waiters;
   Run_Timeout_Close_Reuse;
   Run_Timeout_Readiness_Races (Flyology.Lightweight_Task);
   Run_Timeout_Readiness_Races (Flyology.Native_Task);
   Sockets.Finalize;
end Descriptor_Ownership_Smoke;
