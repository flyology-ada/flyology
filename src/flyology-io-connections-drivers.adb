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

   procedure Wait_Outbound_Source
     (Item : in out Outbound_Wakeup; FD : out Descriptor; Already_Pending : out Boolean);
   procedure Consume_Outbound (Item : in out Outbound_Wakeup);

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
      Try_Acquire_Lease
        (IO.Item.all,
         IO.Guard.Generation,
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

      Wait_Outbound_Source (Outbound, Outbound_FD, Already_Pending);
      if Already_Pending then
         --  Consume before rescheduling so the resumed protocol owner cannot
         --  spin on a stale signal. It must observe every currently published
         --  output item before it calls Arm_Transport again.
         Consume_Outbound (Outbound);
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

      Wait_Outbound_Source (Outbound, Outbound_FD, Already_Pending);
      if Already_Pending then
         --  Keep the existing consume-before-reschedule rule. Additional is a
         --  caller-owned latch and is never consumed here.
         Consume_Outbound (Outbound);
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

   overriding
   procedure Finalize (Item : in out Wake_Claim) is
   begin
      if Item.Armed then
         begin
            Wake_Sources.Signal_Borrowed (Item.Descriptor);
            Item.Delivered := True;
         exception
            when others =>
               null;
         end;
         Item.State.Complete_Signal (Item.Delivered);
         Item.Armed := False;
      end if;
   end Finalize;

   overriding
   procedure Finalize (Item : in out Initialization_Claim) is
   begin
      if Item.Armed then
         Item.State.Cancel_Initialization;
         Item.Armed := False;
      end if;
   end Finalize;

   overriding
   procedure Finalize (Item : in out Drain_Claim) is
      Delivered : Boolean := False;
   begin
      if Item.Armed then
         if Item.Has_Signal then
            begin
               Wake_Sources.Drain (Item.Wake.all);
            exception
               when others =>
                  null;
            end;
         end if;
         Item.State.Complete_Consume (Item.Armed'Access, Item.Signal_Armed'Access, Item.Signal_FD'Access);
      end if;
      if Item.Signal_Armed then
         begin
            Wake_Sources.Signal_Borrowed (Item.Signal_FD);
            Delivered := True;
         exception
            when others =>
               null;
         end;
         Item.State.Complete_Signal (Delivered);
         Item.Signal_Armed := False;
      end if;
   end Finalize;

   protected body Wakeup_Controller is
      procedure Record_Signal (Claim : not null access Wake_Claim) is
      begin
         if not Pending then
            Pending := True;
            if Write_FD >= 0 then
               Signalling := True;
               Claim.Descriptor := Write_FD;
               Claim.Armed := True;
            end if;
         elsif Draining then
            --  A new protocol event during the outside-lock drain needs its
            --  own readable notification after that drain completes.
            Resignal_Required := True;
         elsif not Signalling and then not Signalled and then Write_FD >= 0 then
            --  Retry a hard failure reported by the previous caller.
            Signalling := True;
            Claim.Descriptor := Write_FD;
            Claim.Armed := True;
         end if;
      end Record_Signal;

      procedure Complete_Signal (Delivered : Boolean) is
      begin
         if Signalling then
            Signalling := False;
            Signalled := Delivered;
         end if;
      end Complete_Signal;

      procedure Begin_Wait
        (Claim : not null access Initialization_Claim; FD : out Descriptor; Already_Pending : out Boolean) is
      begin
         Already_Pending := Pending;
         FD := (if Pending then Invalid_Descriptor else Read_FD);
         if not Pending and then Read_FD < 0 and then not Initializing then
            Initializing := True;
            Claim.Armed := True;
         end if;
      end Begin_Wait;

      entry Await_Ready when not Initializing is
      begin
         null;
      end Await_Ready;

      procedure Publish_Source (FD, Signal_FD : Descriptor) is
      begin
         if not Initializing or else Read_FD >= 0 or else FD < 0 or else Signal_FD < 0 then
            raise Program_Error with "invalid outbound wake source publication";
         end if;
         Read_FD := FD;
         Write_FD := Signal_FD;
         Initializing := False;
      end Publish_Source;

      procedure Cancel_Initialization is
      begin
         Initializing := False;
      end Cancel_Initialization;

      procedure Begin_Consume (Claim : not null access Drain_Claim) is
      begin
         if not Pending then
            raise Program_Error with "no protocol wakeup is pending";
         elsif Signalling or else Draining then
            return;
         end if;
         Draining := True;
         Claim.Has_Signal := Signalled;
         Claim.Armed := True;
      end Begin_Consume;

      entry Await_Signal when not Signalling and then not Draining is
      begin
         null;
      end Await_Signal;

      procedure Complete_Consume
        (Armed        : not null access Boolean;
         Signal_Armed : not null access Boolean;
         Signal_FD    : not null access Descriptor) is
      begin
         if Draining and then Armed.all then
            Draining := False;
            Signalled := False;
            if Resignal_Required then
               Resignal_Required := False;
               if Write_FD >= 0 then
                  Signalling := True;
                  Signal_FD.all := Write_FD;
                  Signal_Armed.all := True;
               end if;
            else
               Pending := False;
            end if;
            Armed.all := False;
         end if;
      end Complete_Consume;
   end Wakeup_Controller;

   procedure Wait_Outbound_Source
     (Item : in out Outbound_Wakeup; FD : out Descriptor; Already_Pending : out Boolean) is
   begin
      loop
         declare
            Claim : aliased Initialization_Claim;
         begin
            Claim.State := Item.Controller'Unchecked_Access;
            Item.Controller.Begin_Wait (Claim'Access, FD, Already_Pending);
            if Already_Pending or else FD >= 0 then
               return;
            elsif Claim.Armed then
               Wake_Sources.Ensure (Item.Wake);
               Item.Controller.Publish_Source
                 (Wake_Sources.Descriptor (Item.Wake), Wake_Sources.Signal_Descriptor (Item.Wake));
               Claim.Armed := False;
            else
               Item.Controller.Await_Ready;
            end if;
         end;
      end loop;
   end Wait_Outbound_Source;

   procedure Consume_Outbound (Item : in out Outbound_Wakeup) is
   begin
      loop
         declare
            Claim : aliased Drain_Claim;
         begin
            Claim.State := Item.Controller'Unchecked_Access;
            Claim.Wake := Item.Wake'Unchecked_Access;
            Item.Controller.Begin_Consume (Claim'Access);
            if Claim.Armed then
               if Claim.Has_Signal then
                  Wake_Sources.Drain (Item.Wake);
               end if;
               Item.Controller.Complete_Consume
                 (Claim.Armed'Access, Claim.Signal_Armed'Access, Claim.Signal_FD'Access);
               if Claim.Signal_Armed then
                  Wake_Sources.Signal_Borrowed (Claim.Signal_FD);
                  Item.Controller.Complete_Signal (Delivered => True);
                  Claim.Signal_Armed := False;
               end if;
               return;
            end if;
         end;
         Item.Controller.Await_Signal;
      end loop;
   end Consume_Outbound;

   procedure Signal (Item : in out Outbound_Wakeup) is
      Claim : aliased Wake_Claim;
   begin
      Claim.State := Item.Controller'Unchecked_Access;
      Item.Controller.Record_Signal (Claim'Access);
      if Claim.Armed then
         Wake_Sources.Signal_Borrowed (Claim.Descriptor);
         Claim.Delivered := True;
         Item.Controller.Complete_Signal (Claim.Delivered);
         Claim.Armed := False;
      end if;
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
      Wait_Outbound_Source (Outbound, Outbound_FD, Outbound_Pending);
      if Outbound_Pending then
         Consume_Outbound (Outbound);
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
         Consume_Outbound (Outbound);
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
