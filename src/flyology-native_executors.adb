with Ada.Unchecked_Deallocation;
with Flyology.IO;
with System.Address_To_Access_Conversions;

package body Flyology.Native_Executors is
   use type Ada.Real_Time.Time;
   use type Ada.Exceptions.Exception_Id;
   use type System.Address;

   procedure Free_Token is new Ada.Unchecked_Deallocation
     (Flyology.Cancellation.Token, Token_Access);

   protected body Shared_State is
      procedure Submit
        (Input      : Input_Type;
         Token      : Token_Access;
         Deadline   : Ada.Real_Time.Time;
         Slot       : out Positive;
         Generation : out Natural;
         Replaced_Token : out Token_Access;
         Accepted   : out Boolean)
      is
         Found : Natural := 0;
      begin
         Replaced_Token := null;
         if Stopping then
            Slot := 1;
            Generation := 0;
            Accepted := False;
            return;
         end if;
         for Index in Status'Range loop
            if Status (Index) = Free then
               Found := Index;
               exit;
            end if;
         end loop;
         if Found = 0 then
            Slot := 1;
            Generation := 0;
            Accepted := False;
            return;
         end if;
         Slot := Found;
         Generations (Slot) := Generations (Slot) + 1;
         Generation := Generations (Slot);
         Inputs (Slot) := Input;
         Messages (Slot) := Ada.Strings.Unbounded.Null_Unbounded_String;
         Replaced_Token := Tokens (Slot);
         Tokens (Slot) := Token;
         Deadlines (Slot) := Deadline;
         Error_Ids (Slot) := Ada.Exceptions.Null_Id;
         Detached (Slot) := False;
         Status (Slot) := Queued;
         Queue (Tail) := Slot;
         Tail := (if Tail = Capacity then 1 else Tail + 1);
         Queue_Count := Queue_Count + 1;
         Accepted := True;
      end Submit;

      entry Next
        (Slot : out Positive; Stop : out Boolean)
        when Queue_Count > 0 or else Stopping
      is
      begin
         if Stopping then
            Slot := 1;
            Stop := True;
            return;
         end if;
         Slot := Queue (Head);
         Head := (if Head = Capacity then 1 else Head + 1);
         Queue_Count := Queue_Count - 1;
         Status (Slot) := Running;
         Stop := False;
      end Next;

      procedure Operation_Data
        (Slot     : Positive;
         Input    : out Input_Type;
         Token    : out Token_Access;
         Deadline : out Ada.Real_Time.Time) is
      begin
         if Status (Slot) /= Running then
            raise Program_Error with "native executor slot is not running";
         end if;
         Token := Tokens (Slot);
         Deadline := Deadlines (Slot);
         Input := Inputs (Slot);
      end Operation_Data;

      procedure Complete (Slot : Positive; Result : Result_Type) is
      begin
         if Detached (Slot) then
            Status (Slot) := Free;
            Detached (Slot) := False;
         else
            Results (Slot) := Result;
            Status (Slot) := Completed;
         end if;
      end Complete;

      procedure Fail
        (Slot : Positive; Error : Ada.Exceptions.Exception_Occurrence) is
      begin
         if Detached (Slot) then
            Status (Slot) := Free;
            Detached (Slot) := False;
         else
            --  Make the slot terminal before copying diagnostic text, whose
            --  allocation is allowed to fail without stranding a waiter.
            Error_Ids (Slot) := Ada.Exceptions.Exception_Identity (Error);
            Status (Slot) := Completed;
            Messages (Slot) := Ada.Strings.Unbounded.To_Unbounded_String
              (Ada.Exceptions.Exception_Message (Error));
         end if;
      end Fail;

      procedure Try_Await
        (Slot       : Positive;
         Generation : Natural;
         Result     : out Result_Type;
         Error_Id   : out Ada.Exceptions.Exception_Id;
         Message    : out Ada.Strings.Unbounded.Unbounded_String;
         Ready      : out Boolean)
      is
      begin
         if Generations (Slot) /= Generation or else Generation = 0
           or else Status (Slot) = Free
         then
            raise Invalid_Handle;
         elsif Status (Slot) /= Completed then
            Ready := False;
            return;
         end if;
         Ready := True;
         Result := Results (Slot);
         Error_Id := Error_Ids (Slot);
         Message := Messages (Slot);
         Messages (Slot) := Ada.Strings.Unbounded.Null_Unbounded_String;
         Status (Slot) := Free;
      end Try_Await;

      procedure Abandon
        (Slot       : Positive;
         Generation : Natural;
         Token      : out Token_Access) is
      begin
         Token := null;
         if Generations (Slot) /= Generation or else Generation = 0
           or else Status (Slot) = Free
         then
            raise Invalid_Handle;
         end if;
         Token := Tokens (Slot);
         if Status (Slot) = Completed then
            Status (Slot) := Free;
            Detached (Slot) := False;
         else
            Detached (Slot) := True;
         end if;
      end Abandon;

      procedure Shutdown is
      begin
         Stopping := True;
         for Index in Status'Range loop
            if Status (Index) = Queued then
               Status (Index) := Completed;
               Error_Ids (Index) :=
                 Flyology.Cancellation.Operation_Cancelled'Identity;
            end if;
         end loop;
         Queue_Count := 0;
      end Shutdown;

      procedure Token_At (Slot : Positive; Token : out Token_Access) is
      begin
         Token := Tokens (Slot);
      end Token_At;

      procedure Set_Expected_Workers (Count : Natural) is
      begin
         Expected_Workers := Count;
         Expected_Workers_Set := True;
      end Set_Expected_Workers;

      procedure Worker_Stopped is
      begin
         Stopped_Workers := Stopped_Workers + 1;
      end Worker_Stopped;

      entry Await_Stopped
        when Expected_Workers_Set
          and then Stopped_Workers = Expected_Workers is
      begin
         null;
      end Await_Stopped;

      procedure Take_Token (Slot : Positive; Token : out Token_Access) is
      begin
         Token := Tokens (Slot);
         Tokens (Slot) := null;
      end Take_Token;
   end Shared_State;

   task body Worker is
      package Conversions is new
        System.Address_To_Access_Conversions (Shared_State);
      State_Ptr : Conversions.Object_Pointer;
      Stopped   : Boolean := False;
   begin
      select
         accept Start (State : System.Address) do
            State_Ptr := Conversions.To_Pointer (State);
         end Start;
      or
         accept Stop;
         Stopped := True;
      end select;
      begin
         while not Stopped loop
            declare
               Slot     : Positive;
               Input    : Input_Type;
               Token    : Token_Access;
               Deadline : Ada.Real_Time.Time;
               Stop     : Boolean;
               Result   : Result_Type;
            begin
               State_Ptr.Next (Slot, Stop);
               exit when Stop;
               begin
                  State_Ptr.Operation_Data (Slot, Input, Token, Deadline);
                  if Token /= null and then Token.Requested then
                     raise Flyology.Cancellation.Operation_Cancelled;
                  elsif Deadline /= Ada.Real_Time.Time_Last
                    and then Ada.Real_Time.Clock >= Deadline
                  then
                     raise Flyology.IO.Timeout_Error with
                       "native executor operation deadline expired";
                  end if;
                  Execute (Input, Token, Deadline, Result);
                  State_Ptr.Complete (Slot, Result);
               exception
                  when Error : others =>
                     begin
                        State_Ptr.Fail (Slot, Error);
                     exception
                        when others => null;
                     end;
               end;
            end;
         end loop;
      exception
         when others =>
            null;
      end;
      if not Stopped then
         State_Ptr.Worker_Stopped;
      end if;
   end Worker;

   overriding procedure Initialize (Item : in out Executor) is
   begin
      null;
   end Initialize;

   procedure Start (Item : aliased in out Executor) is
   begin
      if not Item.Started then
         Item.Pool := new Worker_Array (1 .. Item.Workers);
         Item.Started := True;
         for Worker of Item.Pool.all loop
            Worker.Start (Item.State'Address);
            Item.Activated_Workers := Item.Activated_Workers + 1;
         end loop;
      end if;
   end Start;

   overriding procedure Finalize (Item : in out Executor) is
      procedure Free is new Ada.Unchecked_Deallocation
        (Worker_Array, Worker_Array_Access);
   begin
      if Item.Started then
         Item.State.Shutdown;
         for Index in 1 .. Item.Capacity loop
            declare
               Token : Token_Access;
            begin
               Item.State.Token_At (Index, Token);
               if Token /= null and then not Token.Requested then
                  Token.Request;
               end if;
            end;
         end loop;
         if Item.Pool /= null then
            for Index in Item.Activated_Workers + 1 .. Item.Workers loop
               begin
                  Item.Pool (Index).Stop;
               exception
                  when Tasking_Error => null;
               end;
            end loop;
         end if;
         Item.State.Set_Expected_Workers (Item.Activated_Workers);
         Item.State.Await_Stopped;
         Free (Item.Pool);
         for Index in 1 .. Item.Capacity loop
            declare
               Token : Token_Access;
            begin
               Item.State.Take_Token (Index, Token);
               if Token /= null then
                  Free_Token (Token);
               end if;
            end;
         end loop;
      end if;
   end Finalize;

   procedure Submit
     (Item     : aliased in out Executor;
      Input    : Input_Type;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Handle   : in out Operation_Handle;
      Accepted : out Boolean)
   is
      Slot       : Positive;
      Generation : Natural;
      Token_Value : Token_Access := null;
      Replaced_Token : Token_Access := null;
   begin
      if not Item.Started then
         raise Program_Error with "native executor has not been started";
      elsif Handle.Owner.all'Address /= Item'Address then
         raise Invalid_Handle;
      elsif Handle.Guard.Active then
         raise Invalid_Handle with
           "cannot submit through an active native operation handle";
      end if;
      Token_Value := new Flyology.Cancellation.Token;
      if Token /= null and then Token.Requested then
         Token_Value.Request;
      end if;
      begin
         Item.State.Submit
           (Input, Token_Value, Deadline, Slot, Generation, Replaced_Token,
            Accepted);
      exception
         when others =>
            Free_Token (Token_Value);
            raise;
      end;
      if Replaced_Token /= null then
         Free_Token (Replaced_Token);
      end if;
      if not Accepted then
         Free_Token (Token_Value);
      end if;
      Handle.Guard.State := Handle.Owner.State'Unchecked_Access;
      Handle.Guard.Slot := Slot;
      Handle.Guard.Generation := Generation;
      Handle.Guard.Active := Accepted;
   end Submit;

   procedure Await
     (Item   : aliased in out Executor;
      Handle : in out Operation_Handle;
      Result : out Result_Type;
      Token  : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last)
   is
      Error_Id : Ada.Exceptions.Exception_Id;
      Message  : Ada.Strings.Unbounded.Unbounded_String;
      Ready    : Boolean := False;
   begin
      if not Handle.Guard.Active
        or else Handle.Owner.all'Address /= Item'Address
        or else Handle.Guard.Generation = 0
        or else Handle.Guard.Slot > Item.Capacity
      then
         raise Invalid_Handle;
      end if;
      while not Ready loop
         if Token /= null and then Token.Requested then
            Abandon (Item, Handle);
            raise Flyology.Cancellation.Operation_Cancelled;
         elsif Deadline /= Ada.Real_Time.Time_Last
           and then Ada.Real_Time.Clock >= Deadline
         then
            Abandon (Item, Handle);
            raise Flyology.IO.Timeout_Error with
              "native executor await deadline expired";
         end if;
         Item.State.Try_Await
           (Handle.Guard.Slot, Handle.Guard.Generation,
            Result, Error_Id, Message, Ready);
         if not Ready then
            delay 0.001;
         end if;
      end loop;
      Handle.Guard.Active := False;
      if Error_Id /= Ada.Exceptions.Null_Id then
         Ada.Exceptions.Raise_Exception
           (Error_Id, Ada.Strings.Unbounded.To_String (Message));
      end if;
   end Await;

   procedure Abandon
     (Item : aliased in out Executor; Handle : in out Operation_Handle)
   is
      Token : Token_Access;
   begin
      if not Handle.Guard.Active
        or else Handle.Owner.all'Address /= Item'Address
      then
         raise Invalid_Handle;
      end if;
      Item.State.Abandon
        (Handle.Guard.Slot, Handle.Guard.Generation, Token);
      Handle.Guard.Active := False;
      if Token /= null and then not Token.Requested then
         Token.Request;
      end if;
   end Abandon;

   overriding procedure Finalize (Item : in out Handle_Guard) is
      Token : Token_Access;
   begin
      if Item.Active and then Item.State /= null then
         begin
            Item.State.Abandon (Item.Slot, Item.Generation, Token);
            if Token /= null and then not Token.Requested then
               Token.Request;
            end if;
         exception
            when others => null;
         end;
         Item.Active := False;
      end if;
   end Finalize;

end Flyology.Native_Executors;
