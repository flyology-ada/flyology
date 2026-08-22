with Ada.Real_Time;
with Flyology.TLS_Test_Hooks;

package body Flyology.IO.TLS.Testing is

   use type Ada.Real_Time.Time;

   package Test_Hooks renames Flyology.TLS_Test_Hooks;

   function Generation
     (Item : in out Connection) return Interfaces.Unsigned_64
   is
      Snapshot     : aliased Descriptor_Generation;
      State        : aliased Operation_State := Unregistered;
      FD           : Descriptor;
      Lease_Source : Descriptor;
      Close_Source : Descriptor;
   begin
      Item.Controller.Start_Operation
        (Snapshot'Access,
         State'Access,
         FD,
         Lease_Source,
         Close_Source);
      Item.Controller.Abandon_Operation (Snapshot, State'Access);
      return Interfaces.Unsigned_64 (Snapshot);
   end Generation;

   procedure Attempt_Stale_Acquisition
     (Item         : in out Connection;
      Snapshot     : Interfaces.Unsigned_64;
      Was_Replaced : out Boolean)
   is
      FD           : Descriptor;
      Actual       : aliased Descriptor_Generation;
      State        : aliased Operation_State := Unregistered;
      Lease_Source : Descriptor;
      Close_Source : Descriptor;
      Result       : Lease_Result;
   begin
      Item.Controller.Start_Operation
        (Actual'Access,
         State'Access,
         FD,
         Lease_Source,
         Close_Source);
      Item.Controller.Try_Acquire
        (Descriptor_Generation (Snapshot),
         State'Access,
         Result,
         FD,
         Close_Source);
      Was_Replaced := Result = Lease_Cancelled;
      case State is
         when Unregistered =>
            null;
         when Registered =>
            Item.Controller.Abandon_Operation (Actual, State'Access);
         when Acquired =>
            Item.Controller.Release (Actual, State'Access);
      end case;
   end Attempt_Stale_Acquisition;

   procedure Reset_Take_Barriers is
   begin
      Test_Hooks.Reset;
   end Reset_Take_Barriers;

   procedure Arm (Point : Take_Barrier_Point) is
   begin
      Test_Hooks.Arm (Take_Barrier_Point'Pos (Point));
   end Arm;

   procedure Wait_Reached (Point : Take_Barrier_Point) is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while not Test_Hooks.Reached (Take_Barrier_Point'Pos (Point)) loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "TLS take barrier was not reached";
         end if;
         delay 0.001;
      end loop;
   end Wait_Reached;

   procedure Release (Point : Take_Barrier_Point) is
   begin
      Test_Hooks.Release (Take_Barrier_Point'Pos (Point));
   end Release;

   procedure Check_Take_Barrier_State_Machine is
      type Invalid_Point_Array is
        array (Positive range <>) of Integer;
      First_Invalid : constant Integer := -1;
      Last_Invalid  : constant Integer := Take_Barrier_Point'Pos
        (Take_Barrier_Point'Last) + 1;
      Did_Arrive    : Boolean;
   begin
      --  Static C storage began zeroed before the first reset.
      Test_Hooks.Arrive (0, Did_Arrive);
      pragma Assert (not Did_Arrive);

      Test_Hooks.Reset;
      for Point in Take_Barrier_Point loop
         declare
            Position : constant Integer :=
              Take_Barrier_Point'Pos (Point);
         begin
            pragma Assert (not Test_Hooks.Reached (Position));
            pragma Assert (Test_Hooks.Released (Position));

            Test_Hooks.Arm (Position);
            pragma Assert (not Test_Hooks.Reached (Position));
            pragma Assert (not Test_Hooks.Released (Position));
            Test_Hooks.Arrive (Position, Did_Arrive);
            pragma Assert (Did_Arrive);
            pragma Assert (Test_Hooks.Reached (Position));
            pragma Assert (not Test_Hooks.Released (Position));

            Test_Hooks.Release (Position);
            pragma Assert (Test_Hooks.Released (Position));
            Test_Hooks.Arrive (Position, Did_Arrive);
            pragma Assert (not Did_Arrive);
            pragma Assert (Test_Hooks.Reached (Position));
         end;
      end loop;

      --  Every invalid operation is inert. Queries retain the C defaults:
      --  not reached, not arrived, and already released.
      for Point of Invalid_Point_Array'(First_Invalid, Last_Invalid) loop
         Test_Hooks.Arm (Point);
         Test_Hooks.Release (Point);
         Test_Hooks.Arrive (Point, Did_Arrive);
         pragma Assert (not Did_Arrive);
         pragma Assert (not Test_Hooks.Reached (Point));
         pragma Assert (Test_Hooks.Released (Point));
      end loop;
   end Check_Take_Barrier_State_Machine;

end Flyology.IO.TLS.Testing;
