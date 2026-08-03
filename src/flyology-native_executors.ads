with Ada.Real_Time;
with Flyology.Cancellation;
with Flyology.Task_Scopes;

--  Instantiates a bounded structured task scope on explicit native tasks.
--  Use this boundary for CPU-heavy or blocking foreign work; a live
--  lightweight task never changes its own designation.
--  @formal Input_Type Immutable operation input
--  @formal Result_Type Operation result
--  @formal Execute Native child operation implementation
generic
   type Input_Type is private;
   type Result_Type is private;
   with procedure Execute
     (Input    : Input_Type;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Result   : out Result_Type);
package Flyology.Native_Executors is

   --  Structured scope whose children are fixed as native at activation.
   package Operations is new
     Flyology.Task_Scopes
       (Input_Type  => Input_Type,
        Result_Type => Result_Type,
        Execute     => Execute,
        Model       => Flyology.Native_Task);

end Flyology.Native_Executors;
