with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Flyology;
with Flyology.IO.Timers;
with Flyology.Operations;
with Flyology.Operations.Drivers;
with System;

procedure Operation_Return_Boundary_Smoke is
   package Strings renames Ada.Strings.Unbounded;
   package Operations renames Flyology.Operations;
   package Drivers renames Flyology.Operations.Drivers;

   use type Operations.Driver_Event;
   use type Operations.Terminal_Outcome;

   type Result_Status is (Available, Peer_Closed);
   type Version_Kind is (Version_1_1);
   type Protocol_Kind is (Protocol_1_1);

   type Result_Record is record
      Method                : Strings.Unbounded_String;
      Target                : Strings.Unbounded_String;
      Authority             : Strings.Unbounded_String;
      Version               : Version_Kind := Version_1_1;
      Protocol              : Protocol_Kind := Protocol_1_1;
      Header_Block          : Strings.Unbounded_String;
      Physical_Header_Block : Strings.Unbounded_String;
      Payload               : Strings.Unbounded_String;
      Keep_Alive            : Boolean := False;
      Status                : Result_Status := Available;
   end record;

   subtype Buffer_Index is Positive range 1 .. 8 * 1_024;
   type Byte_Buffer is array (Buffer_Index) of Character;

   type Test_Operation
     (Owner : not null access Operations.Completion_Set'Class)
   is new Operations.Operation (Owner) with record
      Item_Handle  : System.Address := System.Null_Address;
      Token_Handle : System.Address := System.Null_Address;
      IO_Started   : Boolean := False;
      Acquiring    : Boolean := False;
      Failure      : Ada.Exceptions.Exception_Occurrence;
      Buffer       : Byte_Buffer := [others => Character'Val (0)];
      Value_Result : Result_Record;
      Peer_Ended   : Boolean := False;
   end record;

   overriding procedure Drive
     (Item  : in out Test_Operation;
      Event : Operations.Driver_Event);

   overriding procedure Request_Cancellation
     (Item : in out Test_Operation);

   procedure Check
     (Condition : Boolean;
      Message   : String)
   is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   procedure Check_Result
     (Item    : Result_Record;
      Context : String)
   is
   begin
      Check (Item.Status = Available, Context & ": status changed");
      Check
        (Strings.To_String (Item.Method) = "GET",
         Context & ": method changed");
      Check
        (Strings.To_String (Item.Target) = "/return-boundary",
         Context & ": target changed");
      Check
        (Strings.To_String (Item.Header_Block) = "x-test: value",
         Context & ": header block changed");
      Check
        (Strings.To_String (Item.Payload) = "body",
         Context & ": body changed");
   end Check_Result;

   procedure Fill (Item : out Result_Record) is
   begin
      Item.Method := Strings.To_Unbounded_String ("GET");
      Item.Target := Strings.To_Unbounded_String ("/return-boundary");
      Item.Authority := Strings.To_Unbounded_String ("example.test");
      Item.Header_Block := Strings.To_Unbounded_String ("x-test: value");
      Item.Physical_Header_Block :=
        Strings.To_Unbounded_String ("X-Test: value");
      Item.Payload := Strings.To_Unbounded_String ("body");
      Item.Status := Peer_Closed;
   end Fill;

   procedure Publish_Plain
     (Source : Result_Record;
      Target : not null access Result_Record)
   is
   begin
      Target.all := Source;
      Target.Status := Available;
      Check_Result (Target.all, "inside plain publisher");
   end Publish_Plain;

   overriding procedure Drive
     (Item  : in out Test_Operation;
      Event : Operations.Driver_Event)
   is
   begin
      if Event /= Operations.Start_Operation then
         Drivers.Complete (Item, Operations.Failed);
         return;
      end if;

      Fill (Item.Value_Result);
      Drivers.Complete (Item, Operations.Succeeded);
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Test_Operation)
   is
   begin
      Drivers.Complete (Item, Operations.Cancelled);
   exception
      when others =>
         null;
   end Request_Cancellation;

   function Start
     (Set : not null access Operations.Completion_Set'Class)
      return Test_Operation
   is
   begin
      return Result : Test_Operation (Set) do
         Drivers.Start (Result);
         Drive (Result, Operations.Start_Operation);
      end return;
   end Start;

   procedure Finish
     (Item   : in out Test_Operation;
      Target : not null access Result_Record)
   is
      Outcome : constant Operations.Terminal_Outcome :=
        Operations.Outcome (Item);
   begin
      Operations.Consume (Item);
      case Outcome is
         when Operations.Succeeded =>
            Target.all := Item.Value_Result;
            Target.Status :=
              (if Item.Peer_Ended then Peer_Closed else Available);
            Check_Result (Target.all, "inside operation finish");
         when Operations.Cancelled =>
            raise Operations.Operation_Cancelled;
         when Operations.Failed =>
            raise Program_Error with "test operation failed";
      end case;
   end Finish;

   type Boolean_Array is array (Positive range 1 .. 2) of Boolean;

   protected Results is
      procedure Publish (Passed : Boolean);
      entry Await (Passed : out Boolean);
   private
      Values    : Boolean_Array := [others => False];
      Published : Natural range 0 .. 2 := 0;
      Consumed  : Natural range 0 .. 2 := 0;
   end Results;

   protected body Results is
      procedure Publish (Passed : Boolean) is
      begin
         Published := Published + 1;
         Values (Published) := Passed;
      end Publish;

      entry Await (Passed : out Boolean) when Consumed < Published is
      begin
         Consumed := Consumed + 1;
         Passed := Values (Consumed);
      end Await;
   end Results;

   procedure Check_Lane (Model : Flyology.Execution_Model) is
      Published : aliased Result_Record;

      task Worker is
         pragma Task_Info (Model);
      end Worker;

      task body Worker is
      begin
         declare
            Set    : aliased Operations.Completion_Set (1);
            Alarm  : Flyology.IO.Timers.Timer_Operation :=
              Flyology.IO.Timers.Sleep_For (Set'Access, 0.0);
            Source : Result_Record;
         begin
            Operations.Wait_All (Set);
            Flyology.IO.Timers.Finish (Alarm);
            Fill (Source);
            Publish_Plain (Source, Published'Access);
            Check_Result (Published, "after plain publisher return");
         end;

         declare
            Set   : aliased Operations.Completion_Set (2);
            Get   : Test_Operation := Start (Set'Access);
            Alarm : Flyology.IO.Timers.Timer_Operation :=
              Flyology.IO.Timers.Sleep_For (Set'Access, 0.0);
         begin
            Operations.Wait_All (Set);
            Flyology.IO.Timers.Finish (Alarm);
            Finish (Get, Published'Access);
            Check_Result (Published, "after operation finish return");
         end;
         Check_Result (Published, "after operation finalization");
         Results.Publish (True);
      exception
         when others =>
            Results.Publish (False);
      end Worker;
   begin
      null;
   end Check_Lane;

   Passed : Boolean;
begin
   Check_Lane (Flyology.Native_Task);
   Check_Lane (Flyology.Lightweight_Task);
   for Lane in 1 .. 2 loop
      Results.Await (Passed);
      Check (Passed, "return-boundary check failed");
   end loop;
end Operation_Return_Boundary_Smoke;
