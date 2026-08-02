with Ada.Finalization;
with System.Multiprocessors;

package Flyology.Execution_Groups with Preelaborate is

   type Group_Id is range 0 .. 255;
   subtype Shared_Group_Id is Group_Id range 0 .. 127;
   subtype Dedicated_Group_Id is Group_Id range 128 .. Group_Id'Last;

   Default_Group : constant Shared_Group_Id := 0;

   subtype Loop_Pool_Size is Positive range 1 .. 128;
   type Automatic_Placement_Policy is (Round_Robin);

   --  Placement of the scheduler pthread is independent from placement of an
   --  Ada task into an execution group. Strict_CPU is a verifiable one-CPU
   --  mask on Linux. Advisory_Tag is Darwin's THREAD_AFFINITY_POLICY cache
   --  locality hint; it is not a physical-CPU request.
   type Loop_Thread_Placement is
     (No_Placement, Strict_CPU, Advisory_Tag);
   subtype Placement_Value is Natural range 0 .. 2_147_483_647;
   type Placement_Configuration_Result is
     (Configured,
      Unchanged,
      Unsupported,
      Invalid_Value,
      Group_Already_Started,
      Runtime_Unavailable);
   type Placement_State is
     (Not_Requested, Pending_Startup, Applied, Failed, Unavailable);
   type Placement_Status is record
      Kind       : Loop_Thread_Placement := No_Placement;
      Value      : Placement_Value := 0;
      State      : Placement_State := Not_Requested;
      Error_Code : Integer := 0;
   end record;

   No_Processor : constant Integer := -1;

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

   --  True for a lightweight task with at least one live Thread_Pin, and for a
   --  native task (which is inherently bound to its pthread).
   function Is_Thread_Pinned return Boolean;

   function For_CPU
     (CPU : System.Multiprocessors.CPU_Range) return Shared_Group_Id
   with Pre => Integer (CPU) <= Integer (Shared_Group_Id'Last),
        Post => Integer (For_CPU'Result) = Integer (CPU);

   function Current return Group_Id;

   --  These configuration queries are inert: they neither create an event
   --  loop nor change the next automatic placement.  A task designated for
   --  event-loop execution whose effective Ada CPU is Not_A_Specific_CPU is
   --  assigned to one of groups 0 .. Configured_Pool_Size - 1 according to
   --  Configured_Placement.  Current reports the task's actual group; an
   --  explicit or inherited CPU assignment continues to select that group.
   function Configured_Pool_Size return Loop_Pool_Size;
   function Configured_Placement return Automatic_Placement_Policy;
   function In_Configured_Pool (Group : Group_Id) return Boolean;

   --  Configure a scheduler pthread before Group starts. The same request is
   --  idempotent, including after startup; changing or clearing it after the
   --  group has entered lazy creation reports Group_Already_Started. A strict
   --  CPU value is a zero-based Linux OS logical-CPU id in the process
   --  leader's allowed affinity set. It is a separate namespace from an Ada
   --  CPU aspect, which selects a Flyology group. Advisory tags must be
   --  positive. No_Placement requires Value = 0.
   function Configure_Loop_Thread
     (Group : Group_Id;
      Kind  : Loop_Thread_Placement;
      Value : Placement_Value := 0) return Placement_Configuration_Result;

   --  These capability/value queries do not start a group. Value_Available
   --  may lazily snapshot Linux's inherited affinity allowance, but creates no
   --  pthread, poller, stack, or scheduler context.
   function Placement_Supported (Kind : Loop_Thread_Placement) return Boolean;
   function Placement_Value_Available
     (Kind  : Loop_Thread_Placement;
      Value : Placement_Value) return Boolean;
   function Loop_Thread_Status (Group : Group_Id) return Placement_Status;

   --  Return the calling pthread's current logical processor where the host
   --  provides a stable public query (Linux), otherwise No_Processor.
   function Current_Processor return Integer;

   --  Reserve an empty reusable group for the calling lightweight task.
   --  Migrating out consumes the reservation so the lane can be reused; call
   --  this again
   --  before re-entering a dedicated group (the same id is normally returned).
   function Create_Dedicated return Dedicated_Group_Id;

   function Is_Dedicated (Group : Group_Id) return Boolean;

   --  Migrate the calling lightweight task at this safe point. The procedure
   --  returns on Group's event-loop pthread. Migration to a different group
   --  raises Migration_Error while any Thread_Pin is live. Stock
   --  Native tasks cannot migrate because their stacks and lifecycle
   --  are owned by pthread/GNARL.
   procedure Migrate (Group : Group_Id);

private
   type Thread_Pin is new Ada.Finalization.Limited_Controlled with record
      Active : Boolean := False;
      Owner  : System.Address := System.Null_Address;
   end record;

   overriding procedure Finalize (Object : in out Thread_Pin);

end Flyology.Execution_Groups;
