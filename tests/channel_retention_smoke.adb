with Ada.Finalization;
with Ada.Unchecked_Deallocation;
with Flyology;
with Flyology.Channels.Bounded;

procedure Channel_Retention_Smoke is
   type Resource is record
      References : Positive := 1;
   end record;
   type Resource_Access is access Resource;

   Released       : Natural := 0;
   Raise_Adjust   : Boolean := False;
   Raise_Finalize : Boolean := False;
   Element_Error  : exception;

   type Tracked_Value is new Ada.Finalization.Controlled with record
      Owner : Resource_Access := null;
   end record;

   overriding procedure Adjust (Item : in out Tracked_Value);
   overriding procedure Finalize (Item : in out Tracked_Value);

   procedure Free is new Ada.Unchecked_Deallocation
     (Resource, Resource_Access);

   overriding procedure Adjust (Item : in out Tracked_Value) is
   begin
      if Raise_Adjust and then Item.Owner /= null then
         --  A failed Adjust must not claim the source's reference.
         Item.Owner := null;
         raise Element_Error with "injected Adjust failure";
      elsif Item.Owner /= null then
         Item.Owner.References := Item.Owner.References + 1;
      end if;
   end Adjust;

   overriding procedure Finalize (Item : in out Tracked_Value) is
   begin
      if Item.Owner = null then
         return;
      elsif Item.Owner.References > 1 then
         Item.Owner.References := Item.Owner.References - 1;
      else
         Free (Item.Owner);
         Released := Released + 1;
      end if;
      Item.Owner := null;
      if Raise_Finalize then
         Raise_Finalize := False;
         raise Element_Error with "injected Finalize failure";
      end if;
   end Finalize;

   function Make return Tracked_Value is
     (Ada.Finalization.Controlled with
        Owner => new Resource'(References => 1));

   procedure Drop (Item : in out Tracked_Value) is
   begin
      Item := (Ada.Finalization.Controlled with Owner => null);
   end Drop;

   Empty : constant Tracked_Value :=
     (Ada.Finalization.Controlled with Owner => null);

   package Channels is new Flyology.Channels.Bounded
     (Element_Type => Tracked_Value,
      Empty_Value  => Empty);

   procedure Check_Released (Expected : Natural; Path : String) is
   begin
      if Released /= Expected then
         raise Program_Error with Path & " retained a delivered element";
      end if;
   end Check_Released;

   procedure Exercise_Receive is
      Queue    : Channels.Channel (Capacity => 1);
      Sent     : Tracked_Value := Make;
      Received : Tracked_Value;
      Before   : constant Natural := Released;
   begin
      Queue.Send (Sent);
      Drop (Sent);
      Queue.Receive (Received);
      Drop (Received);
      Check_Released (Before + 1, "Receive");
   end Exercise_Receive;

   procedure Exercise_Try_Receive is
      use type Channels.Try_Receive_Result;
      Queue    : Channels.Channel (Capacity => 1);
      Sent     : Tracked_Value := Make;
      Received : Tracked_Value;
      Result   : Channels.Try_Receive_Result;
      Before   : constant Natural := Released;
   begin
      Queue.Send (Sent);
      Drop (Sent);
      Queue.Try_Receive (Received, Result);
      pragma Assert (Result = Channels.Item_Received);
      Drop (Received);
      Check_Released (Before + 1, "Try_Receive");
   end Exercise_Try_Receive;

   procedure Exercise_Close_And_Drain is
      use type Channels.Try_Receive_Result;
      Queue    : Channels.Channel (Capacity => 1);
      Sent     : Tracked_Value := Make;
      Received : Tracked_Value;
      Result   : Channels.Try_Receive_Result;
      Before   : constant Natural := Released;
   begin
      Queue.Send (Sent);
      Drop (Sent);
      Queue.Close;
      Queue.Receive (Received);
      Queue.Await_Drained;
      Drop (Received);
      Check_Released (Before + 1, "close and drain");
      Queue.Try_Receive (Received, Result);
      pragma Assert (Result = Channels.Receive_Closed);
   end Exercise_Close_And_Drain;

   procedure Exercise_Timeouts is
      Queue     : Channels.Channel (Capacity => 1);
      First     : Tracked_Value := Make;
      Second    : Tracked_Value := Make;
      Received  : Tracked_Value;
      Timed_Out : Boolean := False;
      Before    : constant Natural := Released;
   begin
      begin
         Channels.Timed_Receive (Queue, Received, 0.0);
      exception
         when Channels.Timeout_Error =>
            Timed_Out := True;
      end;
      pragma Assert (Timed_Out);
      Check_Released (Before, "empty receive timeout");

      Queue.Send (First);
      Drop (First);
      Timed_Out := False;
      begin
         Channels.Timed_Send (Queue, Second, 0.0);
      exception
         when Channels.Timeout_Error =>
            Timed_Out := True;
      end;
      pragma Assert (Timed_Out);
      Drop (Second);
      Check_Released (Before + 1, "full send timeout");

      Queue.Close;
      Channels.Timed_Receive (Queue, Received, 0.0);
      Queue.Await_Drained;
      Drop (Received);
      Check_Released (Before + 2, "timed close and drain");
   end Exercise_Timeouts;

   procedure Exercise_Raising_Adjust is
      Queue    : Channels.Channel (Capacity => 1);
      Sent     : Tracked_Value := Make;
      Received : Tracked_Value;
      Raised   : Boolean := False;
      Before   : constant Natural := Released;
   begin
      Queue.Send (Sent);
      Drop (Sent);
      Raise_Adjust := True;
      begin
         Queue.Receive (Received);
      exception
         --  Ada converts a controlled Adjust exception to Program_Error.
         when Program_Error =>
            Raised := True;
      end;
      Raise_Adjust := False;
      pragma Assert (Raised);
      pragma Assert (Queue.Current.Pending = 1);

      Queue.Receive (Received);
      pragma Assert (Queue.Current.Pending = 0);
      Drop (Received);
      Check_Released (Before + 1, "raising Adjust recovery");
   exception
      when others =>
         Raise_Adjust := False;
         raise;
   end Exercise_Raising_Adjust;

   procedure Exercise_Raising_Finalize is
      Queue    : Channels.Channel (Capacity => 1);
      Sent     : Tracked_Value := Make;
      Received : Tracked_Value;
      Result   : Channels.Try_Receive_Result;
      Raised   : Boolean := False;
      Before   : constant Natural := Released;
   begin
      Queue.Send (Sent);
      Drop (Sent);
      Raise_Finalize := True;
      begin
         Queue.Try_Receive (Received, Result);
      exception
         --  Ada converts a controlled Finalize exception to Program_Error.
         when Program_Error =>
            Raised := True;
      end;
      Raise_Finalize := False;
      pragma Assert (Raised);
      --  Target assignment succeeded, so the dequeue committed before the
      --  prohibited slot finalizer propagated its exception.
      pragma Assert (Queue.Current.Pending = 0);
      Queue.Close;
      Queue.Await_Drained;
      Drop (Received);
      Check_Released (Before + 1, "raising Finalize commit");
   exception
      when others =>
         Raise_Finalize := False;
         raise;
   end Exercise_Raising_Finalize;

   procedure Run (Model : Flyology.Execution_Model) is
      Passed : Boolean := False;
   begin
      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
         begin
            Exercise_Receive;
            Exercise_Try_Receive;
            Exercise_Close_And_Drain;
            Exercise_Timeouts;
            Exercise_Raising_Adjust;
            Exercise_Raising_Finalize;
            Passed := True;
         end Worker;
      begin
         null;
      end;
      if not Passed then
         raise Program_Error with
           "controlled channel checks failed in " & Model'Image;
      end if;
   end Run;

begin
   Run (Flyology.Lightweight_Task);
   Run (Flyology.Native_Task);
end Channel_Retention_Smoke;
