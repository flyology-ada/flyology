with Ada.Real_Time;
with Flyology.Cancellation;
with Interfaces;

--  Deterministic allocation-free CPU workload shared by HTTP benchmark lanes.
package HTTP_CPU_Work is

   type Work_Input is record
      Iterations : Natural := 0;
      Seed       : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
   end record;

   type Work_Result is record
      Iterations : Natural := 0;
      Checksum   : Interfaces.Unsigned_64 := 0;
   end record;

   procedure Execute
     (Input    : Work_Input;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Result   : out Work_Result);

   function Image (Item : Work_Result) return String;

end HTTP_CPU_Work;
