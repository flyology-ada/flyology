with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Long_Float_Text_IO;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Flyology;
with Flyology.Buffers;
with Flyology.Buffers.Channels;
with Flyology.Execution_Groups;
with Flyology.Execution_Groups.Topology;

procedure Buffer_Pool_Contention is
   package CLI renames Ada.Command_Line;
   package RT renames Ada.Real_Time;
   package Buffers renames Flyology.Buffers;
   package Buffer_Channels renames Flyology.Buffers.Channels;
   package Groups renames Flyology.Execution_Groups;
   package Topology renames Flyology.Execution_Groups.Topology;

   use type Ada.Streams.Stream_Element;
   use type RT.Time;
   use type Groups.Group_Id;

   Queue_Capacity : constant Positive := 64;
   Pair_Capacity  : constant Positive := Queue_Capacity + 2;

   type Pool_Policy is (Shared, Partitioned);
   type Workload_Kind is (Churn, Touch);

   function Policy_Name (Value : Pool_Policy) return String is
     (case Value is
         when Shared      => "shared",
         when Partitioned => "partitioned");

   function Workload_Name (Value : Workload_Kind) return String is
     (case Value is
         when Churn => "churn",
         when Touch => "touch");

   function Parse_Policy (Value : String) return Pool_Policy is
   begin
      if Value = "shared" then
         return Shared;
      elsif Value = "partitioned" then
         return Partitioned;
      end if;
      raise Constraint_Error with
        "POLICY must be shared or partitioned";
   end Parse_Policy;

   function Parse_Workload (Value : String) return Workload_Kind is
   begin
      if Value = "churn" then
         return Churn;
      elsif Value = "touch" then
         return Touch;
      end if;
      raise Constraint_Error with "WORKLOAD must be churn or touch";
   end Parse_Workload;

   protected type Run_Control (Worker_Count : Positive) is
      procedure Ready;
      entry Await_Ready;
      procedure Open;
      entry Start;
      procedure Finished;
      procedure Fail;
      entry Await_Finished (Succeeded : out Boolean);
   private
      Ready_Count    : Natural := 0;
      Finished_Count : Natural := 0;
      Is_Open        : Boolean := False;
      Is_Valid       : Boolean := True;
   end Run_Control;

   protected body Run_Control is
      procedure Ready is
      begin
         Ready_Count := Ready_Count + 1;
      end Ready;

      entry Await_Ready when Ready_Count = Worker_Count is
      begin
         null;
      end Await_Ready;

      procedure Open is
      begin
         Is_Open := True;
      end Open;

      entry Start when Is_Open is
      begin
         null;
      end Start;

      procedure Finished is
      begin
         Finished_Count := Finished_Count + 1;
      end Finished;

      procedure Fail is
      begin
         Is_Valid := False;
      end Fail;

      entry Await_Finished (Succeeded : out Boolean)
        when Finished_Count = Worker_Count
      is
      begin
         Succeeded := Is_Valid;
      end Await_Finished;
   end Run_Control;

   type Pool_Access is access all Buffers.Pool;
   type Channel_Access is access all Buffer_Channels.Channel;
   type Run_Control_Access is access all Run_Control;

   task type Producer_Task
     (Assigned_Group : Topology.Shard_Id;
      Storage      : not null Pool_Access;
      Queue        : not null Channel_Access;
      Control      : not null Run_Control_Access;
      Iterations   : Positive;
      Workload     : Workload_Kind)
   is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Producer_Task;

   task body Producer_Task is
      Value : Buffers.Unique_Buffer (Storage);
      Ready_Reported : Boolean := False;

      procedure Touch_Buffer
        (Data   : in out Ada.Streams.Stream_Element_Array;
         Length : in out Natural) is
      begin
         Data (Data'First) := 42;
         Length := 1;
      end Touch_Buffer;
   begin
      Topology.Cross_To_Shard (Assigned_Group);
      if Groups.Current /= Assigned_Group then
         raise Program_Error with "producer entered the wrong group";
      end if;
      Control.Ready;
      Ready_Reported := True;
      Control.Start;
      for Index in 1 .. Iterations loop
         Buffers.Acquire (Value);
         if Workload = Touch then
            Buffers.With_Writable_Data (Value, Touch_Buffer'Access);
         end if;
         Queue.Send_Move (Value);
      end loop;
      Queue.Close;
      Control.Finished;
   exception
      when others =>
         Control.Fail;
         if not Ready_Reported then
            Control.Ready;
         end if;
         Queue.Close;
         Control.Finished;
   end Producer_Task;

   task type Consumer_Task
     (Assigned_Group : Topology.Shard_Id;
      Storage      : not null Pool_Access;
      Queue        : not null Channel_Access;
      Control      : not null Run_Control_Access;
      Iterations   : Positive;
      Workload     : Workload_Kind)
   is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Consumer_Task;

   task body Consumer_Task is
      Value : Buffers.Unique_Buffer (Storage);
      Count : Natural := 0;
      Ready_Reported : Boolean := False;

      procedure Check_Buffer
        (Data : Ada.Streams.Stream_Element_Array) is
      begin
         if Data'Length /= 1 or else Data (Data'First) /= 42 then
            raise Program_Error with "buffer touch did not survive handoff";
         end if;
      end Check_Buffer;
   begin
      Topology.Cross_To_Shard (Assigned_Group);
      if Groups.Current /= Assigned_Group then
         raise Program_Error with "consumer entered the wrong group";
      end if;
      Control.Ready;
      Ready_Reported := True;
      Control.Start;
      loop
         begin
            Queue.Receive_Move (Value);
         exception
            when Buffer_Channels.Channel_Closed => exit;
         end;
         if Workload = Touch then
            Buffers.With_Readable_Data (Value, Check_Buffer'Access);
         end if;
         Buffers.Release (Value);
         Count := Count + 1;
      end loop;
      if Count /= Iterations then
         Control.Fail;
      end if;
      Control.Finished;
   exception
      when others =>
         Control.Fail;
         if not Ready_Reported then
            Control.Ready;
         end if;
         Queue.Close;
         Control.Finished;
   end Consumer_Task;

   type Producer_Access is access Producer_Task;
   type Consumer_Access is access Consumer_Task;

   procedure Free_Pool is new Ada.Unchecked_Deallocation
     (Buffers.Pool, Pool_Access);
   procedure Free_Channel is new Ada.Unchecked_Deallocation
     (Buffer_Channels.Channel, Channel_Access);
   procedure Free_Control is new Ada.Unchecked_Deallocation
     (Run_Control, Run_Control_Access);
   procedure Free_Producer is new Ada.Unchecked_Deallocation
     (Producer_Task, Producer_Access);
   procedure Free_Consumer is new Ada.Unchecked_Deallocation
     (Consumer_Task, Consumer_Access);

   procedure Report
     (Policy      : Pool_Policy;
      Workload    : Workload_Kind;
      Group_Count : Positive;
      Block_Size  : Positive;
      Iterations  : Positive;
      Elapsed     : Duration)
   is
      Total : constant Long_Long_Integer :=
        Long_Long_Integer (Group_Count) * Long_Long_Integer (Iterations);
      Rate  : constant Long_Float :=
        Long_Float (Total) / Long_Float (Elapsed);
   begin
      Ada.Text_IO.Put
        (Policy_Name (Policy) & "," & Workload_Name (Workload) & ","
         & (if Group_Count = 1 then "shared-same" else "shared-ring")
         & ", 0," & Natural'Image (Group_Count - 1) & ","
         & Group_Count'Image & "," & Block_Size'Image & ","
         & Iterations'Image & "," & Total'Image & ",");
      Ada.Long_Float_Text_IO.Put
        (Long_Float (Elapsed), Fore => 1, Aft => 6, Exp => 0);
      Ada.Text_IO.Put (",");
      Ada.Long_Float_Text_IO.Put (Rate, Fore => 1, Aft => 2, Exp => 0);
      Ada.Text_IO.New_Line;
   end Report;

   procedure Run
     (Policy      : Pool_Policy;
      Workload    : Workload_Kind;
      Group_Count : Positive;
      Iterations  : Positive)
   is
      Block_Size : constant Positive :=
        (if Workload = Churn then 64 else 4_096);
      Pool_Count : constant Positive :=
        (if Policy = Shared then 1 else Group_Count);
      Pool_Capacity : constant Positive :=
        (if Policy = Shared
         then Pair_Capacity * Group_Count
         else Pair_Capacity);
      type Pool_Array is array (Positive range <>) of Pool_Access;
      type Channel_Array is array (Positive range <>) of Channel_Access;
      type Producer_Array is array (Positive range <>) of Producer_Access;
      type Consumer_Array is array (Positive range <>) of Consumer_Access;
      Pools     : Pool_Array (1 .. Pool_Count) := (others => null);
      Queues    : Channel_Array (1 .. Group_Count) := (others => null);
      Producers : Producer_Array (1 .. Group_Count) := (others => null);
      Consumers : Consumer_Array (1 .. Group_Count) := (others => null);
      Control   : Run_Control_Access :=
        new Run_Control (Worker_Count => 2 * Group_Count);
      Started, Stopped : RT.Time;
      Succeeded : Boolean;
   begin
      for Index in Pools'Range loop
         Pools (Index) := new Buffers.Pool
           (Block_Size => Block_Size, Capacity => Pool_Capacity);
      end loop;
      for Index in Queues'Range loop
         declare
            Pool_Index : constant Positive :=
              (if Policy = Shared then 1 else Index);
         begin
            Queues (Index) := new Buffer_Channels.Channel
              (Pools (Pool_Index), Queue_Capacity);
            Producers (Index) := new Producer_Task
              (Assigned_Group => Topology.Shard_Id (Index - 1),
               Storage    => Pools (Pool_Index),
               Queue      => Queues (Index),
               Control    => Control,
               Iterations => Iterations,
               Workload   => Workload);
            Consumers (Index) := new Consumer_Task
              (Assigned_Group => Topology.Shard_Id (Index mod Group_Count),
               Storage    => Pools (Pool_Index),
               Queue      => Queues (Index),
               Control    => Control,
               Iterations => Iterations,
               Workload   => Workload);
         end;
      end loop;

      Control.Await_Ready;
      Started := RT.Clock;
      Control.Open;
      Control.Await_Finished (Succeeded);
      Stopped := RT.Clock;

      for Index in Producers'Range loop
         while not Producers (Index).all'Terminated
           or else not Consumers (Index).all'Terminated
         loop
            delay 0.0;
         end loop;
         Free_Producer (Producers (Index));
         Free_Consumer (Consumers (Index));
         Free_Channel (Queues (Index));
      end loop;
      for Index in reverse Pools'Range loop
         Free_Pool (Pools (Index));
      end loop;
      Free_Control (Control);

      if not Succeeded then
         raise Program_Error with "buffer pool contention benchmark failed";
      end if;
      Report
        (Policy, Workload, Group_Count, Block_Size, Iterations,
         RT.To_Duration (Stopped - Started));
   end Run;

begin
   if CLI.Argument_Count /= 4 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "usage: buffer_pool_contention POLICY GROUPS ITERATIONS WORKLOAD");
      CLI.Set_Exit_Status (CLI.Failure);
      return;
   end if;

   declare
      Policy      : constant Pool_Policy := Parse_Policy (CLI.Argument (1));
      Group_Count : constant Positive := Positive'Value (CLI.Argument (2));
      Iterations  : constant Positive := Positive'Value (CLI.Argument (3));
      Workload    : constant Workload_Kind :=
        Parse_Workload (CLI.Argument (4));
   begin
      if Group_Count > Positive (Groups.Configured_Pool_Size) then
         raise Constraint_Error with
           "GROUPS exceeds the configured execution-group pool";
      end if;
      Run (Policy, Workload, Group_Count, Iterations);
   end;
exception
   when Error : others =>
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "buffer_pool_contention: "
         & Ada.Exceptions.Exception_Message (Error));
      CLI.Set_Exit_Status (CLI.Failure);
end Buffer_Pool_Contention;
