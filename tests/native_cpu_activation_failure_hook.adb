with Interfaces.C;
with System;

package body Native_CPU_Activation_Failure_Hook is

   --  The test main's linker switch redirects GNARL's pthread_create calls
   --  through this wrapper and makes the first one reproduce the affinity
   --  rejection that exposed the checked-runtime deadlock.

   function Real_Pthread_Create
     (Thread        : System.Address;
      Attributes    : System.Address;
      Start_Routine : System.Address;
      Argument      : System.Address) return Interfaces.C.int
   with Import, Convention => C, External_Name => "__real_pthread_create";

   Reject_Next : Boolean := False;

   procedure Arm is
   begin
      Reject_Next := True;
   end Arm;

   function Wrapped_Pthread_Create
     (Thread        : System.Address;
      Attributes    : System.Address;
      Start_Routine : System.Address;
      Argument      : System.Address) return Interfaces.C.int
   with Export, Convention => C, External_Name => "__wrap_pthread_create";

   function Wrapped_Pthread_Create
     (Thread        : System.Address;
      Attributes    : System.Address;
      Start_Routine : System.Address;
      Argument      : System.Address) return Interfaces.C.int
   is
      Invalid_Argument : constant Interfaces.C.int := 22;
   begin
      if Reject_Next then
         Reject_Next := False;
         return Invalid_Argument;
      end if;

      return Real_Pthread_Create (Thread, Attributes, Start_Routine, Argument);
   end Wrapped_Pthread_Create;

end Native_CPU_Activation_Failure_Hook;
