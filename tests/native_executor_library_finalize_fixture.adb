with Ada.Real_Time;
with Flyology.Cancellation;
with Flyology.Native_Executors;

package body Native_Executor_Library_Finalize_Fixture is

   procedure Work
     (Input    : Integer;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Result   : out Integer)
   is
      pragma Unreferenced (Token, Deadline);
   begin
      Result := Input * 2;
   end Work;

   package Executors is new Flyology.Native_Executors (Integer, Integer, Work);

   Item : aliased Executors.Executor (Workers => 1, Capacity => 2);

   procedure Exercise is
      Handle   : Executors.Operation_Handle (Item'Access);
      Accepted : Boolean;
      Result   : Integer;
   begin
      Executors.Start (Item);
      Executors.Submit
        (Item, 21, null, Ada.Real_Time.Time_Last, Handle, Accepted);
      if not Accepted then
         raise Program_Error
           with "library-level native executor rejected work";
      end if;
      Executors.Await (Item, Handle, Result);
      if Result /= 42 then
         raise Program_Error
           with "library-level native executor returned the wrong result";
      end if;
   end Exercise;

end Native_Executor_Library_Finalize_Fixture;
