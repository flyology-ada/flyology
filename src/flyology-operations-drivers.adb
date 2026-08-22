with Interfaces;
with Flyology.Wake_Sources;

package body Flyology.Operations.Drivers is
   use type Interfaces.C.int;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   function Pending_Slot
     (Item : Operation'Class) return Operation_Id
   is
   begin
      if Item.Slot = 0 then
         raise Operation_Error with "operation has not been started";
      end if;
      declare
         Id : constant Operation_Id := Operation_Id (Item.Slot);
         Slot : Slot_Record renames Item.Set.Slots (Id);
      begin
         if Slot.Generation /= Item.Generation
           or else Slot.State /= Pending
         then
            raise Operation_Error with "operation is not pending";
         end if;
         return Id;
      end;
   end Pending_Slot;

   procedure Start (Item : in out Operation'Class) is
   begin
      Register (Item);
   end Start;

   procedure Rollback_Start (Item : in out Operation'Class) is
      Id : constant Operation_Id := Pending_Slot (Item);
      Slot : Slot_Record renames Item.Set.Slots (Id);
   begin
      if Slot.Dependents /= 0 then
         raise Operation_Error with
           "operation initiation already has dependent gates";
      end if;
      Slot.State := Idle;
      Slot.Source := No_Source;
      Slot.Source_Count := 0;
      Slot.Descriptors := (others => -1);
      Slot.For_Write := (others => False);
      Slot.Deadline := Duration'Last;
      Slot.Has_Deadline := False;
      Slot.Result := Succeeded;
      Slot.Reported := False;
   end Rollback_Start;

   procedure Arm_Readiness
     (Item       : in out Operation'Class;
      Descriptor : Interfaces.C.int;
      For_Write  : Boolean)
   is
      Sources : constant Readiness_Source_Array :=
        (1 => (Descriptor => Descriptor, For_Write => For_Write));
   begin
      Arm_Readiness (Item, Sources);
   end Arm_Readiness;

   procedure Arm_Readiness
     (Item    : in out Operation'Class;
      Sources : Readiness_Source_Array)
   is
      Id : Operation_Id;
      Position : Natural := Readiness_Source_Index'First;
   begin
      if Sources'Length = 0
        or else Sources'Length > Max_Readiness_Sources_Per_Operation
      then
         raise Operation_Error with "invalid readiness source count";
      end if;
      for Source of Sources loop
         if Source.Descriptor < 0 then
            raise Operation_Error with "invalid readiness descriptor";
         end if;
      end loop;
      Id := Pending_Slot (Item);
      if Item.Set.Slots (Id).Source /= No_Source then
         raise Operation_Error with "operation already has an armed source";
      end if;
      Item.Set.Slots (Id).Source := Descriptor_Source;
      Item.Set.Slots (Id).Source_Count := Sources'Length;
      for Source of Sources loop
         Item.Set.Slots (Id).Descriptors
           (Readiness_Source_Index (Position)) := Source.Descriptor;
         Item.Set.Slots (Id).For_Write
           (Readiness_Source_Index (Position)) := Source.For_Write;
         Position := Position + 1;
      end loop;
   end Arm_Readiness;

   procedure Arm_Deadline
     (Item     : in out Operation'Class;
      Interval : Duration)
   is
      Id  : constant Operation_Id := Pending_Slot (Item);
      Now : constant Duration := Clock;
   begin
      Item.Set.Slots (Id).Has_Deadline := True;
      Item.Set.Slots (Id).Deadline :=
        (if Interval <= 0.0 then Now
         elsif Interval >= Duration'Last - Now then Duration'Last
         else Now + Interval);
   end Arm_Deadline;

   procedure Clear_Deadline (Item : in out Operation'Class) is
      Id : constant Operation_Id := Pending_Slot (Item);
   begin
      Item.Set.Slots (Id).Has_Deadline := False;
      Item.Set.Slots (Id).Deadline := Duration'Last;
   end Clear_Deadline;

   procedure Reschedule (Item : in out Operation'Class) is
      Id : constant Operation_Id := Pending_Slot (Item);
   begin
      if Item.Set.Slots (Id).Source /= No_Source then
         raise Operation_Error with "operation already has an armed source";
      end if;
      Item.Set.Slots (Id).Source := Immediate_Source;
   end Reschedule;

   procedure Completion_Source
     (Item              : in out Operation'Class;
      Read_Descriptor   : out Interfaces.C.int;
      Signal_Descriptor : out Interfaces.C.int)
   is
      Id : constant Operation_Id := Pending_Slot (Item);
      pragma Unreferenced (Id);
   begin
      Flyology.Wake_Sources.Ensure (Item.Set.Wake);
      Read_Descriptor := Flyology.Wake_Sources.Descriptor (Item.Set.Wake);
      Signal_Descriptor :=
        Flyology.Wake_Sources.Signal_Descriptor (Item.Set.Wake);
   end Completion_Source;

   procedure Signal_Completion (Item : in out Operation'Class) is
      Id : constant Operation_Id := Pending_Slot (Item);
      pragma Unreferenced (Id);
   begin
      Flyology.Wake_Sources.Signal (Item.Set.Wake);
   end Signal_Completion;

   procedure Complete
     (Item   : in out Operation'Class;
      Result : Terminal_Outcome)
   is
   begin
      Publish_Terminal (Item, Result);
   end Complete;

end Flyology.Operations.Drivers;
