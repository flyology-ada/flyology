with Flyology.IO.TLS_Driver;

package body Flyology.IO.TLS.Drivers is
   procedure Release (IO : in out Capability) is
   begin
      Release_Driver (IO.State);
   end Release;

   overriding procedure Finalize (IO : in out Capability) is
   begin
      begin
         Release (IO);
      exception
         when others =>
            --  A wake failure can occur after the protected controller has
            --  already discharged the lease. Retry once to clear local
            --  borrows, then keep controlled finalization non-raising.
            begin
               Release (IO);
            exception
               when others =>
                  null;
            end;
      end;
   end Finalize;

   function Is_Engaged (IO : Capability) return Boolean is
     (IO.State.Guard.State /= Unregistered);

   function Is_Acquired (IO : Capability) return Boolean is
     (IO.State.Guard.State = Acquired);

   procedure Poll_Acquisition
     (IO     : in out Capability;
      Result : out Acquisition_Result)
   is
      Lease : Lease_Result;
   begin
      Poll_Driver (IO.State, Lease);
      case Lease is
         when Lease_Busy =>
            Result := Need_Acquire_Readiness;
         when Lease_Cancelled =>
            --  Try_Acquire has already withdrawn the controller registration;
            --  clear the capability's remaining local borrows before exposing
            --  cancellation to a higher-level provider.
            Release (IO);
            raise Operation_Cancelled;
         when Lease_Acquired => Result := Acquired;
      end case;
   end Poll_Acquisition;

   procedure Start
     (IO      : in out Capability;
      Item    : not null access Connection'Class;
      Result  : out Acquisition_Result;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Lease : Lease_Result;
   begin
      Start_Driver (IO.State, Item, Lease, Timeout, Token);
      case Lease is
         when Lease_Acquired =>
            Result := Acquired;
         when Lease_Busy =>
            Result := Need_Acquire_Readiness;
         when Lease_Cancelled =>
            Release (IO);
            raise Operation_Cancelled;
      end case;
   end Start;

   procedure Arm_Acquisition
     (IO        : in out Capability;
      Operation : in out Flyology.Operations.Operation'Class)
   is
   begin
      Arm_Driver_Acquisition (IO.State, Operation);
   end Arm_Acquisition;

   procedure Arm_Transport
     (IO        : in out Capability;
      Operation : in out Flyology.Operations.Operation'Class;
      Required  : Step_Result)
   is
   begin
      if Required not in Need_Read | Need_Write then
         raise Program_Error with "invalid TLS transport readiness request";
      end if;
      Arm_Driver_Transport
        (IO.State,
         Operation,
         (if Required = Need_Read then Want_Read else Want_Write));
   end Arm_Transport;

   procedure Arm_Deadline
     (IO        : in out Capability;
      Operation : in out Flyology.Operations.Operation'Class) is
   begin
      Arm_Driver_Deadline (IO.State, Operation);
   end Arm_Deadline;

   function Mapped (Status : Step_Status) return Step_Result is
     (case Status is
         when Complete    => Made_Progress,
         when Want_Read   => Need_Read,
         when Want_Write  => Need_Write,
         when Peer_Closed => Peer_Closed,
         when Failed      => raise Program_Error with
           "TLS provider failure was not raised");

   procedure Handshake
     (IO     : in out Capability;
      Result : out Step_Result)
   is
      Status : Step_Status;
   begin
      Check_Driver (IO.State);
      TLS_Driver.Handshake_Once (IO.State.Item.Session.all, Status);
      Result := Mapped (Status);
   end Handshake;

   procedure Receive
     (IO     : in out Capability;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Step_Result)
   is
      Status : Step_Status;
   begin
      Check_Driver (IO.State);
      TLS_Driver.Receive_Once
        (IO.State.Item.Session.all, Data, Last, Status);
      Result := Mapped (Status);
   end Receive;

   procedure Send
     (IO     : in out Capability;
      Data   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Step_Result)
   is
      Status : Step_Status;
   begin
      Check_Driver (IO.State);
      TLS_Driver.Send_Once
        (IO.State.Item.Session.all, Data, Last, Status);
      Result := Mapped (Status);
   end Send;

   procedure Shutdown
     (IO     : in out Capability;
      Result : out Step_Result)
   is
      Status : Step_Status;
   begin
      Check_Driver (IO.State);
      TLS_Driver.Shutdown_Once (IO.State.Item.Session.all, Status);
      Result := Mapped (Status);
   end Shutdown;

end Flyology.IO.TLS.Drivers;
