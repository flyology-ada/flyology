with Ada.Task_Identification;
with Flyology;
with Flyology.IO;
with GNAT.Threads;

package body Rust_Ingress_Probe is

   use type Ada.Task_Identification.Task_Id;
   use type Interfaces.C.int;
   use type System.Address;

   protected Metrics is
      procedure Enter;
      procedure Leave (Passed : Boolean);
      procedure Record_Activation_Observation (Incomplete : Boolean);
      function Completed return Interfaces.C.int;
      function Maximum_Concurrent return Interfaces.C.int;
      function Failures return Interfaces.C.int;
      function Activation_Incomplete return Interfaces.C.int;
   private
      Active_Count     : Interfaces.C.int := 0;
      Completed_Count  : Interfaces.C.int := 0;
      Maximum_Count    : Interfaces.C.int := 0;
      Failure_Count    : Interfaces.C.int := 0;
      Incomplete_Count : Interfaces.C.int := 0;
   end Metrics;

   protected body Metrics is
      procedure Enter is
      begin
         Active_Count := Active_Count + 1;
         if Active_Count > Maximum_Count then
            Maximum_Count := Active_Count;
         end if;
      end Enter;

      procedure Leave (Passed : Boolean) is
      begin
         Active_Count := Active_Count - 1;
         Completed_Count := Completed_Count + 1;
         if not Passed then
            Failure_Count := Failure_Count + 1;
         end if;
      end Leave;

      procedure Record_Activation_Observation (Incomplete : Boolean) is
      begin
         if Incomplete then
            Incomplete_Count := Incomplete_Count + 1;
         end if;
      end Record_Activation_Observation;

      function Completed return Interfaces.C.int
      is (Completed_Count);

      function Maximum_Concurrent return Interfaces.C.int
      is (Maximum_Count);

      function Failures return Interfaces.C.int
      is (Failure_Count);

      function Activation_Incomplete return Interfaces.C.int
      is (Incomplete_Count);
   end Metrics;

   function Run
     (Registered_Id : System.Address;
      Caller_Id     : Interfaces.C.int;
      Iteration     : Interfaces.C.int) return Interfaces.C.int
   is
      pragma Unreferenced (Caller_Id, Iteration);

      Caller  : constant Ada.Task_Identification.Task_Id :=
        Ada.Task_Identification.Current_Task;
      Entered : Boolean := False;
      Stage   : Interfaces.C.int := 0;
      Outcome : Interfaces.C.int;

      protected Results is
         procedure Record_Native (Identity_OK, Lane_OK : Boolean);
         procedure Record_Native_Exception;
         procedure Record_Lightweight (Identity_OK, Lane_OK : Boolean);
         procedure Record_Lightweight_Exception;
         entry Wait_All;
         function Status return Interfaces.C.int;
      private
         Native_Seen           : Boolean := False;
         Native_Identity       : Boolean := False;
         Native_Lane           : Boolean := False;
         Native_Exception      : Boolean := False;
         Lightweight_Seen      : Boolean := False;
         Lightweight_Identity  : Boolean := False;
         Lightweight_Lane      : Boolean := False;
         Lightweight_Exception : Boolean := False;
      end Results;

      protected body Results is
         procedure Record_Native (Identity_OK, Lane_OK : Boolean) is
         begin
            Native_Seen := True;
            Native_Identity := Identity_OK;
            Native_Lane := Lane_OK;
         end Record_Native;

         procedure Record_Native_Exception is
         begin
            Native_Exception := True;
         end Record_Native_Exception;

         procedure Record_Lightweight (Identity_OK, Lane_OK : Boolean) is
         begin
            Lightweight_Seen := True;
            Lightweight_Identity := Identity_OK;
            Lightweight_Lane := Lane_OK;
         end Record_Lightweight;

         procedure Record_Lightweight_Exception is
         begin
            Lightweight_Exception := True;
         end Record_Lightweight_Exception;

         entry Wait_All
           when(Native_Seen or Native_Exception)
           and then (Lightweight_Seen or Lightweight_Exception)
         is
         begin
            null;
         end Wait_All;

         function Status return Interfaces.C.int
         is (if Native_Exception
             then 20
             elsif not Native_Seen
             then 21
             elsif not Native_Identity
             then 22
             elsif not Native_Lane
             then 23
             elsif Lightweight_Exception
             then 30
             elsif not Lightweight_Seen
             then 31
             elsif not Lightweight_Identity
             then 32
             elsif not Lightweight_Lane
             then 33
             else 0);
      end Results;

      task type Native_Worker is
         pragma Task_Info (Flyology.Native_Task);
      end Native_Worker;

      task body Native_Worker is
         Identity : constant Ada.Task_Identification.Task_Id :=
           Ada.Task_Identification.Current_Task;
      begin
         delay 0.0;
         Results.Record_Native
           (Identity_OK =>
              Identity /= Ada.Task_Identification.Null_Task_Id
              and then Identity /= Caller,
            Lane_OK     => not Flyology.IO.Is_Lightweight_Task);
      exception
         when others =>
            Results.Record_Native_Exception;
      end Native_Worker;

      task type Lightweight_Worker is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Lightweight_Worker;

      task body Lightweight_Worker is
         Identity : constant Ada.Task_Identification.Task_Id :=
           Ada.Task_Identification.Current_Task;
      begin
         delay 0.0;
         Results.Record_Lightweight
           (Identity_OK =>
              Identity /= Ada.Task_Identification.Null_Task_Id
              and then Identity /= Caller,
            Lane_OK     => Flyology.IO.Is_Lightweight_Task);
      exception
         when others =>
            Results.Record_Lightweight_Exception;
      end Lightweight_Worker;

   begin
      if Registered_Id = System.Null_Address then
         return 10;
      end if;
      if Caller = Ada.Task_Identification.Null_Task_Id then
         return 11;
      end if;
      if GNAT.Threads.To_Task_Id (Registered_Id) /= Caller then
         return 12;
      end if;

      Metrics.Enter;
      Entered := True;
      Stage := 1;

      if Flyology.IO.Is_Lightweight_Task then
         Metrics.Leave (Passed => False);
         return 13;
      end if;

      --  Hold several foreign entries open together before their local task
      --  masters join both children.
      delay 0.002;
      Stage := 2;
      declare
         Native      : Native_Worker;
         Lightweight : Lightweight_Worker;
         pragma Unreferenced (Native, Lightweight);
      begin
         --  Activation starts both task bodies, but does not imply that either
         --  body has published its observation. Preserve that failed
         --  assumption as a counted diagnostic before explicitly waiting.
         Metrics.Record_Activation_Observation (Results.Status /= 0);
         Results.Wait_All;
      end;
      Stage := 3;

      Outcome := Results.Status;
      Metrics.Leave (Passed => Outcome = 0);
      Entered := False;
      return Outcome;
   exception
      when others =>
         if Entered then
            Metrics.Leave (Passed => False);
         end if;
         --  No Ada exception may cross the C ABI into Rust.
         return 100 + Stage;
   end Run;

   function Completed return Interfaces.C.int
   is (Metrics.Completed);

   function Maximum_Concurrent return Interfaces.C.int
   is (Metrics.Maximum_Concurrent);

   function Failures return Interfaces.C.int
   is (Metrics.Failures);

   function Activation_Incomplete return Interfaces.C.int
   is (Metrics.Activation_Incomplete);

end Rust_Ingress_Probe;
