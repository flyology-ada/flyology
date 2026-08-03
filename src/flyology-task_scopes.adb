with System.Address_To_Access_Conversions;

package body Flyology.Task_Scopes is

   protected body Shared_State is
      procedure Configure
        (Token      : Cancellation_Access;
         Deadline   : Ada.Real_Time.Time;
         Cancel_On_Failure : Boolean) is
      begin
         if Configured then
            raise Program_Error with "task scope is already configured";
         end if;
         Parent_Stop := Token;
         End_Time := Deadline;
         Cancel_On_Failure_Value := Cancel_On_Failure;
         Configured := True;
      end Configure;

      procedure Submit (Input : Input_Type; Index : out Positive) is
      begin
         if not Configured then
            raise Program_Error with "task scope is not configured";
         elsif Closed then
            raise Program_Error with "task scope admission is closed";
         elsif Submitted = Capacity then
            raise Constraint_Error with "task scope capacity is exhausted";
         end if;
         Submitted := Submitted + 1;
         Inputs (Submitted) := Input;
         Index := Submitted;
      end Submit;

      entry Next
        (Index    : out Positive;
         Input    : out Input_Type;
         Stop     : out Boolean;
         Token    : out Cancellation_Access;
         Deadline : out Ada.Real_Time.Time;
         Cancel_On_Failure : out Boolean)
        when Next_Index <= Submitted or else Stopping
      is
      begin
         if Stopping and then Next_Index > Submitted then
            Stop := True;
            Index := 1;
            Token := Parent_Stop;
            Deadline := End_Time;
            Cancel_On_Failure := Cancel_On_Failure_Value;
            return;
         end if;
         Stop := False;
         Index := Next_Index;
         Input := Inputs (Index);
         Next_Index := Next_Index + 1;
         Token := Parent_Stop;
         Deadline := End_Time;
         Cancel_On_Failure := Cancel_On_Failure_Value;
      end Next;

      procedure Complete (Index : Positive; Value : Result_Type) is
      begin
         Results (Index) := Value;
         Successes (Index) := True;
         Completed := Completed + 1;
      end Complete;

      procedure Fail
        (Index : Positive; Occurrence : Ada.Exceptions.Exception_Occurrence) is
      begin
         Failure_Ids (Index) := Ada.Exceptions.Exception_Identity (Occurrence);
         Failure_Messages (Index) :=
           Ada.Strings.Unbounded.To_Unbounded_String
             (Ada.Exceptions.Exception_Message (Occurrence));
         Successes (Index) := False;
         Completed := Completed + 1;
      end Fail;

      procedure Close_Admission is
      begin
         Closed := True;
      end Close_Admission;

      entry Await_All when Closed and then Completed = Submitted is
      begin
         null;
      end Await_All;

      procedure Shutdown is
      begin
         Stopping := True;
      end Shutdown;

      function Submitted_Count return Natural is (Submitted);

      function Was_Successful (Index : Positive) return Boolean is
      begin
         if Index > Submitted or else Completed < Submitted then
            raise Invalid_Handle;
         end if;
         return Successes (Index);
      end Was_Successful;

      function Result_Value (Index : Positive) return Result_Type is
      begin
         if Index > Submitted or else Completed < Submitted then
            raise Invalid_Handle;
         end if;
         return Results (Index);
      end Result_Value;

      function Failure_Id
        (Index : Positive) return Ada.Exceptions.Exception_Id is
      begin
         if Index > Submitted or else Completed < Submitted then
            raise Invalid_Handle;
         end if;
         return Failure_Ids (Index);
      end Failure_Id;

      function Failure_Message
        (Index : Positive) return Ada.Strings.Unbounded.Unbounded_String is
      begin
         if Index > Submitted or else Completed < Submitted then
            raise Invalid_Handle;
         end if;
         return Failure_Messages (Index);
      end Failure_Message;
   end Shared_State;

   task body Worker is
      package Conversions is new
        System.Address_To_Access_Conversions (Shared_State);
      State   : Conversions.Object_Pointer;
      Stopped : Boolean := False;
   begin
      select
         accept Start (State_Address : System.Address) do
            State := Conversions.To_Pointer (State_Address);
         end Start;
      or
         accept Stop;
         Stopped := True;
      end select;

      while not Stopped loop
         declare
            Index      : Positive;
            Input      : Input_Type;
            Stop       : Boolean;
            Token      : Cancellation_Access;
            Deadline   : Ada.Real_Time.Time;
            Cancel_On_Failure : Boolean;
            Value      : Result_Type;
         begin
            State.Next
              (Index, Input, Stop, Token, Deadline, Cancel_On_Failure);
            exit when Stop;
            begin
               if Token.Requested then
                  raise Flyology.Cancellation.Operation_Cancelled;
               end if;
               Execute (Input, Token, Deadline, Value);
               State.Complete (Index, Value);
            exception
               when Error : others =>
                  State.Fail (Index, Error);
                  if Cancel_On_Failure and then not Token.Requested then
                     Token.Request;
                  end if;
            end;
         end;
      end loop;
   end Worker;

   procedure Configure
     (Item       : in out Scope;
      Token      : access Flyology.Cancellation.Token;
      Deadline   : Ada.Real_Time.Time;
      Cancel_Siblings_On_Failure : Boolean := True)
   is
   begin
      if Item.Is_Configured then
         raise Program_Error with "task scope is already configured";
      end if;
      Item.Token :=
        (if Token = null then Item.Local_Stop'Unchecked_Access
         else Token.all'Unchecked_Access);
      Item.State.Configure
        (Item.Token, Deadline, Cancel_Siblings_On_Failure);
      for Worker of Item.Workers loop
         Worker.Start (Item.State'Address);
      end loop;
      Item.Is_Configured := True;
   end Configure;

   procedure Spawn
     (Item   : in out Scope;
      Input  : Input_Type;
      Handle : out Operation_Handle)
   is
      Index : Positive;
   begin
      if Item.Is_Joined then
         raise Program_Error with "task scope is already joined";
      end if;
      Item.State.Submit (Input, Index);
      Handle := Operation_Handle (Index);
   end Spawn;

   procedure Join (Item : in out Scope) is
   begin
      if not Item.Is_Configured then
         raise Program_Error with "task scope is not configured";
      elsif Item.Is_Joined then
         return;
      end if;
      Item.State.Close_Admission;
      Item.State.Await_All;
      Item.State.Shutdown;
      Item.Is_Joined := True;
   end Join;

   function Succeeded
     (Item   : Scope;
      Handle : Operation_Handle) return Boolean is
   begin
      if not Item.Is_Joined then
         raise Program_Error with "task scope is not joined";
      end if;
      return Item.State.Was_Successful (Positive (Handle));
   end Succeeded;

   function Result
     (Item   : Scope;
      Handle : Operation_Handle) return Result_Type
   is
      Successful : constant Boolean :=
        Item.State.Was_Successful (Positive (Handle));
      Index : constant Positive := Positive (Handle);
   begin
      if not Item.Is_Joined then
         raise Program_Error with "task scope is not joined";
      end if;
      if not Successful then
         Ada.Exceptions.Raise_Exception
           (Item.State.Failure_Id (Index),
            Ada.Strings.Unbounded.To_String
              (Item.State.Failure_Message (Index)));
      end if;
      return Item.State.Result_Value (Index);
   end Result;

   overriding procedure Finalize (Item : in out Scope) is
   begin
      if not Item.Is_Configured then
         for Worker of Item.Workers loop
            Worker.Stop;
         end loop;
      elsif not Item.Is_Joined then
         if not Item.Token.Requested then
            Item.Token.Request;
         end if;
         Item.State.Close_Admission;
         Item.State.Await_All;
         Item.State.Shutdown;
         Item.Is_Joined := True;
      end if;
   end Finalize;

end Flyology.Task_Scopes;
