with Ada.Real_Time;
with Gnatevl.IO.Sockets;
with Gnatevl.Time_Math;

package body Gnatevl.IO.Connections is
   package Sockets renames GNAT.Sockets;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Sockets.Socket_Type;

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
     (Item        : Connection;
      Token       : access Cancellation_Token;
      Interrupt_1 : out Descriptor;
      Interrupt_2 : out Descriptor)
   is
      Shutdown : Boolean;
      Cancel   : Boolean := False;
   begin
      Item.Owner.Wait_Source (Interrupt_1, Shutdown);
      if Token = null then
         Interrupt_2 := Invalid_Descriptor;
      else
         Token.Wait_Source (Interrupt_2, Cancel);
      end if;
      if Shutdown or else Cancel then
         raise Operation_Cancelled;
      end if;
   end Interrupt_Sources;

   procedure Check_Open (Item : Connection) is
   begin
      if Item.Socket = Sockets.No_Socket or else Item.Owner = null then
         raise Program_Error with "connection is not open";
      end if;
   end Check_Open;

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
      Owner : Server_Access;
   begin
      if Socket = Sockets.No_Socket then
         raise Program_Error with "cannot own No_Socket";
      elsif Is_Open (Item) then
         raise Program_Error with "connection already owns a socket";
      end if;

      Reserve (Manager, Owner);
      Item.Owner := Owner;
      Item.Socket := Socket;
      Socket := Sockets.No_Socket;
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
         Gnatevl.IO.Sockets.Accept_Connection
           (Listener, Socket, Address, Timeout, Interrupt_1, Interrupt_2);
      exception
         when Gnatevl.IO.Sockets.Operation_Interrupted =>
            raise Operation_Cancelled;
      end;
      if Manager.Shutdown_Requested
        or else (Token /= null and then Token.Requested)
      then
         raise Operation_Cancelled;
      end if;
      Item.Owner := Owner;
      Item.Socket := Socket;
      Reserved := False;
   exception
      when others =>
         if Socket /= Sockets.No_Socket then
            Sockets.Close_Socket (Socket);
         end if;
         if Reserved then
            Owner.Release;
         end if;
         raise;
   end Accept_Connection;

   procedure Close (Item : in out Connection) is
      Socket : constant Sockets.Socket_Type := Item.Socket;
      Owner  : constant Server_Access := Item.Owner;
   begin
      Item.Socket := Sockets.No_Socket;
      Item.Owner := null;
      if Socket /= Sockets.No_Socket then
         begin
            Sockets.Close_Socket (Socket);
         exception
            when others =>
               if Owner /= null then
                  Owner.Release;
               end if;
               raise;
         end;
      end if;
      if Owner /= null then
         Owner.Release;
      end if;
   end Close;

   function Is_Open (Item : Connection) return Boolean is
     (Item.Socket /= Sockets.No_Socket and then Item.Owner /= null);

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
      pragma Unreferenced (Cancellation_Quantum);
   begin
      Check_Open (Item);
      Interrupt_Sources (Item, Token, Interrupt_1, Interrupt_2);
      begin
         Gnatevl.IO.Sockets.Receive
           (Item.Socket, Data, Last, Timeout, Interrupt_1, Interrupt_2);
      exception
         when Gnatevl.IO.Sockets.Operation_Interrupted =>
            raise Operation_Cancelled;
      end;
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
      Check_Open (Item);
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
      pragma Unreferenced (Cancellation_Quantum);
   begin
      Check_Open (Item);
      while First <= Data'Last loop
         Interrupt_Sources (Item, Token, Interrupt_1, Interrupt_2);
         begin
            Gnatevl.IO.Sockets.Send
              (Item.Socket,
               Data (First .. Data'Last),
               Last,
               Remaining (Started, Timeout),
               Interrupt_1,
               Interrupt_2);
            if Last < First then
               raise Device_Error with "connection closed while sending";
            end if;
            First := Last + 1;
         exception
            when Gnatevl.IO.Sockets.Operation_Interrupted =>
               raise Operation_Cancelled;
         end;
      end loop;
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

end Gnatevl.IO.Connections;
