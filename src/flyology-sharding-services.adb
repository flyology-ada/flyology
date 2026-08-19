with Ada.Exceptions;
with Flyology.Execution_Groups.Topology;

package body Flyology.Sharding.Services is

   package Groups renames Flyology.Execution_Groups;
   package Topology renames Flyology.Execution_Groups.Topology;
   package Results renames Flyology.Task_Results;

   use type Groups.Group_Id;
   use type Ada.Task_Identification.Task_Id;

   Not_Admitting : constant String :=
     "sharded service is not admitting operations";

   --  Copy an occurrence into the fixed result storage. No allocation and
   --  no callback occurs, so this is safe on an agent's terminal path.
   --  @param Shard Shard reporting the failure
   --  @param Outcome Terminal classification to record
   --  @param Occurrence Exception observed by the shard agent
   --  @return Bounded copied service result
   function Failure_Result
     (Shard      : Shard_Id;
      Outcome    : Service_Outcome;
      Occurrence : Ada.Exceptions.Exception_Occurrence)
      return Service_Result;

   ---------------------
   -- Failure_Result  --
   ---------------------

   function Failure_Result
     (Shard      : Shard_Id;
      Outcome    : Service_Outcome;
      Occurrence : Ada.Exceptions.Exception_Occurrence)
      return Service_Result
   is
      Name : constant String :=
        Ada.Exceptions.Exception_Name (Occurrence);
      Text : constant String :=
        Ada.Exceptions.Exception_Message (Occurrence);
      Kept_Name : constant Natural :=
        Natural'Min (Name'Length, Results.Exception_Name_Capacity);
      Kept_Text : constant Natural :=
        Natural'Min (Text'Length, Results.Exception_Message_Capacity);
      Value : Service_Result;
   begin
      Value.Outcome := Outcome;
      Value.Shard := Shard;
      Value.Exception_Name.Length := Kept_Name;
      Value.Exception_Name.Truncated := Name'Length > Kept_Name;
      Value.Exception_Name.Data (1 .. Kept_Name) :=
        Name (Name'First .. Name'First + Kept_Name - 1);
      Value.Exception_Message.Length := Kept_Text;
      Value.Exception_Message.Truncated := Text'Length > Kept_Text;
      Value.Exception_Message.Data (1 .. Kept_Text) :=
        Text (Text'First .. Text'First + Kept_Text - 1);
      return Value;
   end Failure_Result;

   --------------
   -- Registry --
   --------------

   protected body Registry is

      procedure Begin_Service
        (Count    : Shard_Count;
         Accepted : out Boolean;
         Stopped  : out Boolean) is
      begin
         Stopped := Stopping;
         if Configured then
            Accepted := False;
         else
            Configured := True;
            Shard_Total := Natural (Count);
            Accepted := True;
         end if;
      end Begin_Service;

      procedure Publish_Agent
        (Shard    : Shard_Id;
         Lane     : Lane_Index;
         Executor : Agent_Access) is
      begin
         Executors (Shard) (Lane) := Executor;
      end Publish_Agent;

      procedure Publish_Instance
        (Shard    : Shard_Id;
         Lane     : Lane_Index;
         State    : Instance_Access;
         Identity : Ada.Task_Identification.Task_Id) is
      begin
         States (Shard) := State;
         Identities (Shard) (Lane) := Identity;
         Published := Published + 1;
         if Published = Shard_Total then
            Resolved := True;
         end if;
      end Publish_Instance;

      procedure Publish_Lane
        (Shard    : Shard_Id;
         Lane     : Lane_Index;
         Identity : Ada.Task_Identification.Task_Id) is
      begin
         Identities (Shard) (Lane) := Identity;
      end Publish_Lane;

      procedure Publish_Failure (Failure : Service_Result) is
      begin
         if not Failed then
            Failed := True;
            Outcome := Failure;
         end if;
         Admitting := False;
         Stopping := True;
      end Publish_Failure;

      entry Await_Startup (Ready : out Boolean)
        when Resolved or else Failed is
      begin
         Ready := not Failed;
      end Await_Startup;

      entry Await_Admission (Ready : out Boolean)
        when Admitting or else Failed or else Stopping is
      begin
         Ready := Admitting;
      end Await_Admission;

      function Instance_Of (Shard : Shard_Id) return Instance_Access is
        (States (Shard));

      procedure Open_Admission is
      begin
         if not Stopping and then not Failed then
            Admitting := True;
         end if;
      end Open_Admission;

      entry Await_Stop_Request when Stopping is
      begin
         null;
      end Await_Stop_Request;

      procedure Request_Shutdown is
      begin
         Admitting := False;
         Stopping := True;
      end Request_Shutdown;

      entry Await_Quiescent when In_Flight = 0 is
      begin
         null;
      end Await_Quiescent;

      procedure Enter
        (Shard     : Shard_Id;
         Caller    : Ada.Task_Identification.Task_Id;
         Executors : out Lane_Agents;
         Admitted  : out Boolean;
         Reentry   : out Boolean;
         Armed     : not null access Boolean) is
      begin
         Executors := (others => null);
         Reentry := False;
         Admitted := False;
         for Lane in Lane_Index loop
            if Identities (Shard) (Lane) = Caller then
               Reentry := True;
               return;
            end if;
         end loop;
         if not Admitting or else Stopping then
            return;
         end if;
         Executors := Registry.Executors (Shard);
         Armed.all := True;
         In_Flight := In_Flight + 1;
         Admitted := True;
      end Enter;

      procedure Borrow
        (Shard    : Shard_Id;
         State    : out Instance_Access;
         Admitted : out Boolean;
         Armed    : not null access Boolean) is
      begin
         State := null;
         if not Admitting or else Stopping or else States (Shard) = null then
            Admitted := False;
            return;
         end if;
         State := States (Shard);
         Armed.all := True;
         In_Flight := In_Flight + 1;
         Admitted := True;
      end Borrow;

      procedure Leave (Armed : not null access Boolean) is
      begin
         if Armed.all then
            Armed.all := False;
            In_Flight := In_Flight - 1;
         end if;
      end Leave;

      function Running return Boolean is (Admitting and then not Stopping);

      function Count return Natural is
        (if Resolved and then not Failed then Shard_Total else 0);

      function Result return Service_Result is (Outcome);

   end Registry;

   ---------------------
   -- Lane_Dispatcher --
   ---------------------

   protected body Lane_Dispatcher is

      entry Acquire (Lane : out Lane_Index; Admitted : out Boolean)
        when Available > 0 or else not Opened is
      begin
         Lane := Lane_Index'First;
         Admitted := False;
         if not Opened then
            return;
         end if;
         for Candidate in Lane_Index loop
            if Free (Candidate) then
               Free (Candidate) := False;
               Available := Available - 1;
               Lane := Candidate;
               Admitted := True;
               return;
            end if;
         end loop;
      end Acquire;

      procedure Release (Lane : Lane_Index) is
      begin
         if not Free (Lane) then
            Free (Lane) := True;
            Available := Available + 1;
         end if;
      end Release;

      procedure Open is
      begin
         Opened := True;
      end Open;

      procedure Close is
      begin
         Opened := False;
      end Close;

   end Lane_Dispatcher;

   -----------
   -- Agent --
   -----------

   task body Agent is
      Mine  : Shard_Id := Shard_Id'First;
      Slot  : Lane_Index := Lane_Index'First;
      Home  : Registry_Access := null;
      Phase : Service_Outcome := Startup_Failed;
   begin
      accept Assign
        (Shard : Shard_Id;
         Lane  : Lane_Index;
         Owner : Registry_Access)
      do
         Mine := Shard;
         Slot := Lane;
         Home := Owner;
      end Assign;

      Topology.Cross_To_Shard (Mine);

      declare
         --  The agent owns thread-affine state for the whole of its life,
         --  so it must never migrate again. The pin also turns a stray
         --  Migrate inside an operation into Migration_Error.
         Pin : Groups.Thread_Pin := Groups.Pin_To_Current_Thread;
         pragma Unreferenced (Pin);
      begin
         if Slot = Lane_Index'First then
            declare
               Instance : aliased Service_Type := Create (Mine);
            begin
               Phase := Shard_Failed;
               Home.Publish_Instance
                 (Mine,
                  Slot,
                  Instance'Unchecked_Access,
                  Ada.Task_Identification.Current_Task);
               loop
                  begin
                     select
                        accept Run_Operation (Op : in out Operation'Class) do
                           Execute (Op, Instance, Mine);
                        end Run_Operation;
                     or
                        accept Leave;
                        exit;
                     end select;
                  exception
                     --  Ada already raised this occurrence at the point of
                     --  the entry call. The agent keeps serving.
                     when others =>
                        null;
                  end;
               end loop;
               Shut_Down (Instance);
            end;
         else
            declare
               Ready : Boolean;
               State : Instance_Access;
            begin
               Home.Await_Startup (Ready);
               if Ready then
                  Phase := Shard_Failed;
                  State := Home.Instance_Of (Mine);
                  Home.Publish_Lane
                    (Mine, Slot, Ada.Task_Identification.Current_Task);
                  loop
                     begin
                        select
                           accept Run_Operation
                             (Op : in out Operation'Class)
                           do
                              Execute (Op, State.all, Mine);
                           end Run_Operation;
                        or
                           accept Leave;
                           exit;
                        end select;
                     exception
                        when others =>
                           null;
                     end;
                  end loop;
               end if;
            end;
         end if;
      end;
   exception
      when Occurrence : others =>
         if Home /= null then
            Home.Publish_Failure
              (Failure_Result (Mine, Phase, Occurrence));
         end if;
   end Agent;

   -----------
   -- Serve --
   -----------

   procedure Serve
     (Item     : aliased in out Service;
      Shards   : Shard_Count;
      Result   : out Service_Result;
      On_Ready : access procedure := null)
   is
      Home     : constant Registry_Access := Item.State'Unchecked_Access;
      Last     : constant Shard_Id := Shard_Id (Natural (Shards) - 1);
      Accepted : Boolean;
      Stopped  : Boolean;
   begin
      Item.State.Begin_Service (Shards, Accepted, Stopped);
      if not Accepted then
         raise Configuration_Error
           with "sharded service was already served";
      end if;
      if Stopped then
         Result := Item.State.Result;
         return;
      end if;

      Groups.Grow_Configured_Pool (Shards);

      declare
         Agents : Agent_Array (Shard_Id'First .. Last);
         Ready  : Boolean;
      begin
         for Shard in Agents'Range loop
            for Lane in Lane_Index loop
               Item.State.Publish_Agent
                 (Shard, Lane, Agents (Shard) (Lane)'Unchecked_Access);
            end loop;
            if Concurrency > 1 then
               Item.Dispatchers (Integer (Shard)).Open;
            end if;
         end loop;

         for Shard in Agents'Range loop
            for Lane in Lane_Index loop
               Agents (Shard) (Lane).Assign (Shard, Lane, Home);
            end loop;
         end loop;

         Item.State.Await_Startup (Ready);
         if Ready then
            if On_Ready /= null then
               On_Ready.all;
            end if;
            Item.State.Open_Admission;
            Item.State.Await_Stop_Request;
         end if;

         Item.State.Request_Shutdown;
         if Concurrency > 1 then
            for Shard in Agents'Range loop
               Item.Dispatchers (Integer (Shard)).Close;
            end loop;
         end if;
         Item.State.Await_Quiescent;

         --  Helper lanes borrow the owning lane's frame, so they leave
         --  first. A lane that already terminated reports Tasking_Error.
         for Shard in Agents'Range loop
            for Lane in reverse Lane_Index loop
               begin
                  Agents (Shard) (Lane).Leave;
               exception
                  when Tasking_Error =>
                     null;
               end;
            end loop;
         end loop;
      end;

      Result := Item.State.Result;
   end Serve;

   ----------------------
   -- Request_Shutdown --
   ----------------------

   procedure Request_Shutdown (Item : in out Service) is
   begin
      Item.State.Request_Shutdown;
   end Request_Shutdown;

   -----------------
   -- Await_Ready --
   -----------------

   function Await_Ready
     (Item    : in out Service;
      Timeout : Duration := -1.0) return Boolean
   is
      Ready : Boolean := False;
   begin
      if Timeout < 0.0 then
         Item.State.Await_Admission (Ready);
      else
         select
            Item.State.Await_Admission (Ready);
         or
            delay Timeout;
            return False;
         end select;
      end if;
      return Ready;
   end Await_Ready;

   -------------
   -- Running --
   -------------

   function Running (Item : Service) return Boolean is (Item.State.Running);

   ------------
   -- Shards --
   ------------

   function Shards (Item : Service) return Natural is (Item.State.Count);

   ---------------
   -- Shard_For --
   ---------------

   function Shard_For
     (Item : Service;
      Hash : Interfaces.Unsigned_64) return Shard_Id
   is
      Total : constant Natural := Item.State.Count;
   begin
      if Total = 0 then
         raise Not_Running with Not_Admitting;
      end if;
      return Shard_For_Hash (Hash, Shard_Count (Total));
   end Shard_For;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Invocation_Guard) is
   begin
      if Item.Lane_Held and then Item.Lanes /= null then
         Item.Lane_Held := False;
         Item.Lanes.Release (Item.Lane);
      end if;
      if Item.Held and then Item.Home /= null then
         Item.Home.Leave (Item.Held'Access);
      end if;
   end Finalize;

   ---------------
   -- Invoke_On --
   ---------------

   procedure Invoke_On
     (Item  : in out Service;
      Shard : Shard_Id;
      Op    : in out Operation'Class)
   is
      Caller : constant Ada.Task_Identification.Task_Id :=
        Ada.Task_Identification.Current_Task;
      Total  : constant Natural := Item.State.Count;

      Guard     : Invocation_Guard;
      Lanes     : Lane_Agents;
      Admitted  : Boolean;
      Reentry   : Boolean;
      Selected  : Lane_Index := Lane_Index'First;
   begin
      if Total = 0 then
         raise Not_Running with Not_Admitting;
      end if;
      if Natural (Shard) >= Total then
         raise Constraint_Error
           with "shard is outside this sharded service";
      end if;

      Guard.Home := Item.State'Unchecked_Access;
      Item.State.Enter
        (Shard, Caller, Lanes, Admitted, Reentry, Guard.Held'Access);
      if Reentry then
         raise Reentrant_Operation
           with "shard operation submitted work to its own shard";
      end if;
      if not Admitted then
         raise Not_Running with Not_Admitting;
      end if;

      if Concurrency > 1 then
         declare
            Granted : Boolean;
         begin
            Guard.Lanes := Item.Dispatchers (Integer (Shard))'Unchecked_Access;
            Guard.Lanes.Acquire (Selected, Granted);
            if not Granted then
               raise Not_Running with Not_Admitting;
            end if;
            Guard.Lane := Selected;
            Guard.Lane_Held := True;
         end;
      end if;

      Lanes (Selected).Run_Operation (Op);
   end Invoke_On;

   -------------------
   -- Invoke_On_All --
   -------------------

   procedure Invoke_On_All
     (Item : in out Service;
      Op   : in out Operation'Class)
   is
      Total : constant Natural := Item.State.Count;
   begin
      if Total = 0 then
         raise Not_Running with Not_Admitting;
      end if;
      for Shard in Shard_Id'First .. Shard_Id (Total - 1) loop
         Invoke_On (Item, Shard, Op);
      end loop;
   end Invoke_On_All;

   ----------------------
   -- Invoke_On_Others --
   ----------------------

   procedure Invoke_On_Others
     (Item : in out Service;
      Op   : in out Operation'Class)
   is
      Total : constant Natural := Item.State.Count;
      Owned : Shard_Id := Shard_Id'First;
      Mine  : Boolean := False;
   begin
      if Total = 0 then
         raise Not_Running with Not_Admitting;
      end if;
      begin
         declare
            Group : constant Groups.Group_Id := Groups.Current;
         begin
            if Natural (Group) < Total then
               Owned := Shard_Id (Group);
               Mine := True;
            end if;
         end;
      exception
         --  A native caller owns no group, so it reaches every shard.
         when Groups.Group_Error =>
            Mine := False;
      end;
      for Shard in Shard_Id'First .. Shard_Id (Total - 1) loop
         if not Mine or else Shard /= Owned then
            Invoke_On (Item, Shard, Op);
         end if;
      end loop;
   end Invoke_On_Others;

   ------------------
   -- Borrow_Local --
   ------------------

   function Borrow_Local (Item : in out Service) return Local_Reference is
      Total : constant Natural := Item.State.Count;
   begin
      if Total = 0 then
         raise Not_Running with Not_Admitting;
      end if;
      return Ref : Local_Reference :=
        (Pin    => Groups.Pin_To_Current_Thread,
         Guard  => <>,
         Target => null,
         Shard  => Shard_Id'First)
      do
         declare
            Owned    : Shard_Id;
            State    : Instance_Access;
            Admitted : Boolean;
            Group    : Groups.Group_Id;
         begin
            begin
               Group := Groups.Current;
            exception
               when Groups.Group_Error =>
                  raise Not_Owner
                    with "caller does not run on a Flyology event loop";
            end;
            if Natural (Group) >= Total then
               raise Not_Owner
                 with "caller is not on a shard of this service";
            end if;
            Owned := Shard_Id (Group);
            Ref.Guard.Home := Item.State'Unchecked_Access;
            Item.State.Borrow
              (Owned, State, Admitted, Ref.Guard.Held'Access);
            if not Admitted then
               raise Not_Running with Not_Admitting;
            end if;
            Ref.Target := State;
            Ref.Shard := Owned;
         end;
      end return;
   end Borrow_Local;

   --------------
   -- Instance --
   --------------

   function Instance
     (Ref : Local_Reference) return not null access Service_Type is
   begin
      if Ref.Target = null then
         raise Not_Running with "borrow does not hold an instance";
      end if;
      return Ref.Target;
   end Instance;

   -----------
   -- Owner --
   -----------

   function Owner (Ref : Local_Reference) return Shard_Id is (Ref.Shard);

   ----------------
   -- Map_Reduce --
   ----------------

   package body Map_Reduce is

      overriding procedure Execute
        (Op       : in out Map_Operation;
         Instance : in out Service_Type;
         Shard    : Shard_Id) is
      begin
         Map (Instance, Shard, Op.Value);
      end Execute;

      procedure Run
        (Item : in out Service;
         Into : in out Accumulator)
      is
         Total : constant Natural := Services.Shards (Item);
      begin
         if Total = 0 then
            raise Not_Running with Not_Admitting;
         end if;
         for Shard in Shard_Id'First .. Shard_Id (Total - 1) loop
            declare
               Op : Map_Operation;
            begin
               Invoke_On (Item, Shard, Op);
               Reduce (Into, Shard, Op.Value);
            end;
         end loop;
      end Run;

   end Map_Reduce;

end Flyology.Sharding.Services;
