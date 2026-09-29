pragma Queuing_Policy (FIFO_Queuing);

with Ada.Real_Time;
with Ada.Text_IO;
with Flyology;
with Flyology.Execution_Groups;
with Semantic_Conformance_Cases;

procedure Semantic_Conformance_Matrix is
   package RT renames Ada.Real_Time;
   package Groups renames Flyology.Execution_Groups;

   use type RT.Time;

   package Native_Native is new
     Semantic_Conformance_Cases (Server_Model => Flyology.Native_Task, Caller_Model => Flyology.Native_Task);
   package Native_Lightweight is new
     Semantic_Conformance_Cases
       (Server_Model => Flyology.Native_Task,
        Caller_Model => Flyology.Lightweight_Task);
   package Lightweight_Native is new
     Semantic_Conformance_Cases
       (Server_Model => Flyology.Lightweight_Task,
        Caller_Model => Flyology.Native_Task);
   package Lightweight_Lightweight is new
     Semantic_Conformance_Cases
       (Server_Model => Flyology.Lightweight_Task,
        Caller_Model => Flyology.Lightweight_Task);

   procedure Check (Name : String; Results : Native_Native.Results) is
   begin
      for Item in Results'Range loop
         if not Results (Item) then
            raise Program_Error with Name & " failed " & Native_Native.Check_Id'Image (Item);
         end if;
      end loop;
   end Check;

   --  The overloads retain each generic instance's distinct array type while
   --  keeping the diagnostics uniform.
   procedure Check (Name : String; Results : Native_Lightweight.Results) is
   begin
      for Item in Results'Range loop
         if not Results (Item) then
            raise Program_Error with Name & " failed " & Native_Lightweight.Check_Id'Image (Item);
         end if;
      end loop;
   end Check;

   procedure Check (Name : String; Results : Lightweight_Native.Results) is
   begin
      for Item in Results'Range loop
         if not Results (Item) then
            raise Program_Error with Name & " failed " & Lightweight_Native.Check_Id'Image (Item);
         end if;
      end loop;
   end Check;

   procedure Check (Name : String; Results : Lightweight_Lightweight.Results) is
   begin
      for Item in Results'Range loop
         if not Results (Item) then
            raise Program_Error with Name & " failed " & Lightweight_Lightweight.Check_Id'Image (Item);
         end if;
      end loop;
   end Check;

   procedure Check_Cross_Group_Conformance is
      type Order_Array is array (Positive range 1 .. 3) of Positive;
      type Release_Array is array (Positive range 1 .. 3) of Boolean;

      protected Gate is
         entry Pass (Id : Positive);
         procedure Open;
         function Waiting return Natural;
         function Order return Order_Array;
      private
         Is_Open : Boolean := False;
         Count   : Natural := 0;
         Seen    : Order_Array := (others => 1);
      end Gate;

      protected body Gate is
         entry Pass (Id : Positive) when Is_Open is
         begin
            Count := Count + 1;
            Seen (Count) := Id;
         end Pass;

         procedure Open is
         begin
            Is_Open := True;
         end Open;

         function Waiting return Natural
         is (Pass'Count);

         function Order return Order_Array
         is (Seen);
      end Gate;

      procedure Await_Queued (Expected : Natural) is
         Deadline : constant RT.Time := RT.Clock + RT.Seconds (2);
      begin
         loop
            exit when Gate.Waiting = Expected;
            if RT.Clock >= Deadline then
               raise Program_Error with "protected callers did not queue";
            end if;
            delay 0.001;
         end loop;
      end Await_Queued;

      protected Start_Control is
         entry Wait (Positive range 1 .. 3);
         procedure Release (Id : Positive);
      private
         Released : Release_Array := (others => False);
      end Start_Control;

      protected body Start_Control is
         entry Wait(for Id in Positive range 1 .. 3) when Released (Id) is
         begin
            null;
         end Wait;

         procedure Release (Id : Positive) is
         begin
            Released (Id) := True;
         end Release;
      end Start_Control;

      protected Completion is
         procedure Mark_Done;
         entry Wait;
      private
         Count : Natural := 0;
      end Completion;

      protected body Completion is
         procedure Mark_Done is
         begin
            Count := Count + 1;
         end Mark_Done;

         entry Wait when Count = 3 is
         begin
            null;
         end Wait;
      end Completion;

      Exchange_Result : Natural := 0;

      task Native_Client is
         pragma Task_Info (Flyology.Native_Task);
      end Native_Client;

      task Lightweight_One
        with CPU => 1 is
         pragma Task_Info (Flyology.Lightweight_Task);
         entry Exchange (Value : Natural; Result : out Natural);
      end Lightweight_One;

      task Lightweight_Two
        with CPU => 2 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Lightweight_Two;

      task body Native_Client is
      begin
         Start_Control.Wait (1);
         Gate.Pass (1);
         Completion.Mark_Done;
      end Native_Client;

      task body Lightweight_One is
      begin
         Start_Control.Wait (2);
         Gate.Pass (2);
         accept Exchange (Value : Natural; Result : out Natural) do
            Result := Value + 1;
         end Exchange;
         Completion.Mark_Done;
      end Lightweight_One;

      task body Lightweight_Two is
      begin
         Start_Control.Wait (3);
         Gate.Pass (3);
         Lightweight_One.Exchange (41, Exchange_Result);
         Completion.Mark_Done;
      end Lightweight_Two;
   begin
      --  Queue order is established by Entry'Count before the next caller is
      --  released.  This unit explicitly selects FIFO_Queuing, so observing
      --  the same order after the barrier opens is a language-policy check,
      --  not a scheduling-timing assertion.
      for Id in Positive range 1 .. 3 loop
         Start_Control.Release (Id);
         Await_Queued (Id);
      end loop;
      Gate.Open;
      Completion.Wait;
      pragma Assert (Gate.Order = (1, 2, 3));
      pragma Assert (Exchange_Result = 42);
      pragma Assert (Groups.Configured_Pool_Size >= 3);
   end Check_Cross_Group_Conformance;

begin
   Check ("native/native", Native_Native.Run);
   Check ("native/lightweight", Native_Lightweight.Run);
   Check ("lightweight/native", Lightweight_Native.Run);
   Check ("lightweight/lightweight", Lightweight_Lightweight.Run);
   Check_Cross_Group_Conformance;
   Ada.Text_IO.Put_Line
     ("semantic conformance matrix: 16 lane-pair checks and 2 cross-group " & "checks passed");
end Semantic_Conformance_Matrix;
