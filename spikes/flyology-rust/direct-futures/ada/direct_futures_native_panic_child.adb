with Direct_Futures_Bridge;
with Flyology.Operations;

procedure Direct_Futures_Native_Panic_Child is
   Set      : aliased Flyology.Operations.Completion_Set (1);
   Item     : Direct_Futures_Bridge.Future_Operation (Set'Access);
   Value    : Long_Long_Integer;
   Panicked : Boolean := False;
begin
   Direct_Futures_Bridge.Start (Item, Direct_Futures_Bridge.Panic, 0, 0);
   Flyology.Operations.Wait_All (Set);
   begin
      Direct_Futures_Bridge.Finish (Item, Value);
   exception
      when Direct_Futures_Bridge.Rust_Future_Panic =>
         Panicked := True;
   end;
   if not Panicked then
      raise Program_Error with "Rust panic was not translated on the native environment task";
   end if;
end Direct_Futures_Native_Panic_Child;
