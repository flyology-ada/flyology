with Direct_Futures_Bridge;
with Flyology;
with Flyology.Operations;

procedure Direct_Futures_Panic_Child is
   protected State is
      procedure Report;
      entry Await_Result;
   private
      Done : Boolean := False;
   end State;

   protected body State is
      procedure Report is
      begin
         Done := True;
      end Report;

      entry Await_Result when Done is
      begin
         null;
      end Await_Result;
   end State;

   task Runner
     with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Runner;

   task body Runner is
      Set   : aliased Flyology.Operations.Completion_Set (1);
      Item  : Direct_Futures_Bridge.Future_Operation (Set'Access);
      Value : Long_Long_Integer;
   begin
      Direct_Futures_Bridge.Start (Item, Direct_Futures_Bridge.Panic, 0, 0);
      Flyology.Operations.Wait_All (Set);
      begin
         Direct_Futures_Bridge.Finish (Item, Value);
      exception
         when Direct_Futures_Bridge.Rust_Future_Panic =>
            null;
      end;
      State.Report;
   end Runner;

   pragma Unreferenced (Runner);
begin
   State.Await_Result;
end Direct_Futures_Panic_Child;
