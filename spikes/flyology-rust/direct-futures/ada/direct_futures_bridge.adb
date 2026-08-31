with Flyology.Operations.Drivers;
with Interfaces;

package body Direct_Futures_Bridge is
   use type Flyology.Operations.Driver_Event;
   use type Flyology.Operations.Terminal_Outcome;
   use type Interfaces.C.int;
   use type System.Address;

   function Create
     (Kind : Interfaces.C.int; Delay_Millis : Interfaces.Unsigned_64; Value : Interfaces.Integer_64)
      return System.Address
   with Import, Convention => C, External_Name => "flyology_rust_future_create";

   function Read_FD (Handle : System.Address) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_rust_future_read_fd";

   function Poll (Handle : System.Address; Result : access Interfaces.Integer_64) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_rust_future_poll";

   function Cancel (Handle : System.Address) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_rust_future_cancel";

   procedure Destroy (Handle : System.Address)
   with Import, Convention => C, External_Name => "flyology_rust_future_destroy";

   procedure Rust_Reset_Observations
   with Import, Convention => C, External_Name => "flyology_rust_future_reset_observations";

   function Rust_Late_Wakes return Interfaces.Unsigned_64
   with Import, Convention => C, External_Name => "flyology_rust_future_late_wakes";

   function Rust_Signal_Failures return Interfaces.Unsigned_64
   with Import, Convention => C, External_Name => "flyology_rust_future_signal_failures";

   function Rust_Concurrent_Polls return Interfaces.Unsigned_64
   with Import, Convention => C, External_Name => "flyology_rust_future_concurrent_polls";

   procedure Release_Handle (Item : in out Future_Operation; Cancel_First : Boolean) is
      Status : Interfaces.C.int;
   begin
      if Item.Handle /= System.Null_Address then
         if Cancel_First then
            Status := Cancel (Item.Handle);
            if Status /= 0 then
               Item.Panicked := True;
            end if;
         end if;
         Destroy (Item.Handle);
         Item.Handle := System.Null_Address;
         Item.Descriptor := -1;
      end if;
   end Release_Handle;

   procedure Start
     (Item : in out Future_Operation; Kind : Future_Kind; Delay_Millis : Natural; Value : Long_Long_Integer)
   is
   begin
      Flyology.Operations.Drivers.Start (Item);
      Item.Handle :=
        Create (Future_Kind'Pos (Kind), Interfaces.Unsigned_64 (Delay_Millis), Interfaces.Integer_64 (Value));
      if Item.Handle = System.Null_Address then
         Flyology.Operations.Drivers.Rollback_Start (Item);
         raise Rust_Future_Error with "Rust future creation failed";
      end if;
      Item.Descriptor := Read_FD (Item.Handle);
      if Item.Descriptor < 0 then
         Release_Handle (Item, Cancel_First => True);
         Flyology.Operations.Drivers.Rollback_Start (Item);
         raise Rust_Future_Error with "Rust wake descriptor creation failed";
      end if;
      Flyology.Operations.Drive
        (Flyology.Operations.Operation'Class (Item), Flyology.Operations.Start_Operation);
   exception
      when others =>
         if Flyology.Operations.Is_Active (Item) then
            Release_Handle (Item, Cancel_First => True);
            Flyology.Operations.Drivers.Rollback_Start (Item);
         end if;
         raise;
   end Start;

   overriding
   procedure Drive (Item : in out Future_Operation; Event : Flyology.Operations.Driver_Event) is
      Rust_Result : aliased Interfaces.Integer_64 := 0;
      Status      : Interfaces.C.int;
   begin
      if Event /= Flyology.Operations.Start_Operation and then Event /= Flyology.Operations.Source_Ready then
         Item.Panicked := True;
         Release_Handle (Item, Cancel_First => True);
         Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
         return;
      end if;

      Status := Poll (Item.Handle, Rust_Result'Access);
      case Status is
         when 0      =>
            Flyology.Operations.Drivers.Arm_Readiness (Item, Item.Descriptor, For_Write => False);

         when 1      =>
            Item.Result := Long_Long_Integer (Rust_Result);
            Release_Handle (Item, Cancel_First => False);
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Succeeded);

         when 2      =>
            Item.Panicked := True;
            Release_Handle (Item, Cancel_First => False);
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);

         when others =>
            Release_Handle (Item, Cancel_First => True);
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
      end case;
   end Drive;

   overriding
   procedure Request_Cancellation (Item : in out Future_Operation) is
   begin
      Release_Handle (Item, Cancel_First => True);
      Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Cancelled);
   exception
      when others =>
         Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
   end Request_Cancellation;

   procedure Finish (Item : in out Future_Operation; Value : out Long_Long_Integer) is
      Outcome  : constant Flyology.Operations.Terminal_Outcome := Flyology.Operations.Outcome (Item);
      Result   : constant Long_Long_Integer := Item.Result;
      Panicked : constant Boolean := Item.Panicked;
   begin
      Flyology.Operations.Consume (Item);
      case Outcome is
         when Flyology.Operations.Succeeded =>
            Value := Result;

         when Flyology.Operations.Cancelled =>
            raise Flyology.Operations.Operation_Cancelled;

         when Flyology.Operations.Failed    =>
            if Panicked then
               raise Rust_Future_Panic with "Rust future panicked while being polled";
            else
               raise Rust_Future_Error with "Rust future polling failed";
            end if;
      end case;
   end Finish;

   function Late_Wakes return Interfaces.Unsigned_64
   is (Rust_Late_Wakes);

   function Signal_Failures return Interfaces.Unsigned_64
   is (Rust_Signal_Failures);

   function Concurrent_Polls return Interfaces.Unsigned_64
   is (Rust_Concurrent_Polls);

   procedure Reset_Observations is
   begin
      Rust_Reset_Observations;
   end Reset_Observations;
end Direct_Futures_Bridge;
