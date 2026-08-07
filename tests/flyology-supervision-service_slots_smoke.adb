with Ada.Synchronous_Task_Control;
with Flyology.Supervision.Service_Slots;

procedure Flyology.Supervision.Service_Slots_Smoke is
   package STC renames Ada.Synchronous_Task_Control;

   type Service_Kind is (Metrics, Commands);

   function Logical_Id (Service : Service_Kind) return Child_Id is
     (case Service is
         when Metrics  => 41,
         when Commands => 42);

   package Slots is new Flyology.Supervision.Service_Slots
     (Service_Kind => Service_Kind,
      Logical_Id   => Logical_Id);
   use type Slots.Availability_Status;

   Directory : aliased Slots.Directory;

   First : constant Child_Handle :=
     (Controller => New_Controller, Id => 41, Generation => 1);
   Replacement : constant Child_Handle :=
     (Controller => Controller (First), Id => 41, Generation => 2);
   Foreign : constant Child_Handle :=
     (Controller => New_Controller, Id => 41, Generation => 1);
   Wrong_Child : constant Child_Handle :=
     (Controller => Controller (First), Id => 42, Generation => 1);

   First_Control       : Generation_Control;
   Duplicate_Control   : Generation_Control;
   Replacement_Control : Generation_Control;
   Wrong_Control       : Generation_Control;

   Observation : Slots.Service_Observation;
   Old_Lease   : Slots.Service_Lease;
   Rejected    : Boolean;
begin
   Open (First_Control, First);
   Open (Duplicate_Control, First);
   Open (Replacement_Control, Replacement);
   Open (Wrong_Control, Wrong_Child);
   declare
      Publication : Slots.Publication (Directory'Access);
      Duplicate   : Slots.Publication (Directory'Access);
   begin
      Slots.Publish_Ready (Publication, Metrics, First_Control);
      pragma Assert (Slots.Active (Publication));
      Observation := Slots.Acquire (Directory, Metrics);
      pragma Assert (Observation.Status = Slots.Available);
      Old_Lease := Observation.Lease;
      pragma Assert (Slots.Service (Old_Lease) = Metrics);
      pragma Assert (Slots.Handle (Old_Lease) = First);
      pragma Assert (Slots.Current (Directory, Old_Lease));

      Rejected := False;
      begin
         Slots.Publish_Ready (Duplicate, Metrics, Duplicate_Control);
      exception
         when Program_Error =>
            Rejected := True;
      end;
      pragma Assert (Rejected);

      Slots.Withdraw (Publication);
      Slots.Withdraw (Publication);
      pragma Assert (not Slots.Active (Publication));
      pragma Assert (not Slots.Current (Directory, Old_Lease));
      pragma Assert
        (Slots.Acquire (Directory, Metrics).Status = Slots.Unavailable);
   end;

   declare
      Publication : Slots.Publication (Directory'Access);
   begin
      Slots.Publish_Ready (Publication, Metrics, Replacement_Control);
      Observation := Slots.Acquire (Directory, Metrics);
      pragma Assert (Observation.Status = Slots.Available);
      pragma Assert (Slots.Handle (Observation.Lease) = Replacement);
      pragma Assert (not Slots.Current (Directory, Old_Lease));
   end;
   pragma Assert
     (Slots.Acquire (Directory, Metrics).Status = Slots.Unavailable);

   Rejected := False;
   declare
      Publication : Slots.Publication (Directory'Access);
   begin
      begin
         Slots.Publish_Ready (Publication, Metrics, Wrong_Control);
      exception
         when Program_Error =>
            Rejected := True;
      end;
   end;
   pragma Assert (Rejected);

   --  A task abort finalizes its controlled publication and revokes exactly
   --  its own entry before the enclosing Ada master can complete.
   declare
      Started : STC.Suspension_Object;
      Gate    : STC.Suspension_Object;
      Control : Generation_Control;

      task Publisher is
         entry Start;
      end Publisher;

      task body Publisher is
         Publication : Slots.Publication (Directory'Access);
      begin
         accept Start;
         Slots.Publish_Ready (Publication, Metrics, Control);
         STC.Set_True (Started);
         STC.Suspend_Until_True (Gate);
      end Publisher;
   begin
      Open (Control, Foreign);
      Publisher.Start;
      STC.Suspend_Until_True (Started);
      Observation := Slots.Acquire (Directory, Metrics);
      pragma Assert (Observation.Status = Slots.Available);
      pragma Assert (Slots.Handle (Observation.Lease) = Foreign);
      abort Publisher;
   end;
   pragma Assert
     (Slots.Acquire (Directory, Metrics).Status = Slots.Unavailable);
end Flyology.Supervision.Service_Slots_Smoke;
