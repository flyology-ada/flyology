with Gnatevl;
with Gnatevl.Execution_Groups;
with Interfaces.C.Extensions;
with System;

procedure Thread_Affinity_Smoke is
   package Groups renames Gnatevl.Execution_Groups;
   package C_Ext renames Interfaces.C.Extensions;

   use type C_Ext.unsigned_long_long;
   use type Groups.Group_Id;
   use type System.Address;

   Group_One_Value : constant C_Ext.unsigned_long_long := 101;
   Group_Two_Value : constant C_Ext.unsigned_long_long := 202;
   Dedicated_Value : constant C_Ext.unsigned_long_long := 303;
   Native_Value    : constant C_Ext.unsigned_long_long := 404;

   Cleanup_Test : exception;

   function Current_Thread return System.Address;
   pragma Import (C, Current_Thread, "pthread_self");

   function TLS_Get return C_Ext.unsigned_long_long;
   pragma Import (C, TLS_Get, "gnatevl_test_tls_get");

   procedure TLS_Set (Value : C_Ext.unsigned_long_long);
   pragma Import (C, TLS_Set, "gnatevl_test_tls_set");

   protected Observations is
      procedure Group_One_Seeded (Thread : System.Address);
      procedure Group_Two_Seeded (Thread : System.Address);
      entry Wait_For_Seeds
        (One : out System.Address; Two : out System.Address);
      procedure Finished (Passed : Boolean);
      entry Wait_For_Results;
      function Passed return Boolean;
   private
      Seed_Count   : Natural := 0;
      Finish_Count : Natural := 0;
      One_Thread   : System.Address := System.Null_Address;
      Two_Thread   : System.Address := System.Null_Address;
      OK           : Boolean := True;
   end Observations;

   protected body Observations is
      procedure Group_One_Seeded (Thread : System.Address) is
      begin
         One_Thread := Thread;
         Seed_Count := Seed_Count + 1;
      end Group_One_Seeded;

      procedure Group_Two_Seeded (Thread : System.Address) is
      begin
         Two_Thread := Thread;
         Seed_Count := Seed_Count + 1;
      end Group_Two_Seeded;

      entry Wait_For_Seeds
        (One : out System.Address; Two : out System.Address)
        when Seed_Count = 2
      is
      begin
         One := One_Thread;
         Two := Two_Thread;
      end Wait_For_Seeds;

      procedure Finished (Passed : Boolean) is
      begin
         Finish_Count := Finish_Count + 1;
         OK := OK and Passed;
      end Finished;

      entry Wait_For_Results when Finish_Count = 3 is
      begin
         null;
      end Wait_For_Results;

      function Passed return Boolean is (OK);
   end Observations;

   task Group_One_Seeder with CPU => 11 is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Group_One_Seeder;

   task Group_One_Observer with CPU => 11 is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Group_One_Observer;

   task Group_Two_Seeder with CPU => 12 is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Group_Two_Seeder;

   task Migrator with CPU => 11 is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Migrator;

   task Native is
      pragma Task_Info (Gnatevl.Native_Thread);
   end Native;

   task body Group_One_Seeder is
   begin
      TLS_Set (Group_One_Value);
      Observations.Group_One_Seeded (Current_Thread);
   end Group_One_Seeder;

   task body Group_Two_Seeder is
   begin
      TLS_Set (Group_Two_Value);
      Observations.Group_Two_Seeded (Current_Thread);
   end Group_Two_Seeder;

   task body Group_One_Observer is
      One : System.Address;
      Two : System.Address;
   begin
      Observations.Wait_For_Seeds (One, Two);
      Observations.Finished
        (Current_Thread = One
         and then One /= Two
         and then TLS_Get = Group_One_Value);
   exception
      when others =>
         Observations.Finished (False);
   end Group_One_Observer;

   task body Migrator is
      One              : System.Address;
      Two              : System.Address;
      Before_Yield     : System.Address;
      Dedicated        : Groups.Dedicated_Group_Id;
      Dedicated_Thread : System.Address;
      Rejected         : Boolean := False;
      OK               : Boolean := True;
   begin
      Observations.Wait_For_Seeds (One, Two);
      Before_Yield := Current_Thread;
      delay 0.0;
      OK :=
        OK
        and then Current_Thread = Before_Yield
        and then Current_Thread = One
        and then TLS_Get = Group_One_Value;

      Groups.Migrate (12);
      OK :=
        OK
        and then Groups.Current = 12
        and then Current_Thread = Two
        and then Current_Thread /= One
        and then TLS_Get = Group_Two_Value;

      declare
         Outer : Groups.Thread_Pin := Groups.Pin_To_Current_Thread;
         pragma Unreferenced (Outer);
      begin
         OK := OK and then Groups.Is_Thread_Pinned;
         declare
            Inner : Groups.Thread_Pin := Groups.Pin_To_Current_Thread;
            pragma Unreferenced (Inner);
         begin
            begin
               Groups.Migrate (11);
            exception
               when Groups.Migration_Error =>
                  Rejected := True;
            end;
            OK := OK and then Rejected and then Groups.Is_Thread_Pinned;
         end;

         Rejected := False;
         begin
            Groups.Migrate (11);
         exception
            when Groups.Migration_Error =>
               Rejected := True;
         end;
         OK := OK and then Rejected and then Groups.Is_Thread_Pinned;
      end;

      OK := OK and then not Groups.Is_Thread_Pinned;
      begin
         declare
            Pin : Groups.Thread_Pin := Groups.Pin_To_Current_Thread;
            pragma Unreferenced (Pin);
         begin
            raise Cleanup_Test;
         end;
      exception
         when Cleanup_Test =>
            null;
      end;
      OK := OK and then not Groups.Is_Thread_Pinned;
      Groups.Migrate (11);
      OK := OK and then Current_Thread = One;

      Dedicated := Groups.Create_Dedicated;
      Groups.Migrate (Dedicated);
      Dedicated_Thread := Current_Thread;
      TLS_Set (Dedicated_Value);
      declare
         Pin : Groups.Thread_Pin := Groups.Pin_To_Current_Thread;
         pragma Unreferenced (Pin);
      begin
         delay 0.0;
         OK :=
           OK
           and then Groups.Is_Dedicated (Groups.Current)
           and then Groups.Is_Thread_Pinned
           and then Current_Thread = Dedicated_Thread
           and then TLS_Get = Dedicated_Value;
         Rejected := False;
         begin
            Groups.Migrate (11);
         exception
            when Groups.Migration_Error =>
               Rejected := True;
         end;
         OK := OK and then Rejected;
      end;
      Groups.Migrate (11);
      OK := OK and then Current_Thread = One;
      Observations.Finished (OK);
   exception
      when others =>
         Observations.Finished (False);
   end Migrator;

   task body Native is
      Thread : constant System.Address := Current_Thread;
      OK     : Boolean;
   begin
      TLS_Set (Native_Value);
      delay 0.001;
      OK :=
        Groups.Is_Thread_Pinned
        and then Current_Thread = Thread
        and then TLS_Get = Native_Value;
      declare
         Pin : Groups.Thread_Pin := Groups.Pin_To_Current_Thread;
         pragma Unreferenced (Pin);
      begin
         delay 0.001;
         OK :=
           OK
           and then Groups.Is_Thread_Pinned
           and then Current_Thread = Thread
           and then TLS_Get = Native_Value;
      end;
      Observations.Finished (OK);
   exception
      when others =>
         Observations.Finished (False);
   end Native;

begin
   Observations.Wait_For_Results;
   if not Observations.Passed then
      raise Program_Error with "thread-affinity contract failed";
   end if;
end Thread_Affinity_Smoke;
