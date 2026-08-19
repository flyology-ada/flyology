with Ada.Exceptions;
with Ada.Real_Time;
with Flyology;
with Flyology.Execution_Groups;
with Flyology.Execution_Groups.Topology;
with Flyology.Sharding;
with Flyology.Sharding.Services;
with Flyology.Task_Results;
with Interfaces;

procedure Sharding_Smoke is
   package Groups renames Flyology.Execution_Groups;
   package Topology renames Flyology.Execution_Groups.Topology;
   package Shards renames Flyology.Sharding;

   use type Groups.Group_Id;
   use type Ada.Real_Time.Time;
   use type Ada.Real_Time.Time_Span;
   use type Ada.Exceptions.Exception_Id;
   use type Shards.Service_Outcome;

   Shard_Total : constant Shards.Shard_Count := 4;
   subtype Test_Shard is Shards.Shard_Id range
     0 .. Shards.Shard_Id (Shard_Total - 1);

   Probe_Error : exception;

   --  Shared observations written from several shards in parallel.
   protected Audit is
      procedure Note_Teardown;
      procedure Note_Started;
      entry Await_Started;
      procedure Reset;
      function Teardowns return Natural;
   private
      Torn_Down : Natural := 0;
      Started   : Boolean := False;
   end Audit;

   protected body Audit is
      procedure Note_Teardown is
      begin
         Torn_Down := Torn_Down + 1;
      end Note_Teardown;

      procedure Note_Started is
      begin
         Started := True;
      end Note_Started;

      entry Await_Started when Started is
      begin
         null;
      end Await_Started;

      procedure Reset is
      begin
         Started := False;
      end Reset;

      function Teardowns return Natural is (Torn_Down);
   end Audit;

   --  --------------------------------------------------------------
   --  Service instance and operations
   --  --------------------------------------------------------------

   package Kit is

      type Counter is limited record
         Shard : Shards.Shard_Id := 0;
         Total : Natural := 0;
         Calls : Natural := 0;
      end record;

      function Make (Shard : Shards.Shard_Id) return Counter;
      procedure Release (Instance : in out Counter);

      package Counters is new Shards.Services
        (Service_Type => Counter,
         Create       => Make,
         Shut_Down    => Release);

      package Wide_Counters is new Shards.Services
        (Service_Type => Counter,
         Create       => Make,
         Shut_Down    => Release,
         Concurrency  => 3);

      --  Add Amount and report what the shard observed.
      type Add_Op is limited new Counters.Operation with record
         Amount    : Natural := 0;
         Total     : Natural := 0;
         Visited   : Natural := 0;
         Observed  : Groups.Group_Id := Groups.Group_Id'Last;
         Announced : Shards.Shard_Id := 0;
         Pinned    : Boolean := False;
      end record;
      overriding procedure Execute
        (Op       : in out Add_Op;
         Instance : in out Counter;
         Shard    : Shards.Shard_Id);

      --  Fail inside the shard.
      type Raise_Op is limited new Counters.Operation with null record;
      overriding procedure Execute
        (Op       : in out Raise_Op;
         Instance : in out Counter;
         Shard    : Shards.Shard_Id);

      --  Submit work back to the shard that is already running it.
      Reentrant_Target : access Counters.Service := null;
      type Reentrant_Op is limited new Counters.Operation with record
         Rejected : Boolean := False;
      end record;
      overriding procedure Execute
        (Op       : in out Reentrant_Op;
         Instance : in out Counter;
         Shard    : Shards.Shard_Id);

      --  Suspend on a remote shard so the caller's own loop can be
      --  observed while the caller waits.
      type Nap_Op is limited new Counters.Operation with record
         Nap      : Duration := 0.10;
         Observed : Groups.Group_Id := Groups.Group_Id'Last;
      end record;
      overriding procedure Execute
        (Op       : in out Nap_Op;
         Instance : in out Counter;
         Shard    : Shards.Shard_Id);

      --  Suspend on the shard so a second caller can be timed.
      type Slow_Op is limited new Wide_Counters.Operation with record
         Nap : Duration := 0.20;
      end record;
      overriding procedure Execute
        (Op       : in out Slow_Op;
         Instance : in out Counter;
         Shard    : Shards.Shard_Id);

      type Touch_Op is limited new Wide_Counters.Operation with null record;
      overriding procedure Execute
        (Op       : in out Touch_Op;
         Instance : in out Counter;
         Shard    : Shards.Shard_Id);

      procedure Sum_Total
        (Instance : in out Counter;
         Shard    : Shards.Shard_Id;
         Value    : out Natural);
      procedure Add_Into
        (Into  : in out Natural;
         Shard : Shards.Shard_Id;
         Value : Natural);

      package Totals is new Counters.Map_Reduce
        (Mapped      => Natural,
         Accumulator => Natural,
         Map         => Sum_Total,
         Reduce      => Add_Into);

   end Kit;

   package body Kit is

      function Make (Shard : Shards.Shard_Id) return Counter is
      begin
         if Groups.Current /= Groups.Group_Id (Shard) then
            raise Program_Error
              with "shard instance was not built on its own group";
         end if;
         return (Shard => Shard, Total => 0, Calls => 0);
      end Make;

      procedure Release (Instance : in out Counter) is
      begin
         Instance.Calls := 0;
         Audit.Note_Teardown;
      end Release;

      overriding procedure Execute
        (Op       : in out Add_Op;
         Instance : in out Counter;
         Shard    : Shards.Shard_Id) is
      begin
         Instance.Total := Instance.Total + Op.Amount;
         Instance.Calls := Instance.Calls + 1;
         Op.Total := Instance.Total;
         Op.Visited := Op.Visited + 1;
         Op.Observed := Groups.Current;
         Op.Announced := Shard;
         Op.Pinned := Groups.Is_Thread_Pinned;
      end Execute;

      overriding procedure Execute
        (Op       : in out Raise_Op;
         Instance : in out Counter;
         Shard    : Shards.Shard_Id)
      is
         pragma Unreferenced (Op, Shard);
      begin
         Instance.Calls := Instance.Calls + 1;
         raise Probe_Error with "shard operation failed";
      end Execute;

      overriding procedure Execute
        (Op       : in out Reentrant_Op;
         Instance : in out Counter;
         Shard    : Shards.Shard_Id)
      is
         pragma Unreferenced (Instance);
         Inner : Add_Op;
      begin
         Inner.Amount := 1;
         Counters.Invoke_On (Reentrant_Target.all, Shard, Inner);
      exception
         when Shards.Reentrant_Operation =>
            Op.Rejected := True;
      end Execute;

      overriding procedure Execute
        (Op       : in out Nap_Op;
         Instance : in out Counter;
         Shard    : Shards.Shard_Id)
      is
         pragma Unreferenced (Instance, Shard);
      begin
         Op.Observed := Groups.Current;
         delay Op.Nap;
      end Execute;

      overriding procedure Execute
        (Op       : in out Slow_Op;
         Instance : in out Counter;
         Shard    : Shards.Shard_Id)
      is
         pragma Unreferenced (Instance, Shard);
      begin
         Audit.Note_Started;
         delay Op.Nap;
      end Execute;

      overriding procedure Execute
        (Op       : in out Touch_Op;
         Instance : in out Counter;
         Shard    : Shards.Shard_Id)
      is
         pragma Unreferenced (Op, Shard);
      begin
         Instance.Calls := Instance.Calls + 1;
      end Execute;

      procedure Sum_Total
        (Instance : in out Counter;
         Shard    : Shards.Shard_Id;
         Value    : out Natural)
      is
         pragma Unreferenced (Shard);
      begin
         Value := Instance.Total;
      end Sum_Total;

      procedure Add_Into
        (Into  : in out Natural;
         Shard : Shards.Shard_Id;
         Value : Natural)
      is
         pragma Unreferenced (Shard);
      begin
         Into := Into + Value;
      end Add_Into;

   end Kit;

   use Kit;

   --  --------------------------------------------------------------
   --  Serve drivers
   --  --------------------------------------------------------------

   Main_Result : Shards.Service_Result;
   Wide_Result : Shards.Service_Result;

   task type Main_Server (Target : access Counters.Service) is
      pragma Task_Info (Flyology.Native_Task);
   end Main_Server;

   task body Main_Server is
   begin
      Counters.Serve (Target.all, Shard_Total, Main_Result);
   end Main_Server;

   task type Wide_Server (Target : access Wide_Counters.Service) is
      pragma Task_Info (Flyology.Native_Task);
   end Wide_Server;

   task body Wide_Server is
   begin
      Wide_Counters.Serve (Target.all, Shard_Total, Wide_Result);
   end Wide_Server;

   --  --------------------------------------------------------------
   --  Phase 1: a running service with one lane per shard
   --  --------------------------------------------------------------

   procedure Check_Running_Service is
      Table : aliased Counters.Service;
   begin
      Reentrant_Target := Table'Unchecked_Access;
      declare
         Server : Main_Server (Table'Access);
         pragma Unreferenced (Server);

         Native_Passed      : Boolean := False;
         Lightweight_Passed : Boolean := False;

         --  Observations made by the lightweight caller.
         Ticks         : Natural := 0;
         pragma Volatile (Ticks);
         Caller_Done   : Boolean := False;
         pragma Volatile (Caller_Done);
         Borrowed      : Integer := -1;
         Borrow_Pinned : Boolean := False;
         Own_Shard_Ok  : Boolean := False;
         Remote_Ok     : Boolean := False;
         Home_Ok       : Boolean := False;
         Others_Ok     : Boolean := False;
         Nap_Ok        : Boolean := False;
         Caller_Failed : Boolean := False;
      begin
         if not Counters.Await_Ready (Table, 30.0) then
            raise Program_Error with "sharded service did not become ready";
         end if;
         if Counters.Shards (Table) /= Natural (Shard_Total) then
            raise Program_Error with "sharded service reported wrong width";
         end if;
         if not Counters.Running (Table) then
            raise Program_Error with "ready service is not running";
         end if;

         --  Routing uses the service's own width.
         for Key in Interfaces.Unsigned_64 range 0 .. 15 loop
            if Counters.Shard_For (Table, Key) /=
              Topology.Shard_For_Hash (Key, Shard_Total)
            then
               raise Program_Error with "sharded routing disagrees";
            end if;
         end loop;

         --  A native caller reaches a shard and sees its outputs.
         declare
            Op : Add_Op;
         begin
            Op.Amount := 5;
            Counters.Invoke_On (Table, 2, Op);
            Native_Passed :=
              Op.Observed = 2
              and then Op.Announced = 2
              and then Op.Total = 5
              and then Op.Pinned;
         end;
         if not Native_Passed then
            raise Program_Error
              with "native caller did not reach the owning shard";
         end if;

         --  An exception reaches the caller and the shard keeps serving.
         declare
            Failing : Raise_Op;
            Seen    : Boolean := False;
         begin
            begin
               Counters.Invoke_On (Table, 1, Failing);
            exception
               when E : others =>
                  Seen :=
                    Ada.Exceptions.Exception_Identity (E) =
                      Probe_Error'Identity
                    and then Ada.Exceptions.Exception_Message (E) =
                      "shard operation failed";
            end;
            if not Seen then
               raise Program_Error
                 with "shard exception did not reach the caller intact";
            end if;
         end;
         declare
            Op : Add_Op;
         begin
            Op.Amount := 7;
            Counters.Invoke_On (Table, 1, Op);
            if Op.Total /= 7 or else Op.Observed /= 1 then
               raise Program_Error
                 with "shard did not survive a failed operation";
            end if;
         end;

         --  A shard operation cannot submit work to its own shard.
         declare
            Op : Reentrant_Op;
         begin
            Counters.Invoke_On (Table, 3, Op);
            if not Op.Rejected then
               raise Program_Error
                 with "reentrant shard submission was not rejected";
            end if;
         end;

         --  A native caller owns no shard.
         declare
            Rejected : Boolean := False;
         begin
            begin
               declare
                  Ref : constant Counters.Local_Reference :=
                    Counters.Borrow_Local (Table);
               begin
                  Rejected := Counters.Owner (Ref) not in Test_Shard;
               end;
            exception
               when Shards.Not_Owner =>
                  Rejected := True;
            end;
            if not Rejected then
               raise Program_Error
                 with "a native caller borrowed a shard instance";
            end if;
         end;

         --  Broadcast reaches every shard exactly once.
         declare
            Op : Add_Op;
         begin
            Op.Amount := 1;
            Counters.Invoke_On_All (Table, Op);
            if Op.Visited /= Natural (Shard_Total) then
               raise Program_Error
                 with "broadcast did not reach every shard";
            end if;
         end;

         --  Fold across shards. Shard 1 holds 7 + 1, shard 2 holds 5 + 1,
         --  and the other two hold 1 each.
         declare
            Sum : Natural := 0;
         begin
            Totals.Run (Table, Sum);
            if Sum /= 7 + 1 + 5 + 1 + 1 + 1 then
               raise Program_Error with "map-reduce total is wrong";
            end if;
         end;

         --  A lightweight caller keeps its loop available while it waits,
         --  borrows only its own shard, and returns where it started.
         declare
            task Caller is
               pragma Task_Info (Flyology.Lightweight_Task);
            end Caller;

            task Spinner is
               pragma Task_Info (Flyology.Lightweight_Task);
            end Spinner;

            task body Caller is
               Own    : Add_Op;
               Remote : Add_Op;
               Spread : Add_Op;
               Nap    : Nap_Op;
            begin
               Topology.Cross_To_Shard (3);
               declare
                  Ref : constant Counters.Local_Reference :=
                    Counters.Borrow_Local (Table);
               begin
                  Borrow_Pinned := Groups.Is_Thread_Pinned;
                  Borrowed := Integer (Counters.Instance (Ref).Shard);
                  Own_Shard_Ok := Counters.Owner (Ref) = 3;
               end;

               Own.Amount := 2;
               Counters.Invoke_On (Table, 3, Own);
               Own_Shard_Ok := Own_Shard_Ok and then Own.Observed = 3;

               Remote.Amount := 4;
               Counters.Invoke_On (Table, 0, Remote);
               Remote_Ok := Remote.Observed = 0;
               Home_Ok := Groups.Current = 3;

               Spread.Amount := 0;
               Counters.Invoke_On_Others (Table, Spread);
               Others_Ok := Spread.Visited = Natural (Shard_Total) - 1;

               --  Suspend inside shard 0 long enough for the spinner that
               --  shares this caller's loop to make observable progress.
               Nap.Nap := 0.10;
               Counters.Invoke_On (Table, 0, Nap);
               Nap_Ok := Nap.Observed = 0 and then Groups.Current = 3;

               Caller_Done := True;
            exception
               when others =>
                  Caller_Failed := True;
                  Caller_Done := True;
            end Caller;

            task body Spinner is
            begin
               Topology.Cross_To_Shard (3);
               while not Caller_Done loop
                  Ticks := Ticks + 1;
                  delay 0.0;
               end loop;
            end Spinner;
         begin
            null;
         end;

         Lightweight_Passed :=
           not Caller_Failed
           and then Borrowed = 3
           and then Borrow_Pinned
           and then Own_Shard_Ok
           and then Remote_Ok
           and then Home_Ok
           and then Others_Ok
           and then Nap_Ok
           and then Ticks > 1_000;

         if not Lightweight_Passed then
            raise Program_Error with "lightweight caller semantics failed";
         end if;

         Counters.Request_Shutdown (Table);
      exception
         --  A failed check must still stop the service, or the enclosing
         --  block would wait on Serve forever.
         when others =>
            Counters.Request_Shutdown (Table);
            raise;
      end;

      if Main_Result.Outcome /= Shards.Shutdown_Completed then
         raise Program_Error with "sharded service did not shut down cleanly";
      end if;
      if Audit.Teardowns /= Natural (Shard_Total) then
         raise Program_Error with "shard teardown did not run on every shard";
      end if;
      if Counters.Running (Table) then
         raise Program_Error with "stopped service still reports running";
      end if;

      declare
         Op       : Add_Op;
         Rejected : Boolean := False;
      begin
         Op.Amount := 1;
         begin
            Counters.Invoke_On (Table, 0, Op);
         exception
            when Shards.Not_Running =>
               Rejected := True;
         end;
         if not Rejected then
            raise Program_Error
              with "stopped service still admitted an operation";
         end if;
      end;
   end Check_Running_Service;

   --  --------------------------------------------------------------
   --  Phase 2: per-shard concurrency
   --  --------------------------------------------------------------

   procedure Check_Concurrency is
      Table   : aliased Wide_Counters.Service;
      Elapsed : Duration := 0.0;
   begin
      Audit.Reset;
      declare
         Server : Wide_Server (Table'Access);
         pragma Unreferenced (Server);

         task Blocker is
            pragma Task_Info (Flyology.Native_Task);
         end Blocker;

         task body Blocker is
            Slow : Slow_Op;
         begin
            if Wide_Counters.Await_Ready (Table, 30.0) then
               Slow.Nap := 0.20;
               Wide_Counters.Invoke_On (Table, 0, Slow);
            end if;
         end Blocker;
      begin
         if not Wide_Counters.Await_Ready (Table, 30.0) then
            raise Program_Error
              with "concurrent sharded service did not become ready";
         end if;
         select
            Audit.Await_Started;
         or
            delay 10.0;
            Wide_Counters.Request_Shutdown (Table);
            raise Program_Error
              with "a concurrent shard operation never started";
         end select;
         declare
            Quick : Touch_Op;
            Start : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
         begin
            Wide_Counters.Invoke_On (Table, 0, Quick);
            Elapsed :=
              Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Start);
         end;
         Wide_Counters.Request_Shutdown (Table);
      exception
         when others =>
            Wide_Counters.Request_Shutdown (Table);
            raise;
      end;

      if Elapsed > 0.10 then
         raise Program_Error
           with "a second lane did not run while the first was suspended";
      end if;
      if Wide_Result.Outcome /= Shards.Shutdown_Completed then
         raise Program_Error
           with "concurrent sharded service did not shut down cleanly";
      end if;
   end Check_Concurrency;

   --  --------------------------------------------------------------
   --  Phase 3: strict serialization with the default single lane
   --  --------------------------------------------------------------

   Serial_Result : Shards.Service_Result;

   package Serial_Kit is

      package Serial is new Shards.Services
        (Service_Type => Counter,
         Create       => Make,
         Shut_Down    => Release);

      type Slow_Op is limited new Serial.Operation with record
         Nap : Duration := 0.20;
      end record;
      overriding procedure Execute
        (Op       : in out Slow_Op;
         Instance : in out Counter;
         Shard    : Shards.Shard_Id);

      type Touch_Op is limited new Serial.Operation with null record;
      overriding procedure Execute
        (Op       : in out Touch_Op;
         Instance : in out Counter;
         Shard    : Shards.Shard_Id);

   end Serial_Kit;

   package body Serial_Kit is

      overriding procedure Execute
        (Op       : in out Slow_Op;
         Instance : in out Counter;
         Shard    : Shards.Shard_Id)
      is
         pragma Unreferenced (Instance, Shard);
      begin
         Audit.Note_Started;
         delay Op.Nap;
      end Execute;

      overriding procedure Execute
        (Op       : in out Touch_Op;
         Instance : in out Counter;
         Shard    : Shards.Shard_Id)
      is
         pragma Unreferenced (Op, Shard);
      begin
         Instance.Calls := Instance.Calls + 1;
      end Execute;

   end Serial_Kit;

   task type Serial_Server (Target : access Serial_Kit.Serial.Service) is
      pragma Task_Info (Flyology.Native_Task);
   end Serial_Server;

   task body Serial_Server is
   begin
      Serial_Kit.Serial.Serve (Target.all, Shard_Total, Serial_Result);
   end Serial_Server;

   procedure Check_Serialization is
      package Serial renames Serial_Kit.Serial;
      Table   : aliased Serial.Service;
      Elapsed : Duration := 0.0;
   begin
      Audit.Reset;
      declare
         Server : Serial_Server (Table'Access);
         pragma Unreferenced (Server);

         task Blocker is
            pragma Task_Info (Flyology.Native_Task);
         end Blocker;

         task body Blocker is
            Slow : Serial_Kit.Slow_Op;
         begin
            if Serial.Await_Ready (Table, 30.0) then
               Slow.Nap := 0.20;
               Serial.Invoke_On (Table, 0, Slow);
            end if;
         end Blocker;
      begin
         if not Serial.Await_Ready (Table, 30.0) then
            raise Program_Error
              with "serial sharded service did not become ready";
         end if;
         select
            Audit.Await_Started;
         or
            delay 10.0;
            Serial.Request_Shutdown (Table);
            raise Program_Error
              with "a single-lane shard operation never started";
         end select;
         declare
            Quick : Serial_Kit.Touch_Op;
            Start : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
         begin
            Serial.Invoke_On (Table, 0, Quick);
            Elapsed :=
              Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Start);
         end;
         Serial.Request_Shutdown (Table);
      exception
         when others =>
            Serial.Request_Shutdown (Table);
            raise;
      end;

      if Elapsed < 0.05 then
         raise Program_Error
           with "a single-lane shard did not serialize its operations";
      end if;
      if Serial_Result.Outcome /= Shards.Shutdown_Completed then
         raise Program_Error
           with "serial sharded service did not shut down cleanly";
      end if;
   end Check_Serialization;

   --  --------------------------------------------------------------
   --  Phase 4: a readiness callback that fails
   --  --------------------------------------------------------------

   Ready_Result : Shards.Service_Result;
   Ready_Raised : Boolean := False;

   procedure Failing_Ready;

   procedure Failing_Ready is
   begin
      raise Probe_Error with "readiness callback failed";
   end Failing_Ready;

   task type Ready_Server (Target : access Counters.Service) is
      pragma Task_Info (Flyology.Native_Task);
   end Ready_Server;

   task body Ready_Server is
   begin
      Counters.Serve
        (Target.all, Shard_Total, Ready_Result, Failing_Ready'Access);
   exception
      when Probe_Error =>
         Ready_Raised := True;
   end Ready_Server;

   --  Serve must stop every agent on this path too. Leaving its block
   --  without doing so would wait on tasks that never received Leave, so a
   --  regression here hangs rather than fails.
   procedure Check_Ready_Callback_Failure is
      Table : aliased Counters.Service;
   begin
      declare
         Server : Ready_Server (Table'Access);
         pragma Unreferenced (Server);
      begin
         if Counters.Await_Ready (Table, 30.0) then
            raise Program_Error
              with "a service whose readiness callback failed became ready";
         end if;
      end;

      if not Ready_Raised then
         raise Program_Error
           with "a failing readiness callback did not propagate from Serve";
      end if;
      if Counters.Running (Table) then
         raise Program_Error
           with "a service whose readiness callback failed still runs";
      end if;
   end Check_Ready_Callback_Failure;

   --  --------------------------------------------------------------
   --  Phase 5: a shard that cannot be constructed
   --  --------------------------------------------------------------

   Broken_Result : Shards.Service_Result;

   function Broken_Make (Shard : Shards.Shard_Id) return Counter;

   function Broken_Make (Shard : Shards.Shard_Id) return Counter is
   begin
      if Shard = 1 then
         raise Probe_Error with "shard refused to start";
      end if;
      return (Shard => Shard, Total => 0, Calls => 0);
   end Broken_Make;

   package Broken is new Shards.Services
     (Service_Type => Counter,
      Create       => Broken_Make);

   task type Broken_Server (Target : access Broken.Service) is
      pragma Task_Info (Flyology.Native_Task);
   end Broken_Server;

   task body Broken_Server is
   begin
      Broken.Serve (Target.all, Shard_Total, Broken_Result);
   end Broken_Server;

   procedure Check_Startup_Failure is
      Table : aliased Broken.Service;
   begin
      declare
         Server : Broken_Server (Table'Access);
         pragma Unreferenced (Server);
      begin
         if Broken.Await_Ready (Table, 30.0) then
            raise Program_Error
              with "a service with a failing shard reported readiness";
         end if;
      end;

      if Broken_Result.Outcome /= Shards.Startup_Failed then
         raise Program_Error
           with "a failing shard was not reported as a startup failure";
      end if;
      if Broken_Result.Shard /= 1 then
         raise Program_Error with "startup failure named the wrong shard";
      end if;
      if Flyology.Task_Results.Text (Broken_Result.Exception_Message) /=
        "shard refused to start"
      then
         raise Program_Error
           with "startup failure did not retain its diagnostic";
      end if;
   end Check_Startup_Failure;

begin
   if Test_Shard'Last /= 3 then
      raise Program_Error with "unexpected sharding test width";
   end if;

   Check_Running_Service;
   Check_Concurrency;
   Check_Serialization;
   Check_Ready_Callback_Failure;
   Check_Startup_Failure;
end Sharding_Smoke;
