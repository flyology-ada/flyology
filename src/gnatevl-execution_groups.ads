with Ada.Finalization;
with System.Multiprocessors;

package Gnatevl.Execution_Groups with Preelaborate is

   type Group_Id is range 0 .. 255;
   subtype Shared_Group_Id is Group_Id range 0 .. 127;
   subtype Dedicated_Group_Id is Group_Id range 128 .. Group_Id'Last;

   Default_Group : constant Shared_Group_Id := 0;

   Group_Error     : exception;
   Migration_Error : exception;

   --  A Thread_Pin keeps the calling Ada task on its current OS pthread for
   --  the lifetime of the object. Declare and finalize the object in the task
   --  that calls Pin_To_Current_Thread; a pin is task-owned and must not be
   --  transferred to another task. Pins nest: every object releases exactly
   --  one level when its scope is finalized. Native tasks accept pins as
   --  no-ops because their pthread identity is already permanent.
   type Thread_Pin is limited private;

   function Pin_To_Current_Thread return Thread_Pin;

   --  True for an evented task with at least one live Thread_Pin, and for a
   --  native task (which is inherently bound to its pthread).
   function Is_Thread_Pinned return Boolean;

   function For_CPU
     (CPU : System.Multiprocessors.CPU_Range) return Shared_Group_Id
   with Pre => Integer (CPU) <= Integer (Shared_Group_Id'Last),
        Post => Integer (For_CPU'Result) = Integer (CPU);

   function Current return Group_Id;

   --  Reserve an empty reusable group for the calling evented task. Migrating
   --  out consumes the reservation so the lane can be reused; call this again
   --  before re-entering a dedicated group (the same id is normally returned).
   function Create_Dedicated return Dedicated_Group_Id;

   function Is_Dedicated (Group : Group_Id) return Boolean;

   --  Migrate the calling evented task at this safe point. The procedure
   --  returns on Group's event-loop pthread. Migration to a different group
   --  raises Migration_Error while any Thread_Pin is live. Stock
   --  Native_Thread tasks cannot migrate because their stacks and lifecycle
   --  are owned by pthread/GNARL.
   procedure Migrate (Group : Group_Id);

private
   type Thread_Pin is new Ada.Finalization.Limited_Controlled with record
      Active : Boolean := False;
      Owner  : System.Address := System.Null_Address;
   end record;

   overriding procedure Finalize (Object : in out Thread_Pin);

end Gnatevl.Execution_Groups;
