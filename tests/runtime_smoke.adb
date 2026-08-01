with Ada.Real_Time;
with Gnatevl;
with System;

procedure Runtime_Smoke is

   use Ada.Real_Time;
   use type System.Address;

   function Current_Thread return System.Address;
   pragma Import (C, Current_Thread, "pthread_self");

   Environment_Thread : constant System.Address := Current_Thread;

   protected Results is
      procedure Event_Ran (On_Thread : System.Address);
      procedure Native_Ran (On_Thread : System.Address);
      procedure Rendezvous_Completed (Delay_Was_Correct : Boolean);
      entry Await_Complete;
      function Passed return Boolean;
   private
      Event_Reported            : Boolean := False;
      Native_Reported           : Boolean := False;
      Event_Was_On_Environment : Boolean := False;
      Native_Was_Separate      : Boolean := False;
      Rendezvous_Was_Completed : Boolean := False;
      Event_Delay_Was_Correct  : Boolean := False;
   end Results;

   protected body Results is
      procedure Event_Ran (On_Thread : System.Address) is
      begin
         Event_Reported := True;
         Event_Was_On_Environment := On_Thread = Environment_Thread;
      end Event_Ran;

      procedure Native_Ran (On_Thread : System.Address) is
      begin
         Native_Reported := True;
         Native_Was_Separate := On_Thread /= Environment_Thread;
      end Native_Ran;

      procedure Rendezvous_Completed (Delay_Was_Correct : Boolean) is
      begin
         Rendezvous_Was_Completed := True;
         Event_Delay_Was_Correct := Delay_Was_Correct;
      end Rendezvous_Completed;

      entry Await_Complete
        when Event_Reported
          and Native_Reported
          and Rendezvous_Was_Completed
      is
      begin
         null;
      end Await_Complete;

      function Passed return Boolean is
        (Event_Was_On_Environment
         and Native_Was_Separate
         and Rendezvous_Was_Completed
         and Event_Delay_Was_Correct);
   end Results;

   task Evented is
      entry Called_From_Native;
   end Evented;

   task body Evented is
      Started : Time;
   begin
      Results.Event_Ran (Current_Thread);
      accept Called_From_Native;
      Started := Clock;
      delay 0.020;
      Results.Rendezvous_Completed
        (To_Duration (Clock - Started) >= 0.019);
   end Evented;

   task Native is
      pragma Task_Info (Gnatevl.Native_Thread);
   end Native;

   task body Native is
   begin
      Results.Native_Ran (Current_Thread);
      delay 0.005;
      Evented.Called_From_Native;
   end Native;

begin
   Results.Await_Complete;

   if not Results.Passed then
      raise Program_Error with "hybrid tasking observations failed";
   end if;
end Runtime_Smoke;
