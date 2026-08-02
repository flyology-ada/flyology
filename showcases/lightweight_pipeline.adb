with Ada.Text_IO;
with Flyology;
with Showcase_Support;

procedure Lightweight_Pipeline is
   use Ada.Text_IO;

   task Sink is
      pragma Task_Info (Flyology.Lightweight_Task);
      entry Put (Value : Positive);
      entry Finish;
   end Sink;

   task Transform is
      pragma Task_Info (Flyology.Lightweight_Task);
      entry Put (Value : Positive);
      entry Finish;
   end Transform;

   task Producer is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Producer;

   task body Sink is
   begin
      loop
         select
            accept Put (Value : Positive) do
               Put_Line
                 ("sink      value=" & Value'Image
                  & " thread=" & Showcase_Support.Thread_Image);
            end Put;
         or
            accept Finish;
            exit;
         end select;
      end loop;
   end Sink;

   task body Transform is
   begin
      loop
         select
            accept Put (Value : Positive) do
               Put_Line
                 ("transform value=" & Value'Image
                  & " thread=" & Showcase_Support.Thread_Image);
               Sink.Put (Value * Value);
            end Put;
         or
            accept Finish;
            Sink.Finish;
            exit;
         end select;
      end loop;
   end Transform;

   task body Producer is
   begin
      for Value in 1 .. 5 loop
         Put_Line
           ("producer  value=" & Value'Image
            & " thread=" & Showcase_Support.Thread_Image);
         Transform.Put (Value);
         delay 0.010;
      end loop;
      Transform.Finish;
   end Producer;

begin
   Put_Line
     ("lightweight pipeline; environment thread="
      & Showcase_Support.Thread_Image);
end Lightweight_Pipeline;
