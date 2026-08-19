--  Runs one sharded counter service and reports what each way of reaching a
--  shard costs on this host. Absolute values move with machine load; the
--  ratios between the rows are the durable result.
with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Text_IO;
with Flyology;
with Flyology.Execution_Groups;
with Flyology.Execution_Groups.Topology;
with Flyology.Sharding;
with Flyology.Sharding.Services;
with Interfaces;

procedure Sharded_Service is
   use Ada.Text_IO;
   use Ada.Real_Time;

   package Groups renames Flyology.Execution_Groups;
   package Topology renames Flyology.Execution_Groups.Topology;
   package Shards renames Flyology.Sharding;

   use type Groups.Group_Id;
   use type Shards.Service_Outcome;

   Width : constant Shards.Shard_Count :=
     (if Ada.Command_Line.Argument_Count = 0
      then 4
      else Shards.Shard_Count'Value (Ada.Command_Line.Argument (1)));
   Calls : constant Positive :=
     (if Ada.Command_Line.Argument_Count < 2
      then 5_000
      else Positive'Value (Ada.Command_Line.Argument (2)));

   Broadcasts      : constant Positive := 100;
   Slow_Broadcasts : constant Positive := 20;
   Shard_Nap       : constant Duration := 0.010;

   package Kit is

      --  State owned by exactly one shard.
      type Counter is limited record
         Shard : Shards.Shard_Id := 0;
         Total : Natural := 0;
      end record;

      function Make (Shard : Shards.Shard_Id) return Counter;

      package Counters is new Shards.Services
        (Service_Type => Counter,
         Create       => Make);

      --  One unit of work applied to the owning shard's counter.
      type Bump is limited new Counters.Operation with record
         Amount   : Natural := 1;
         Nap      : Duration := 0.0;
         Total    : Natural := 0;
         Visited  : Natural := 0;
         Observed : Groups.Group_Id := Groups.Group_Id'Last;
      end record;
      overriding procedure Execute
        (Op       : in out Bump;
         Instance : in out Counter;
         Shard    : Shards.Shard_Id);

      procedure Read_Total
        (Instance : in out Counter;
         Shard    : Shards.Shard_Id;
         Value    : out Natural);
      procedure Add_Total
        (Into  : in out Natural;
         Shard : Shards.Shard_Id;
         Value : Natural);

      package Grand_Total is new Counters.Map_Reduce
        (Mapped      => Natural,
         Accumulator => Natural,
         Map         => Read_Total,
         Reduce      => Add_Total);

   end Kit;

   package body Kit is

      function Make (Shard : Shards.Shard_Id) return Counter is
        ((Shard => Shard, Total => 0));

      overriding procedure Execute
        (Op       : in out Bump;
         Instance : in out Counter;
         Shard    : Shards.Shard_Id) is
      begin
         Instance.Total := Instance.Total + Op.Amount;
         Op.Total := Instance.Total;
         Op.Visited := Op.Visited + 1;
         Op.Observed := Groups.Current;
         if Op.Nap > 0.0 then
            delay Op.Nap;
         end if;
         pragma Assert (Groups.Current = Groups.Group_Id (Shard));
      end Execute;

      procedure Read_Total
        (Instance : in out Counter;
         Shard    : Shards.Shard_Id;
         Value    : out Natural)
      is
         pragma Unreferenced (Shard);
      begin
         Value := Instance.Total;
      end Read_Total;

      procedure Add_Total
        (Into  : in out Natural;
         Shard : Shards.Shard_Id;
         Value : Natural)
      is
         pragma Unreferenced (Shard);
      begin
         Into := Into + Value;
      end Add_Total;

   end Kit;

   use Kit;

   Table  : aliased Counters.Service;
   Result : Shards.Service_Result;

   task type Owner is
      pragma Task_Info (Flyology.Native_Task);
   end Owner;

   task body Owner is
   begin
      Counters.Serve (Table, Width, Result);
   end Owner;

   --  One helper per shard, used only to show what a concurrent broadcast
   --  would cost against the sequential Invoke_On_All the library provides.
   Fan_Out_Nap : Duration := 0.0;

   task type Fan_Out (Shard : Shards.Shard_Id) is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Fan_Out;

   task body Fan_Out is
      Op : Bump;
   begin
      Op.Amount := 0;
      Op.Nap := Fan_Out_Nap;
      Counters.Invoke_On (Table, Shard, Op);
   end Fan_Out;

   type Fan_Out_Access is access Fan_Out;
   type Fan_Out_Array is array (Shards.Shard_Id range <>) of Fan_Out_Access;

   procedure Fan_Out_All (Nap : Duration) is
      Workers : Fan_Out_Array
        (0 .. Shards.Shard_Id (Natural (Width) - 1));
   begin
      Fan_Out_Nap := Nap;
      for Shard in Workers'Range loop
         Workers (Shard) := new Fan_Out (Shard);
      end loop;
      for Shard in Workers'Range loop
         while not Workers (Shard)'Terminated loop
            delay 0.000_5;
         end loop;
      end loop;
   end Fan_Out_All;

   procedure Report_Nanoseconds
     (Label : String;
      Total : Duration;
      Count : Positive) is
   begin
      Put_Line
        ("  " & Label & ":"
         & Long_Float'Image
             (Long_Float (Total) * 1.0E9 / Long_Float (Count))
         & " ns/op");
   end Report_Nanoseconds;

   procedure Report_Microseconds
     (Label : String;
      Total : Duration;
      Count : Positive) is
   begin
      Put_Line
        ("  " & Label & ":"
         & Long_Float'Image
             (Long_Float (Total) * 1.0E6 / Long_Float (Count))
         & " us/broadcast");
   end Report_Microseconds;

   Local_Cost   : Duration := 0.0;
   Held_Cost    : Duration := 0.0;
   Own_Cost     : Duration := 0.0;
   Remote_Cost  : Duration := 0.0;
   Native_Cost  : Duration := 0.0;

begin
   if Ada.Command_Line.Argument_Count > 2 then
      raise Constraint_Error with "usage: sharded_service [SHARDS] [CALLS]";
   end if;

   declare
      Driver : Owner;
      pragma Unreferenced (Driver);
   begin
      if not Counters.Await_Ready (Table, 30.0) then
         raise Program_Error with "sharded service did not start";
      end if;

      Put_Line
        ("shards =" & Shards.Shard_Count'Image (Width)
         & "  calls_per_row =" & Positive'Image (Calls));
      New_Line;

      --  A lightweight task that owns a shard measures every single-shard
      --  path from that shard.
      declare
         task Measurer is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Measurer;

         task body Measurer is
            Start : Time;
         begin
            Topology.Cross_To_Shard (0);

            Start := Clock;
            for Round in 1 .. Calls loop
               declare
                  Ref : constant Counters.Local_Reference :=
                    Counters.Borrow_Local (Table);
               begin
                  Counters.Instance (Ref).Total :=
                    Counters.Instance (Ref).Total + 1;
               end;
            end loop;
            Local_Cost := To_Duration (Clock - Start);

            Start := Clock;
            declare
               Ref : constant Counters.Local_Reference :=
                 Counters.Borrow_Local (Table);
            begin
               for Round in 1 .. Calls loop
                  Counters.Instance (Ref).Total :=
                    Counters.Instance (Ref).Total + 1;
               end loop;
            end;
            Held_Cost := To_Duration (Clock - Start);

            Start := Clock;
            for Round in 1 .. Calls loop
               declare
                  Op : Bump;
               begin
                  Counters.Invoke_On (Table, 0, Op);
               end;
            end loop;
            Own_Cost := To_Duration (Clock - Start);

            Start := Clock;
            for Round in 1 .. Calls loop
               declare
                  Op : Bump;
               begin
                  Counters.Invoke_On
                    (Table, Shards.Shard_Id (Natural (Width) - 1), Op);
               end;
            end loop;
            Remote_Cost := To_Duration (Clock - Start);
         end Measurer;
      begin
         null;
      end;

      declare
         Start : constant Time := Clock;
      begin
         for Round in 1 .. Calls loop
            declare
               Op : Bump;
            begin
               Counters.Invoke_On
                 (Table, Shards.Shard_Id (Natural (Width) - 1), Op);
            end;
         end loop;
         Native_Cost := To_Duration (Clock - Start);
      end;

      Put_Line ("reaching one shard");
      Report_Nanoseconds
        ("owner  Borrow_Local per mutation     ", Local_Cost, Calls);
      Report_Nanoseconds
        ("owner  one borrow, then mutate       ", Held_Cost, Calls);
      Report_Nanoseconds
        ("owner  Invoke_On, same group         ", Own_Cost, Calls);
      Report_Nanoseconds
        ("owner  Invoke_On, another group      ", Remote_Cost, Calls);
      Report_Nanoseconds
        ("native Invoke_On, another group      ", Native_Cost, Calls);
      New_Line;

      --  Broadcast: the library runs shards one at a time and reuses one
      --  operation object. A concurrent fan-out needs one task per shard.
      declare
         Start : Time := Clock;
      begin
         for Round in 1 .. Broadcasts loop
            declare
               Op : Bump;
            begin
               Op.Amount := 0;
               Counters.Invoke_On_All (Table, Op);
            end;
         end loop;
         Put_Line ("broadcast, operation returns immediately");
         Report_Microseconds
           ("sequential Invoke_On_All             ",
            To_Duration (Clock - Start), Broadcasts);

         Start := Clock;
         for Round in 1 .. Broadcasts loop
            Fan_Out_All (0.0);
         end loop;
         Report_Microseconds
           ("one helper task per shard            ",
            To_Duration (Clock - Start), Broadcasts);
         New_Line;

         Start := Clock;
         for Round in 1 .. Slow_Broadcasts loop
            declare
               Op : Bump;
            begin
               Op.Amount := 0;
               Op.Nap := Shard_Nap;
               Counters.Invoke_On_All (Table, Op);
            end;
         end loop;
         Put_Line
           ("broadcast, operation suspends"
            & Duration'Image (Shard_Nap * 1_000.0) & " ms on its shard");
         Report_Microseconds
           ("sequential Invoke_On_All             ",
            To_Duration (Clock - Start), Slow_Broadcasts);

         Start := Clock;
         for Round in 1 .. Slow_Broadcasts loop
            Fan_Out_All (Shard_Nap);
         end loop;
         Report_Microseconds
           ("one helper task per shard            ",
            To_Duration (Clock - Start), Slow_Broadcasts);
      end;

      New_Line;
      declare
         Total : Natural := 0;
      begin
         Grand_Total.Run (Table, Total);
         Put_Line
           ("map-reduce over every shard: total ="
            & Natural'Image (Total));
         for Key in Interfaces.Unsigned_64 range 0 .. 3 loop
            Put_Line
              ("  key" & Interfaces.Unsigned_64'Image (Key)
               & " routes to shard"
               & Shards.Shard_Id'Image (Counters.Shard_For (Table, Key)));
         end loop;
      end;

      Counters.Request_Shutdown (Table);
   exception
      when others =>
         Counters.Request_Shutdown (Table);
         raise;
   end;

   if Result.Outcome /= Shards.Shutdown_Completed then
      raise Program_Error with "sharded service did not shut down cleanly";
   end if;
exception
   when Constraint_Error =>
      Put_Line ("usage: sharded_service [SHARDS] [CALLS]");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Sharded_Service;
