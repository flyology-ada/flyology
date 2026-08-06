separate (Flyology.HTTP.Client)
--  Serializes bounded transport-slot transitions and their coherent counters.
--  Socket establishment and close remain outside this protected object.
protected body Pool_Controller is
      procedure Configure (Value : Pool_Configuration) is
      begin
         if Is_Configured then
            raise Program_Error with "HTTP client pool is already configured";
         end if;
         Policy := Value;
         Policy.Max_Idle := Natural'Min (Value.Max_Idle, Capacity);
         Is_Configured := True;
      end Configure;

      procedure Try_Checkout
        (Now        : Ada.Real_Time.Time;
         Result     : out Checkout_Result;
         Slot_Index : out Natural;
         Connection : out Pooled_Connection_Access)
      is
         Available_After : Boolean := False;
      begin
         Slot_Index := 0;
         Connection := null;
         if Stopping then
            Result := Checkout_Closed;
            return;
         end if;

         for Index in Slots'Range loop
            if Slots (Index).Phase = Idle then
               declare
                  Idle_Age : constant Duration := Ada.Real_Time.To_Duration
                    (Now - Slots (Index).Last_Used);
                  Total_Age : constant Duration := Ada.Real_Time.To_Duration
                    (Now - Slots (Index).Born);
                  Expired : constant Boolean :=
                    (Policy.Idle_Timeout >= 0.0
                       and then Idle_Age >= Policy.Idle_Timeout)
                    or else
                    (Policy.Max_Connection_Age >= 0.0
                       and then Total_Age >= Policy.Max_Connection_Age)
                    or else
                    (Policy.Max_Requests_Per_Connection > 0
                       and then Slots (Index).Request_Count >=
                         Policy.Max_Requests_Per_Connection);
               begin
                  Slot_Index := Index;
                  Connection := Slots (Index).Connection;
                  Idle_Count := Idle_Count - 1;
                  if Expired then
                     Slots (Index).Phase := Closing;
                     Closing_Count := Closing_Count + 1;
                     Result := Checkout_Discard;
                  else
                     Slots (Index).Phase := Leased;
                     Slots (Index).Request_Count :=
                       Slots (Index).Request_Count + 1;
                     Leased_Count := Leased_Count + 1;
                     Reused_Count := Reused_Count + 1;
                     Result := Checkout_Idle;
                  end if;
                  exit;
               end;
            end if;
         end loop;

         if Slot_Index = 0 then
            for Index in Slots'Range loop
               if Slots (Index).Phase = Empty then
                  Slots (Index).Phase := Connecting;
                  Connecting_Count := Connecting_Count + 1;
                  Slot_Index := Index;
                  Result := Checkout_Create;
                  exit;
               end if;
            end loop;
         end if;

         if Slot_Index = 0 then
            Result := Checkout_Busy;
         end if;

         for Item of Slots loop
            if Item.Phase in Empty | Idle then
               Available_After := True;
               exit;
            end if;
         end loop;
         if Checkout_Signalled and then not Available_After then
            Flyology.Wake_Sources.Consume (Checkout_Wake);
            Checkout_Signalled := False;
         end if;
      end Try_Checkout;

      procedure Install
        (Slot_Index : Positive;
         Connection : Pooled_Connection_Access;
         Now        : Ada.Real_Time.Time) is
      begin
         if Slot_Index > Capacity
           or else Slots (Slot_Index).Phase /= Connecting
           or else Connection = null
         then
            raise Program_Error with "invalid HTTP pool connection install";
         elsif Stopping then
            raise Client_Closed;
         end if;
         Slots (Slot_Index) :=
           (Phase         => Leased,
            Connection    => Connection,
            Born          => Now,
            Last_Used     => Now,
            Request_Count => 1,
            Interrupting  => False,
            Interrupt_Sent => False,
            Owner_Done    => False);
         Connecting_Count := Connecting_Count - 1;
         Leased_Count := Leased_Count + 1;
         Created_Count := Created_Count + 1;
      end Install;

      procedure Publish_Connecting
        (Slot_Index : Positive; Connection : Pooled_Connection_Access) is
      begin
         if Slot_Index > Capacity
           or else Slots (Slot_Index).Phase /= Connecting
           or else Connection = null
         then
            raise Program_Error with
              "invalid HTTP pool connecting transport publication";
         elsif Stopping then
            raise Client_Closed;
         end if;
         Slots (Slot_Index).Connection := Connection;
      end Publish_Connecting;

      procedure Creation_Failed
        (Slot_Index : Positive; Result : out Failure_Result) is
      begin
         if Slot_Index > Capacity
           or else Slots (Slot_Index).Phase /= Connecting
         then
            raise Program_Error with "invalid HTTP pool creation failure";
         end if;
         Connecting_Count := Connecting_Count - 1;
         if Slots (Slot_Index).Interrupting then
            Slots (Slot_Index).Phase := Closing;
            Slots (Slot_Index).Owner_Done := True;
            Closing_Count := Closing_Count + 1;
            Result := Failure_Free_Deferred;
         else
            Slots (Slot_Index) := (others => <>);
            Result := Failure_Free;
            if Flyology.Wake_Sources.Descriptor (Checkout_Wake) >= 0
              and then not Checkout_Signalled
            then
               Flyology.Wake_Sources.Signal (Checkout_Wake);
               Checkout_Signalled := True;
            end if;
         end if;
      end Creation_Failed;

      procedure Return_Lease
        (Slot_Index : Positive;
         Reusable   : Boolean;
         Now        : Ada.Real_Time.Time;
         Result     : out Return_Result;
         Connection : out Pooled_Connection_Access)
      is
         Total_Age : Duration;
      begin
         if Slot_Index > Capacity
           or else Slots (Slot_Index).Phase /= Leased
         then
            raise Program_Error with "invalid HTTP pool lease return";
         end if;
         Connection := Slots (Slot_Index).Connection;
         Total_Age := Ada.Real_Time.To_Duration
           (Now - Slots (Slot_Index).Born);
         Leased_Count := Leased_Count - 1;
         if Reusable and then not Stopping
           and then Idle_Count < Policy.Max_Idle
           and then
             (Policy.Max_Connection_Age < 0.0
                or else Total_Age < Policy.Max_Connection_Age)
           and then
             (Policy.Max_Requests_Per_Connection = 0
                or else Slots (Slot_Index).Request_Count <
                  Policy.Max_Requests_Per_Connection)
         then
            Slots (Slot_Index).Phase := Idle;
            Slots (Slot_Index).Last_Used := Now;
            Idle_Count := Idle_Count + 1;
            Result := Returned_Idle;
         elsif Slots (Slot_Index).Interrupting then
            Slots (Slot_Index).Phase := Closing;
            Slots (Slot_Index).Owner_Done := True;
            Closing_Count := Closing_Count + 1;
            Result := Return_Close_Deferred;
         else
            Slots (Slot_Index).Phase := Closing;
            Slots (Slot_Index).Owner_Done := True;
            Closing_Count := Closing_Count + 1;
            Result := Return_Close;
         end if;
         if Flyology.Wake_Sources.Descriptor (Checkout_Wake) >= 0
           and then not Checkout_Signalled
         then
            Flyology.Wake_Sources.Signal (Checkout_Wake);
            Checkout_Signalled := True;
         end if;
      end Return_Lease;

      procedure Finish_Close (Slot_Index : Positive) is
      begin
         if Slot_Index > Capacity
           or else Slots (Slot_Index).Phase /= Closing
         then
            raise Program_Error with "invalid HTTP pool close completion";
         end if;
         Slots (Slot_Index) := (others => <>);
         Closing_Count := Closing_Count - 1;
         Closed_Count := Closed_Count + 1;
         if Flyology.Wake_Sources.Descriptor (Checkout_Wake) >= 0
           and then not Checkout_Signalled
         then
            Flyology.Wake_Sources.Signal (Checkout_Wake);
            Checkout_Signalled := True;
         end if;
      end Finish_Close;

      procedure Take_Idle
        (Found      : out Boolean;
         Slot_Index : out Natural;
         Connection : out Pooled_Connection_Access) is
      begin
         Found := False;
         Slot_Index := 0;
         Connection := null;
         for Index in Slots'Range loop
            if Slots (Index).Phase = Idle then
               Slots (Index).Phase := Closing;
               Idle_Count := Idle_Count - 1;
               Closing_Count := Closing_Count + 1;
               Found := True;
               Slot_Index := Index;
               Connection := Slots (Index).Connection;
               exit;
            end if;
         end loop;
      end Take_Idle;

      procedure Request_Shutdown is
      begin
         if not Stopping then
            Stopping := True;
            Flyology.Wake_Sources.Ensure (Shutdown_Wake);
            Flyology.Wake_Sources.Signal (Shutdown_Wake);
            if Flyology.Wake_Sources.Descriptor (Checkout_Wake) >= 0
              and then not Checkout_Signalled
            then
               Flyology.Wake_Sources.Signal (Checkout_Wake);
               Checkout_Signalled := True;
            end if;
         end if;
      end Request_Shutdown;

      procedure Take_Active_For_Interrupt
        (Found      : out Boolean;
         Slot_Index : out Natural;
         Connection : out Pooled_Connection_Access) is
      begin
         Found := False;
         Slot_Index := 0;
         Connection := null;
         for Index in Slots'Range loop
            if Slots (Index).Phase in Connecting | Leased
              and then Slots (Index).Connection /= null
              and then not Slots (Index).Interrupt_Sent
            then
               Slots (Index).Interrupting := True;
               Slots (Index).Interrupt_Sent := True;
               Found := True;
               Slot_Index := Index;
               Connection := Slots (Index).Connection;
               exit;
            end if;
         end loop;
      end Take_Active_For_Interrupt;

      procedure Finish_Interrupt
        (Slot_Index : Positive;
         Release_Ownership : out Boolean;
         Connection : out Pooled_Connection_Access) is
      begin
         if Slot_Index > Capacity
           or else not Slots (Slot_Index).Interrupting
         then
            raise Program_Error with "invalid HTTP pool interrupt completion";
         end if;
         Slots (Slot_Index).Interrupting := False;
         Release_Ownership :=
           Slots (Slot_Index).Phase = Closing
             and then Slots (Slot_Index).Owner_Done;
         if Release_Ownership then
            Connection := Slots (Slot_Index).Connection;
            Slots (Slot_Index) := (others => <>);
            Closing_Count := Closing_Count - 1;
            Closed_Count := Closed_Count + 1;
            if Flyology.Wake_Sources.Descriptor (Checkout_Wake) >= 0
              and then not Checkout_Signalled
            then
               Flyology.Wake_Sources.Signal (Checkout_Wake);
               Checkout_Signalled := True;
            end if;
         else
            Connection := null;
         end if;
      end Finish_Interrupt;

      entry Await_Drained
        when Connecting_Count + Leased_Count + Idle_Count + Closing_Count = 0
      is
      begin
         null;
      end Await_Drained;

      procedure Wait_Source
        (FD : out Flyology.IO.Descriptor; Can_Checkout : out Boolean)
      is
      begin
         Can_Checkout := Stopping;
         if not Can_Checkout then
            for Item of Slots loop
               if Item.Phase in Empty | Idle then
                  Can_Checkout := True;
                  exit;
               end if;
            end loop;
         end if;
         if Can_Checkout then
            FD := Flyology.IO.Invalid_Descriptor;
         else
            Flyology.Wake_Sources.Ensure (Checkout_Wake);
            FD := Flyology.Wake_Sources.Descriptor (Checkout_Wake);
         end if;
      end Wait_Source;

      procedure Shutdown_Source
        (FD : out Flyology.IO.Descriptor; Requested : out Boolean) is
      begin
         Requested := Stopping;
         if Stopping then
            FD := Flyology.IO.Invalid_Descriptor;
         else
            Flyology.Wake_Sources.Ensure (Shutdown_Wake);
            FD := Flyology.Wake_Sources.Descriptor (Shutdown_Wake);
         end if;
      end Shutdown_Source;

      procedure Register_Waiter is
      begin
         Waiter_Count := Waiter_Count + 1;
      end Register_Waiter;

      procedure Unregister_Waiter is
      begin
         if Waiter_Count = 0 then
            raise Program_Error with "HTTP pool waiter released twice";
         end if;
         Waiter_Count := Waiter_Count - 1;
      end Unregister_Waiter;

      procedure Record_Admission_Timeout is
      begin
         Timeout_Count := Timeout_Count + 1;
      end Record_Admission_Timeout;

      procedure Record_Stale_Retry is
      begin
         Stale_Retry_Count := Stale_Retry_Count + 1;
      end Record_Stale_Retry;

      function Snapshot return Client_Diagnostics is
        (Transport_Capacity => Capacity,
         Pending_Transports => Connecting_Count,
         Active_Exchanges   => Leased_Count,
         Reusable_Transports => Idle_Count,
         Closing_Transports => Closing_Count,
         Admission_Waiters  => Waiter_Count,
         Transports_Created => Created_Count,
         Transport_Reuses   => Reused_Count,
         Transports_Closed  => Closed_Count,
         Stale_Retries      => Stale_Retry_Count,
         Admission_Timeouts => Timeout_Count);

      function Is_Stopping return Boolean is (Stopping);
end Pool_Controller;
