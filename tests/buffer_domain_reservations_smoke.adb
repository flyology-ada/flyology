with Ada.Exceptions;
with Flyology.Buffers.Domains;
with Flyology.Buffers.Domains.Drivers;
with Flyology.Buffers.Domains.Testing;

procedure Buffer_Domain_Reservations_Smoke is
   package Domains renames Flyology.Buffers.Domains;
   package Drivers renames Flyology.Buffers.Domains.Drivers;
   package Testing renames Flyology.Buffers.Domains.Testing;

   use type Domains.Acquisition_Result;
   use type Domains.Pool_Reference;
   use type Domains.Pool_Reservation;
   use type Drivers.Release_Preparation_Result;
   use type Drivers.Reservation_Result;

   procedure Assert (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Assert;

   protected type Retirement_Cut is
      procedure Retire
        (Token       : in out Drivers.Reservation_Release;
         Reservation : Domains.Pool_Reservation);
      procedure Retire_Both
        (First       : in out Drivers.Reservation_Release;
         Second      : in out Drivers.Reservation_Release;
         Reservation : Domains.Pool_Reservation);
      function Count return Natural;
   private
      Retirements : Natural := 0;
   end Retirement_Cut;

   protected body Retirement_Cut is
      procedure Retire
        (Token       : in out Drivers.Reservation_Release;
         Reservation : Domains.Pool_Reservation) is
      begin
         Drivers.Authorize (Token, Reservation);
         Retirements := Retirements + 1;
      end Retire;

      procedure Retire_Both
        (First       : in out Drivers.Reservation_Release;
         Second      : in out Drivers.Reservation_Release;
         Reservation : Domains.Pool_Reservation) is
      begin
         Drivers.Authorize (First, Reservation);
         Drivers.Authorize (Second, Reservation);
         Retirements := Retirements + 1;
      end Retire_Both;

      function Count return Natural
      is (Retirements);
   end Retirement_Cut;

   procedure Reserve_And_Commit
     (Domain : not null access Domains.Buffer_Domain;
      Pool   : Domains.Pool_Reference;
      Target : aliased in out Domains.Pool_Reservation)
   is
      Claim  : Drivers.Reservation_Claim (Domain);
      Result : Drivers.Reservation_Result;
   begin
      Drivers.Reserve (Claim, Pool, Result);
      Assert (Result = Drivers.Reservation_Acquired, "pool reservation was rejected");
      Drivers.Commit_Reservation (Claim, Target);
      Assert
        (not Drivers.Has_Reservation (Claim)
         and then Domains.Is_Valid (Target)
         and then Domains.Reserved_Pool (Target) = Pool,
         "reservation commit did not transfer exact authority");
   end Reserve_And_Commit;

   procedure Run_Basic_Lifecycle is
      Configuration : constant Domains.Pool_Configuration_Array :=
        [1 => (Block_Size => 16, Capacity => 2, Maximum_Claims => 3)];
      Domain      : aliased Domains.Buffer_Domain := Domains.Create (Configuration);
      Other       : aliased Domains.Buffer_Domain := Domains.Create (Configuration);
      Pool        : constant Domains.Pool_Reference := Domains.Pool_At (Domain, 1);
      Other_Pool  : constant Domains.Pool_Reference := Domains.Pool_At (Other, 1);
      Current     : aliased Domains.Pool_Reservation := Domains.Invalid_Reservation;
      Other_Value : aliased Domains.Pool_Reservation := Domains.Invalid_Reservation;
      Item        : Domains.Owned_Buffer (Domain'Access);
      Moved_Item  : Domains.Owned_Buffer (Domain'Access);
      Capability  : aliased Drivers.Buffer_Capability;
      Moved_Capability : aliased Drivers.Buffer_Capability;
      Result      : Domains.Acquisition_Result;
      Reserve_Result : Drivers.Reservation_Result;
      Release_Result : Drivers.Release_Preparation_Result;
      Rejected    : Boolean;
      Authority   : Retirement_Cut;
   begin
      Assert
        (not Domains.Is_Valid (Domains.Invalid_Reservation)
         and then Domains.Reserved_Pool (Domains.Invalid_Reservation) = Domains.Invalid_Pool,
         "invalid reservation sentinel was classified as authority");

      Reserve_And_Commit (Domain'Access, Pool, Current);
      Reserve_And_Commit (Other'Access, Other_Pool, Other_Value);
      declare
         Competing : Drivers.Reservation_Claim (Domain'Access);
      begin
         Drivers.Reserve (Competing, Pool, Reserve_Result);
         Assert
           (Reserve_Result = Drivers.Reservation_In_Use
            and then not Drivers.Has_Reservation (Competing),
            "live reservation admitted a competing claim");
      end;

      Domains.Acquire (Item, Pool, Result);
      Assert
        (Result = Domains.Pool_Reserved and then not Domains.Has_Buffer (Item),
         "ordinary acquisition entered a reserved pool");
      Domains.Try_Acquire (Item, Current, Result);
      Assert
        (Result = Domains.Buffer_Acquired
         and then Domains.Buffer_Reservation (Item) = Current,
         "qualified acquisition lost reservation provenance");

      Rejected := False;
      begin
         Domains.Try_Acquire (Item, Domains.Invalid_Reservation, Result);
      exception
         when Occurrence : Program_Error =>
            Rejected :=
              Ada.Exceptions.Exception_Message (Occurrence) =
                "acquire into an occupied domain buffer";
      end;
      Assert (Rejected and then Domains.Has_Buffer (Item), "invalid authority preceded occupied target");
      Rejected := False;
      begin
         Domains.Try_Acquire (Item, Other_Value, Result);
      exception
         when Occurrence : Program_Error =>
            Rejected :=
              Ada.Exceptions.Exception_Message (Occurrence) =
                "acquire into an occupied domain buffer";
      end;
      Assert (Rejected and then Domains.Has_Buffer (Item), "foreign authority preceded occupied target");

      Domains.Move (Item, Moved_Item);
      Assert
        (not Domains.Has_Buffer (Item)
         and then Domains.Buffer_Reservation (Moved_Item) = Current,
         "public move lost reserved provenance");
      Drivers.Move_From (Domain'Access, Moved_Item, Capability);
      Drivers.Move (Domain'Access, Capability, Moved_Capability);
      Assert
        (not Drivers.Has_Buffer (Capability)
         and then Drivers.Buffer_Reservation (Domain'Access, Moved_Capability) = Current,
         "capability-to-capability move lost reservation provenance");
      declare
         Token : Drivers.Reservation_Release (Domain'Access);
      begin
         Drivers.Prepare_Release (Token, Current, Release_Result);
         Assert
           (Release_Result = Drivers.Live_Claims_Remain and then not Drivers.Has_Release (Token),
            "release prepared while a capability claim was live");
      end;

      Rejected := False;
      begin
         Drivers.Rollback_Reservation (Domain'Access, Current);
      exception
         when Program_Error =>
            Rejected := True;
      end;
      Assert
        (Rejected and then Domains.Is_Valid (Current),
         "rollback crossed a live reservation claim");

      Drivers.Move_To (Domain'Access, Moved_Capability, Item);
      Testing.Arm_Next_Release_Claim_Gap_Failure;
      Rejected := False;
      begin
         Domains.Release (Item);
      exception
         when Program_Error =>
            Rejected := True;
      end;
      Assert
        (Rejected
         and then not Domains.Has_Buffer (Item)
         and then Drivers.Active_Claims (Domain'Access, Pool) = 0
         and then Domains.Current (Domain, Pool).Outstanding = 0,
         "release-gap unwinding did not finish base return and claim decrement");

      declare
         Token : Drivers.Reservation_Release (Domain'Access);
      begin
         Drivers.Prepare_Release (Token, Current, Release_Result);
         Assert
           (Release_Result = Drivers.Release_Prepared
            and then Drivers.Matches (Token, Current)
            and then not Drivers.Is_Authorized (Token),
            "release token was not published unauthorized");
         Rejected := False;
         begin
            Drivers.Acknowledge (Token);
         exception
            when Program_Error =>
               Rejected := True;
         end;
         Assert
           (Rejected
            and then Drivers.Matches (Token, Current)
            and then not Drivers.Is_Authorized (Token),
            "unauthorized acknowledgment entered or cleared the domain token");
      end;

      declare
         Competing : Drivers.Reservation_Claim (Domain'Access);
      begin
         Drivers.Reserve (Competing, Pool, Reserve_Result);
         Assert
           (Reserve_Result = Drivers.Reservation_In_Use,
            "unauthorized token finalization released a pending pool");
      end;
      Domains.Acquire (Item, Pool, Result);
      Assert
        (Result = Domains.Reservation_Releasing and then not Domains.Has_Buffer (Item),
         "ordinary blocking acquisition crossed a pending release");
      Domains.Acquire_For (Item, Current, 0.01, Result);
      Assert
        (Result = Domains.Reservation_Releasing and then not Domains.Has_Buffer (Item),
         "qualified timed acquisition crossed a pending release");

      declare
         First  : Drivers.Reservation_Release (Domain'Access);
         Second : Drivers.Reservation_Release (Domain'Access);
         Old    : constant Domains.Pool_Reservation := Current;
         Newer  : aliased Domains.Pool_Reservation := Domains.Invalid_Reservation;
         Saved_Newer : Domains.Pool_Reservation := Domains.Invalid_Reservation;
      begin
         Drivers.Prepare_Release (First, Current, Release_Result);
         Assert (Release_Result = Drivers.Release_Prepared, "pending release did not resume");
         Rejected := False;
         begin
            Drivers.Authorize (First, Testing.Next_Reservation (Current));
         exception
            when Program_Error =>
               Rejected := True;
         end;
         Assert
           (Rejected and then Drivers.Matches (First, Current) and then not Drivers.Is_Authorized (First),
            "mismatched authorization mutated the release token");
         Rejected := False;
         begin
            Drivers.Prepare_Release (First, Current, Release_Result);
         exception
            when Program_Error =>
               Rejected := True;
         end;
         Assert
           (Rejected and then Drivers.Matches (First, Current),
            "prepare into an occupied token mutated pending authority");
         Drivers.Prepare_Release (Second, Current, Release_Result);
         Assert (Release_Result = Drivers.Release_Prepared, "pending release was not reissued");
         Authority.Retire_Both (First, Second, Current);
         Drivers.Acknowledge (First);
         Assert (not Drivers.Has_Release (First), "acknowledgment retained its token");

         Reserve_And_Commit (Domain'Access, Pool, Newer);
         Saved_Newer := Newer;
         Drivers.Acknowledge (Second);
         Assert
           (not Drivers.Has_Release (Second) and then Domains.Is_Valid (Newer),
            "older duplicate acknowledgment released a newer reservation");

         declare
            Token : Drivers.Reservation_Release (Domain'Access);
         begin
            Drivers.Prepare_Release (Token, Old, Release_Result);
            Assert
              (Release_Result = Drivers.Release_Already_Acknowledged
               and then not Drivers.Has_Release (Token),
               "older release preparation was not inert");
            Rejected := False;
            begin
               Drivers.Prepare_Release (Token, Testing.Next_Reservation (Newer), Release_Result);
            exception
               when Program_Error =>
                  Rejected := True;
            end;
            Assert
              (Rejected and then not Drivers.Has_Release (Token),
               "future release preparation mutated its token");
         end;

         Domains.Try_Acquire (Item, Old, Result);
         Assert (Result = Domains.Reservation_Stale, "older acquisition was not stale");
         Rejected := False;
         begin
            Domains.Try_Acquire (Item, Testing.Next_Reservation (Newer), Result);
         exception
            when Program_Error =>
               Rejected := True;
         end;
         Assert
           (Rejected and then not Domains.Has_Buffer (Item) and then Domains.Is_Valid (Newer),
            "future reservation failure mutated the active reservation");
         Drivers.Rollback_Reservation (Domain'Access, Newer);
         Domains.Try_Acquire (Item, Saved_Newer, Result);
         Assert
           (Result = Domains.Reservation_Not_Active,
            "rolled-back exact reservation did not report inactive");
         declare
            Token : Drivers.Reservation_Release (Domain'Access);
         begin
            Rejected := False;
            begin
               Drivers.Prepare_Release (Token, Saved_Newer, Release_Result);
            exception
               when Program_Error =>
                  Rejected := True;
            end;
            Assert
              (Rejected and then not Drivers.Has_Release (Token),
               "exact available generation prepared a release token");
         end;
      end;

      Rejected := False;
      begin
         Domains.Try_Acquire (Item, Other_Value, Result);
      exception
         when Program_Error =>
            Rejected := True;
      end;
      Assert
        (Rejected and then not Domains.Has_Buffer (Item),
         "foreign reservation entered another domain");
      declare
         Token : Drivers.Reservation_Release (Domain'Access);
      begin
         Rejected := False;
         begin
            Drivers.Prepare_Release (Token, Other_Value, Release_Result);
         exception
            when Program_Error =>
               Rejected := True;
         end;
         Assert
           (Rejected and then not Drivers.Has_Release (Token),
            "foreign release preparation mutated its token");
      end;
      Drivers.Rollback_Reservation (Other'Access, Other_Value);
      Assert (Authority.Count = 1, "retirement cut count is wrong");
   end Run_Basic_Lifecycle;

   procedure Run_Publication_Faults is
      Configuration : constant Domains.Pool_Configuration_Array :=
        [1 => (Block_Size => 8, Capacity => 1, Maximum_Claims => 1)];
      Domain      : aliased Domains.Buffer_Domain := Domains.Create (Configuration);
      Pool        : constant Domains.Pool_Reference := Domains.Pool_At (Domain, 1);
      Current     : aliased Domains.Pool_Reservation := Domains.Invalid_Reservation;
      Result      : Drivers.Reservation_Result;
      Release_Result : Drivers.Release_Preparation_Result;
      Injected    : Boolean;
      Authority   : Retirement_Cut;
   begin
      Injected := False;
      declare
         Claim : Drivers.Reservation_Claim (Domain'Access);
      begin
         Testing.Arm_Next_Reservation_Publication_Failure;
         begin
            Drivers.Reserve (Claim, Pool, Result);
         exception
            when Program_Error =>
               Injected := True;
         end;
         Assert
           (Injected and then Drivers.Has_Reservation (Claim),
            "reservation publication failure lost rollback authority");
      end;
      Reserve_And_Commit (Domain'Access, Pool, Current);

      Injected := False;
      declare
         Token : Drivers.Reservation_Release (Domain'Access);
      begin
         Testing.Arm_Next_Prepare_Release_Publication_Failure;
         begin
            Drivers.Prepare_Release (Token, Current, Release_Result);
         exception
            when Program_Error =>
               Injected := True;
         end;
         Assert
           (Injected
            and then Drivers.Has_Release (Token)
            and then not Drivers.Is_Authorized (Token),
            "prepare publication failure lost resumable pending authority");
      end;

      declare
         Token : Drivers.Reservation_Release (Domain'Access);
      begin
         Drivers.Prepare_Release (Token, Current, Release_Result);
         Assert (Release_Result = Drivers.Release_Prepared, "pending prepare did not resume");
         Authority.Retire (Token, Current);
         Testing.Arm_Next_Acknowledge_Post_Commit_Failure;
         Injected := False;
         begin
            Drivers.Acknowledge (Token);
         exception
            when Program_Error =>
               Injected := True;
         end;
         Assert
           (Injected and then not Drivers.Has_Release (Token),
            "post-acknowledgment failure retained stale authority");
      end;

      Current := Domains.Invalid_Reservation;
      Reserve_And_Commit (Domain'Access, Pool, Current);
      Drivers.Rollback_Reservation (Domain'Access, Current);

      Reserve_And_Commit (Domain'Access, Pool, Current);
      declare
         Token : Drivers.Reservation_Release (Domain'Access);
      begin
         Drivers.Prepare_Release (Token, Current, Release_Result);
         Assert (Release_Result = Drivers.Release_Prepared, "fallback release did not prepare");
         Authority.Retire (Token, Current);
      end;
      Current := Domains.Invalid_Reservation;
      Reserve_And_Commit (Domain'Access, Pool, Current);
      Drivers.Rollback_Reservation (Domain'Access, Current);
   end Run_Publication_Faults;

   procedure Run_Claim_Bound is
      Configuration : constant Domains.Pool_Configuration_Array :=
        [1 => (Block_Size => 8, Capacity => 1, Maximum_Claims => 2)];
      Domain  : aliased Domains.Buffer_Domain := Domains.Create (Configuration);
      Pool    : constant Domains.Pool_Reference := Domains.Pool_At (Domain, 1);
      Held    : Domains.Owned_Buffer (Domain'Access);
      Third   : Domains.Owned_Buffer (Domain'Access);
      Result  : Domains.Acquisition_Result;
      Reserve_Result : Drivers.Reservation_Result;

      task Waiter is
         entry Start;
         entry Finish (Outcome : out Domains.Acquisition_Result);
      end Waiter;

      task body Waiter is
         Item        : Domains.Owned_Buffer (Domain'Access);
         Wait_Result : Domains.Acquisition_Result;
      begin
         accept Start;
         Domains.Acquire (Item, Pool, Wait_Result);
         if Wait_Result = Domains.Buffer_Acquired then
            Domains.Release (Item);
         end if;
         accept Finish (Outcome : out Domains.Acquisition_Result) do
            Outcome := Wait_Result;
         end Finish;
      end Waiter;
   begin
      Domains.Acquire (Held, Pool, Result);
      Assert (Result = Domains.Buffer_Acquired, "claim-bound setup acquisition failed");
      Domains.Try_Acquire (Third, Pool, Result);
      Assert
        (Result = Domains.Pool_Empty
         and then not Domains.Has_Buffer (Third)
         and then Drivers.Active_Claims (Domain'Access, Pool) = 1,
         "empty immediate acquisition retained its claim");
      Domains.Acquire_For (Third, Pool, 0.001, Result);
      Assert
        (Result = Domains.Acquisition_Timed_Out
         and then not Domains.Has_Buffer (Third)
         and then Drivers.Active_Claims (Domain'Access, Pool) = 1,
         "timed acquisition retained its claim");
      Waiter.Start;
      for Attempt in 1 .. 10_000 loop
         exit when Drivers.Active_Claims (Domain'Access, Pool) = 2;
         delay 0.001;
      end loop;
      Assert
        (Drivers.Active_Claims (Domain'Access, Pool) = 2,
         "blocking acquisition did not publish its bounded claim");

      Domains.Acquire (Third, Pool, Result);
      Assert
        (Result = Domains.Claim_Limit_Reached and then not Domains.Has_Buffer (Third),
         "blocking acquisition exceeded Maximum_Claims");
      declare
         Claim : Drivers.Reservation_Claim (Domain'Access);
      begin
         Drivers.Reserve (Claim, Pool, Reserve_Result);
         Assert
           (Reserve_Result = Drivers.Reservation_In_Use,
            "reservation crossed held and acquisition-in-progress claims");
      end;

      Domains.Release (Held);
      Waiter.Finish (Result);
      Assert
        (Result = Domains.Buffer_Acquired
         and then Drivers.Active_Claims (Domain'Access, Pool) = 0,
         "waiting acquisition did not finish and release its claim");
   exception
      when others =>
         abort Waiter;
         if Domains.Has_Buffer (Held) then
            Domains.Release (Held);
         end if;
         raise;
   end Run_Claim_Bound;

   procedure Run_Final_Generation is
      Configuration : constant Domains.Pool_Configuration_Array :=
        [1 => (Block_Size => 8, Capacity => 1, Maximum_Claims => 1)];
      Domain      : aliased Domains.Buffer_Domain := Domains.Create (Configuration);
      Pool        : constant Domains.Pool_Reference := Domains.Pool_At (Domain, 1);
      Current     : aliased Domains.Pool_Reservation := Domains.Invalid_Reservation;
      Claim       : Drivers.Reservation_Claim (Domain'Access);
      First       : Drivers.Reservation_Release (Domain'Access);
      Second      : Drivers.Reservation_Release (Domain'Access);
      Item        : Domains.Owned_Buffer (Domain'Access);
      Extra       : Domains.Owned_Buffer (Domain'Access);
      Reserve_Result : Drivers.Reservation_Result;
      Release_Result : Drivers.Release_Preparation_Result;
      Result      : Domains.Acquisition_Result;
      Authority   : Retirement_Cut;
   begin
      Domains.Acquire (Item, Pool, Result);
      Assert (Result = Domains.Buffer_Acquired, "final-hook rearm setup acquisition failed");
      Testing.Arm_Next_Reservation_Final_Generation;
      Drivers.Reserve (Claim, Pool, Reserve_Result);
      Assert
        (Reserve_Result = Drivers.Reservation_In_Use and then not Drivers.Has_Reservation (Claim),
         "failed reservation did not preserve a vacant claim");
      Domains.Release (Item);
      Drivers.Reserve (Claim, Pool, Reserve_Result);
      Assert (Reserve_Result = Drivers.Reservation_Acquired, "final reservation was rejected");
      Drivers.Commit_Reservation (Claim, Current);
      Domains.Acquire (Item, Current, Result);
      Assert (Result = Domains.Buffer_Acquired, "final reservation acquisition failed");
      Domains.Acquire (Extra, Current, Result);
      Assert
        (Result = Domains.Claim_Limit_Reached and then not Domains.Has_Buffer (Extra),
         "reserved blocking acquisition exceeded Maximum_Claims");
      Domains.Release (Item);
      Drivers.Prepare_Release (First, Current, Release_Result);
      Drivers.Prepare_Release (Second, Current, Release_Result);
      Authority.Retire_Both (First, Second, Current);
      Drivers.Acknowledge (First);
      Drivers.Acknowledge (Second);

      Drivers.Reserve (Claim, Pool, Reserve_Result);
      Assert
        (Reserve_Result = Drivers.Reservation_Generation_Exhausted,
         "final-generation acknowledgment did not exhaust reservation space");
      Domains.Acquire (Item, Pool, Result);
      Assert
        (Result = Domains.Pool_Permanently_Exhausted,
         "ordinary acquisition entered a permanently exhausted pool");
      Domains.Try_Acquire (Item, Current, Result);
      Assert
        (Result = Domains.Pool_Permanently_Exhausted,
         "exact final reservation did not report permanent exhaustion");
      begin
         Drivers.Acknowledge (First);
         Assert (False, "vacant acknowledgment returned normally");
      exception
         when Program_Error =>
            null;
      end;
      Drivers.Prepare_Release (First, Current, Release_Result);
      Assert
        (Release_Result = Drivers.Release_Already_Acknowledged,
         "final reservation release was not idempotent");
   end Run_Final_Generation;

   procedure Run_Invalid_Configuration is
      Rejected : Boolean := False;
   begin
      begin
         declare
            Invalid : constant Domains.Pool_Configuration_Array :=
              [1 => (Block_Size => 8, Capacity => 2, Maximum_Claims => 1)];
            Domain  : Domains.Buffer_Domain := Domains.Create (Invalid);
            pragma Unreferenced (Domain);
         begin
            null;
         end;
      exception
         when Constraint_Error =>
            Rejected := True;
      end;
      Assert (Rejected, "Maximum_Claims smaller than Capacity was accepted");
   end Run_Invalid_Configuration;
begin
   Run_Basic_Lifecycle;
   Run_Publication_Faults;
   Run_Claim_Bound;
   Run_Final_Generation;
   Run_Invalid_Configuration;
end Buffer_Domain_Reservations_Smoke;
