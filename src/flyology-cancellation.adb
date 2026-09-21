with Flyology.Worker_Pool_Test_Hooks;

package body Flyology.Cancellation is

   use type Interfaces.C.int;

   overriding
   procedure Finalize (Guard : in out Signal_Guard) is
   begin
      if Guard.Armed then
         --  Abort can arrive immediately after the protected state cut.
         --  Finalization runs on the caller stack after that cut exits.
         begin
            Flyology.Wake_Sources.Signal_Borrowed (Guard.Descriptor);
         exception
            when others =>
               null;
         end;
         Guard.Armed := False;
      end if;
   end Finalize;

   overriding
   procedure Finalize (Guard : in out Initialization_Guard) is
   begin
      if Guard.Armed and then Guard.State /= null then
         Guard.State.Cancel_Initialization;
         Guard.Armed := False;
      end if;
   end Finalize;

   protected body Token_State is
      procedure Record_Request (Guard : not null access Signal_Guard) is
      begin
         if not Is_Requested then
            --  Publish the terminal state and the caller-owned signal claim
            --  in one protected action. The borrowed descriptor is stable
            --  until Token finalization, after every waiter leaves scope.
            Is_Requested := True;
            if Write_FD >= 0 then
               Guard.Descriptor := Write_FD;
               Guard.Armed := True;
            end if;
         end if;
      end Record_Request;

      entry Await_Request when Is_Requested is
      begin
         null;
      end Await_Request;

      function Requested return Boolean
      is (Is_Requested);

      procedure Begin_Wait
        (Guard : not null access Initialization_Guard;
         FD : out Interfaces.C.int;
         Already_Requested : out Boolean)
      is
      begin
         Already_Requested := Is_Requested;
         if Is_Requested then
            FD := -1;
         elsif Read_FD >= 0 then
            FD := Read_FD;
         else
            FD := -1;
            if not Initializing then
               Initializing := True;
               Guard.Armed := True;
            end if;
         end if;
      end Begin_Wait;

      entry Wait_Ready (FD : out Interfaces.C.int; Already_Requested : out Boolean)
        when not Initializing
      is
      begin
         Already_Requested := Is_Requested;
         FD := (if Is_Requested then -1 else Read_FD);
      end Wait_Ready;

      procedure Publish_Wake (FD, Signal_FD : Interfaces.C.int) is
      begin
         if not Initializing or else Read_FD >= 0 or else FD < 0 or else Signal_FD < 0 then
            raise Program_Error with "invalid cancellation wake publication";
         end if;
         Read_FD := FD;
         Write_FD := Signal_FD;
         Initializing := False;
      end Publish_Wake;

      procedure Cancel_Initialization is
      begin
         Initializing := False;
      end Cancel_Initialization;
   end Token_State;

   procedure Request (Item : in out Token) is
      Guard : aliased Signal_Guard;
   begin
      Item.State.Record_Request (Guard'Access);
      if Guard.Armed then
         if Flyology.Worker_Pool_Test_Hooks.Enabled
           and then Flyology.Worker_Pool_Test_Hooks.Cancellation_Failure
         then
            --  The hook models a failed write after cancellation commits.
            --  Keep the cleanup guard armed so an abort or exception still
            --  makes a best-effort attempt to wake the borrowed descriptor.
            raise Program_Error with "injected cancellation wake signaling failure";
         end if;
         Flyology.Wake_Sources.Signal_Borrowed (Guard.Descriptor);
         Guard.Armed := False;
      end if;
   end Request;

   procedure Await_Request (Item : in out Token) is
   begin
      Item.State.Await_Request;
   end Await_Request;

   function Wait_Event (Item : aliased in out Token) return not null access Request_Waiter'Class is
   begin
      return Item.State'Access;
   end Wait_Event;

   function Requested (Item : Token) return Boolean
   is (Item.State.Requested);

   procedure Wait_Source (Item : in out Token; FD : out Interfaces.C.int; Already_Requested : out Boolean) is
   begin
      loop
         declare
            Guard : aliased Initialization_Guard;
         begin
            Guard.State := Item.State'Unchecked_Access;
            Item.State.Begin_Wait (Guard'Access, FD, Already_Requested);
            if Already_Requested or else FD >= 0 then
               return;
            elsif Guard.Armed then
               Flyology.Wake_Sources.Ensure (Item.Wake);
               Item.State.Publish_Wake
                 (Flyology.Wake_Sources.Descriptor (Item.Wake),
                  Flyology.Wake_Sources.Signal_Descriptor (Item.Wake));
               Guard.Armed := False;
            else
               Item.State.Wait_Ready (FD, Already_Requested);
               if Already_Requested or else FD >= 0 then
                  return;
               end if;
            end if;
         end;
      end loop;
   end Wait_Source;

end Flyology.Cancellation;
