with Ada.Exceptions;
with Ada.Text_IO;
with Flyology;

procedure Exception_Traceback_Smoke is
   Marker_Error : exception;

   protected Results is
      procedure Report_Caught;
      procedure Report_Uncaught_Started;
      entry Wait_Caught;
      entry Wait_Uncaught_Started;
   private
      Caught            : Boolean := False;
      Uncaught_Started  : Boolean := False;
   end Results;

   protected body Results is
      procedure Report_Caught is
      begin
         Caught := True;
      end Report_Caught;

      procedure Report_Uncaught_Started is
      begin
         Uncaught_Started := True;
      end Report_Uncaught_Started;

      entry Wait_Caught when Caught is
      begin
         null;
      end Wait_Caught;

      entry Wait_Uncaught_Started when Uncaught_Started is
      begin
         null;
      end Wait_Uncaught_Started;
   end Results;

   procedure Raise_Marker (Depth : Natural) is
   begin
      if Depth = 0 then
         raise Marker_Error with "lightweight traceback marker";
      end if;
      Raise_Marker (Depth - 1);
   end Raise_Marker;
   pragma No_Inline (Raise_Marker);

   task Caught_Worker is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Caught_Worker;

   task body Caught_Worker is
      Saved : Ada.Exceptions.Exception_Occurrence;
   begin
      delay 0.0;
      begin
         begin
            Raise_Marker (3);
         exception
            when Error : Marker_Error =>
               pragma Assert
                 (Ada.Exceptions.Exception_Message (Error) =
                    "lightweight traceback marker");
               Ada.Exceptions.Save_Occurrence (Saved, Error);
         end;
         Ada.Exceptions.Reraise_Occurrence (Saved);
      exception
         when Error : Marker_Error =>
            pragma Assert
              (Ada.Exceptions.Exception_Message (Error) =
                 "lightweight traceback marker");
            Results.Report_Caught;
      end;
   end Caught_Worker;

begin
   Results.Wait_Caught;

   declare
      task Uncaught_Worker is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Uncaught_Worker;

      task body Uncaught_Worker is
      begin
         Results.Report_Uncaught_Started;
         delay 0.0;
         Raise_Marker (2);
      end Uncaught_Worker;
   begin
      Results.Wait_Uncaught_Started;
      for Attempt in 1 .. 1_000 loop
         exit when Uncaught_Worker'Terminated;
         delay 0.001;
      end loop;
      pragma Assert (Uncaught_Worker'Terminated);
   end;

   Ada.Text_IO.Put_Line
     ("lightweight symbolic traceback exception checks passed");
end Exception_Traceback_Smoke;
