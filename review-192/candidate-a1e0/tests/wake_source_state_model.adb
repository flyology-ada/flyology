with Ada.Exceptions;
with Ada.Text_IO;
with Flyology;
with Flyology.IO;
with Flyology.Wake_Sources;
with Interfaces.C;

procedure Wake_Source_State_Model is
   package C renames Interfaces.C;
   package Wake_Sources renames Flyology.Wake_Sources;

   use type C.int;

   function Open_FD_Count return C.int
   with Import, Convention => C, External_Name => "flyology_test_open_fd_count";

   function FD_Is_Open (FD : C.int) return C.int
   with Import, Convention => C, External_Name => "flyology_test_fd_is_open";

   function FD_Is_Nonblocking (FD : C.int) return C.int
   with Import, Convention => C, External_Name => "flyology_test_fd_is_nonblocking";

   function FD_Is_Close_On_Exec (FD : C.int) return C.int
   with Import, Convention => C, External_Name => "flyology_test_fd_is_close_on_exec";

   procedure Require (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Require;

   procedure Expect_Consume_Error (Item : in out Wake_Sources.Source; Context : String) is
      Raised : Boolean := False;
   begin
      begin
         Wake_Sources.Consume (Item);
      exception
         when Program_Error =>
            Raised := True;
      end;
      Require (Raised, Context & " did not reject Consume");
   end Expect_Consume_Error;

   procedure Check_Descriptor (FD : Flyology.IO.Descriptor; Context : String) is
   begin
      Require (FD >= 0, Context & " returned a negative descriptor");
      Require (FD_Is_Open (FD) = 1, Context & " descriptor is not open");
      Require (FD_Is_Nonblocking (FD) = 1, Context & " descriptor is not nonblocking");
      Require (FD_Is_Close_On_Exec (FD) = 1, Context & " descriptor is not close-on-exec");
   end Check_Descriptor;

   procedure Exercise_Lifecycle is
      Item      : Wake_Sources.Source;
      First_FD  : Flyology.IO.Descriptor;
      Second_FD : Flyology.IO.Descriptor;
   begin
      Require (Wake_Sources.Descriptor (Item) = Flyology.IO.Invalid_Descriptor, "a new source is not absent");
      Expect_Consume_Error (Item, "an absent source");

      Wake_Sources.Ensure (Item);
      First_FD := Wake_Sources.Descriptor (Item);
      Check_Descriptor (First_FD, "Ensure");
      Wake_Sources.Ensure (Item);
      Require (Wake_Sources.Descriptor (Item) = First_FD, "Ensure replaced a live descriptor generation");
      Require
        (not Flyology.IO.Wait (First_FD, Flyology.IO.For_Read, 0.0), "a newly ensured source is readable");

      Wake_Sources.Signal (Item);
      Require
        (Flyology.IO.Wait (First_FD, Flyology.IO.For_Read, 0.0),
         "one signal did not make the source readable");
      Wake_Sources.Consume (Item);
      Require
        (not Flyology.IO.Wait (First_FD, Flyology.IO.For_Read, 0.0), "one Consume did not remove one signal");
      Expect_Consume_Error (Item, "an empty source");

      Wake_Sources.Signal (Item);
      Wake_Sources.Signal (Item);
      Require
        (Flyology.IO.Wait (First_FD, Flyology.IO.For_Read, 0.0),
         "repeated signals did not make the source readable");
      Wake_Sources.Consume (Item);
      Require
        (Flyology.IO.Wait (First_FD, Flyology.IO.For_Read, 0.0),
         "Consume removed more than one repeated signal");
      Wake_Sources.Consume (Item);
      Require
        (not Flyology.IO.Wait (First_FD, Flyology.IO.For_Read, 0.0),
         "two Consumes did not remove two signals");
      Expect_Consume_Error (Item, "a twice-consumed source");

      for Signal_Number in 1 .. 32 loop
         Wake_Sources.Signal (Item);
      end loop;
      Wake_Sources.Consume_All (Item);
      Require
        (not Flyology.IO.Wait (First_FD, Flyology.IO.For_Read, 0.0),
         "Consume_All left a coalesced signal readable");
      Expect_Consume_Error (Item, "a source drained by Consume_All");

      Wake_Sources.Release (Item);
      Require
        (Wake_Sources.Descriptor (Item) = Flyology.IO.Invalid_Descriptor,
         "Release did not return the source to absent");
      Require (FD_Is_Open (First_FD) = 0, "Release left its read end open");
      Wake_Sources.Release (Item);
      Require
        (Wake_Sources.Descriptor (Item) = Flyology.IO.Invalid_Descriptor,
         "repeated Release changed absent state");

      Wake_Sources.Ensure (Item);
      Second_FD := Wake_Sources.Descriptor (Item);
      Check_Descriptor (Second_FD, "Ensure after Release");
      Require
        (not Flyology.IO.Wait (Second_FD, Flyology.IO.For_Read, 0.0),
         "a replacement generation inherited readiness");
      Wake_Sources.Release (Item);
      Require (FD_Is_Open (Second_FD) = 0, "the replacement generation remained open after Release");
   end Exercise_Lifecycle;

   procedure Exercise_Implicit_Ensure is
      Item : Wake_Sources.Source;
      FD   : Flyology.IO.Descriptor;
   begin
      Wake_Sources.Signal (Item);
      FD := Wake_Sources.Descriptor (Item);
      Check_Descriptor (FD, "Signal on an absent source");
      Require (Flyology.IO.Wait (FD, Flyology.IO.For_Read, 0.0), "Signal did not ensure a ready source");
      Wake_Sources.Consume (Item);
   end Exercise_Implicit_Ensure;

   procedure Exercise_Finalization is
      Baseline     : constant C.int := Open_FD_Count;
      Finalized_FD : Flyology.IO.Descriptor;
   begin
      declare
         Item : Wake_Sources.Source;
      begin
         Wake_Sources.Ensure (Item);
         Finalized_FD := Wake_Sources.Descriptor (Item);
         Require (FD_Is_Open (Finalized_FD) = 1, "controlled source was not open in scope");
      end;
      Require (FD_Is_Open (Finalized_FD) = 0, "controlled finalization left the read end open");
      Require (Open_FD_Count = Baseline, "controlled finalization did not release both descriptor ends");
   end Exercise_Finalization;

   procedure Exercise_FD_Conservation is
      Iterations : constant Positive := 128;
      Baseline   : constant C.int := Open_FD_Count;
   begin
      for Iteration in 1 .. Iterations loop
         declare
            Item : Wake_Sources.Source;
         begin
            Wake_Sources.Ensure (Item);
            if Iteration mod 2 = 0 then
               Wake_Sources.Signal (Item);
               Wake_Sources.Consume (Item);
            end if;
            if Iteration mod 3 = 0 then
               Wake_Sources.Release (Item);
            end if;
         end;
         Require (Open_FD_Count = Baseline, "wake-source cycle changed the process descriptor count");
      end loop;
   end Exercise_FD_Conservation;

   Native_Passed      : Boolean := False;
   Lightweight_Passed : Boolean := False;

   procedure Check_Lane (Model : Flyology.Execution_Model; Passed : out Boolean) is
      protected Completion is
         procedure Finish (Passed : Boolean);
         entry Wait (Passed : out Boolean);
      private
         Done : Boolean := False;
         OK   : Boolean := False;
      end Completion;

      protected body Completion is
         procedure Finish (Passed : Boolean) is
         begin
            OK := Passed;
            Done := True;
         end Finish;

         entry Wait (Passed : out Boolean) when Done is
         begin
            Passed := OK;
         end Wait;
      end Completion;

      task Runner is
         pragma Task_Info (Model);
      end Runner;

      task body Runner is
      begin
         Exercise_Lifecycle;
         Exercise_Implicit_Ensure;
         Exercise_Finalization;
         Exercise_FD_Conservation;
         Completion.Finish (True);
      exception
         when Occurrence : others =>
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error, Ada.Exceptions.Exception_Information (Occurrence));
            Completion.Finish (False);
      end Runner;
   begin
      Completion.Wait (Passed);
   end Check_Lane;
begin
   Check_Lane (Flyology.Native_Task, Native_Passed);
   Require (Native_Passed, "native wake-source state model failed");
   Check_Lane (Flyology.Lightweight_Task, Lightweight_Passed);
   Require (Lightweight_Passed, "lightweight wake-source state model failed");
end Wake_Source_State_Model;
