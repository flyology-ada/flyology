with Ada.Strings;
with Ada.Strings.Fixed;
with Flyology.IO;

package body HTTP_CPU_Work is
   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_64;

   Check_Quantum : constant := 1_024;

   procedure Execute
     (Input    : Work_Input;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Result   : out Work_Result)
   is
      Value : Interfaces.Unsigned_64 := Input.Seed;
      Sum   : Interfaces.Unsigned_64 := 0;
   begin
      for Index in 1 .. Input.Iterations loop
         Value := Value xor Interfaces.Shift_Right (Value, 12);
         Value := Value xor Interfaces.Shift_Left (Value, 25);
         Value := Value xor Interfaces.Shift_Right (Value, 27);
         Value := Value * 16#2545_F491_4F6C_DD1D#;
         Sum := Sum + (Value xor Interfaces.Unsigned_64 (Index));
         if Index mod Check_Quantum = 0 then
            if Token /= null and then Token.Requested then
               raise Flyology.Cancellation.Operation_Cancelled;
            elsif Deadline /= Ada.Real_Time.Time_Last
              and then Ada.Real_Time.Clock >= Deadline
            then
               raise Flyology.IO.Timeout_Error with
                 "CPU benchmark workload deadline expired";
            end if;
         end if;
      end loop;
      Result :=
        (Iterations => Input.Iterations,
         Checksum   => Sum xor Value);
   end Execute;

   function Image (Item : Work_Result) return String is
      Iterations : constant String := Ada.Strings.Fixed.Trim
        (Natural'Image (Item.Iterations), Ada.Strings.Both);
      Checksum : constant String := Ada.Strings.Fixed.Trim
        (Interfaces.Unsigned_64'Image (Item.Checksum), Ada.Strings.Both);
   begin
      return "iterations=" & Iterations & " checksum=" & Checksum;
   end Image;

end HTTP_CPU_Work;
