with Ada.Exceptions;
with Ada.Streams;
with Flyology.Buffers.Domains;
with Flyology.Buffers.Domains.Drivers;
with Flyology.Buffers.Domains.Testing;
with Interfaces;

procedure Buffer_Domain_Reservations_Smoke is
   package Domains renames Flyology.Buffers.Domains;
   package Drivers renames Flyology.Buffers.Domains.Drivers;
   package Testing renames Flyology.Buffers.Domains.Testing;

   use type Ada.Streams.Stream_Element_Array;
   use type Flyology.Buffers.Pool_Snapshot;
   use type Interfaces.Unsigned_64;
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

   procedure Run_Protected_Publication is
      Configuration : constant Domains.Pool_Configuration_Array :=
        [1 => (Block_Size => 16, Capacity => 2, Maximum_Claims => 2),
         2 => (Block_Size => 32, Capacity => 2, Maximum_Claims => 2)];
      Domain             : aliased Domains.Buffer_Domain := Domains.Create (Configuration);
      Other              : aliased Domains.Buffer_Domain := Domains.Create (Configuration);
      Header_Pool        : constant Domains.Pool_Reference := Domains.Pool_At (Domain, 1);
      Payload_Pool       : constant Domains.Pool_Reference := Domains.Pool_At (Domain, 2);
      Other_Payload_Pool : constant Domains.Pool_Reference := Domains.Pool_At (Other, 2);
      Reservation        : aliased Domains.Pool_Reservation := Domains.Invalid_Reservation;

      protected type Publication_Gate is
         procedure Open;
         entry Publish
           (Header_Source  : not null access Domains.Owned_Buffer;
            Payload_Source : not null access Domains.Owned_Buffer);
         procedure Shift_Header;
         procedure Extract
           (Header_Target  : not null access Drivers.Buffer_Capability;
            Payload_Target : not null access Drivers.Buffer_Capability);
         function Waiting return Natural;
         function Has_Pair return Boolean;
      private
         Opened  : Boolean := False;
         Header  : Drivers.Buffer_Capability;
         Payload : Drivers.Buffer_Capability;
         Staging : Drivers.Buffer_Capability;
      end Publication_Gate;

      protected body Publication_Gate is
         procedure Open is
         begin
            Opened := True;
         end Open;

         entry Publish
           (Header_Source  : not null access Domains.Owned_Buffer;
            Payload_Source : not null access Domains.Owned_Buffer)
           when Opened
         is
         begin
            if not Domains.Has_Buffer (Header_Source.all)
              or else not Domains.Has_Buffer (Payload_Source.all)
              or else Drivers.Has_Buffer (Header)
              or else Drivers.Has_Buffer (Payload)
              or else Drivers.Has_Buffer (Staging)
            then
               raise Program_Error with "invalid prevalidated publication state";
            end if;
            Drivers.Commit_Prevalidated_From_Owned (Header_Source.all, Header);
            Drivers.Commit_Prevalidated_From_Owned (Payload_Source.all, Payload);
         end Publish;

         procedure Shift_Header is
         begin
            if not Drivers.Has_Buffer (Header) or else Drivers.Has_Buffer (Staging) then
               raise Program_Error with "invalid prevalidated capability move state";
            end if;
            Drivers.Commit_Prevalidated_Move (Header, Staging);
         end Shift_Header;

         procedure Extract
           (Header_Target  : not null access Drivers.Buffer_Capability;
            Payload_Target : not null access Drivers.Buffer_Capability)
         is
         begin
            if not Drivers.Has_Buffer (Staging)
              or else not Drivers.Has_Buffer (Payload)
              or else Drivers.Has_Buffer (Header_Target.all)
              or else Drivers.Has_Buffer (Payload_Target.all)
            then
               raise Program_Error with "invalid prevalidated extraction state";
            end if;
            Drivers.Commit_Prevalidated_Move (Staging, Header_Target.all);
            Drivers.Commit_Prevalidated_Move (Payload, Payload_Target.all);
         end Extract;

         function Waiting return Natural
         is (Publish'Count);

         function Has_Pair return Boolean
         is
           ((Drivers.Has_Buffer (Header) or else Drivers.Has_Buffer (Staging))
            and then Drivers.Has_Buffer (Payload));
      end Publication_Gate;

      procedure Publish_Checked
        (Gate           : in out Publication_Gate;
         Header_Source  : not null access Domains.Owned_Buffer;
         Payload_Source : not null access Domains.Owned_Buffer)
      is
      begin
         if not Domains.Has_Buffer (Header_Source.all)
           or else not Domains.Has_Buffer (Payload_Source.all)
           or else not Domains.Belongs_To (Domain, Domains.Buffer_Pool (Header_Source.all))
           or else Domains.Buffer_Pool (Header_Source.all) /= Header_Pool
           or else Domains.Buffer_Reservation (Header_Source.all) /= Reservation
           or else not Domains.Belongs_To (Domain, Domains.Buffer_Pool (Payload_Source.all))
           or else Domains.Buffer_Pool (Payload_Source.all) /= Payload_Pool
           or else Domains.Buffer_Reservation (Payload_Source.all) /= Domains.Invalid_Reservation
         then
            raise Program_Error with "source rejected before protected publication";
         end if;
         Gate.Publish (Header_Source, Payload_Source);
      end Publish_Checked;

      procedure Acquire_Header (Item : in out Domains.Owned_Buffer) is
         Result : Domains.Acquisition_Result;
      begin
         Domains.Acquire (Item, Reservation, Result);
         Assert (Result = Domains.Buffer_Acquired, "reserved header acquisition failed");
      end Acquire_Header;

      procedure Acquire_Payload (Item : in out Domains.Owned_Buffer) is
         Result : Domains.Acquisition_Result;
      begin
         Domains.Acquire (Item, Payload_Pool, Result);
         Assert (Result = Domains.Buffer_Acquired, "ordinary payload acquisition failed");
      end Acquire_Payload;

      procedure Wait_For_Queue (Gate : Publication_Gate) is
      begin
         for Attempt in 1 .. 10_000 loop
            exit when Gate.Waiting = 1;
            delay 0.001;
         end loop;
         Assert (Gate.Waiting = 1, "publication task did not queue");
      end Wait_For_Queue;

      procedure Check_Header (Data : Ada.Streams.Stream_Element_Array) is
      begin
         Assert (Data = [1, 2, 3], "prevalidated header bytes changed");
      end Check_Header;

      procedure Check_Payload (Data : Ada.Streams.Stream_Element_Array) is
      begin
         Assert (Data = [4, 5, 6, 7], "prevalidated payload bytes changed");
      end Check_Payload;

      Authority      : Retirement_Cut;
      Gate           : Publication_Gate;
      Header_Source  : aliased Domains.Owned_Buffer (Domain'Access);
      Payload_Source : aliased Domains.Owned_Buffer (Domain'Access);
      Extra_Header   : aliased Domains.Owned_Buffer (Domain'Access);
      Extra_Payload  : aliased Domains.Owned_Buffer (Domain'Access);
      Foreign        : aliased Domains.Owned_Buffer (Other'Access);
      Header_Result  : aliased Drivers.Buffer_Capability;
      Payload_Result : aliased Drivers.Buffer_Capability;
      Header_Target  : Domains.Owned_Buffer (Domain'Access);
      Payload_Target : Domains.Owned_Buffer (Domain'Access);
      Release_Result : Drivers.Release_Preparation_Result;
      Result         : Domains.Acquisition_Result;
      Rejected       : Boolean;
   begin
      Reserve_And_Commit (Domain'Access, Header_Pool, Reservation);
      Acquire_Header (Header_Source);
      Acquire_Payload (Payload_Source);
      Domains.Copy_From (Header_Source, [1, 2, 3]);
      Domains.Copy_From (Payload_Source, [4, 5, 6, 7]);
      Domains.Set_Tag (Header_Source, 101);
      Domains.Set_Tag (Payload_Source, 202);

      declare
         task Queued_Publisher;

         task body Queued_Publisher is
         begin
            Publish_Checked (Gate, Header_Source'Access, Payload_Source'Access);
         end Queued_Publisher;
      begin
         Wait_For_Queue (Gate);
         abort Queued_Publisher;
      end;
      Assert
        (Domains.Has_Buffer (Header_Source)
         and then Domains.Has_Buffer (Payload_Source)
         and then not Gate.Has_Pair,
         "abort while queued changed publication ownership");

      Gate.Open;
      Publish_Checked (Gate, Header_Source'Access, Payload_Source'Access);
      Assert
        (not Domains.Has_Buffer (Header_Source)
         and then not Domains.Has_Buffer (Payload_Source)
         and then Gate.Has_Pair,
         "protected publication did not commit the pair");

      Acquire_Header (Extra_Header);
      Acquire_Payload (Extra_Payload);
      Rejected := False;
      begin
         Publish_Checked (Gate, Extra_Header'Access, Extra_Payload'Access);
      exception
         when Program_Error =>
            Rejected := True;
      end;
      Assert
        (Rejected
         and then Domains.Has_Buffer (Extra_Header)
         and then Domains.Has_Buffer (Extra_Payload)
         and then Gate.Has_Pair,
         "occupied target validation followed ownership mutation");
      Domains.Release (Extra_Header);
      Domains.Release (Extra_Payload);

      Gate.Shift_Header;
      Gate.Extract (Header_Result'Access, Payload_Result'Access);
      Assert
        (not Gate.Has_Pair
         and then Drivers.Buffer_Pool (Domain'Access, Header_Result) = Header_Pool
         and then Drivers.Buffer_Pool (Domain'Access, Payload_Result) = Payload_Pool
         and then Drivers.Buffer_Reservation (Domain'Access, Header_Result) = Reservation
         and then Drivers.Buffer_Reservation (Domain'Access, Payload_Result)
           = Domains.Invalid_Reservation,
         "prevalidated capability move lost exact pool or reservation provenance");
      Drivers.Move_To (Domain'Access, Header_Result, Header_Target);
      Drivers.Move_To (Domain'Access, Payload_Result, Payload_Target);
      Domains.With_Readable_Data (Header_Target, Check_Header'Access);
      Domains.With_Readable_Data (Payload_Target, Check_Payload'Access);
      Assert
        (Domains.Buffer_Pool (Header_Target) = Header_Pool
         and then Domains.Buffer_Pool (Payload_Target) = Payload_Pool
         and then Domains.Tag (Header_Target) = 101
         and then Domains.Tag (Payload_Target) = 202,
         "prevalidated capability move lost exact pool or application tag");
      Domains.Release (Header_Target);
      Domains.Release (Payload_Target);

      Acquire_Header (Extra_Header);
      Domains.Acquire (Foreign, Other_Payload_Pool, Result);
      Assert (Result = Domains.Buffer_Acquired, "wrong-domain prevalidation setup failed");
      Rejected := False;
      begin
         Publish_Checked (Gate, Extra_Header'Access, Foreign'Access);
      exception
         when Program_Error =>
            Rejected := True;
      end;
      Assert
        (Rejected
         and then Domains.Has_Buffer (Extra_Header)
         and then Domains.Has_Buffer (Foreign)
         and then not Gate.Has_Pair,
         "wrong-domain source entered or mutated protected publication state");
      Domains.Release (Extra_Header);
      Domains.Release (Foreign);

      Acquire_Header (Header_Source);
      Acquire_Payload (Payload_Source);
      declare
         After_Gate : Publication_Gate;
         task Publisher;

         task body Publisher is
         begin
            After_Gate.Open;
            Publish_Checked (After_Gate, Header_Source'Access, Payload_Source'Access);
            loop
               delay 1.0;
            end loop;
         end Publisher;
      begin
         for Attempt in 1 .. 10_000 loop
            exit when After_Gate.Has_Pair;
            delay 0.001;
         end loop;
         Assert (After_Gate.Has_Pair, "post-publication abort task did not commit");
         abort Publisher;
         Assert
           (not Domains.Has_Buffer (Header_Source)
            and then not Domains.Has_Buffer (Payload_Source)
            and then After_Gate.Has_Pair,
            "abort after protected publication changed accepted ownership");
         After_Gate.Shift_Header;
         After_Gate.Extract (Header_Result'Access, Payload_Result'Access);
      end;
      Drivers.Release (Domain'Access, Header_Result);
      Drivers.Release (Domain'Access, Payload_Result);

      declare
         Token : Drivers.Reservation_Release (Domain'Access);
      begin
         Drivers.Prepare_Release (Token, Reservation, Release_Result);
         Assert (Release_Result = Drivers.Release_Prepared, "publication reservation did not release");
         Authority.Retire (Token, Reservation);
         Drivers.Acknowledge (Token);
      end;
      Assert
        (Domains.Current (Domain, Header_Pool) = (Available => 2, Outstanding => 0)
         and then Domains.Current (Domain, Payload_Pool) = (Available => 2, Outstanding => 0),
         "prevalidated publication did not restore heterogeneous pool capacity");
   end Run_Protected_Publication;

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
   Run_Protected_Publication;
   Run_Invalid_Configuration;
end Buffer_Domain_Reservations_Smoke;
