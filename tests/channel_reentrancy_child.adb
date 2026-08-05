with Ada.Command_Line;
with Ada.Finalization;
with Flyology;
with Flyology.Channels.Bounded;
with Interfaces.C;
with System;

procedure Channel_Reentrancy_Child is
   use type Interfaces.C.long;

   function Write
     (FD     : Interfaces.C.int;
      Buffer : System.Address;
      Length : Interfaces.C.size_t) return Interfaces.C.long
     with Import, Convention => C, External_Name => "write";

   procedure Signal_Reentry is
      Message : aliased constant String :=
        "FLYOLOGY_EXPECT_BLOCKED_REACHED" & ASCII.LF;
      Result : constant Interfaces.C.long :=
        Write
          (2,
           Message (Message'First)'Address,
           Interfaces.C.size_t (Message'Length));
   begin
      if Result /= Interfaces.C.long (Message'Length) then
         raise Program_Error with "cannot signal reentry test boundary";
      end if;
   end Signal_Reentry;

   Model : constant Flyology.Execution_Model :=
     (if Ada.Command_Line.Argument_Count = 1
        and then Ada.Command_Line.Argument (1) = "lightweight"
      then Flyology.Lightweight_Task
      else Flyology.Native_Task);

   procedure Exercise (Designation : Flyology.Execution_Model) is
      type Reentrant_Value is new Ada.Finalization.Controlled with record
         Live : Boolean := False;
      end record;

      overriding procedure Adjust (Item : in out Reentrant_Value);
      overriding procedure Finalize (Item : in out Reentrant_Value);

      Reentry_Hook : access procedure := null;

      overriding procedure Adjust (Item : in out Reentrant_Value) is
      begin
         null;
      end Adjust;

      overriding procedure Finalize (Item : in out Reentrant_Value) is
      begin
         if Item.Live then
            Item.Live := False;
            if Reentry_Hook /= null then
               Signal_Reentry;
               Reentry_Hook.all;
            end if;
         end if;
      end Finalize;

      Empty : constant Reentrant_Value :=
        (Ada.Finalization.Controlled with Live => False);

      package Channels is new Flyology.Channels.Bounded
        (Element_Type => Reentrant_Value,
         Empty_Value  => Empty);

      Queue   : Channels.Channel (Capacity => 1);

      procedure Reenter_Queue is
         State : constant Channels.Snapshot := Queue.Current;
         pragma Unreferenced (State);
      begin
         null;
      end Reenter_Queue;

      task Worker is
         pragma Task_Info (Designation);
      end Worker;

      task body Worker is
         Sent     : Reentrant_Value;
         Received : Reentrant_Value;
      begin
         Sent.Live := True;
         Queue.Send (Sent);
         Sent := (Ada.Finalization.Controlled with Live => False);
         Reentry_Hook := Reenter_Queue'Access;
         --  This same-object protected call from Finalize is deliberately a
         --  contract violation. The runner confirms that the documented
         --  bounded-error outcome occurs at this exact boundary.
         Queue.Receive (Received);
      end Worker;
   begin
      null;
   end Exercise;
begin
   Exercise (Model);
end Channel_Reentrancy_Child;
