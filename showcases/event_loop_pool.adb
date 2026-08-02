with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Text_IO;
with GNAT.Sockets;
with Gnatevl;
with Gnatevl.Execution_Groups;
with Gnatevl.IO.Sockets;
with Gnatevl.Observability;
with Showcase_Support;

procedure Event_Loop_Pool is
   use Ada.Real_Time;
   use Ada.Streams;
   use Ada.Text_IO;

   package Groups renames Gnatevl.Execution_Groups;
   package Observe renames Gnatevl.Observability;

   type Socket_Array is
     array (Positive range <>) of GNAT.Sockets.Socket_Type;
   type Socket_Array_Access is access Socket_Array;
   type Group_Count_Array is array (Groups.Shared_Group_Id) of Natural;

   procedure Run (Workers, Rounds : Positive) is
      Servers : constant Socket_Array_Access := new Socket_Array (1 .. Workers);
      Peers   : constant Socket_Array_Access := new Socket_Array (1 .. Workers);
      Byte    : constant Stream_Element_Array := [1 => 42];

      protected Progress is
         procedure Ready (Group : Groups.Group_Id);
         entry Await_Ready;
         procedure Complete (Succeeded : Boolean);
         entry Await_Round;
         function Failures return Natural;
         function Group_Count (Group : Groups.Shared_Group_Id) return Natural;
      private
         Ready_Count      : Natural := 0;
         Completion_Count : Natural := 0;
         Next_Target      : Natural := Workers;
         Failure_Count    : Natural := 0;
         Counts           : Group_Count_Array := (others => 0);
      end Progress;

      protected body Progress is
         procedure Ready (Group : Groups.Group_Id) is
         begin
            Ready_Count := Ready_Count + 1;
            if Group in Groups.Shared_Group_Id then
               Counts (Group) := Counts (Group) + 1;
            else
               Failure_Count := Failure_Count + 1;
            end if;
         end Ready;

         entry Await_Ready when Ready_Count = Workers is
         begin
            null;
         end Await_Ready;

         procedure Complete (Succeeded : Boolean) is
         begin
            Completion_Count := Completion_Count + 1;
            if not Succeeded then
               Failure_Count := Failure_Count + 1;
            end if;
         end Complete;

         entry Await_Round when Completion_Count >= Next_Target is
         begin
            Next_Target := Next_Target + Workers;
         end Await_Round;

         function Failures return Natural is (Failure_Count);

         function Group_Count
           (Group : Groups.Shared_Group_Id) return Natural
         is (Counts (Group));
      end Progress;

      task type Connection (Index : Positive) is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
         pragma Storage_Size (16 * 1_024);
      end Connection;

      task body Connection is
         Incoming : Stream_Element_Array (Byte'Range);
      begin
         Progress.Ready (Groups.Current);
         for Round in 1 .. Rounds loop
            begin
               Gnatevl.IO.Sockets.Receive_Exactly
                 (Servers (Index), Incoming, Timeout => 30.0);
               Progress.Complete (Incoming = Byte);
            exception
               when others =>
                  Progress.Complete (False);
                  for Remaining in Round + 1 .. Rounds loop
                     Progress.Complete (False);
                  end loop;
                  exit;
            end;
         end loop;
      end Connection;

      type Connection_Access is access Connection;
      type Connection_Array is
        array (Positive range <>) of Connection_Access;
      Connections : Connection_Array (1 .. Workers);
      pragma Unreferenced (Connections);

      Started  : Time;
      Elapsed  : Duration;
      Snapshot : Observe.Group_Snapshot;
      Pool     : constant Groups.Loop_Pool_Size := Groups.Configured_Pool_Size;
   begin
      for Index in 1 .. Workers loop
         GNAT.Sockets.Create_Socket_Pair (Servers (Index), Peers (Index));
      end loop;
      for Index in 1 .. Workers loop
         Connections (Index) := new Connection (Index);
      end loop;

      Progress.Await_Ready;
      Started := Clock;
      for Round in 1 .. Rounds loop
         for Index in 1 .. Workers loop
            Gnatevl.IO.Sockets.Send_All
              (Peers (Index), Byte, Timeout => 30.0);
         end loop;
         Progress.Await_Round;
      end loop;
      Elapsed := To_Duration (Clock - Started);

      if Progress.Failures /= 0 then
         raise Program_Error with
           Natural'Image (Progress.Failures) & " socket operations failed";
      end if;

      Put_Line
        ("configured_loops=" & Groups.Loop_Pool_Size'Image (Pool)
         & " policy=round_robin"
         & " workers=" & Workers'Image
         & " rounds=" & Rounds'Image
         & " receive_operations=" & Natural'Image (Workers * Rounds));
      Put_Line
        ("elapsed_seconds="
         & Showcase_Support.Fixed_Image (Long_Float (Elapsed), 6));
      for Group in Groups.Shared_Group_Id range
        0 .. Groups.Shared_Group_Id (Pool - 1)
      loop
         if Observe.Snapshot (Group, Snapshot) then
            Put_Line
              ("  group=" & Groups.Group_Id'Image (Group)
               & " workers=" & Natural'Image (Progress.Group_Count (Group))
               & " dispatches=" & Observe.Counter'Image (Snapshot.Dispatches)
               & " poll_batches=" & Observe.Counter'Image (Snapshot.Poll_Batches)
               & " poll_events=" & Observe.Counter'Image (Snapshot.Poll_Events));
         end if;
      end loop;

      for Index in 1 .. Workers loop
         GNAT.Sockets.Close_Socket (Servers (Index));
         GNAT.Sockets.Close_Socket (Peers (Index));
      end loop;
   end Run;

   procedure Usage is
   begin
      Put_Line ("usage: event_loop_pool WORKERS ROUNDS");
   end Usage;
begin
   if Ada.Command_Line.Argument_Count /= 2 then
      Usage;
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Run
     (Positive'Value (Ada.Command_Line.Argument (1)),
      Positive'Value (Ada.Command_Line.Argument (2)));
exception
   when Constraint_Error =>
      Usage;
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Event_Loop_Pool;
