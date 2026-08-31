with Flyology.Operations.Drivers;

package body Direct_IO_Futures_Bridge is
   use type Flyology.Operations.Driver_Event;
   use type Flyology.Operations.Terminal_Outcome;
   use type Interfaces.Integer_64;
   use type Interfaces.Unsigned_64;
   use type System.Address;

   Maximum_Interests : constant := 6;
   No_Deadline       : constant Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last;

   type Descriptor_Array is array (Natural range 0 .. Maximum_Interests - 1) of Interfaces.Integer_64
   with Convention => C;
   type Flag_Array is array (Natural range 0 .. Maximum_Interests - 1) of Interfaces.Unsigned_64
   with Convention => C;

   type Interest_Plan is record
      Count           : Interfaces.Unsigned_64;
      Descriptors     : Descriptor_Array;
      For_Write       : Flag_Array;
      Deadline_Micros : Interfaces.Unsigned_64;
   end record
   with Convention => C;

   function Create
     (Kind         : Interfaces.C.int;
      First_FD     : Interfaces.C.int;
      Second_FD    : Interfaces.C.int;
      Delay_Millis : Interfaces.Unsigned_64;
      Value        : Interfaces.Integer_64) return System.Address
   with Import, Convention => C, External_Name => "flyology_rust_interest_create";

   function Poll
     (Handle : System.Address; Result : access Interfaces.Integer_64; Plan : access Interest_Plan)
      return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_rust_interest_poll";

   procedure Destroy (Handle : System.Address)
   with Import, Convention => C, External_Name => "flyology_rust_interest_destroy";

   procedure Rust_Reset_Observations
   with Import, Convention => C, External_Name => "flyology_rust_interest_reset_observations";

   function Rust_Poll_Count return Interfaces.Unsigned_64
   with Import, Convention => C, External_Name => "flyology_rust_interest_poll_count";

   function Rust_Concurrent_Polls return Interfaces.Unsigned_64
   with Import, Convention => C, External_Name => "flyology_rust_interest_concurrent_polls";

   function Rust_Drop_Count return Interfaces.Unsigned_64
   with Import, Convention => C, External_Name => "flyology_rust_interest_drop_count";

   procedure Release_Handle (Item : in out Future_Operation) is
   begin
      if Item.Handle /= System.Null_Address then
         Destroy (Item.Handle);
         Item.Handle := System.Null_Address;
      end if;
   end Release_Handle;

   procedure Arm (Item : in out Future_Operation; Plan : Interest_Plan) is
      Count : constant Natural := Natural (Plan.Count);
   begin
      if Count > Maximum_Interests or else (Count = 0 and then Plan.Deadline_Micros = No_Deadline) then
         raise Rust_Future_Error with "Rust future returned an invalid empty or oversized interest plan";
      end if;

      if Count > 0 then
         declare
            Sources : Flyology.Operations.Drivers.Readiness_Source_Array (1 .. Count);
         begin
            for Position in Sources'Range loop
               if Plan.Descriptors (Position - 1) < 0
                 or else Plan.Descriptors (Position - 1) > Interfaces.Integer_64 (Interfaces.C.int'Last)
                 or else Plan.For_Write (Position - 1) > 1
               then
                  raise Rust_Future_Error with "Rust future returned an invalid descriptor interest";
               end if;
               Sources (Position) :=
                 (Descriptor => Interfaces.C.int (Plan.Descriptors (Position - 1)),
                  For_Write  => Plan.For_Write (Position - 1) = 1);
            end loop;
            Flyology.Operations.Drivers.Arm_Readiness (Item, Sources);
         end;
      end if;

      if Plan.Deadline_Micros /= No_Deadline then
         Flyology.Operations.Drivers.Arm_Deadline (Item, Duration (Plan.Deadline_Micros) / 1_000_000.0);
      end if;
   end Arm;

   procedure Start
     (Item         : in out Future_Operation;
      Kind         : Future_Kind;
      First_FD     : Interfaces.C.int;
      Second_FD    : Interfaces.C.int;
      Delay_Millis : Natural;
      Value        : Long_Long_Integer) is
   begin
      Flyology.Operations.Drivers.Start (Item);
      Item.Handle :=
        Create
          (Future_Kind'Pos (Kind),
           First_FD,
           Second_FD,
           Interfaces.Unsigned_64 (Delay_Millis),
           Interfaces.Integer_64 (Value));
      if Item.Handle = System.Null_Address then
         Flyology.Operations.Drivers.Rollback_Start (Item);
         raise Rust_Future_Error with "Rust future creation rejected its arguments";
      end if;
      Flyology.Operations.Drive
        (Flyology.Operations.Operation'Class (Item), Flyology.Operations.Start_Operation);
   exception
      when others =>
         if Flyology.Operations.Is_Active (Item) then
            Release_Handle (Item);
            Flyology.Operations.Drivers.Rollback_Start (Item);
         end if;
         raise;
   end Start;

   overriding
   procedure Drive (Item : in out Future_Operation; Event : Flyology.Operations.Driver_Event) is
      Rust_Result : aliased Interfaces.Integer_64 := 0;
      Plan        : aliased Interest_Plan :=
        (Count           => 0,
         Descriptors     => (others => -1),
         For_Write       => (others => 0),
         Deadline_Micros => No_Deadline);
      Status      : Interfaces.C.int;
   begin
      if Event
         not in Flyology.Operations.Start_Operation
              | Flyology.Operations.Source_Ready
              | Flyology.Operations.Deadline_Reached
      then
         Release_Handle (Item);
         Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
         return;
      end if;

      Status := Poll (Item.Handle, Rust_Result'Access, Plan'Access);
      case Status is
         when 0      =>
            Arm (Item, Plan);

         when 1      =>
            Item.Result := Long_Long_Integer (Rust_Result);
            Release_Handle (Item);
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Succeeded);

         when others =>
            Release_Handle (Item);
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
      end case;
   exception
      when others =>
         Release_Handle (Item);
         Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
   end Drive;

   overriding
   procedure Request_Cancellation (Item : in out Future_Operation) is
   begin
      Release_Handle (Item);
      Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Cancelled);
   exception
      when others =>
         Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
   end Request_Cancellation;

   procedure Finish (Item : in out Future_Operation; Value : out Long_Long_Integer) is
      Outcome : constant Flyology.Operations.Terminal_Outcome := Flyology.Operations.Outcome (Item);
      Result  : constant Long_Long_Integer := Item.Result;
   begin
      Flyology.Operations.Consume (Item);
      case Outcome is
         when Flyology.Operations.Succeeded =>
            Value := Result;

         when Flyology.Operations.Cancelled =>
            raise Flyology.Operations.Operation_Cancelled;

         when Flyology.Operations.Failed    =>
            raise Rust_Future_Error with "Rust future polling or interest planning failed";
      end case;
   end Finish;

   function Poll_Count return Interfaces.Unsigned_64
   is (Rust_Poll_Count);

   function Concurrent_Polls return Interfaces.Unsigned_64
   is (Rust_Concurrent_Polls);

   function Drop_Count return Interfaces.Unsigned_64
   is (Rust_Drop_Count);

   procedure Reset_Observations is
   begin
      Rust_Reset_Observations;
   end Reset_Observations;
end Direct_IO_Futures_Bridge;
