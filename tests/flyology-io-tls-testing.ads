with Interfaces;

--  Exposes serialized TLS controller state to deterministic runtime tests.
--  Applications should not depend on this child package.
--  @exclude
package Flyology.IO.TLS.Testing is

   --  Snapshot the descriptor generation through the controller operation
   --  used by normal TLS calls.
   --  @param Item Connection to inspect
   --  @return Current generation encoded as an unsigned test value
   function Generation
     (Item : in out Connection) return Interfaces.Unsigned_64;

   --  Attempt to acquire Item using an earlier generation snapshot. The
   --  helper releases the gate if Snapshot unexpectedly remains current.
   --  @param Item Connection whose generation is tested
   --  @param Snapshot Earlier value returned by Generation
   --  @param Was_Replaced True when the controller rejects Snapshot
   procedure Attempt_Stale_Acquisition
     (Item         : in out Connection;
      Snapshot     : Interfaces.Unsigned_64;
      Was_Replaced : out Boolean);

   --  Points inside the Take ownership transfer where a test can park the
   --  calling task. The library only contains these barriers when it is
   --  compiled with FLYOLOGY_TLS_TEST_HOOKS.
   --  @enum Session_Created The provider session exists but nothing was
   --     transferred yet
   --  @enum Descriptor_Adopted The controller owns the descriptor but the
   --     session and socket were not transferred yet
   type Take_Barrier_Point is (Session_Created, Descriptor_Adopted);

   --  Disarm every Take barrier and clear its observations.
   procedure Reset_Take_Barriers;

   --  Park the next task that reaches Point until Release.
   --  @param Point Barrier to arm
   procedure Arm (Point : Take_Barrier_Point);

   --  Wait until a task parks at Point.
   --  @param Point Armed barrier to observe
   --  @exception Program_Error No task reached Point within two seconds
   procedure Wait_Reached (Point : Take_Barrier_Point);

   --  Release the task parked at Point and disarm the barrier.
   --  @param Point Barrier to release
   procedure Release (Point : Take_Barrier_Point);

end Flyology.IO.TLS.Testing;
