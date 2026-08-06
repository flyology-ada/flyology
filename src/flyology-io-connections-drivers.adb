with Ada.Exceptions;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.IO.TLS_Driver;

package body Flyology.IO.Connections.Drivers is
   package Sockets renames Flyology.IO.Sockets;
   package TLS renames Flyology.IO.TLS;

   use type Ada.Streams.Stream_Element_Offset;
   use type Sockets.Error_Type;
   use type TLS.Session_Access;
   use type TLS.Step_Status;

   protected body Wakeup_Controller is
      procedure Signal is
      begin
         if Pending then
            return;
         end if;
         --  Publish the logical event before the fallible descriptor signal.
         --  A failed signal is still observed synchronously by Wait_Source.
         Pending := True;
         Wake_Sources.Signal (Wake);
         Signalled := True;
      end Signal;

      procedure Wait_Source
        (FD : out Descriptor; Already_Pending : out Boolean)
      is
      begin
         Already_Pending := Pending;
         if Pending then
            FD := Invalid_Descriptor;
         else
            Wake_Sources.Ensure (Wake);
            FD := Wake_Sources.Descriptor (Wake);
         end if;
      end Wait_Source;

      procedure Consume is
      begin
         if not Pending then
            raise Program_Error with "no protocol wakeup is pending";
         end if;
         if Signalled then
            Wake_Sources.Consume (Wake);
         end if;
         Pending := False;
         Signalled := False;
      end Consume;
   end Wakeup_Controller;

   procedure Signal (Item : in out Outbound_Wakeup) is
   begin
      Item.Controller.Signal;
   end Signal;

   procedure Check (Item : in out Capability) is
   begin
      Check_TLS_Operation
        (Item.Item.all, Item.Guard.Generation, Item.Owner, Item.Token);
      if Item.Deadline >= 0.0
        and then Remaining (Item.Started, Item.Deadline) = 0.0
      then
         raise Timeout_Error with "connection driver timed out";
      end if;
   end Check;

   function Mapped (Status : TLS.Step_Status) return Step_Result is
     (case Status is
         when TLS.Complete    => Made_Progress,
         when TLS.Want_Read   => Need_Read,
         when TLS.Want_Write  => Need_Write,
         when TLS.Peer_Closed => Peer_Closed,
         when TLS.Failed      => raise Program_Error with
           "TLS driver returned an unhandled failure");

   procedure Receive
     (Item   : in out Capability;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Step_Result)
   is
      Status : TLS.Step_Status;
   begin
      Last := Data'First - 1;
      Check (Item);
      case Item.Transport is
         when TLS_Transport =>
            if Item.Item.TLS_Session = null then
               raise Program_Error with
                 "TLS transport has no provider session";
            end if;
            TLS_Driver.Receive_Once
              (Item.Item.TLS_Session.all, Data, Last, Status);
            Result := Mapped (Status);
         when Plain_Transport =>
            begin
               Sockets.Receive_Socket (Item.Guard.Socket, Data, Last);
               Result :=
                 (if Data'Length = 0 or else Last >= Data'First
                  then Made_Progress
                  else Peer_Closed);
            exception
               when Occurrence : Sockets.Socket_Error =>
                  if Sockets.Resolve_Exception (Occurrence) in
                    Sockets.Resource_Temporarily_Unavailable |
                    Sockets.Interrupted_System_Call
                  then
                     Last := Data'First - 1;
                     Result := Need_Read;
                  else
                     Ada.Exceptions.Reraise_Occurrence (Occurrence);
                  end if;
            end;
         when No_Transport | TLS_Upgrading =>
            raise Program_Error with "connection driver transport is invalid";
      end case;
   end Receive;

   procedure Send
     (Item   : in out Capability;
      Data   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Step_Result)
   is
      Status : TLS.Step_Status;
   begin
      Last := Data'First - 1;
      Check (Item);
      case Item.Transport is
         when TLS_Transport =>
            if Item.Item.TLS_Session = null then
               raise Program_Error with
                 "TLS transport has no provider session";
            end if;
            TLS_Driver.Send_Once
              (Item.Item.TLS_Session.all, Data, Last, Status);
            Result := Mapped (Status);
         when Plain_Transport =>
            begin
               Sockets.Send_Socket (Item.Guard.Socket, Data, Last);
               Result :=
                 (if Data'Length = 0 or else Last >= Data'First
                  then Made_Progress
                  else Peer_Closed);
            exception
               when Occurrence : Sockets.Socket_Error =>
                  if Sockets.Resolve_Exception (Occurrence) in
                    Sockets.Resource_Temporarily_Unavailable |
                    Sockets.Interrupted_System_Call |
                    Sockets.No_Buffer_Space_Available
                  then
                     Last := Data'First - 1;
                     Result := Need_Write;
                  else
                     Ada.Exceptions.Reraise_Occurrence (Occurrence);
                  end if;
            end;
         when No_Transport | TLS_Upgrading =>
            raise Program_Error with "connection driver transport is invalid";
      end case;
   end Send;

   procedure Wait
     (Item     : in out Capability;
      Outbound : in out Outbound_Wakeup;
      Interest : Readiness_Interest := Read_Interest;
      Timeout  : Duration := Infinite;
      Result   : out Wait_Result)
   is
      Requests          : Wait_Request_Array (1 .. 7);
      Count             : Natural := 0;
      Outbound_FD       : Descriptor;
      Outbound_Pending  : Boolean;
      Outbound_Index    : Natural := 0;
      Interrupts        : Interrupt_Set (1 .. 2);
      Interrupt_Count   : Natural;
      Global_Remaining  : Duration;
      Wait_For          : Duration;
      Ready_Index       : Natural;

      procedure Append (FD : Descriptor; Condition : Wait_Kind) is
      begin
         Count := Count + 1;
         Requests (Count) := (FD => FD, Condition => Condition);
      end Append;
   begin
      Check (Item);
      Outbound.Controller.Wait_Source
        (Outbound_FD, Outbound_Pending);
      if Outbound_Pending then
         Outbound.Controller.Consume;
         Result := Outbound_Ready;
         return;
      end if;

      Append (Outbound_FD, For_Read);
      Outbound_Index := Count;
      if Interest.Readable then
         Append (Item.FD, For_Read);
      end if;
      if Interest.Writable then
         Append (Item.FD, For_Write);
      end if;
      Append (Item.Close_Source, For_Read);
      Interrupt_Sources
        (Item.Owner, Item.Token, Interrupts, Interrupt_Count);
      for Index in Interrupts'First .. Interrupts'First + Interrupt_Count - 1
      loop
         Append (Interrupts (Index), For_Read);
      end loop;

      Global_Remaining := Remaining (Item.Started, Item.Deadline);
      Wait_For :=
        (if Timeout < 0.0 then Global_Remaining
         elsif Item.Deadline < 0.0 then Timeout
         else Duration'Min (Timeout, Global_Remaining));
      Ready_Index := Wait_Any (Requests (1 .. Count), Wait_For);

      if Ready_Index = 0 then
         if Item.Deadline >= 0.0
           and then Remaining (Item.Started, Item.Deadline) = 0.0
         then
            raise Timeout_Error with "connection driver timed out";
         end if;
         Result := Wait_Timed_Out;
         return;
      end if;

      Check (Item);
      if Ready_Index = Outbound_Index then
         Outbound.Controller.Consume;
         Result := Outbound_Ready;
      elsif Ready_Index <=
        Outbound_Index
        + Boolean'Pos (Interest.Readable)
        + Boolean'Pos (Interest.Writable)
      then
         Result := Transport_Ready;
      else
         --  Lifecycle sources are persistent state. Check must have raised if
         --  one selected request became ready.
         raise Program_Error with "spurious connection lifecycle wakeup";
      end if;
   end Wait;

   procedure Run
     (Item    : in out Connection;
      Process : not null access procedure (IO : in out Capability);
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      IO      : Capability (Item'Unchecked_Access, Token);
   begin
      IO.Started := Started;
      IO.Deadline := Timeout;
      Acquire_Operation
        (Item'Unchecked_Access, Started, Timeout, Token, IO.FD, IO.Guard,
         IO.Close_Source, IO.Owner, IO.Transport);
      if IO.Transport not in Plain_Transport | TLS_Transport then
         raise Program_Error with "connection driver transport is invalid";
      end if;
      Sockets.Prepare (IO.Guard.Socket);
      Check (IO);
      Process.all (IO);
      Check (IO);
   end Run;

end Flyology.IO.Connections.Drivers;
