with Gnatevl;

procedure Lifecycle_Smoke is
   protected Results is
      procedure Finished (Passed : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Done : Boolean := False;
      OK   : Boolean := False;
   end Results;

   protected body Results is
      procedure Finished (Passed : Boolean) is
      begin
         OK := Passed;
         Done := True;
      end Finished;

      entry Wait when Done is
      begin
         null;
      end Wait;

      function Passed return Boolean is (OK);
   end Results;

   task Native_Master is
      pragma Task_Info (Gnatevl.Native_Thread);
   end Native_Master;

   task body Native_Master is
   begin
      for Round in 1 .. 200 loop
         declare
            task type Evented_Child;

            task body Evented_Child is
            begin
               delay 0.0;
            end Evented_Child;

            Children : array (1 .. 8) of Evented_Child;
            pragma Unreferenced (Children);
         begin
            null;
         end;
      end loop;
      Results.Finished (True);
   exception
      when others =>
         Results.Finished (False);
   end Native_Master;

begin
   Results.Wait;
   if not Results.Passed then
      raise Program_Error with
        "evented child lifecycle failed under a native master";
   end if;
end Lifecycle_Smoke;
