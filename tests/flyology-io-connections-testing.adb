with Ada.Real_Time;
with Interfaces.C;
with System.Address_To_Access_Conversions;

package body Flyology.IO.Connections.Testing is

   use type Ada.Real_Time.Time;
   use type Interfaces.C.int;

   type Controller_Data is record
      Current_FD         : Flyology.IO.Descriptor;
      Current_Generation : Descriptor_Generation;
      Active             : Boolean with Atomic;
      Closing            : Boolean with Atomic;
      Started_Operations : Natural with Atomic;
   end record;

   package Data_Conversions is new System.Address_To_Access_Conversions
     (Controller_Data);

   procedure C_Reset
     with Import,
          Convention => C,
          External_Name => "flyology_test_connection_barrier_reset";
   procedure C_Arm (Point : Interfaces.C.int)
     with Import,
          Convention => C,
          External_Name => "flyology_test_connection_barrier_arm";
   function C_Reached (Point : Interfaces.C.int) return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_connection_barrier_reached";
   procedure C_Release (Point : Interfaces.C.int)
     with Import,
          Convention => C,
          External_Name => "flyology_test_connection_barrier_release";

   function Data (Item : Connection)
      return Data_Conversions.Object_Pointer is
     (Data_Conversions.To_Pointer (Item.Controller'Address));

   function Waiting_Operations (Item : Connection) return Natural is
      Controller : constant Data_Conversions.Object_Pointer := Data (Item);
      Started : constant Natural := Controller.Started_Operations;
   begin
      --  These fields are atomic in the controller. The layout mirror remains
      --  confined to this smoke-test child and adds no production observer.
      return Started - (if Controller.Active then 1 else 0);
   end Waiting_Operations;

   function Operation_Active (Item : Connection) return Boolean is
     (Data (Item).Active);

   function Close_Requested (Item : Connection) return Boolean is
     (Data (Item).Closing);

   procedure Reset_Barriers is
   begin
      C_Reset;
   end Reset_Barriers;

   procedure Arm (Point : Barrier_Point) is
   begin
      C_Arm (Barrier_Point'Pos (Point));
   end Arm;

   procedure Wait_Reached (Point : Barrier_Point) is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while C_Reached (Barrier_Point'Pos (Point)) = 0 loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "connection test barrier was not reached";
         end if;
         delay 0.001;
      end loop;
   end Wait_Reached;

   procedure Release (Point : Barrier_Point) is
   begin
      C_Release (Barrier_Point'Pos (Point));
   end Release;

end Flyology.IO.Connections.Testing;
