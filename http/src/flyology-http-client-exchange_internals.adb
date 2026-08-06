separate (Flyology.HTTP.Client)
--  Owns admission, DNS, connect, TLS establishment, and shutdown/cancellation
--  translation. Protocol serialization and parsing remain in HTTP_1_Internals.
package body Exchange_Internals is
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
   function Test_Barrier_Arrive
     (Point : Interfaces.C.int) return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_connection_barrier_arrive";
   function Test_Barrier_Released
     (Point : Interfaces.C.int) return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_connection_barrier_released";

   procedure Test_Barrier (Point : Interfaces.C.int) is
   begin
      if Test_Barrier_Arrive (Point) /= 0 then
         while Test_Barrier_Released (Point) = 0 loop
            delay 0.0;
         end loop;
      end if;
   end Test_Barrier;
#end if;

   procedure Check_Deadline
     (Started : Ada.Real_Time.Time; Timeout : Duration) is
   begin
      if Timeout >= 0.0 and then Remaining (Started, Timeout) <= 0.0 then
         raise Flyology.IO.Timeout_Error;
      end if;
   end Check_Deadline;

   procedure Interrupt_Sources
     (State   : not null Client_State_Access;
      Token   : access Flyology.Cancellation.Token;
      Sources : out Flyology.IO.Interrupt_Set;
      Count   : out Natural)
   is
      FD        : Flyology.IO.Descriptor;
      Requested : Boolean;
   begin
      Count := 0;
      State.Pool.Shutdown_Source (FD, Requested);
      if Requested then
         raise Client_Closed;
      end if;
      Count := Count + 1;
      Sources (Sources'First + Count - 1) := FD;
      if Token /= null then
         Token.Wait_Source (FD, Requested);
         if Requested then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         Count := Count + 1;
         Sources (Sources'First + Count - 1) := FD;
      end if;
   end Interrupt_Sources;

   procedure Translate_Interruption
     (State : not null Client_State_Access;
      Token : access Flyology.Cancellation.Token)
   is
      FD : Flyology.IO.Descriptor;
      Requested : Boolean;
   begin
      State.Pool.Shutdown_Source (FD, Requested);
      if Requested then
         raise Client_Closed;
      elsif Token /= null and then Token.Requested then
         raise Flyology.Cancellation.Operation_Cancelled;
      else
         raise Flyology.Cancellation.Operation_Cancelled;
      end if;
   end Translate_Interruption;

   procedure Establish
     (State      : not null Client_State_Access;
      Slot_Index : Positive;
      Connection : in out Pooled_Connection_Access;
      Started    : Ada.Real_Time.Time;
      Timeout    : Duration;
      Token      : access Flyology.Cancellation.Token)
   is
      Socket    : Sockets.Socket_Type;
      Connected : Boolean := False;

      procedure Cleanup is
      begin
         if Sockets.Is_Open (Socket) then
            begin
               Sockets.Close_Socket (Socket);
            exception
               when others => null;
            end;
         end if;
         if Connection /= null then
            begin
               Connections.Close (Connection.Channel);
            exception
               when others => null;
            end;
         end if;
      end Cleanup;
   begin
      declare
         Sources : Flyology.IO.Interrupt_Set (1 .. 2);
         Count   : Natural;
      begin
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
         Test_Barrier (15);
#end if;
         Interrupt_Sources (State, Token, Sources, Count);
         Check_Deadline (Started, Timeout);
         declare
            Addresses : constant Flyology.IO.DNS.Address_Array :=
              Flyology.IO.DNS.Resolve
                (Host (State.Origin_Value),
                 Timeout => Remaining (Started, Timeout),
                 Interrupts => Sources (1 .. Count));
         begin
            for Address of Addresses loop
               begin
                  Sockets.Create_Socket (Socket, Address.Family);
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
                  Test_Barrier (16);
#end if;
                  Interrupt_Sources (State, Token, Sources, Count);
                  Check_Deadline (Started, Timeout);
                  Sockets.Connect
                    (Socket,
                     Sockets.Network_Endpoint
                       (Address, Sockets.Port (Port (State.Origin_Value))),
                     Remaining (Started, Timeout), Sources (1 .. Count));
                  Connected := True;
               exception
                  when Sockets.Operation_Interrupted =>
                     if Sockets.Is_Open (Socket) then
                        Sockets.Close_Socket (Socket);
                     end if;
                     Translate_Interruption (State, Token);
                  when Flyology.IO.Timeout_Error =>
                     if Sockets.Is_Open (Socket) then
                        Sockets.Close_Socket (Socket);
                     end if;
                     raise;
                  when Sockets.Socket_Error | Flyology.IO.Device_Error =>
                     if Sockets.Is_Open (Socket) then
                        begin
                           Sockets.Close_Socket (Socket);
                        exception
                           when others => null;
                        end;
                     end if;
               end;
               exit when Connected;
            end loop;
         end;
      end;

      if not Connected then
         raise Connection_Error with "all resolved HTTP endpoints failed";
      end if;

      Connection := new Pooled_Connection;
      Connections.Take (State.Manager, Socket, Connection.Channel);
      State.Pool.Publish_Connecting (Slot_Index, Connection);
      if Scheme (State.Origin_Value) = Secure_HTTPS then
         Flyology.IO.Connections.TLS.Upgrade
           (Connection.Channel, State.Backend.all,
            Flyology.IO.TLS.Client, Host (State.Origin_Value),
            Remaining (Started, Timeout), Token);
      end if;
   exception
      when Flyology.IO.DNS.Operation_Cancelled =>
         Cleanup;
         Translate_Interruption (State, Token);
      when Flyology.IO.DNS.Name_Not_Found |
           Flyology.IO.DNS.Resolution_Failed |
           Flyology.IO.DNS.Malformed_Response =>
         Cleanup;
         raise Connection_Error with "HTTP origin resolution failed";
      when Connections.Admission_Closed =>
         Cleanup;
         raise Client_Closed;
      when Flyology.Cancellation.Operation_Cancelled =>
         Cleanup;
         Translate_Interruption (State, Token);
      when others =>
         Cleanup;
         raise;
   end Establish;

   procedure Wait_For_Pool
     (State   : not null Client_State_Access;
      Started : Ada.Real_Time.Time;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      Pool_FD   : Flyology.IO.Descriptor;
      Token_FD  : Flyology.IO.Descriptor := Flyology.IO.Invalid_Descriptor;
      Ready_Now : Boolean;
      Cancelled : Boolean := False;
      Index     : Natural;
   begin
      State.Pool.Wait_Source (Pool_FD, Ready_Now);
      if Ready_Now then
         return;
      end if;
      if Token /= null then
         Token.Wait_Source (Token_FD, Cancelled);
         if Cancelled then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
      end if;
      if Token = null then
         declare
            Sources : Flyology.IO.Wait_Request_Array (1 .. 1);
         begin
            Sources (1) :=
              (FD => Pool_FD, Condition => Flyology.IO.For_Read);
            Index := Flyology.IO.Wait_Any
              (Sources, Remaining (Started, Timeout));
         end;
      else
         declare
            Sources : Flyology.IO.Wait_Request_Array (1 .. 2);
         begin
            Sources (1) :=
              (FD => Pool_FD, Condition => Flyology.IO.For_Read);
            Sources (2) :=
              (FD => Token_FD, Condition => Flyology.IO.For_Read);
            Index := Flyology.IO.Wait_Any
              (Sources, Remaining (Started, Timeout));
         end;
      end if;
      if Index = 0 then
         State.Pool.Record_Admission_Timeout;
         raise Flyology.IO.Timeout_Error;
      elsif Index = 2 then
         raise Flyology.Cancellation.Operation_Cancelled;
      end if;
   end Wait_For_Pool;

   procedure Checkout
     (Item       : in out Client;
      Connection : out Pooled_Connection_Access;
      Slot_Index : out Positive;
      Was_Reused : out Boolean;
      Started    : Ada.Real_Time.Time;
      Timeout    : Duration;
      Token      : access Flyology.Cancellation.Token)
   is
      Result : Checkout_Result;
      Index  : Natural;
      Value  : Pooled_Connection_Access;
      Waiting : Boolean := False;
   begin
      if Item.Control.State = null
        or else not Item.Control.State.Is_Configured
      then
         raise Program_Error with "HTTP client is not configured";
      end if;
      Was_Reused := False;
      loop
         Item.Control.State.Pool.Try_Checkout
           (Ada.Real_Time.Clock, Result, Index, Value);
         case Result is
            when Checkout_Idle =>
               if Waiting then
                  Item.Control.State.Pool.Unregister_Waiter;
                  Waiting := False;
               end if;
               Connection := Value;
               Slot_Index := Positive (Index);
               Was_Reused := True;
               return;
            when Checkout_Create =>
               begin
                  Establish
                    (Item.Control.State, Positive (Index), Value,
                     Started, Timeout, Token);
                  Item.Control.State.Pool.Install
                    (Positive (Index), Value, Ada.Real_Time.Clock);
               exception
                  when others =>
                     declare
                        Failure : Failure_Result;
                     begin
                        Item.Control.State.Pool.Creation_Failed
                          (Positive (Index), Failure);
                        if Failure = Failure_Free and then Value /= null then
                           Free_Connection (Value);
                        end if;
                     end;
                     if Waiting then
                        Item.Control.State.Pool.Unregister_Waiter;
                        Waiting := False;
                     end if;
                     raise;
               end;
               if Waiting then
                  Item.Control.State.Pool.Unregister_Waiter;
                  Waiting := False;
               end if;
               Connection := Value;
               Slot_Index := Positive (Index);
               Was_Reused := False;
               return;
            when Checkout_Discard =>
               Close_And_Finish
                 (Item.Control.State, Positive (Index), Value);
            when Checkout_Busy =>
               if not Waiting then
                  Item.Control.State.Pool.Register_Waiter;
                  Waiting := True;
               end if;
               Wait_For_Pool
                 (Item.Control.State, Started, Timeout, Token);
            when Checkout_Closed =>
               if Waiting then
                  Item.Control.State.Pool.Unregister_Waiter;
                  Waiting := False;
               end if;
               raise Client_Closed;
         end case;
      end loop;
   exception
      when others =>
         if Waiting then
            begin
               Item.Control.State.Pool.Unregister_Waiter;
            exception
               when others => null;
            end;
         end if;
         raise;
   end Checkout;
end Exchange_Internals;
