with Gnatevl;
with Gnatevl.Execution_Groups;
with System;

procedure Execution_Groups_Smoke is
   package Groups renames Gnatevl.Execution_Groups;
   Mover_Total : constant := 8;

   use type Groups.Group_Id;
   use type System.Address;

   function Current_Thread return System.Address;
   pragma Import (C, Current_Thread, "pthread_self");

   protected Results is
      procedure Static_Observation
        (Group  : Groups.Group_Id;
         Thread : System.Address;
         Passed : Boolean);
      procedure Migration_Observation
        (Start_Thread     : System.Address;
         Group_Two_Thread : System.Address;
         Dedicated_Thread : System.Address;
         Return_Thread    : System.Address;
         Passed           : Boolean);
      procedure Native_Observation (Passed : Boolean);
      procedure Mover_Observation (Passed : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Count          : Natural := 0;
      Mover_Count    : Natural := 0;
      OK             : Boolean := True;
      Group_One_Seen : Boolean := False;
      Group_Two_Seen : Boolean := False;
      Group_One_Thread : System.Address := System.Null_Address;
      Group_Two_Thread : System.Address := System.Null_Address;
      Migrator_Start   : System.Address := System.Null_Address;
      Migrator_Two     : System.Address := System.Null_Address;
      Migrator_Private : System.Address := System.Null_Address;
      Migrator_Return  : System.Address := System.Null_Address;
   end Results;

   protected body Results is
      procedure Static_Observation
        (Group  : Groups.Group_Id;
         Thread : System.Address;
         Passed : Boolean)
      is
      begin
         Count := Count + 1;
         OK := OK and Passed;
         if Group = 1 then
            if Group_One_Seen then
               OK := OK and Thread = Group_One_Thread;
            else
               Group_One_Seen := True;
               Group_One_Thread := Thread;
            end if;
         elsif Group = 2 then
            Group_Two_Seen := True;
            Group_Two_Thread := Thread;
         else
            OK := False;
         end if;
      end Static_Observation;

      procedure Migration_Observation
        (Start_Thread      : System.Address;
         Group_Two_Thread : System.Address;
         Dedicated_Thread : System.Address;
         Return_Thread    : System.Address;
         Passed           : Boolean)
      is
      begin
         Count := Count + 1;
         OK := OK and Passed;
         Migrator_Start := Start_Thread;
         Migrator_Two := Group_Two_Thread;
         Migrator_Private := Dedicated_Thread;
         Migrator_Return := Return_Thread;
      end Migration_Observation;

      procedure Native_Observation (Passed : Boolean) is
      begin
         Count := Count + 1;
         OK := OK and Passed;
      end Native_Observation;

      procedure Mover_Observation (Passed : Boolean) is
      begin
         Mover_Count := Mover_Count + 1;
         OK := OK and Passed;
      end Mover_Observation;

      entry Wait when Count = 5 and Mover_Count = Mover_Total is
      begin
         OK :=
           OK
           and Group_One_Seen
           and Group_Two_Seen
           and Group_One_Thread /= Group_Two_Thread
           and Migrator_Start = Group_One_Thread
           and Migrator_Two = Group_Two_Thread
           and Migrator_Private /= Group_One_Thread
           and Migrator_Private /= Group_Two_Thread
           and Migrator_Return = Group_One_Thread;
      end Wait;

      function Passed return Boolean is (OK);
   end Results;

   task Group_One_A with CPU => 1 is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Group_One_A;

   task Group_One_B with CPU => 1 is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Group_One_B;

   task Group_Two with CPU => 2 is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Group_Two;

   task Migrator with CPU => 1 is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Migrator;
   task Native is
      pragma Task_Info (Gnatevl.Native_Thread);
   end Native;

   task type Ping_Pong_Mover is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Ping_Pong_Mover;

   task body Ping_Pong_Mover is
      Dedicated : Groups.Dedicated_Group_Id;
      OK        : Boolean := True;
   begin
      Groups.Migrate (1);
      for Round in 1 .. 50 loop
         Groups.Migrate (2);
         OK := OK and Groups.Current = 2;
         delay 0.0;
         Groups.Migrate (1);
         OK := OK and Groups.Current = 1;
         if Round = 25 then
            Dedicated := Groups.Create_Dedicated;
            Groups.Migrate (Dedicated);
            OK := OK and Groups.Is_Dedicated (Groups.Current);
            delay 0.001;
            Groups.Migrate (1);
         end if;
      end loop;
      Results.Mover_Observation (OK);
   exception
      when others =>
         Results.Mover_Observation (False);
   end Ping_Pong_Mover;

   Movers : array (1 .. Mover_Total) of Ping_Pong_Mover;
   pragma Unreferenced (Movers);

   task body Group_One_A is
   begin
      Results.Static_Observation
        (Groups.Current, Current_Thread, Groups.Current = 1);
   exception
      when others =>
         Results.Static_Observation (0, Current_Thread, False);
   end Group_One_A;

   task body Group_One_B is
   begin
      Results.Static_Observation
        (Groups.Current, Current_Thread, Groups.Current = 1);
   exception
      when others =>
         Results.Static_Observation (0, Current_Thread, False);
   end Group_One_B;

   task body Group_Two is
   begin
      Results.Static_Observation
        (Groups.Current, Current_Thread, Groups.Current = 2);
   exception
      when others =>
         Results.Static_Observation (0, Current_Thread, False);
   end Group_Two;

   task body Migrator is
      Dedicated : Groups.Dedicated_Group_Id;
      Reused    : Groups.Dedicated_Group_Id;
      Start_Thread : System.Address;
      Two_Thread   : System.Address;
      Private_Thread : System.Address;
      Return_Thread  : System.Address;
      OK : Boolean := True;
   begin
      Start_Thread := Current_Thread;
      OK := OK and Groups.Current = 1;

      Groups.Migrate (2);
      Two_Thread := Current_Thread;
      OK := OK and Groups.Current = 2 and Two_Thread /= Start_Thread;

      Dedicated := Groups.Create_Dedicated;
      OK := OK and Groups.Is_Dedicated (Dedicated);
      Groups.Migrate (Dedicated);
      Private_Thread := Current_Thread;
      OK := OK and Groups.Current = Dedicated;

      Groups.Migrate (1);
      Return_Thread := Current_Thread;
      OK := OK and Groups.Current = 1 and Return_Thread = Start_Thread;

      Reused := Groups.Create_Dedicated;
      OK := OK and Reused = Dedicated;
      Groups.Migrate (Reused);
      OK := OK and Current_Thread = Private_Thread;
      Groups.Migrate (1);

      Results.Migration_Observation
        (Start_Thread,
         Two_Thread,
         Private_Thread,
         Return_Thread,
         OK);
   exception
      when others =>
         Results.Migration_Observation
           (System.Null_Address,
            System.Null_Address,
            System.Null_Address,
            System.Null_Address,
            False);
   end Migrator;

   task body Native is
      Rejected : Boolean := False;
   begin
      begin
         Groups.Migrate (Groups.Default_Group);
      exception
         when Groups.Migration_Error =>
            Rejected := True;
      end;
      Results.Native_Observation (Rejected);
   exception
      when others =>
         Results.Native_Observation (False);
   end Native;

begin
   Results.Wait;
   if not Results.Passed then
      raise Program_Error with "execution-group migration failed";
   end if;
end Execution_Groups_Smoke;
