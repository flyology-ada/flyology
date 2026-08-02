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
         Is_Requested := True;
      end Request;

      function Requested return Boolean is (Is_Requested);
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
         Stopping := True;
      end Request_Shutdown;

      entry Await_Drained when Stopping and then Active_Count = 0 is
      begin
         null;
      end Await_Drained;

      function Shutdown_Requested return Boolean is (Stopping);
      function Active return Natural is (Active_Count);
      function Waiting return Natural is (Acquire'Count);
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

   function Window
     (Started : Ada.Real_Time.Time;
      Timeout : Duration;
      Quantum : Duration) return Duration
   is
      Left : constant Duration := Remaining (Started, Timeout);
   begin
      if Left < 0.0 then
         return Quantum;
      else
         return Duration'Min (Left, Quantum);
      end if;
   end Window;

   function Cancelled
     (Item  : Connection;
      Token : access Cancellation_Token) return Boolean
   is
   begin
      return (Item.Owner /= null and then Item.Owner.Shutdown_Requested)
        or else (Token /= null and then Token.Requested);
   end Cancelled;

   procedure Check_Cancellation
     (Item  : Connection;
      Token : access Cancellation_Token)
   is
   begin
      if Cancelled (Item, Token) then
         raise Operation_Cancelled;
      end if;
   end Check_Cancellation;

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
      Started  : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Owner    : Server_Access;
      Socket   : Sockets.Socket_Type := Sockets.No_Socket;
      Reserved : Boolean := False;
   begin
      if Is_Open (Item) then
         raise Program_Error with "connection already owns a socket";
      end if;
      Reserve (Manager, Owner);
      Reserved := True;

      loop
         if Manager.Shutdown_Requested
           or else (Token /= null and then Token.Requested)
         then
            raise Operation_Cancelled;
         end if;
         begin
            Gnatevl.IO.Sockets.Accept_Connection
              (Listener,
               Socket,
               Address,
               Window (Started, Timeout, Cancellation_Quantum));
            if Manager.Shutdown_Requested
              or else (Token /= null and then Token.Requested)
            then
               raise Operation_Cancelled;
            end if;
            Item.Owner := Owner;
            Item.Socket := Socket;
            Reserved := False;
            return;
         exception
            when Timeout_Error =>
               if Timeout >= 0.0 and then Remaining (Started, Timeout) = 0.0
               then
                  raise;
               end if;
         end;
      end loop;
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
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      Check_Open (Item);
      loop
         Check_Cancellation (Item, Token);
         begin
            Gnatevl.IO.Sockets.Receive
              (Item.Socket,
               Data,
               Last,
               Window (Started, Timeout, Cancellation_Quantum));
            return;
         exception
            when Timeout_Error =>
               Check_Cancellation (Item, Token);
               if Timeout >= 0.0 and then Remaining (Started, Timeout) = 0.0
               then
                  raise;
               end if;
         end;
      end loop;
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
   begin
      Check_Open (Item);
      while First <= Data'Last loop
         Check_Cancellation (Item, Token);
         begin
            Gnatevl.IO.Sockets.Send
              (Item.Socket,
               Data (First .. Data'Last),
               Last,
               Window (Started, Timeout, Cancellation_Quantum));
            if Last < First then
               raise Device_Error with "connection closed while sending";
            end if;
            First := Last + 1;
         exception
            when Timeout_Error =>
               Check_Cancellation (Item, Token);
               if Timeout >= 0.0 and then Remaining (Started, Timeout) = 0.0
               then
                  raise;
               end if;
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
