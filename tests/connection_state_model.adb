with Ada.Real_Time;
with Ada.Streams;
with Flyology;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Connections.Testing;
with Flyology.IO.Sockets;
with Interfaces.C;

procedure Connection_State_Model is
   package Connections renames Flyology.IO.Connections;
   package Testing renames Flyology.IO.Connections.Testing;
   package Sockets renames Flyology.IO.Sockets;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.C.int;
   use type Testing.Barrier_Point;

   function Open_FD_Count return Interfaces.C.int
     with Import, Convention => C,
          External_Name => "flyology_test_open_fd_count";

   type Ownership_State is (Closed, Open);
   type Admission_State is (Accepting, Stopping);
   type Result_Kind is
     (Returned,
      Raised_Program_Error,
      Raised_Admission_Closed,
      Raised_Timeout,
      Raised_Cancelled);
   type Action_Kind is
     (Close_Idempotently,
      Receive_While_Closed,
      Take_Closed_Socket,
      Adopt_Socket,
      Adopt_While_Open,
      Immediate_Receive,
      Precancelled_Receive,
      Roundtrip,
      Close_Owned,
      Request_Shutdown,
      Take_After_Shutdown,
      Await_Drained);

   type Transition is record
      Action           : Action_Kind;
      From_Ownership   : Ownership_State;
      From_Admission   : Admission_State;
      Expected         : Result_Kind;
      To_Ownership     : Ownership_State;
      To_Admission     : Admission_State;
      To_Active        : Natural;
   end record;

   --  This table is the oracle. Repeated generations and rejected operations
   --  are deliberately interleaved so state restoration is checked after
   --  every public call, not only at the end of a scenario.
   Lifecycle : constant array (Positive range <>) of Transition :=
     [(Close_Idempotently, Closed, Accepting, Returned,
       Closed, Accepting, 0),
      (Receive_While_Closed, Closed, Accepting, Raised_Program_Error,
       Closed, Accepting, 0),
      (Take_Closed_Socket, Closed, Accepting, Raised_Program_Error,
       Closed, Accepting, 0),
      (Adopt_Socket, Closed, Accepting, Returned,
       Open, Accepting, 1),
      (Adopt_While_Open, Open, Accepting, Raised_Program_Error,
       Open, Accepting, 1),
      (Immediate_Receive, Open, Accepting, Raised_Timeout,
       Open, Accepting, 1),
      (Precancelled_Receive, Open, Accepting, Raised_Cancelled,
       Open, Accepting, 1),
      (Roundtrip, Open, Accepting, Returned,
       Open, Accepting, 1),
      (Close_Owned, Open, Accepting, Returned,
       Closed, Accepting, 0),
      (Close_Idempotently, Closed, Accepting, Returned,
       Closed, Accepting, 0),
      (Adopt_Socket, Closed, Accepting, Returned,
       Open, Accepting, 1),
      (Roundtrip, Open, Accepting, Returned,
       Open, Accepting, 1),
      (Close_Owned, Open, Accepting, Returned,
       Closed, Accepting, 0),
      (Request_Shutdown, Closed, Accepting, Returned,
       Closed, Stopping, 0),
      (Request_Shutdown, Closed, Stopping, Returned,
       Closed, Stopping, 0),
      (Take_After_Shutdown, Closed, Stopping, Raised_Admission_Closed,
       Closed, Stopping, 0),
      (Await_Drained, Closed, Stopping, Returned,
       Closed, Stopping, 0)];

   procedure Close_If_Open (Socket : in out Sockets.Socket_Type) is
   begin
      if Sockets.Is_Open (Socket) then
         Sockets.Close_Socket (Socket);
      end if;
   exception
      when others =>
         null;
   end Close_If_Open;

   procedure Assert_Descriptors
     (Before : Interfaces.C.int;
      Label  : String)
   is
      After : constant Interfaces.C.int := Open_FD_Count;
   begin
      if After /= Before then
         raise Program_Error with
           Label & " leaked descriptors: before=" & Before'Image
           & ", after=" & After'Image;
      end if;
   end Assert_Descriptors;

   procedure Run_Table (Model : Flyology.Execution_Model) is
      Before : constant Interfaces.C.int := Open_FD_Count;
      Passed : Boolean := False with Atomic;
      Failed_At : Natural := 0 with Atomic;
   begin
      declare
         Manager : aliased Connections.Server (Capacity => 1);
         Item    : Connections.Connection;

         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            Actual_Ownership : Ownership_State := Closed;
            Actual_Admission : Admission_State := Accepting;
            Owned_Socket     : Sockets.Socket_Type;
            Peer             : Sockets.Socket_Type;
            Candidate        : Sockets.Socket_Type;
            Candidate_Peer   : Sockets.Socket_Type;

            procedure Assert_State (Step : Transition) is
            begin
               if Connections.Is_Open (Item) /=
                 (Step.To_Ownership = Open)
                 or else Manager.Shutdown_Requested /=
                   (Step.To_Admission = Stopping)
                 or else Manager.Active /= Step.To_Active
                 or else Manager.Waiting /= 0
               then
                  raise Program_Error with
                    "observed lifecycle state differs from model";
               end if;
            end Assert_State;

            procedure Apply (Step : Transition) is
               Result : Result_Kind := Returned;
            begin
               if Actual_Ownership /= Step.From_Ownership
                 or else Actual_Admission /= Step.From_Admission
               then
                  raise Program_Error with "invalid lifecycle table edge";
               end if;

               begin
                  case Step.Action is
                     when Close_Idempotently | Close_Owned =>
                        Connections.Close (Item);
                        Close_If_Open (Peer);

                     when Receive_While_Closed =>
                        declare
                           Data : Ada.Streams.Stream_Element_Array (1 .. 1);
                        begin
                           Item.Receive_Exactly (Data, Timeout => 0.0);
                        end;

                     when Take_Closed_Socket =>
                        Connections.Take (Manager, Owned_Socket, Item);

                     when Adopt_Socket =>
                        Sockets.Create_Socket_Pair (Owned_Socket, Peer);
                        Connections.Take (Manager, Owned_Socket, Item);
                        if Sockets.Is_Open (Owned_Socket) then
                           raise Program_Error with
                             "Take did not consume socket ownership";
                        end if;

                     when Adopt_While_Open | Take_After_Shutdown =>
                        Sockets.Create_Socket_Pair
                          (Candidate, Candidate_Peer);
                        begin
                           Connections.Take (Manager, Candidate, Item);
                        exception
                           when Program_Error =>
                              Result := Raised_Program_Error;
                           when Connections.Admission_Closed =>
                              Result := Raised_Admission_Closed;
                        end;
                        if not Sockets.Is_Open (Candidate) then
                           raise Program_Error with
                             "rejected Take consumed caller ownership";
                        end if;
                        Close_If_Open (Candidate);
                        Close_If_Open (Candidate_Peer);

                     when Immediate_Receive =>
                        declare
                           Data : Ada.Streams.Stream_Element_Array (1 .. 1);
                        begin
                           Item.Receive_Exactly (Data, Timeout => 0.0);
                        end;

                     when Precancelled_Receive =>
                        declare
                           Token : aliased Connections.Cancellation_Token;
                           Data  : Ada.Streams.Stream_Element_Array (1 .. 1);
                        begin
                           Token.Request;
                           Item.Receive_Exactly
                             (Data, Timeout => -1.0, Token => Token'Access);
                        end;

                     when Roundtrip =>
                        declare
                           Sent : Ada.Streams.Stream_Element_Offset;
                           Data : Ada.Streams.Stream_Element_Array (1 .. 1);
                           Expected : constant
                             Ada.Streams.Stream_Element_Array (1 .. 1) :=
                               [1 => Ada.Streams.Stream_Element
                                 (17 + Natural (Failed_At mod 200))];
                        begin
                           Sockets.Send_Socket (Peer, Expected, Sent);
                           if Sent /= Expected'Last then
                              raise Program_Error with
                                "roundtrip send was incomplete";
                           end if;
                           Item.Receive_Exactly (Data, Timeout => 1.0);
                           if Data /= Expected then
                              raise Program_Error with
                                "roundtrip used the wrong generation";
                           end if;
                        end;

                     when Request_Shutdown =>
                        Manager.Request_Shutdown;

                     when Await_Drained =>
                        Manager.Await_Drained;
                  end case;
               exception
                  when Program_Error =>
                     Result := Raised_Program_Error;
                  when Connections.Admission_Closed =>
                     Result := Raised_Admission_Closed;
                  when Flyology.IO.Timeout_Error =>
                     Result := Raised_Timeout;
                  when Connections.Operation_Cancelled =>
                     Result := Raised_Cancelled;
               end;

               if Result /= Step.Expected then
                  raise Program_Error with
                    "unexpected result: action=" & Step.Action'Image
                    & ", expected=" & Step.Expected'Image
                    & ", got=" & Result'Image;
               end if;
               Actual_Ownership := Step.To_Ownership;
               Actual_Admission := Step.To_Admission;
               Assert_State (Step);
            end Apply;
         begin
            for Index in Lifecycle'Range loop
               Failed_At := Index;
               Apply (Lifecycle (Index));
            end loop;
            Failed_At := 0;
            Passed := True;
         exception
            when others =>
               begin
                  Connections.Close (Item);
               exception
                  when others =>
                     null;
               end;
               Close_If_Open (Owned_Socket);
               Close_If_Open (Peer);
               Close_If_Open (Candidate);
               Close_If_Open (Candidate_Peer);
         end Worker;
      begin
         null;
      end;

      if not Passed then
         raise Program_Error with
           "lifecycle table failed at step" & Failed_At'Image
           & " for " & Model'Image;
      end if;
      Assert_Descriptors (Before, "lifecycle table " & Model'Image);
   end Run_Table;

   procedure Run_Generation_Handoff
     (Model : Flyology.Execution_Model;
      Point : Testing.Barrier_Point)
   is
      Before : constant Interfaces.C.int := Open_FD_Count;
   begin
      if Point /= Testing.After_Registration
        and then Point /= Testing.After_Acquisition
      then
         raise Program_Error with "invalid generation handoff barrier";
      end if;

      declare
         Manager : aliased Connections.Server (Capacity => 1);
         Item    : Connections.Connection;
         Server, Peer : Sockets.Socket_Type;

         type Operation_Result is
           (Pending, Cancelled, Completed, Failed);

         protected Progress is
            procedure Reader_Finished (Result : Operation_Result);
            procedure Close_Finished (Succeeded : Boolean);
            entry Wait
              (Reader_Result : out Operation_Result;
               Close_OK      : out Boolean);
         private
            Reader_Outcome : Operation_Result := Pending;
            Close_Done     : Boolean := False;
            Close_Passed   : Boolean := False;
         end Progress;

         protected body Progress is
            procedure Reader_Finished (Result : Operation_Result) is
            begin
               Reader_Outcome := Result;
            end Reader_Finished;

            procedure Close_Finished (Succeeded : Boolean) is
            begin
               Close_Passed := Succeeded;
               Close_Done := True;
            end Close_Finished;

            entry Wait
              (Reader_Result : out Operation_Result;
               Close_OK      : out Boolean)
              when Reader_Outcome /= Pending and then Close_Done
            is
            begin
               Reader_Result := Reader_Outcome;
               Close_OK := Close_Passed;
            end Wait;
         end Progress;

         Reader_Result : Operation_Result;
         Close_OK      : Boolean;
      begin
         Testing.Reset_Barriers;
         Testing.Arm (Point);
         Sockets.Create_Socket_Pair (Server, Peer);
         Connections.Take (Manager, Server, Item);

         declare
            task Reader is
               pragma Task_Info (Model);
            end Reader;

            task Closer is
               entry Start;
            end Closer;

            task body Reader is
               Data : Ada.Streams.Stream_Element_Array (1 .. 1);
            begin
               begin
                  Item.Receive_Exactly (Data, Timeout => -1.0);
                  Progress.Reader_Finished (Completed);
               exception
                  when Connections.Operation_Cancelled =>
                     Progress.Reader_Finished (Cancelled);
                  when others =>
                     Progress.Reader_Finished (Failed);
               end;
            end Reader;

            task body Closer is
               Succeeded : Boolean := False;
            begin
               accept Start;
               begin
                  Connections.Close (Item);
                  Succeeded := True;
               exception
                  when others =>
                     null;
               end;
               Progress.Close_Finished (Succeeded);
            end Closer;
         begin
            Testing.Wait_Reached (Point);
            if Point = Testing.After_Registration then
               if Testing.Operation_Active (Item)
                 or else Testing.Waiting_Operations (Item) /= 1
               then
                  raise Program_Error with
                    "registration barrier exposed the wrong state";
               end if;
            elsif not Testing.Operation_Active (Item)
              or else Testing.Waiting_Operations (Item) /= 0
            then
               raise Program_Error with
                 "acquisition barrier exposed the wrong state";
            end if;

            Closer.Start;
            declare
               Deadline : constant Ada.Real_Time.Time :=
                 Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
            begin
               while not Testing.Close_Requested (Item) loop
                  if Ada.Real_Time.Clock >= Deadline then
                     raise Program_Error with
                       "close did not publish its generation barrier";
                  end if;
                  delay 0.001;
               end loop;
            end;
            Testing.Release (Point);
            select
               Progress.Wait (Reader_Result, Close_OK);
            or
               delay 2.0;
               raise Program_Error with
                 "generation handoff did not drain";
            end select;
         exception
            when others =>
               Testing.Release (Point);
               Close_If_Open (Peer);
               raise;
         end;

         if Reader_Result /= Cancelled or else not Close_OK
           or else Connections.Is_Open (Item)
           or else Manager.Active /= 0
           or else Testing.Operation_Active (Item)
           or else Testing.Waiting_Operations (Item) /= 0
         then
            raise Program_Error with
              "old connection generation did not terminate cleanly";
         end if;

         --  Reuse the same controller immediately. A stale operation from the
         --  old generation must neither consume this byte nor cancel the new
         --  owner.
         Close_If_Open (Peer);
         Sockets.Create_Socket_Pair (Server, Peer);
         Connections.Take (Manager, Server, Item);
         declare
            Expected : constant Ada.Streams.Stream_Element_Array (1 .. 1) :=
              [1 => 16#6D#];
            Data : Ada.Streams.Stream_Element_Array (1 .. 1);
            Last : Ada.Streams.Stream_Element_Offset;
         begin
            Sockets.Send_Socket (Peer, Expected, Last);
            if Last /= Expected'Last then
               raise Program_Error with "generation send was incomplete";
            end if;
            Item.Receive_Exactly (Data, Timeout => 1.0);
            if Data /= Expected then
               raise Program_Error with "new generation received stale data";
            end if;
         end;
         Connections.Close (Item);
         Close_If_Open (Peer);
         Testing.Reset_Barriers;
      exception
         when others =>
            Testing.Release (Point);
            begin
               Connections.Close (Item);
            exception
               when others =>
                  null;
            end;
            Close_If_Open (Server);
            Close_If_Open (Peer);
            raise;
      end;

      Assert_Descriptors
        (Before,
         "generation handoff " & Model'Image & "/" & Point'Image);
   end Run_Generation_Handoff;

begin

   --  Lazy event-loop descriptors are process-lifetime resources. Start the
   --  loop before taking per-scenario descriptor baselines.
   declare
      task Warmup is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Warmup;
      task body Warmup is
      begin
         delay 0.0;
      end Warmup;
   begin
      null;
   end;

   Run_Table (Flyology.Lightweight_Task);
   Run_Table (Flyology.Native_Task);
   for Point in Testing.Barrier_Point range
     Testing.After_Registration .. Testing.After_Acquisition
   loop
      Run_Generation_Handoff (Flyology.Lightweight_Task, Point);
      Run_Generation_Handoff (Flyology.Native_Task, Point);
   end loop;
end Connection_State_Model;
