with Ada.Text_IO;
with Gnatevl;
with Showcase_Support;

procedure Hybrid_Blocking_Bridge is
   use Ada.Text_IO;

   task Inbox is
      entry Deliver (Value : Integer);
   end Inbox;

   task Ticker;

   task Blocking_Worker is
      pragma Task_Info (Gnatevl.Native_Thread);
   end Blocking_Worker;

   task body Inbox is
   begin
      accept Deliver (Value : Integer) do
         Put_Line
           ("evented inbox received" & Value'Image
            & " on thread=" & Showcase_Support.Thread_Image);
      end Deliver;
   end Inbox;

   task body Ticker is
   begin
      for Tick in 1 .. 5 loop
         delay 0.015;
         Put_Line
           ("event-loop tick" & Tick'Image
            & " on thread=" & Showcase_Support.Thread_Image);
      end loop;
   end Ticker;

   task body Blocking_Worker is
   begin
      Put_Line
        ("native worker started on thread="
         & Showcase_Support.Thread_Image);

      --  Stand-in for a blocking driver or foreign library call. This task
      --  owns a pthread, so the event-loop tasks continue to make progress.
      delay 0.050;
      Inbox.Deliver (42);
      Put_Line
        ("native worker rendezvous completed on thread="
         & Showcase_Support.Thread_Image);
   end Blocking_Worker;

begin
   Put_Line
     ("hybrid bridge; environment thread="
      & Showcase_Support.Thread_Image);
end Hybrid_Blocking_Bridge;
