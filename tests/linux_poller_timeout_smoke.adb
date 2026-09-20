with Ada.Command_Line;
with Ada.Real_Time;
with Interfaces.C;
with System.Flyology.Poller;
with System.Flyology.Time_ABI;

procedure Linux_Poller_Timeout_Smoke is
   package Pollers renames System.Flyology.Poller;
   package Clock renames Ada.Real_Time;
   package C renames Interfaces.C;

   use type Clock.Time;
   use type Clock.Time_Span;
   use type C.int;
   use type C.long;
   use type C.long_long;

   function Block_Epoll_Pwait2 return C.int;
   pragma Import (C, Block_Epoll_Pwait2, "flyology_test_block_epoll_pwait2");

   function Epoll_Pwait2_Available return C.int;
   pragma
     Import
       (C, Epoll_Pwait2_Available, "flyology_test_epoll_pwait2_available");

   function Block_Epoll_Wait return C.int;
   pragma Import (C, Block_Epoll_Wait, "flyology_test_block_epoll_wait");

   Poller     : Pollers.Poller;
   Events     : Pollers.Poll_Event_Array (1 .. 2);
   One_Event  : Pollers.Poll_Event_Array (1 .. 1);
   Count      : Natural;
   Started    : Clock.Time;
   Elapsed    : Clock.Time_Span;
   Legacy_Min : constant Clock.Time_Span := Clock.Microseconds (800);
   Available  : C.int;

   procedure Check_Wait
     (Legacy        : Boolean;
      Single_Result : Boolean := False;
      Timeout       : Duration := 0.000_2) is
   begin
      Started := Clock.Clock;
      if Single_Result then
         if not Pollers.Wait_Batch (Poller, Timeout, One_Event, Count) then
            raise Program_Error with "one-result poller timeout wait failed";
         end if;
      elsif not Pollers.Wait_Batch (Poller, Timeout, Events, Count) then
         raise Program_Error with "poller timeout wait failed";
      end if;
      Elapsed := Clock.Clock - Started;
      if Count /= 0 or else Elapsed < Clock.To_Time_Span (Timeout) then
         raise Program_Error
           with "poller timed out before its requested deadline";
      end if;
      if Legacy and then Elapsed < Legacy_Min then
         raise Program_Error with "ENOSYS fallback lost millisecond ceiling";
      end if;
   end Check_Wait;
begin
   if Ada.Command_Line.Argument_Count /= 1 then
      raise Program_Error with "expected high-resolution or fallback mode";
   end if;
   declare
      Limit : constant System.Flyology.Time_ABI.Timespec :=
        System.Flyology.Time_ABI.To_Timespec (0.000_05);
   begin
      if C.long_long (Limit.tv_sec) /= 0
        or else C.long_long (Limit.tv_nsec) /= 50_000
      then
         raise Program_Error with "timespec conversion lost 50 microseconds";
      end if;
   end;
   if not Pollers.Initialize (Poller) then
      raise Program_Error with "poller initialization failed";
   end if;

   Available := Epoll_Pwait2_Available;
   if Available < 0 then
      raise Program_Error with "could not probe epoll_pwait2 availability";
   end if;

   --  The first path blocks directly; the one-result path performs a file
   --  probe first. Run each in both syscall modes, in separate processes.
   if Ada.Command_Line.Argument (1) = "high-resolution" then
      if Available = 1 then
         if Block_Epoll_Wait /= 0 then
            raise Program_Error with "could not reject legacy epoll_wait";
         end if;
         Check_Wait (Legacy => False, Timeout => 0.000_05);
         Check_Wait
           (Legacy => False, Single_Result => True, Timeout => 0.000_05);
      end if;
   elsif Ada.Command_Line.Argument (1) = "fallback" then
      if Block_Epoll_Pwait2 /= 0 then
         raise Program_Error
           with "could not install epoll_pwait2 ENOSYS filter";
      end if;
      Check_Wait (Legacy => True);
      Check_Wait (Legacy => True, Single_Result => True);
   else
      raise Program_Error with "unknown poller timeout test mode";
   end if;
   Pollers.Finalize (Poller);
end Linux_Poller_Timeout_Smoke;
