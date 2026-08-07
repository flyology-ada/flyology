with Ada.Real_Time;
with Interfaces.C;

package body Flyology.IO.TLS.Testing is

   use type Ada.Real_Time.Time;
   use type Interfaces.C.int;

   procedure C_Reset
     with Import,
          Convention => C,
          External_Name => "flyology_test_tls_barrier_reset";
   procedure C_Arm (Point : Interfaces.C.int)
     with Import,
          Convention => C,
          External_Name => "flyology_test_tls_barrier_arm";
   function C_Reached (Point : Interfaces.C.int) return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_tls_barrier_reached";
   procedure C_Release (Point : Interfaces.C.int)
     with Import,
          Convention => C,
          External_Name => "flyology_test_tls_barrier_release";

   function Generation
     (Item : in out Connection) return Interfaces.Unsigned_64
   is
      State    : Acquire_Result;
      Snapshot : Descriptor_Generation;
   begin
      Item.Controller.Snapshot_Acquisition (State, Snapshot);
      return Interfaces.Unsigned_64 (Snapshot);
   end Generation;

   procedure Attempt_Stale_Acquisition
     (Item         : in out Connection;
      Snapshot     : Interfaces.Unsigned_64;
      Was_Replaced : out Boolean)
   is
      FD           : Descriptor;
      Actual       : aliased Descriptor_Generation;
      Armed        : aliased Boolean := False;
      Close_Source : Descriptor;
      Result       : Acquire_Result;
   begin
      Item.Controller.Acquire
        (Descriptor_Generation (Snapshot),
         FD,
         Actual'Access,
         Armed'Access,
         Close_Source,
         Result);
      Was_Replaced := Result = Replaced;
      if Armed then
         Item.Controller.Release (Actual);
      end if;
   end Attempt_Stale_Acquisition;

   procedure Reset_Take_Barriers is
   begin
      C_Reset;
   end Reset_Take_Barriers;

   procedure Arm (Point : Take_Barrier_Point) is
   begin
      C_Arm (Take_Barrier_Point'Pos (Point));
   end Arm;

   procedure Wait_Reached (Point : Take_Barrier_Point) is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while C_Reached (Take_Barrier_Point'Pos (Point)) = 0 loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "TLS take barrier was not reached";
         end if;
         delay 0.001;
      end loop;
   end Wait_Reached;

   procedure Release (Point : Take_Barrier_Point) is
   begin
      C_Release (Take_Barrier_Point'Pos (Point));
   end Release;

end Flyology.IO.TLS.Testing;
