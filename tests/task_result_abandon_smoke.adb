with Ada.Exceptions;
with Ada.Synchronous_Task_Control;
with Ada.Task_Identification;
with Ada.Text_IO;
with Flyology;
with Flyology.Task_Results;

--  A task that is created but never activated never reaches the wrapper that
--  publishes its result, so its completion gate stays closed. Reclaiming that
--  task finalizes the gate underneath a queued waiter, which RM 9.4 turns into
--  Program_Error inside the runtime's Convention-C wait entry point. The
--  exported body must translate that into its ABI failure code so the public
--  wrapper raises the documented Program_Error instead of letting an arbitrary
--  exception escape the runtime boundary.
procedure Task_Result_Abandon_Smoke is
   package Results renames Flyology.Task_Results;
   package STC renames Ada.Synchronous_Task_Control;
   package Task_Ids renames Ada.Task_Identification;

   Expected_Message : constant String := "Flyology task-result wait failed";

   Setup_Failure : exception;

   Subject_Ready  : STC.Suspension_Object;
   Waiter_Started : STC.Suspension_Object;
   Subject_Id     : Task_Ids.Task_Id := Task_Ids.Null_Task_Id;

   type Outcome_Kind is
     (Pending, Returned_Normally, Documented_Failure, Foreign_Exception);

   protected Outcome is
      procedure Note (Kind : Outcome_Kind; Detail : String);
      function Kind return Outcome_Kind;
      function Detail return String;
   private
      Recorded     : Outcome_Kind := Pending;
      Text         : String (1 .. 160) := (others => ' ');
      Text_Length  : Natural := 0;
   end Outcome;

   protected body Outcome is
      procedure Note (Kind : Outcome_Kind; Detail : String) is
         Count : constant Natural := Natural'Min (Detail'Length, Text'Length);
      begin
         Recorded := Kind;
         Text_Length := Count;
         Text (1 .. Count) := Detail (Detail'First .. Detail'First + Count - 1);
      end Note;

      function Kind return Outcome_Kind is (Recorded);

      function Detail return String is (Text (1 .. Text_Length));
   end Outcome;

   task Waiter is
      pragma Task_Info (Flyology.Native_Task);
   end Waiter;

   task body Waiter is
      Observation : Results.Task_Observation;
      pragma Unreferenced (Observation);
   begin
      STC.Suspend_Until_True (Subject_Ready);
      STC.Set_True (Waiter_Started);
      Observation := Results.Wait (Subject_Id);
      Outcome.Note (Returned_Normally, "");
   exception
      when Error : Program_Error =>
         if Ada.Exceptions.Exception_Message (Error) = Expected_Message then
            Outcome.Note (Documented_Failure, Expected_Message);
         else
            Outcome.Note
              (Foreign_Exception,
               "PROGRAM_ERROR without the documented wait message: '"
               & Ada.Exceptions.Exception_Message (Error) & "'");
         end if;
      when Error : others =>
         Outcome.Note
           (Foreign_Exception,
            Ada.Exceptions.Exception_Name (Error)
            & " escaped the runtime wait");
   end Waiter;

   task type Unactivated_Task is
      pragma Task_Info (Flyology.Native_Task);
   end Unactivated_Task;

   task body Unactivated_Task is
   begin
      raise Program_Error with "unactivated subject task ran";
   end Unactivated_Task;

   --  Called from the same declarative part that created the subject task, so
   --  the subject exists, has its Flyology sidecar attached, and has not been
   --  activated. Raising here abandons the declarative part and sends the
   --  subject through the runtime's unactivated-task reclamation path.
   function Abandon_After_Waiter_Queued
     (Subject : Task_Ids.Task_Id) return Boolean is
   begin
      Subject_Id := Subject;
      STC.Set_True (Subject_Ready);
      STC.Suspend_Until_True (Waiter_Started);

      --  Let the waiter reach the gate's entry queue before the sidecar is
      --  finalized. The queued state is not observable from here.
      delay 0.25;
      raise Setup_Failure;
      return False;
   end Abandon_After_Waiter_Queued;

begin
   begin
      declare
         Subject : Unactivated_Task;
         Marker  : constant Boolean :=
           Abandon_After_Waiter_Queued (Subject'Identity);
         pragma Unreferenced (Marker);
      begin
         raise Program_Error with "unactivated subject task was activated";
      end;
   exception
      when Setup_Failure =>
         null;
   end;

   while Outcome.Kind = Pending loop
      delay 0.01;
   end loop;

   case Outcome.Kind is
      when Documented_Failure =>
         null;
      when Returned_Normally =>
         raise Program_Error with
           "wait on an abandoned task reported success";
      when Foreign_Exception =>
         raise Program_Error with
           "runtime wait leaked an exception: " & Outcome.Detail;
      when Pending =>
         raise Program_Error with "wait outcome was not recorded";
   end case;

   Ada.Text_IO.Put_Line
     ("task result abandon: gate finalization surfaces as the documented "
      & "wait failure");
end Task_Result_Abandon_Smoke;
