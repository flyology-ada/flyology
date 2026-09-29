with Ada.Streams;
with Flyology;
with Flyology.Execution_Groups;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.IO.Timers;
with Flyology.Observability;
with System.Flyology.Scheduling_Policy;

procedure Deadline_Clamp_Smoke is
   package Groups renames Flyology.Execution_Groups;
   package Observation renames Flyology.Observability;
   package Scheduling renames System.Flyology.Scheduling_Policy;

   use type Ada.Streams.Stream_Element_Array;
   use type Observation.Counter;
   use type Observation.Task_Instance_Id;
   use type Observation.Task_State;
   use type Scheduling.Deadline_Status;

   protected Control is
      procedure Note_Waiter
        (Instance : Observation.Task_Instance_Id; Group : Groups.Group_Id);
      entry Waiter_Started
        (Instance : out Observation.Task_Instance_Id;
         Group    : out Groups.Group_Id);
      procedure Release_Sender;
      entry Wait_For_Sender_Release;
      procedure Set_Result (Value : Boolean);
      entry Wait_Result;
      function Passed return Boolean;
   private
      Waiter_Is_Started : Boolean := False;
      Waiter_Instance   : Observation.Task_Instance_Id :=
        Observation.No_Task_Instance;
      Waiter_Group      : Groups.Group_Id := Groups.Default_Group;
      Sender_Released   : Boolean := False;
      Result_Available  : Boolean := False;
      Result_Passed     : Boolean := False;
   end Control;

   protected body Control is
      procedure Note_Waiter
        (Instance : Observation.Task_Instance_Id; Group : Groups.Group_Id) is
      begin
         Waiter_Instance := Instance;
         Waiter_Group := Group;
         Waiter_Is_Started := True;
      end Note_Waiter;

      entry Waiter_Started
        (Instance : out Observation.Task_Instance_Id;
         Group    : out Groups.Group_Id)
        when Waiter_Is_Started
      is
      begin
         Instance := Waiter_Instance;
         Group := Waiter_Group;
      end Waiter_Started;

      procedure Release_Sender is
      begin
         Sender_Released := True;
      end Release_Sender;

      entry Wait_For_Sender_Release when Sender_Released is
      begin
         null;
      end Wait_For_Sender_Release;

      procedure Set_Result (Value : Boolean) is
      begin
         Result_Passed := Value;
         Result_Available := True;
      end Set_Result;

      entry Wait_Result when Result_Available is
      begin
         null;
      end Wait_Result;

      function Passed return Boolean
      is (Result_Passed);
   end Control;

   Left, Right : Flyology.IO.Sockets.Socket_Type;
begin
   pragma
     Assert (Scheduling.Deadline_After (1.0, Duration'Last) = Duration'Last);
   pragma
     Assert
       (Scheduling.Classify_Deadline
          (Scheduling.Deadline_After (1.0, Duration'Last), 1.0)
          = Scheduling.Pending);

   Flyology.IO.Sockets.Create_Socket_Pair (Left, Right);
   declare
      Payload : constant Ada.Streams.Stream_Element_Array := [1 => 145];

      task Waiter is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Waiter;

      task Sender is
         pragma Task_Info (Flyology.Native_Task);
      end Sender;

      task body Waiter is
         Incoming : Ada.Streams.Stream_Element_Array (Payload'Range);
      begin
         Control.Note_Waiter
           (Observation.Current_Task_Instance, Groups.Current);
         if Flyology.IO.Wait
              (Flyology.IO.Sockets.Native_Descriptor (Left),
               Flyology.IO.For_Read,
               Timeout => Duration'Last)
         then
            Flyology.IO.Sockets.Receive_Exactly
              (Left, Incoming, Timeout => 1.0);
            Control.Set_Result (Incoming = Payload);
         else
            Control.Set_Result (False);
         end if;
      exception
         when others =>
            Control.Set_Result (False);
      end Waiter;

      task body Sender is
      begin
         Control.Wait_For_Sender_Release;
         Flyology.IO.Timers.Sleep_For (0.020);
         Flyology.IO.Sockets.Send_All (Right, Payload, Timeout => 1.0);
      exception
         when others =>
            Control.Set_Result (False);
      end Sender;
   begin
      declare
         Items      : Observation.Task_Snapshot_Array (1 .. 1);
         Count      : Natural;
         Total      : Observation.Counter;
         Instance   : Observation.Task_Instance_Id;
         Group      : Groups.Group_Id;
         Wait_Armed : Boolean := False;
      begin
         Control.Waiter_Started (Instance, Group);
         if Instance = Observation.No_Task_Instance then
            Control.Release_Sender;
            raise Program_Error
              with "lightweight waiter has no runtime identity";
         end if;
         for Attempt in 1 .. 2_000 loop
            if Observation.Snapshot_Tasks (Group, Items, Count, Total)
              and then Count = 1
              and then Total = 1
              and then Items (1).Instance = Instance
              and then Items (1).State = Observation.Task_Waiting
              and then Observation.Has_Flag
                         (Items (1), Observation.Task_Timer_Wait_Flag)
              and then Observation.Has_Flag
                         (Items (1), Observation.Task_Descriptor_Wait_Flag)
            then
               Wait_Armed := True;
               exit;
            end if;
            delay 0.001;
         end loop;
         if not Wait_Armed then
            Control.Release_Sender;
            raise Program_Error
              with
                "readiness wait did not register both descriptor and timer state";
         end if;
      end;
      Control.Release_Sender;
      select
         Control.Wait_Result;
      or
         delay 2.0;
         raise Program_Error
           with "saturated lightweight wait did not resume on readiness";
      end select;
      pragma Assert (Control.Passed);
   end;
   Flyology.IO.Sockets.Close_Socket (Left);
   Flyology.IO.Sockets.Close_Socket (Right);
end Deadline_Clamp_Smoke;
