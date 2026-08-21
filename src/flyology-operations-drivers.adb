with Interfaces;
with Flyology.Wake_Sources;

package body Flyology.Operations.Drivers is
   use type Interfaces.C.int;
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

   procedure Arm_Readiness
     (Item       : in out Operation'Class;
      Descriptor : Interfaces.C.int;
      For_Write  : Boolean)
   is
      Id : Operation_Id;
   begin
      if Descriptor < 0 then
         raise Operation_Error with "invalid readiness descriptor";
      end if;
      Id := Pending_Slot (Item);
      if Item.Set.Slots (Id).Source /= No_Source then
         raise Operation_Error with "operation already has an armed source";
      end if;
      Item.Set.Slots (Id).Source := Descriptor_Source;
      Item.Set.Slots (Id).Descriptor := Descriptor;
      Item.Set.Slots (Id).For_Write := For_Write;
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

   procedure Complete
     (Item   : in out Operation'Class;
      Result : Terminal_Outcome)
   is
   begin
      Publish_Terminal (Item, Result);
   end Complete;

end Flyology.Operations.Drivers;
