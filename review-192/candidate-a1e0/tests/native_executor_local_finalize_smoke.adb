with Ada.Real_Time;
with Ada.Text_IO;
with Flyology.Cancellation;
with Flyology.Native_Executors;

procedure Native_Executor_Local_Finalize_Smoke is

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

   Item     : aliased Executors.Executor (Workers => 1, Capacity => 2);
   Handle   : Executors.Operation_Handle (Item'Access);
   Accepted : Boolean;
   Result   : Integer;

begin
   Executors.Start (Item);
   Executors.Submit
     (Item, 21, null, Ada.Real_Time.Time_Last, Handle, Accepted);
   if not Accepted then
      raise Program_Error
        with "main-declarative native executor rejected work";
   end if;
   Executors.Await (Item, Handle, Result);
   if Result /= 42 then
      raise Program_Error
        with "main-declarative native executor returned the wrong result";
   end if;
   Ada.Text_IO.Put_Line ("native executor local finalization: main returned");
end Native_Executor_Local_Finalize_Smoke;
