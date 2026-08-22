with Ada.Exceptions;
with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.Sockets;
with Flyology.IO.Timers;
with Flyology.Operations;
with Flyology.Operations.Drivers;

procedure Operation_Composition_Smoke is
   package Sockets renames Flyology.IO.Sockets;
   package Operations renames Flyology.Operations;
   package Drivers renames Flyology.Operations.Drivers;

   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Streams.Stream_Element_Offset;
   use type Flyology.Execution_Model;
   use type Operations.Driver_Event;
   use type Operations.Terminal_Outcome;

   function Contains (Batch : Operations.Completion_Batch; Id : Natural) return Boolean is
   begin
      for Position in 1 .. Batch.Count loop
         if Natural (Batch.Ids (Position)) = Id then
            return True;
         end if;
      end loop;
      return False;
   end Contains;

   type HTTP_Phase is (Sending_Request, Waiting_To_Receive, Receiving_Response);

   --  This deliberately models a third-party HTTP provider. It uses only
   --  public Flyology operation and socket APIs; no Flyology.IO implementation
   --  state or provider step routine is visible here.
   type HTTP_Shaped_Operation
     (Owner    : not null access Operations.Completion_Set'Class;
      Socket   : not null access Sockets.Socket_Type;
      Request  : not null access Ada.Streams.Stream_Element_Array;
      Response : not null access Ada.Streams.Stream_Element_Array)
   is new Operations.Operation (Owner) with record
      Send_Child      : Sockets.Send_All_Operation (Owner);
      Pause_Child     : Flyology.IO.Timers.Timer_Operation (Owner);
      Receive_Child   : Sockets.Receive_Exactly_Operation (Owner);
      Phase           : HTTP_Phase := Sending_Request;
      Cancelling      : Boolean := False;
      Provider_Failed : Boolean := False;
      Send_Slot       : Natural := 0;
      Pause_Slot      : Natural := 0;
      Receive_Slot    : Natural := 0;
   end record;

   overriding
   procedure Drive (Item : in out HTTP_Shaped_Operation; Event : Operations.Driver_Event);

   overriding
   procedure Request_Cancellation (Item : in out HTTP_Shaped_Operation);

   procedure Finish_Child (Item : in out HTTP_Shaped_Operation; Succeeded : out Boolean) is
   begin
      Succeeded := False;
      case Item.Phase is
         when Sending_Request    =>
            begin
               Sockets.Finish (Item.Send_Child);
               Succeeded := True;
            exception
               when others =>
                  null;
            end;
            Operations.Release (Item.Send_Child);

         when Waiting_To_Receive =>
            begin
               Flyology.IO.Timers.Finish (Item.Pause_Child);
               Succeeded := True;
            exception
               when others =>
                  null;
            end;
            Operations.Release (Item.Pause_Child);

         when Receiving_Response =>
            begin
               Sockets.Finish (Item.Receive_Child);
               Succeeded := True;
            exception
               when others =>
                  null;
            end;
            Operations.Release (Item.Receive_Child);
      end case;
   end Finish_Child;

   overriding
   procedure Drive (Item : in out HTTP_Shaped_Operation; Event : Operations.Driver_Event) is
      Child_Succeeded : Boolean;
   begin
      if Event /= Operations.Dependency_Changed then
         Item.Provider_Failed := True;
         Drivers.Complete (Item, Operations.Failed);
         return;
      end if;

      Finish_Child (Item, Child_Succeeded);
      if Item.Cancelling then
         Drivers.Complete (Item, Operations.Cancelled);
      elsif not Child_Succeeded then
         Item.Provider_Failed := True;
         Drivers.Complete (Item, Operations.Failed);
      elsif Item.Phase = Sending_Request then
         Item.Phase := Waiting_To_Receive;
         begin
            Flyology.IO.Timers.Sleep_For (Interval => 0.0, Operation => Item.Pause_Child);
            Item.Pause_Slot := Operations.Id (Item.Pause_Child);
            Operations.Continue_After (Item, Item.Pause_Child);
         exception
            when others =>
               if Operations.Id (Item.Pause_Child) /= 0 then
                  Operations.Release (Item.Pause_Child);
               end if;
               Item.Provider_Failed := True;
               Drivers.Complete (Item, Operations.Failed);
         end;
      elsif Item.Phase = Waiting_To_Receive then
         Item.Phase := Receiving_Response;
         begin
            Sockets.Receive_Exactly
              (Socket => Item.Socket, Item => Item.Response, Timeout => 1.0, Operation => Item.Receive_Child);
            Item.Receive_Slot := Operations.Id (Item.Receive_Child);
            Operations.Continue_After (Item, Item.Receive_Child);
         exception
            when others =>
               if Operations.Id (Item.Receive_Child) /= 0 then
                  Operations.Release (Item.Receive_Child);
               end if;
               Item.Provider_Failed := True;
               Drivers.Complete (Item, Operations.Failed);
         end;
      else
         Drivers.Complete (Item, Operations.Succeeded);
      end if;
   end Drive;

   overriding
   procedure Request_Cancellation (Item : in out HTTP_Shaped_Operation) is
   begin
      Item.Cancelling := True;
      case Item.Phase is
         when Sending_Request    =>
            Operations.Cancel (Item.Send_Child);

         when Waiting_To_Receive =>
            Operations.Cancel (Item.Pause_Child);

         when Receiving_Response =>
            Operations.Cancel (Item.Receive_Child);
      end case;
   end Request_Cancellation;

   function Start_Request
     (Set      : not null access Operations.Completion_Set'Class;
      Socket   : not null access Sockets.Socket_Type;
      Request  : not null access Ada.Streams.Stream_Element_Array;
      Response : not null access Ada.Streams.Stream_Element_Array) return HTTP_Shaped_Operation is
   begin
      return Result : HTTP_Shaped_Operation (Set, Socket, Request, Response) do
         Drivers.Start (Result);
         Sockets.Send_All (Socket => Socket, Item => Request, Timeout => 1.0, Operation => Result.Send_Child);
         Result.Send_Slot := Operations.Id (Result.Send_Child);
         Operations.Continue_After (Result, Result.Send_Child);
      end return;
   end Start_Request;

   procedure Finish (Item : in out HTTP_Shaped_Operation) is
      Result : constant Operations.Terminal_Outcome := Operations.Outcome (Item);
   begin
      Operations.Consume (Item);
      case Result is
         when Operations.Succeeded =>
            null;

         when Operations.Cancelled =>
            raise Operations.Operation_Cancelled;

         when Operations.Failed    =>
            raise Sockets.Socket_Error with "HTTP-shaped composed operation failed";
      end case;
   end Finish;

   type Result_Array is array (Positive range 1 .. 2) of Boolean;

   protected Result is
      procedure Set (Passed : Boolean);
      entry Wait (Passed : out Boolean);
   private
      Values    : Result_Array := [others => False];
      Published : Natural range 0 .. 2 := 0;
      Consumed  : Natural range 0 .. 2 := 0;
   end Result;

   protected body Result is
      procedure Set (Passed : Boolean) is
      begin
         Published := Published + 1;
         Values (Published) := Passed;
      end Set;

      entry Wait (Passed : out Boolean) when Consumed < Published is
      begin
         Consumed := Consumed + 1;
         Passed := Values (Consumed);
      end Wait;
   end Result;

   task type Runner (Model : Flyology.Execution_Model) is
      pragma Task_Info (Model);
   end Runner;

   task body Runner is
      Left, Right : aliased Sockets.Socket_Type;
      Request     : aliased Ada.Streams.Stream_Element_Array := [1, 2, 3];
      Response    : aliased Ada.Streams.Stream_Element_Array := [0, 0, 0];
      Reply       : constant Ada.Streams.Stream_Element_Array := [7, 8, 9];
      Incoming    : Ada.Streams.Stream_Element_Array (Request'Range);
      Passed      : Boolean := True;
   begin
      Sockets.Create_Socket_Pair (Left, Right);
      declare
         Set               : aliased Operations.Completion_Set (3);
         Request_Operation : HTTP_Shaped_Operation :=
           Start_Request (Set'Access, Left'Access, Request'Access, Response'Access);
         Request_Succeeded : Operations.Gate_Operation :=
           Operations.Wait_For_Success (Set'Access, [Operations.Reference (Request_Operation)]);
         Batch             : Operations.Completion_Batch (Set.Capacity);
         Matched           : Operations.Completion_Batch (Set.Capacity);
      begin
         Passed :=
           Passed
           and then Operations.Pending_Count (Set) = 2
           and then not Operations.Is_Terminal (Request_Operation);
         declare
            Rejected : Boolean := False;
         begin
            begin
               case Request_Operation.Phase is
                  when Sending_Request    =>
                     declare
                        Hidden : constant Operations.Operation_Reference :=
                          Operations.Reference (Request_Operation.Send_Child);
                        pragma Unreferenced (Hidden);
                     begin
                        null;
                     end;

                  when Waiting_To_Receive =>
                     declare
                        Hidden : constant Operations.Operation_Reference :=
                          Operations.Reference (Request_Operation.Pause_Child);
                        pragma Unreferenced (Hidden);
                     begin
                        null;
                     end;

                  when Receiving_Response =>
                     declare
                        Hidden : constant Operations.Operation_Reference :=
                          Operations.Reference (Request_Operation.Receive_Child);
                        pragma Unreferenced (Hidden);
                     begin
                        null;
                     end;
               end case;
            exception
               when Operations.Operation_Error =>
                  Rejected := True;
            end;
            Passed := Passed and then Rejected;
         end;
         Sockets.Receive_Exactly (Right, Incoming, Timeout => 1.0);
         Sockets.Send_All (Right, Reply, Timeout => 1.0);
         Operations.Wait_Some (Set, Batch);
         Passed :=
           Passed
           and then Batch.Count = 2
           and then Contains (Batch, Operations.Id (Request_Operation))
           and then Contains (Batch, Operations.Id (Request_Succeeded))
           and then Request_Operation.Send_Slot = Request_Operation.Pause_Slot
           and then Request_Operation.Pause_Slot = Request_Operation.Receive_Slot;
         Operations.Finish (Request_Succeeded, Matched);
         Passed :=
           Passed and then Matched.Count = 1 and then Contains (Matched, Operations.Id (Request_Operation));
         Finish (Request_Operation);
         Passed := Passed and then Incoming = Request and then Response = Reply;
      end;
      Sockets.Close_Socket (Left);
      Sockets.Close_Socket (Right);

      Sockets.Create_Socket_Pair (Left, Right);
      Response := [0, 0, 0];
      declare
         Set               : aliased Operations.Completion_Set (2);
         Request_Operation : HTTP_Shaped_Operation :=
           Start_Request (Set'Access, Left'Access, Request'Access, Response'Access);
         Batch             : Operations.Completion_Batch (Set.Capacity);
         Cancelled         : Boolean := False;
      begin
         Operations.Cancel (Request_Operation);
         Operations.Wait_Some (Set, Batch);
         Passed :=
           Passed
           and then Batch.Count = 1
           and then Natural (Batch.Ids (1)) = Operations.Id (Request_Operation);
         begin
            Finish (Request_Operation);
         exception
            when Operations.Operation_Cancelled =>
               Cancelled := True;
         end;
         Passed := Passed and then Cancelled;
      end;
      Sockets.Close_Socket (Left);
      Sockets.Close_Socket (Right);

      --  A child provider failure terminalizes only the visible parent and is
      --  retained for the parent's typed Finish.
      Sockets.Create_Socket_Pair (Left, Right);
      Response := [0, 0, 0];
      declare
         Set               : aliased Operations.Completion_Set (2);
         Request_Operation : HTTP_Shaped_Operation :=
           Start_Request (Set'Access, Left'Access, Request'Access, Response'Access);
         Batch             : Operations.Completion_Batch (Set.Capacity);
         Failed            : Boolean := False;
      begin
         Sockets.Close_Socket (Right);
         Operations.Wait_Some (Set, Batch);
         Passed :=
           Passed
           and then Batch.Count = 1
           and then Operations.Outcome (Request_Operation) = Operations.Failed;
         begin
            Finish (Request_Operation);
         exception
            when Sockets.Socket_Error =>
               Failed := True;
         end;
         Passed := Passed and then Failed;
      end;
      Sockets.Close_Socket (Left);

      --  Abandoning a pending parent cancels and drains its hidden child. Both
      --  bounded slots are then available to unrelated operation types.
      Sockets.Create_Socket_Pair (Left, Right);
      declare
         Set : aliased Operations.Completion_Set (2);
      begin
         declare
            Abandoned : HTTP_Shaped_Operation :=
              Start_Request (Set'Access, Left'Access, Request'Access, Response'Access);
            pragma Unreferenced (Abandoned);
         begin
            null;
         end;
         Passed :=
           Passed and then Operations.Pending_Count (Set) = 0 and then Operations.Terminal_Count (Set) = 0;
         declare
            First  : Flyology.IO.Timers.Timer_Operation := Flyology.IO.Timers.Sleep_For (Set'Access, 0.0);
            Second : Flyology.IO.Timers.Timer_Operation := Flyology.IO.Timers.Sleep_For (Set'Access, 0.0);
         begin
            Operations.Wait_All (Set);
            Flyology.IO.Timers.Finish (First);
            Flyology.IO.Timers.Finish (Second);
         end;
      end;
      Sockets.Close_Socket (Left);
      Sockets.Close_Socket (Right);
      Result.Set (Passed);
   exception
      when Error : others =>
         Ada.Text_IO.Put_Line
           ("composition runner " & Model'Image & ": " & Ada.Exceptions.Exception_Information (Error));
         if Sockets.Is_Open (Left) then
            Sockets.Close_Socket (Left);
         end if;
         if Sockets.Is_Open (Right) then
            Sockets.Close_Socket (Right);
         end if;
         Result.Set (False);
   end Runner;

   Native                    : Runner (Flyology.Native_Task);
   Lightweight               : Runner (Flyology.Lightweight_Task);
   Native_OK, Lightweight_OK : Boolean;
begin
   Result.Wait (Native_OK);
   Result.Wait (Lightweight_OK);
   pragma Assert (Native_OK and Lightweight_OK);
   Ada.Text_IO.Put_Line ("operation composition smoke passed");
end Operation_Composition_Smoke;
