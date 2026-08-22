with Ada.Exceptions;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.IO.TLS_Driver;
with Flyology.Operations.Drivers;

package body Flyology.IO.Connections.Drivers is
   package Sockets renames Flyology.IO.Sockets;
   package TLS renames Flyology.IO.TLS;

   use type Ada.Streams.Stream_Element_Offset;
   use type Flyology.IO.Descriptor;
   use type Sockets.Error_Type;
   use type TLS.Session_Access;
   use type TLS.Step_Status;

   procedure Reset (Item : in out Capability) is
   begin
      Item.Item := null;
      Item.Token := null;
      Item.FD := Invalid_Descriptor;
      Item.Lease_Source := Invalid_Descriptor;
      Item.Initial_Close_Source := Invalid_Descriptor;
      Item.Close_Source := Invalid_Descriptor;
      Item.Owner := null;
      Item.Transport := No_Transport;
      Item.Deadline := Infinite;
   end Reset;

   procedure Release (IO : in out Capability) is
   begin
      Release_Operation (IO.Guard);
      Reset (IO);
   exception
      when others =>
         if IO.Guard.State = Unregistered then
            Reset (IO);
         end if;
         raise;
   end Release;

   overriding
   procedure Finalize (IO : in out Capability) is
   begin
      Release (IO);
   end Finalize;

   function Is_Acquired (IO : Capability) return Boolean
   is (IO.Guard.State = Acquired);

   function Is_Engaged (IO : Capability) return Boolean
   is (IO.Item /= null and then IO.Guard.State /= Unregistered);

   procedure Poll_Acquisition (IO : in out Capability; Result : out Acquisition_Result) is
      Lease      : Lease_Result;
      Interrupts : Interrupt_Set (1 .. 2);
      Count      : Natural;
   begin
      if IO.Item = null or else IO.Guard.State /= Registered then
         raise Program_Error with "connection capability is not awaiting acquisition";
      end if;
      Interrupt_Sources (IO.Owner, IO.Token, Interrupts, Count);
      IO.Item.Controller.Try_Acquire
        (IO.Guard.Generation,
         IO.Guard.State'Access,
         Lease,
         IO.FD,
         IO.Close_Source,
         IO.Guard.Socket,
         IO.Owner,
         IO.Transport);
      case Lease is
         when Lease_Busy      =>
            Result := Need_Acquire_Readiness;

         when Lease_Cancelled =>
            Reset (IO);
            raise Operation_Cancelled with "connection closed during capability acquisition";

         when Lease_Acquired  =>
            if IO.Transport not in Plain_Transport | TLS_Transport then
               Release (IO);
               raise Program_Error with "connection capability transport is invalid";
            end if;
            begin
               Sockets.Prepare (IO.Guard.Socket);
            exception
               when others =>
                  Release (IO);
                  raise;
            end;
            Result := Acquired;
      end case;
   end Poll_Acquisition;

   procedure Start
     (IO      : in out Capability;
      Item    : not null access Connection'Class;
      Result  : out Acquisition_Result;
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null) is
   begin
      if IO.Item /= null or else IO.Guard.State /= Unregistered then
         raise Program_Error with "connection capability is already active";
      end if;
      IO.Item := Item.all'Unchecked_Access;
      IO.Token := (if Token = null then null else Token.all'Unchecked_Access);
      IO.Guard.Item := IO.Item;
      IO.Started := Ada.Real_Time.Clock;
      IO.Deadline := Timeout;
      begin
         IO.Item.Controller.Start_Operation
           (IO.Guard.Generation'Access,
            IO.Guard.State'Access,
            IO.FD,
            IO.Lease_Source,
            IO.Initial_Close_Source,
            IO.Owner);
         Poll_Acquisition (IO, Result);
      exception
         when others =>
            if IO.Guard.State /= Unregistered then
               Release_Operation (IO.Guard);
            end if;
            if IO.Guard.State = Unregistered then
               Reset (IO);
            end if;
            raise;
      end;
   end Start;

   procedure Arm_Acquisition (IO : in out Capability; Operation : in out Flyology.Operations.Operation'Class)
   is
      Interrupts      : Interrupt_Set (1 .. 2);
      Interrupt_Count : Natural;
      Sources         : Flyology.Operations.Drivers.Readiness_Source_Array (1 .. 4);
      Count           : Natural := 2;
   begin
      if IO.Item = null or else IO.Guard.State /= Registered then
         raise Program_Error with "connection capability is not awaiting acquisition";
      end if;
      Sources (1) := (Descriptor => IO.Lease_Source, For_Write => False);
      Sources (2) := (Descriptor => IO.Initial_Close_Source, For_Write => False);
      Interrupt_Sources (IO.Owner, IO.Token, Interrupts, Interrupt_Count);
      for Index in 1 .. Interrupt_Count loop
         Count := Count + 1;
         Sources (Count) := (Descriptor => Interrupts (Index), For_Write => False);
      end loop;
      Flyology.Operations.Drivers.Arm_Readiness (Operation, Sources (1 .. Count));
   end Arm_Acquisition;

   procedure Validate_Transport_Arm (IO : Capability; Required : Step_Result) is
   begin
      if IO.Item = null or else IO.Guard.State /= Acquired then
         raise Program_Error with "connection capability is not acquired";
      elsif Required not in Need_Read | Need_Write then
         raise Program_Error with "transport arming requires Need_Read or Need_Write";
      end if;
   end Validate_Transport_Arm;

   procedure Validate_Additional (Additional : Descriptor) is
   begin
      if Additional = Invalid_Descriptor then
         raise Program_Error with "additional readiness descriptor is invalid";
      end if;
   end Validate_Additional;

   procedure Arm_Transport
     (IO : in out Capability; Operation : in out Flyology.Operations.Operation'Class; Required : Step_Result)
   is
      Interrupts      : Interrupt_Set (1 .. 2);
      Interrupt_Count : Natural;
      Sources         : Flyology.Operations.Drivers.Readiness_Source_Array (1 .. 4);
      Count           : Natural := 2;
   begin
      Validate_Transport_Arm (IO, Required);
      Sources (1) := (Descriptor => IO.FD, For_Write => Required = Need_Write);
      Sources (2) := (Descriptor => IO.Close_Source, For_Write => False);
      Interrupt_Sources (IO.Owner, IO.Token, Interrupts, Interrupt_Count);
      for Index in 1 .. Interrupt_Count loop
         Count := Count + 1;
         Sources (Count) := (Descriptor => Interrupts (Index), For_Write => False);
      end loop;
      Flyology.Operations.Drivers.Arm_Readiness (Operation, Sources (1 .. Count));
   end Arm_Transport;

   procedure Arm_Transport
     (IO                   : in out Capability;
      Operation            : in out Flyology.Operations.Operation'Class;
      Required             : Step_Result;
      Additional           : Descriptor;
      Additional_For_Write : Boolean)
   is
      Interrupts      : Interrupt_Set (1 .. 2);
      Interrupt_Count : Natural;
      Sources         : Flyology.Operations.Drivers.Readiness_Source_Array (1 .. 5);
      Count           : Natural := 3;
   begin
      Validate_Transport_Arm (IO, Required);
      Validate_Additional (Additional);
      Sources (1) := (Descriptor => IO.FD, For_Write => Required = Need_Write);
      Sources (2) := (Descriptor => Additional, For_Write => Additional_For_Write);
      Sources (3) := (Descriptor => IO.Close_Source, For_Write => False);
      Interrupt_Sources (IO.Owner, IO.Token, Interrupts, Interrupt_Count);
      for Index in 1 .. Interrupt_Count loop
         Count := Count + 1;
         Sources (Count) := (Descriptor => Interrupts (Index), For_Write => False);
      end loop;
      Flyology.Operations.Drivers.Arm_Readiness (Operation, Sources (1 .. Count));
   end Arm_Transport;

   procedure Arm_Transport
     (IO        : in out Capability;
      Operation : in out Flyology.Operations.Operation'Class;
      Required  : Step_Result;
      Outbound  : in out Outbound_Wakeup)
   is
      Interrupts      : Interrupt_Set (1 .. 2);
      Interrupt_Count : Natural;
      Sources         : Flyology.Operations.Drivers.Readiness_Source_Array (1 .. 5);
      Count           : Natural := 3;
      Outbound_FD     : Descriptor;
      Already_Pending : Boolean;
   begin
      Validate_Transport_Arm (IO, Required);

      Outbound.Controller.Wait_Source (Outbound_FD, Already_Pending);
      if Already_Pending then
         --  Consume before rescheduling so the resumed protocol owner cannot
         --  spin on a stale signal. It must observe every currently published
         --  output item before it calls Arm_Transport again.
         Outbound.Controller.Consume;
         Flyology.Operations.Drivers.Reschedule (Operation);
         return;
      end if;

      Sources (1) := (Descriptor => IO.FD, For_Write => Required = Need_Write);
      Sources (2) := (Descriptor => Outbound_FD, For_Write => False);
      Sources (3) := (Descriptor => IO.Close_Source, For_Write => False);
      Interrupt_Sources (IO.Owner, IO.Token, Interrupts, Interrupt_Count);
      for Index in 1 .. Interrupt_Count loop
         Count := Count + 1;
         Sources (Count) := (Descriptor => Interrupts (Index), For_Write => False);
      end loop;
      Flyology.Operations.Drivers.Arm_Readiness (Operation, Sources (1 .. Count));
   end Arm_Transport;

   procedure Arm_Transport
     (IO                   : in out Capability;
      Operation            : in out Flyology.Operations.Operation'Class;
      Required             : Step_Result;
      Outbound             : in out Outbound_Wakeup;
      Additional           : Descriptor;
      Additional_For_Write : Boolean)
   is
      Interrupts      : Interrupt_Set (1 .. 2);
      Interrupt_Count : Natural;
      Sources         : Flyology.Operations.Drivers.Readiness_Source_Array (1 .. 6);
      Count           : Natural := 4;
      Outbound_FD     : Descriptor;
      Already_Pending : Boolean;
   begin
      Validate_Transport_Arm (IO, Required);
      Validate_Additional (Additional);

      Outbound.Controller.Wait_Source (Outbound_FD, Already_Pending);
      if Already_Pending then
         --  Keep the existing consume-before-reschedule rule. Additional is a
         --  caller-owned latch and is never consumed here.
         Outbound.Controller.Consume;
         Flyology.Operations.Drivers.Reschedule (Operation);
         return;
      end if;

      Sources (1) := (Descriptor => IO.FD, For_Write => Required = Need_Write);
      Sources (2) := (Descriptor => Outbound_FD, For_Write => False);
      Sources (3) := (Descriptor => Additional, For_Write => Additional_For_Write);
      Sources (4) := (Descriptor => IO.Close_Source, For_Write => False);
      Interrupt_Sources (IO.Owner, IO.Token, Interrupts, Interrupt_Count);
      for Index in 1 .. Interrupt_Count loop
         Count := Count + 1;
         Sources (Count) := (Descriptor => Interrupts (Index), For_Write => False);
      end loop;
      Flyology.Operations.Drivers.Arm_Readiness (Operation, Sources (1 .. Count));
   end Arm_Transport;

   procedure Arm_Deadline (IO : in out Capability; Operation : in out Flyology.Operations.Operation'Class) is
   begin
      if not Is_Engaged (IO) then
         raise Program_Error with "connection capability is not engaged";
      elsif IO.Deadline >= 0.0 then
         Flyology.Operations.Drivers.Arm_Deadline (Operation, Remaining (IO.Started, IO.Deadline));
      end if;
   end Arm_Deadline;

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

      procedure Wait_Source (FD : out Descriptor; Already_Pending : out Boolean) is
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
      if Item.Item = null or else Item.Guard.State /= Acquired then
         raise Program_Error with "connection capability is not acquired";
      end if;
      Check_TLS_Operation (Item.Item.all, Item.Guard.Generation, Item.Owner, Item.Token);
      if Item.Deadline >= 0.0 and then Remaining (Item.Started, Item.Deadline) = 0.0 then
         raise Timeout_Error with "connection driver timed out";
      end if;
   end Check;

   function Mapped (Status : TLS.Step_Status) return Step_Result
   is (case Status is
         when TLS.Complete    => Made_Progress,
         when TLS.Want_Read   => Need_Read,
         when TLS.Want_Write  => Need_Write,
         when TLS.Peer_Closed => Peer_Closed,
         when TLS.Failed      => raise Program_Error with "TLS driver returned an unhandled failure");

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
         when TLS_Transport                =>
            if Item.Item.TLS_Session = null then
               raise Program_Error with "TLS transport has no provider session";
            end if;
            TLS_Driver.Receive_Once (Item.Item.TLS_Session.all, Data, Last, Status);
            Result := Mapped (Status);

         when Plain_Transport              =>
            begin
               Sockets.Receive_Socket (Item.Guard.Socket, Data, Last);
               Result := (if Data'Length = 0 or else Last >= Data'First then Made_Progress else Peer_Closed);
            exception
               when Occurrence : Sockets.Socket_Error =>
                  if Sockets.Resolve_Exception (Occurrence)
                     in Sockets.Resource_Temporarily_Unavailable | Sockets.Interrupted_System_Call
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
         when TLS_Transport                =>
            if Item.Item.TLS_Session = null then
               raise Program_Error with "TLS transport has no provider session";
            end if;
            TLS_Driver.Send_Once (Item.Item.TLS_Session.all, Data, Last, Status);
            Result := Mapped (Status);

         when Plain_Transport              =>
            begin
               Sockets.Send_Socket (Item.Guard.Socket, Data, Last);
               Result := (if Data'Length = 0 or else Last >= Data'First then Made_Progress else Peer_Closed);
            exception
               when Occurrence : Sockets.Socket_Error =>
                  if Sockets.Resolve_Exception (Occurrence)
                     in Sockets.Resource_Temporarily_Unavailable
                      | Sockets.Interrupted_System_Call
                      | Sockets.No_Buffer_Space_Available
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
      Requests         : Wait_Request_Array (1 .. 7);
      Count            : Natural := 0;
      Outbound_FD      : Descriptor;
      Outbound_Pending : Boolean;
      Outbound_Index   : Natural := 0;
      Interrupts       : Interrupt_Set (1 .. 2);
      Interrupt_Count  : Natural;
      Global_Remaining : Duration;
      Wait_For         : Duration;
      Ready_Index      : Natural;

      procedure Append (FD : Descriptor; Condition : Wait_Kind) is
      begin
         Count := Count + 1;
         Requests (Count) := (FD => FD, Condition => Condition);
      end Append;
   begin
      Check (Item);
      Outbound.Controller.Wait_Source (Outbound_FD, Outbound_Pending);
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
      Interrupt_Sources (Item.Owner, Item.Token, Interrupts, Interrupt_Count);
      for Index in Interrupts'First .. Interrupts'First + Interrupt_Count - 1 loop
         Append (Interrupts (Index), For_Read);
      end loop;

      Global_Remaining := Remaining (Item.Started, Item.Deadline);
      Wait_For :=
        (if Timeout < 0.0
         then Global_Remaining
         elsif Item.Deadline < 0.0
         then Timeout
         else Duration'Min (Timeout, Global_Remaining));
      Ready_Index := Wait_Any (Requests (1 .. Count), Wait_For);

      if Ready_Index = 0 then
         if Item.Deadline >= 0.0 and then Remaining (Item.Started, Item.Deadline) = 0.0 then
            raise Timeout_Error with "connection driver timed out";
         end if;
         Result := Wait_Timed_Out;
         return;
      end if;

      Check (Item);
      if Ready_Index = Outbound_Index then
         Outbound.Controller.Consume;
         Result := Outbound_Ready;
      elsif Ready_Index <= Outbound_Index + Boolean'Pos (Interest.Readable) + Boolean'Pos (Interest.Writable)
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
      Started         : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      IO              : Capability;
      Acquisition     : Acquisition_Result;
      Requests        : Wait_Request_Array (1 .. 4);
      Count           : Natural;
      Interrupts      : Interrupt_Set (1 .. 2);
      Interrupt_Count : Natural;
      Ready           : Natural;
   begin
      Start (IO, Item'Unchecked_Access, Acquisition, Timeout => Timeout, Token => Token);
      IO.Started := Started;
      while Acquisition = Need_Acquire_Readiness loop
         Count := 2;
         Requests (1) := (FD => IO.Lease_Source, Condition => For_Read);
         Requests (2) := (FD => IO.Initial_Close_Source, Condition => For_Read);
         Interrupt_Sources (IO.Owner, IO.Token, Interrupts, Interrupt_Count);
         for Index in 1 .. Interrupt_Count loop
            Count := Count + 1;
            Requests (Count) := (FD => Interrupts (Index), Condition => For_Read);
         end loop;
         Ready := Wait_Any (Requests (1 .. Count), Remaining (Started, Timeout));
         if Ready = 0 then
            raise Timeout_Error with "connection driver timed out";
         end if;
         Poll_Acquisition (IO, Acquisition);
      end loop;
      Check (IO);
      Process.all (IO);
      Check (IO);
      Release (IO);
   end Run;

end Flyology.IO.Connections.Drivers;
