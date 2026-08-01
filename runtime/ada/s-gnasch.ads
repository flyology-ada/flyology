with Interfaces.C;

package System.Gnatevl.Scheduler is
   pragma Preelaborate;

   function Initialize (Environment : System.Address) return Interfaces.C.int;

   function Create
     (T          : System.Address;
      Stack_Size : Interfaces.C.size_t;
      Priority   : Interfaces.C.int;
      Wrapper    : System.Address) return Interfaces.C.int;

   function Is_Event_Task (T : System.Address) return Interfaces.C.int;
   function Current_Task return System.Address;

   function Sleep
     (Task_Lock : System.Address;
      Deadline  : Duration;
      Timed_Out : access Interfaces.C.int) return Interfaces.C.int;

   function Wake (T : System.Address) return Interfaces.C.int;
   function Yield return Interfaces.C.int;

   function Set_Priority
     (T : System.Address; Priority : Interfaces.C.int)
      return Interfaces.C.int;

   function Destroy (T : System.Address) return Interfaces.C.int;

private
   pragma Inline (Is_Event_Task);
   pragma Inline (Current_Task);
end System.Gnatevl.Scheduler;
