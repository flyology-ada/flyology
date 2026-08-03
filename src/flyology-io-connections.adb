with Ada.Real_Time;
with Flyology.IO.Sockets;
with Flyology.Time_Math;
with Interfaces.C;

package body Flyology.IO.Connections is
   package Sockets renames GNAT.Sockets;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.C.int;
   use type Sockets.Socket_Type;

   protected body Descriptor_Controller is
      procedure Adopt
        (FD     : Descriptor;
         Socket : Sockets.Socket_Type;
         Owner  : Server_Access)
      is
      begin
         if FD < 0
           or else Socket = Sockets.No_Socket
           or else Flyology.IO.Sockets.Native_Descriptor (Socket) /= FD
           or else Owner = null
           or else Current_FD >= 0
           or else Active
           or else Closing
         then
            raise Program_Error with
              "descriptor controller already owns a resource";
         end if;
         Wake_Sources.Ensure (Close_Wake);
         Current_Socket := Socket;
         Current_Owner := Owner;
         Current_FD := FD;
         Current_Generation := Current_Generation + 1;
      end Adopt;

      entry Acquire
        (FD           : out Descriptor;
         Generation   : out Descriptor_Generation;
         Close_Source : out Descriptor;
         Socket       : out Sockets.Socket_Type;
         Owner        : out Server_Access)
        when not Active
      is
      begin
         if Current_FD < 0
           or else Closing
           or else Current_Socket = Sockets.No_Socket
           or else Current_Owner = null
         then
            raise Program_Error with "connection is not open";
         end if;
         Active := True;
         FD := Current_FD;
         Generation := Current_Generation;
         Close_Source := Wake_Sources.Descriptor (Close_Wake);
         Socket := Current_Socket;
         Owner := Current_Owner;
      end Acquire;

      procedure Release (Generation : Descriptor_Generation) is
      begin
         if not Active or else Generation /= Current_Generation then
            raise Program_Error with "stale descriptor operation release";
         end if;
         Active := False;
      end Release;

      procedure Begin_Close
        (FD         : out Descriptor;
         Generation : out Descriptor_Generation;
         Leader     : out Boolean)
      is
      begin
         FD := Current_FD;
         Generation := Current_Generation;
         Leader := Current_FD >= 0 and then not Closing;
         if Leader then
            Closing := True;
            if Active then
               Wake_Sources.Signal (Close_Wake);
            end if;
         end if;
      end Begin_Close;

      entry Await_Drained
        (Socket : out Sockets.Socket_Type;
         Owner  : out Server_Access)
        when not Active
      is
      begin
         if not Closing
           or else Current_FD < 0
           or else Current_Socket = Sockets.No_Socket
           or else Current_Owner = null
         then
            raise Program_Error with "invalid descriptor close handoff";
         end if;
         Socket := Current_Socket;
         Owner := Current_Owner;
         Current_Socket := Sockets.No_Socket;
         Current_Owner := null;
      end Await_Drained;

      entry Await_Closed when not Closing is
      begin
         null;
      end Await_Closed;

      procedure Finish_Close (Generation : Descriptor_Generation) is
      begin
         if not Closing
           or else Active
           or else Generation /= Current_Generation
           or else Current_Socket /= Sockets.No_Socket
           or else Current_Owner /= null
         then
            raise Program_Error with "stale descriptor close completion";
         end if;
         Current_FD := Invalid_Descriptor;
         Wake_Sources.Release (Close_Wake);
         Closing := False;
      end Finish_Close;

      function Is_Open_State return Boolean is
        (Current_FD >= 0 and then not Closing);

   end Descriptor_Controller;

   protected body Cancellation_Token is
      procedure Request is
      begin
         if not Is_Requested then
            Wake_Sources.Signal (Wake);
            Is_Requested := True;
         end if;
      end Request;

      function Requested return Boolean is (Is_Requested);

      procedure Wait_Source
        (FD : out Descriptor; Already_Requested : out Boolean)
      is
      begin
         Already_Requested := Is_Requested;
         if Is_Requested then
            FD := Invalid_Descriptor;
         else
            Wake_Sources.Ensure (Wake);
            FD := Wake_Sources.Descriptor (Wake);
         end if;
      end Wait_Source;
   end Cancellation_Token;

   protected body Server is
      entry Acquire (Accepted : out Boolean)
        when Stopping or else Active_Count < Capacity
      is
      begin
         Accepted := not Stopping;
         if Accepted then
            Active_Count := Active_Count + 1;
         end if;
      end Acquire;

      procedure Release is
      begin
         if Active_Count = 0 then
            raise Program_Error with "connection permit released twice";
         end if;
         Active_Count := Active_Count - 1;
      end Release;

      procedure Request_Shutdown is
      begin
         if not Stopping then
            Wake_Sources.Signal (Wake);
            Stopping := True;
         end if;
      end Request_Shutdown;

      entry Await_Drained when Stopping and then Active_Count = 0 is
      begin
         null;
      end Await_Drained;

      function Shutdown_Requested return Boolean is (Stopping);
      function Active return Natural is (Active_Count);
      function Waiting return Natural is (Acquire'Count);

      procedure Wait_Source
        (FD : out Descriptor; Already_Requested : out Boolean)
      is
      begin
         Already_Requested := Stopping;
         if Stopping then
            FD := Invalid_Descriptor;
         else
            Wake_Sources.Ensure (Wake);
            FD := Wake_Sources.Descriptor (Wake);
         end if;
      end Wait_Source;
   end Server;

   function Remaining
     (Started : Ada.Real_Time.Time;
      Timeout : Duration) return Duration
   is
   begin
      if Timeout < 0.0 then
         return Infinite;
      end if;
      return Time_Math.Remaining
        (Timeout,
         Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started));
   end Remaining;

   procedure Interrupt_Sources
     (Owner       : not null Server_Access;
      Token       : access Cancellation_Token;
      Interrupt_1 : out Descriptor;
      Interrupt_2 : out Descriptor)
   is
      Shutdown : Boolean;
      Cancel   : Boolean := False;
   begin
      Owner.Wait_Source (Interrupt_1, Shutdown);
      if Token = null then
         Interrupt_2 := Invalid_Descriptor;
      else
         Token.Wait_Source (Interrupt_2, Cancel);
      end if;
      if Shutdown or else Cancel then
         raise Operation_Cancelled;
      end if;
   end Interrupt_Sources;

   procedure Reserve
     (Manager : aliased in out Server;
      Owner   : out Server_Access)
   is
      Accepted : Boolean;
   begin
      Manager.Acquire (Accepted);
      if not Accepted then
         raise Admission_Closed;
      end if;
      Owner := Manager'Unchecked_Access;
   end Reserve;

   procedure Take
     (Manager : aliased in out Server;
      Socket  : in out Sockets.Socket_Type;
      Item    : in out Connection)
   is
      Owner    : Server_Access;
      Reserved : Boolean := False;
   begin
      if Socket = Sockets.No_Socket then
         raise Program_Error with "cannot own No_Socket";
      elsif Is_Open (Item) then
         raise Program_Error with "connection already owns a socket";
      end if;

      Reserve (Manager, Owner);
      Reserved := True;
      begin
         Item.Controller.Adopt
           (Flyology.IO.Sockets.Native_Descriptor (Socket),
            Socket,
            Owner);
         Reserved := False;
         Socket := Sockets.No_Socket;
      exception
         when others =>
            if Reserved then
               Owner.Release;
            end if;
            raise;
      end;
   end Take;

   procedure Accept_Connection
     (Manager              : aliased in out Server;
      Listener             : Sockets.Socket_Type;
      Item                 : in out Connection;
      Address              : out Sockets.Sock_Addr_Type;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   is
      Owner    : Server_Access;
      Socket   : Sockets.Socket_Type := Sockets.No_Socket;
      Reserved : Boolean := False;
      Shutdown : Boolean;
      Cancel   : Boolean := False;
      Interrupt_1 : Descriptor;
      Interrupt_2 : Descriptor;
      pragma Unreferenced (Cancellation_Quantum);
   begin
      if Is_Open (Item) then
         raise Program_Error with "connection already owns a socket";
      end if;
      Reserve (Manager, Owner);
      Reserved := True;

      Manager.Wait_Source (Interrupt_1, Shutdown);
      if Token = null then
         Interrupt_2 := Invalid_Descriptor;
      else
         Token.Wait_Source (Interrupt_2, Cancel);
      end if;
      if Shutdown or else Cancel then
         raise Operation_Cancelled;
      end if;

      begin
         Flyology.IO.Sockets.Accept_Connection
           (Listener, Socket, Address, Timeout, Interrupt_1, Interrupt_2);
      exception
         when Flyology.IO.Sockets.Operation_Interrupted =>
            raise Operation_Cancelled;
      end;
      if Manager.Shutdown_Requested
        or else (Token /= null and then Token.Requested)
      then
         raise Operation_Cancelled;
      end if;
      Item.Controller.Adopt
        (Flyology.IO.Sockets.Native_Descriptor (Socket), Socket, Owner);
      Reserved := False;
   exception
      when others =>
         if Reserved then
            Owner.Release;
         end if;
         --  Capacity is released before a fallible cleanup close so a close
         --  error cannot strand the admission permit.
         if Socket /= Sockets.No_Socket then
            Sockets.Close_Socket (Socket);
         end if;
         raise;
   end Accept_Connection;

   procedure Close (Item : in out Connection) is
      FD         : Descriptor;
      Generation : Descriptor_Generation;
      Leader     : Boolean;
      Socket     : Sockets.Socket_Type;
      Owner      : Server_Access;
   begin
      Item.Controller.Begin_Close (FD, Generation, Leader);
      if not Leader then
         if FD >= 0 then
            Item.Controller.Await_Closed;
         end if;
         return;
      end if;

      --  The exact generation remains allocated until its sole operation has
      --  observed Close_Wake and acknowledged release. Only then may the OS
      --  recycle the integer descriptor.
      Item.Controller.Await_Drained (Socket, Owner);
      if Socket /= Sockets.No_Socket then
         begin
            Sockets.Close_Socket (Socket);
         exception
            when others =>
               Item.Controller.Finish_Close (Generation);
               if Owner /= null then
                  Owner.Release;
               end if;
               raise;
         end;
      end if;
      Item.Controller.Finish_Close (Generation);
      if Owner /= null then
         Owner.Release;
      end if;
   end Close;

   function Is_Open (Item : Connection) return Boolean is
     (Item.Controller.Is_Open_State);

   procedure Receive
     (Item                 : in out Connection;
      Data                 : out Ada.Streams.Stream_Element_Array;
      Last                 : out Ada.Streams.Stream_Element_Offset;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   is
      Interrupt_1 : Descriptor;
      Interrupt_2 : Descriptor;
      Close_Interrupt : Descriptor;
      FD : Descriptor;
      Generation : Descriptor_Generation;
      Socket : Sockets.Socket_Type;
      Owner : Server_Access;
      pragma Unreferenced (Cancellation_Quantum);
   begin
      Item.Controller.Acquire
        (FD, Generation, Close_Interrupt, Socket, Owner);
      pragma Assert (FD = Flyology.IO.Sockets.Native_Descriptor (Socket));
      begin
         Interrupt_Sources (Owner, Token, Interrupt_1, Interrupt_2);
         Flyology.IO.Sockets.Receive
           (Socket, Data, Last, Timeout,
            Close_Interrupt, Interrupt_1, Interrupt_2);
      exception
         when Flyology.IO.Sockets.Operation_Interrupted =>
            Item.Controller.Release (Generation);
            raise Operation_Cancelled;
         when others =>
            Item.Controller.Release (Generation);
            raise;
      end;
      Item.Controller.Release (Generation);
   end Receive;

   procedure Receive_Exactly
     (Item                 : in out Connection;
      Data                 : out Ada.Streams.Stream_Element_Array;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      First   : Ada.Streams.Stream_Element_Offset := Data'First;
      Last    : Ada.Streams.Stream_Element_Offset;
   begin
      while First <= Data'Last loop
         Receive
           (Item,
            Data (First .. Data'Last),
            Last,
            Remaining (Started, Timeout),
            Cancellation_Quantum,
            Token);
         if Last < First then
            raise Device_Error with "connection closed while receiving";
         end if;
         First := Last + 1;
      end loop;
   end Receive_Exactly;

   procedure Send_All
     (Item                 : in out Connection;
      Data                 : Ada.Streams.Stream_Element_Array;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      First   : Ada.Streams.Stream_Element_Offset := Data'First;
      Last    : Ada.Streams.Stream_Element_Offset;
      Interrupt_1 : Descriptor;
      Interrupt_2 : Descriptor;
      Close_Interrupt : Descriptor;
      FD : Descriptor;
      Generation : Descriptor_Generation;
      Socket : Sockets.Socket_Type;
      Owner : Server_Access;
      pragma Unreferenced (Cancellation_Quantum);
   begin
      Item.Controller.Acquire
        (FD, Generation, Close_Interrupt, Socket, Owner);
      pragma Assert (FD = Flyology.IO.Sockets.Native_Descriptor (Socket));
      begin
         while First <= Data'Last loop
            Interrupt_Sources (Owner, Token, Interrupt_1, Interrupt_2);
            Flyology.IO.Sockets.Send
              (Socket,
               Data (First .. Data'Last),
               Last,
               Remaining (Started, Timeout),
               Close_Interrupt,
               Interrupt_1,
               Interrupt_2);
            if Last < First then
               raise Device_Error with "connection closed while sending";
            end if;
            First := Last + 1;
         end loop;
      exception
         when Flyology.IO.Sockets.Operation_Interrupted =>
            Item.Controller.Release (Generation);
            raise Operation_Cancelled;
         when others =>
            Item.Controller.Release (Generation);
            raise;
      end;
      Item.Controller.Release (Generation);
   end Send_All;

   overriding procedure Finalize (Item : in out Connection) is
   begin
      Close (Item);
   exception
      --  Close clears ownership and releases admission even when the OS close
      --  reports an error. Finalization must not mask an enclosing exception.
      when others =>
         null;
   end Finalize;

end Flyology.IO.Connections;
