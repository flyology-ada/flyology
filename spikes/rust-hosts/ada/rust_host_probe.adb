with Ada.Task_Identification;
with Flyology;
with Flyology.IO;
with Flyology.Process_Lifecycle;
with GNAT.Threads;
with System;

package body Rust_Host_Probe is

   use type Ada.Task_Identification.Task_Id;
   use type Flyology.Process_Lifecycle.Event_Runtime_State;
   use type System.Address;

   protected type Observations is
      procedure Record_Caller (Identity_OK : Boolean);
      procedure Record_Native (Identity_OK, Lane_OK : Boolean);
      procedure Record_Lightweight (Identity_OK, Lane_OK : Boolean);
      function Passed return Boolean;
   private
      Caller_Seen      : Boolean := False;
      Native_Seen      : Boolean := False;
      Lightweight_Seen : Boolean := False;
      All_OK           : Boolean := True;
   end Observations;

   protected body Observations is
      procedure Record_Caller (Identity_OK : Boolean) is
      begin
         Caller_Seen := True;
         All_OK := All_OK and Identity_OK;
      end Record_Caller;

      procedure Record_Native (Identity_OK, Lane_OK : Boolean) is
      begin
         Native_Seen := True;
         All_OK := All_OK and Identity_OK and Lane_OK;
      end Record_Native;

      procedure Record_Lightweight (Identity_OK, Lane_OK : Boolean) is
      begin
         Lightweight_Seen := True;
         All_OK := All_OK and Identity_OK and Lane_OK;
      end Record_Lightweight;

      function Passed return Boolean
      is (Caller_Seen and Native_Seen and Lightweight_Seen and All_OK);
   end Observations;

   function Run return Interfaces.C.int is
      Caller  : constant Ada.Task_Identification.Task_Id :=
        Ada.Task_Identification.Current_Task;
      Results : Observations;

      task type Native_Worker is
         pragma Task_Info (Flyology.Native_Task);
      end Native_Worker;

      task body Native_Worker is
         Identity : constant Ada.Task_Identification.Task_Id :=
           Ada.Task_Identification.Current_Task;
      begin
         Results.Record_Native
           (Identity_OK =>
              Identity /= Ada.Task_Identification.Null_Task_Id
              and then Identity /= Caller,
            Lane_OK     => not Flyology.IO.Is_Lightweight_Task);
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
      end Lightweight_Worker;

   begin
      Results.Record_Caller (Caller /= Ada.Task_Identification.Null_Task_Id);

      declare
         Native      : Native_Worker;
         Lightweight : Lightweight_Worker;
         pragma Unreferenced (Native, Lightweight);
      begin
         null;
      end;

      if not Results.Passed then
         return 1;
      end if;
      if GNAT.Threads.Register_Thread'Address = System.Null_Address then
         return 2;
      end if;
      if Flyology.Process_Lifecycle.State /= Flyology.Process_Lifecycle.Running
      then
         return 3;
      end if;
      if Flyology.Process_Lifecycle.Created_Groups = 0 then
         return 4;
      end if;
      return 0;
   exception
      when others =>
         --  No Ada exception may cross the C ABI into Rust.
         return 100;
   end Run;

end Rust_Host_Probe;
