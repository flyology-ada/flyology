with Ada.Real_Time;
with Ada.Unchecked_Deallocation;

package body Flyology.Observability.Stall_Watchdogs is
   package RT renames Ada.Real_Time;

   use type RT.Time;
   protected type Watchdog_State is
      procedure Configure (Value : Watchdog_Config);
      function Configuration return Watchdog_Config;
      procedure Publish (Value : Watchdog_Report);
      function Latest return Watchdog_Report;
   private
      Config : Watchdog_Config;
      Report : Watchdog_Report;
   end Watchdog_State;

   protected body Watchdog_State is
      procedure Configure (Value : Watchdog_Config) is
      begin
         Config := Value;
         Report :=
           (Group              => Value.Group,
            Condition          => Not_Started,
            Sample_Sequence    => 0,
            Snapshot_Available => False,
            Observed_For       => 0.0,
            Ready              => 0,
            Waiting            => 0,
            Running            => 0,
            Dispatches         => 0,
            Poll_Batches       => 0,
            Stall_Episodes     => 0);
      end Configure;

      function Configuration return Watchdog_Config is (Config);

      procedure Publish (Value : Watchdog_Report) is
      begin
         Report := Value;
      end Publish;

      function Latest return Watchdog_Report is (Report);
   end Watchdog_State;

   task type Monitor_Task (State : not null Watchdog_State_Access) is
      pragma Task_Info (Flyology.Native_Task);
      entry Stop;
   end Monitor_Task;

   task body Monitor_Task is
      Config              : constant Watchdog_Config := State.Configuration;
      Previous            : Group_Snapshot;
      Current             : Group_Snapshot;
      Have_Previous       : Boolean := False;
      Tracking_No_Progress : Boolean := False;
      In_Stall_Episode    : Boolean := False;
      No_Progress_Since   : RT.Time := RT.Clock;
      Next_Sample         : RT.Time := RT.Clock;
      Sequence            : Counter := 0;
      Episodes            : Counter := 0;

      function Runnable (Item : Group_Snapshot) return Boolean is
        (Item.Ready /= 0 or else Item.Running /= 0);

      procedure Sample is
         Available : constant Boolean := Snapshot (Config.Group, Current);
         Now       : constant RT.Time := RT.Clock;
         Elapsed   : Duration := 0.0;
         Condition : Group_Condition;
      begin
         Sequence := Sequence + 1;

         if not Available then
            Condition := Group_Absent;
            Have_Previous := False;
            Tracking_No_Progress := False;
            In_Stall_Episode := False;
            State.Publish
              ((Group              => Config.Group,
                Condition          => Condition,
                Sample_Sequence    => Sequence,
                Snapshot_Available => False,
                Observed_For       => 0.0,
                Ready              => 0,
                Waiting            => 0,
                Running            => 0,
                Dispatches         => 0,
                Poll_Batches       => 0,
                Stall_Episodes     => Episodes));
            return;
         end if;

         if Current.Thread_State = Failed then
            Condition := Group_Failed;
            Tracking_No_Progress := False;
            In_Stall_Episode := False;
         elsif Current.Thread_State = Starting then
            Condition := Group_Starting;
            Tracking_No_Progress := False;
            In_Stall_Episode := False;
         elsif not Runnable (Current) then
            Condition := (if Current.Waiting /= 0 then Waiting else Idle);
            Tracking_No_Progress := False;
            In_Stall_Episode := False;
         elsif Have_Previous and then Made_Progress (Previous, Current) then
            Condition := Advancing;
            Tracking_No_Progress := False;
            In_Stall_Episode := False;
         else
            if not Tracking_No_Progress then
               Tracking_No_Progress := True;
               No_Progress_Since := Now;
            end if;
            Elapsed := RT.To_Duration (Now - No_Progress_Since);
            if Elapsed >= Config.Stall_Threshold then
               Condition := Suspected_Stall;
               if not In_Stall_Episode then
                  Episodes := Episodes + 1;
                  In_Stall_Episode := True;
               end if;
            else
               Condition := Runnable_Not_Progressing;
            end if;
         end if;

         State.Publish
           ((Group              => Config.Group,
             Condition          => Condition,
             Sample_Sequence    => Sequence,
             Snapshot_Available => True,
             Observed_For       => Elapsed,
             Ready              => Current.Ready,
             Waiting            => Current.Waiting,
             Running            => Current.Running,
             Dispatches         => Current.Dispatches,
             Poll_Batches       => Current.Poll_Batches,
             Stall_Episodes     => Episodes));
         Previous := Current;
         Have_Previous := True;
      end Sample;
   begin
      loop
         Sample;
         Next_Sample := Next_Sample + RT.To_Time_Span (Config.Sample_Interval);
         select
            accept Stop;
            exit;
         or
            delay until Next_Sample;
         end select;
      end loop;

      declare
         Final_Report : Watchdog_Report := State.Latest;
      begin
         Final_Report.Condition := Monitor_Stopped;
         State.Publish (Final_Report);
      end;
   exception
      when others =>
         declare
            Failure : Watchdog_Report := State.Latest;
         begin
            Failure.Condition := Monitor_Failed;
            State.Publish (Failure);
         end;
   end Monitor_Task;

   procedure Free_State is new Ada.Unchecked_Deallocation
     (Watchdog_State, Watchdog_State_Access);
   procedure Free_Monitor is new Ada.Unchecked_Deallocation
     (Monitor_Task, Monitor_Task_Access);

   procedure Start
     (Object : in out Watchdog;
      Config : Watchdog_Config := (others => <>))
   is
      Allocated_State : Boolean := False;
   begin
      if Config.Sample_Interval <= 0.0
        or else Config.Stall_Threshold <= 0.0
        or else Config.Stall_Threshold < Config.Sample_Interval
      then
         raise Invalid_Configuration with
           "positive threshold must be at least the sampling interval";
      elsif Object.Monitor /= null then
         raise Program_Error with "watchdog is already running";
      end if;

      if Object.State = null then
         Object.State := new Watchdog_State;
         Allocated_State := True;
      end if;
      Object.State.Configure (Config);
      Object.Monitor := new Monitor_Task (Object.State);
   exception
      when others =>
         if Object.Monitor = null
           and then Allocated_State
           and then Object.State /= null
         then
            Free_State (Object.State);
         end if;
         raise;
   end Start;

   procedure Stop (Object : in out Watchdog) is
   begin
      if Object.Monitor /= null then
         if not Object.Monitor.all'Terminated then
            begin
               Object.Monitor.Stop;
            exception
               when Tasking_Error => null;
            end;
         end if;
         while not Object.Monitor.all'Terminated loop
            delay 0.0;
         end loop;
         Free_Monitor (Object.Monitor);
      end if;
   end Stop;

   function Is_Running (Object : Watchdog) return Boolean is
     (Object.Monitor /= null and then not Object.Monitor.all'Terminated);

   function Latest_Report (Object : Watchdog) return Watchdog_Report is
   begin
      if Object.State = null then
         return (others => <>);
      end if;
      return Object.State.Latest;
   end Latest_Report;

   overriding procedure Finalize (Object : in out Watchdog) is
   begin
      Stop (Object);
      if Object.State /= null then
         Free_State (Object.State);
      end if;
   exception
      when others => null;
   end Finalize;

end Flyology.Observability.Stall_Watchdogs;
