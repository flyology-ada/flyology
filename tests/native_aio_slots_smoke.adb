with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Real_Time;
with Interfaces.C;
with System.Flyology.File_Engine;
with System.Storage_Elements;
with Fault_Control;

procedure Native_AIO_Slots_Smoke is
   package C renames Interfaces.C;
   package Engine renames System.Flyology.File_Engine;
   package SSE renames System.Storage_Elements;

   use type Ada.Real_Time.Time;
   use type C.int;
   use type C.long_long;
   use type SSE.Integer_Address;
   use type System.Address;
   use type Engine.Cancellation_Disposition;

   Burst_Size : constant Positive := 128;
   Rounds     : constant Positive := 8;
   Path       : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_TEST_TEMP_ROOT")
     & "/native-aio-slots.data";
   C_Path     : constant C.char_array := C.To_C (Path);
   Mode       : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_NATIVE_AIO_FAULT", "");

   function Creat (Name : C.char_array; Permissions : C.unsigned) return C.int;
   pragma Import (C, Creat, "creat");

   function Eventfd (Initial : C.unsigned; Flags : C.int) return C.int;
   pragma Import (C, Eventfd, "eventfd");

   function Close (Descriptor : C.int) return C.int;
   pragma Import (C, Close, "close");

   function Unlink (Name : C.char_array) return C.int;
   pragma Import (C, Unlink, "unlink");

   function Selected_Linux_Backend return C.int;
   pragma Import (C, Selected_Linux_Backend, "flyology_linux_file_backend");

   type Byte_Array is array (Positive range <>) of aliased C.unsigned_char;
   Data    : Byte_Array (1 .. Burst_Size) := (others => 73);
   Seen    : array (1 .. Burst_Size) of Boolean;
   File_FD : C.int := -1;
   Wake_FD : C.int := -1;
   Item    : Engine.Engine;
   Values  : Engine.Completion_Array (1 .. Burst_Size);
   Count   : Natural;
   Error   : C.int;

   procedure Drain_One (Expected_Token : System.Address) is
      Limit : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (10);
   begin
      loop
         if not Engine.Drain (Item, Values, Count) then
            raise Program_Error with "native-AIO drain failed";
         end if;
         if Count = 1 then
            if Values (1).Token /= Expected_Token
              or else Values (1).Result /= 1
              or else Values (1).Error_Code /= 0
            then
               raise Program_Error
                 with "native-AIO completion did not retain its result";
            end if;
            return;
         elsif Count /= 0 then
            raise Program_Error
              with "native-AIO drain returned unexpected completions";
         elsif Ada.Real_Time.Clock >= Limit then
            raise Program_Error with "native-AIO completion timed out";
         end if;
         delay 0.001;
      end loop;
   end Drain_One;

begin
   if Ada.Directories.Exists (Path) then
      Ada.Directories.Delete_File (Path);
   end if;
   File_FD := Creat (C_Path, 8#600#);
   Wake_FD := Eventfd (0, 0);
   if File_FD < 0 or else Wake_FD < 0 then
      raise Program_Error
        with "native-AIO test descriptors could not be created";
   elsif not Engine.Initialize (Item, Poller_FD => -1, Wake_FD => Wake_FD) then
      raise Program_Error with "native-AIO test engine could not initialize";
   elsif Selected_Linux_Backend /= 2 then
      Engine.Finalize (Item);
      raise Program_Error
        with "native-AIO slot test requires the forced fallback";
   end if;

   for Round in 1 .. Rounds loop
      Seen := (others => False);
      for Index in Data'Range loop
         if not Engine.Submit
                  (Item,
                   Descriptor => File_FD,
                   Buffer     => Data (Index)'Address,
                   Length     => 1,
                   Offset     =>
                     C.long_long ((Round - 1) * Burst_Size + Index - 1),
                   For_Write  => True,
                   Token      => SSE.To_Address (SSE.Integer_Address (Index)),
                   Error_Code => Error)
         then
            raise Program_Error
              with "native-AIO burst submission failed" & C.int'Image (Error);
         end if;
      end loop;
      declare
         Completed : Natural := 0;
         Limit     : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (10);
      begin
         while Completed < Burst_Size loop
            if not Engine.Drain (Item, Values, Count) then
               raise Program_Error with "native-AIO burst drain failed";
            end if;
            for Result_Index in 1 .. Count loop
               declare
                  Number : constant SSE.Integer_Address :=
                    SSE.To_Integer (Values (Result_Index).Token);
               begin
                  if Number not in 1 .. SSE.Integer_Address (Burst_Size)
                    or else Seen (Natural (Number))
                    or else Values (Result_Index).Result /= 1
                    or else Values (Result_Index).Error_Code /= 0
                  then
                     raise Program_Error
                       with
                         "native-AIO burst returned a duplicate or invalid result";
                  end if;
                  Seen (Natural (Number)) := True;
                  Completed := Completed + 1;
               end;
            end loop;
            if Count = 0 then
               if Ada.Real_Time.Clock >= Limit then
                  raise Program_Error with "native-AIO burst timed out";
               end if;
               delay 0.001;
            end if;
         end loop;
      end;
   end loop;

   for Index in 1 .. 64 loop
      declare
         Token          : constant System.Address :=
           SSE.To_Address (SSE.Integer_Address (Index));
         Cancelled      : Engine.Completion;
         Has_Completion : Boolean;
         Disposition    : Engine.Cancellation_Disposition;
      begin
         if not Engine.Submit
                  (Item,
                   Descriptor => File_FD,
                   Buffer     => Data (Index)'Address,
                   Length     => 1,
                   Offset     =>
                     C.long_long ((Rounds * Burst_Size) + Index - 1),
                   For_Write  => True,
                   Token      => Token,
                   Error_Code => Error)
         then
            raise Program_Error
              with "native-AIO cancellation submission failed";
         end if;
         Disposition :=
           Engine.Cancel
             (Item, File_FD, Token, Cancelled, Has_Completion, Error);
         if Disposition = Engine.Cancellation_Failed or else Has_Completion
         then
            raise Program_Error
              with "native-AIO cancellation lost terminal ownership";
         end if;
         Drain_One (Token);
      end;
   end loop;

   if Mode /= "" then
      declare
         Point    : constant Fault_Control.Point :=
           (if Mode = "stale"
            then Fault_Control.File_Native_AIO_Stale_Data
            elsif Mode = "object"
            then Fault_Control.File_Native_AIO_Bad_Object
            else
              raise Program_Error
                with "unknown native-AIO payload fault mode");
         Rejected : Boolean := False;
         Limit    : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (10);
      begin
         if not Fault_Control.Enabled then
            raise Program_Error
              with "native-AIO payload fault hooks are disabled";
         end if;
         if not Engine.Submit
                  (Item,
                   Descriptor => File_FD,
                   Buffer     => Data (1)'Address,
                   Length     => 1,
                   Offset     => C.long_long (Rounds * Burst_Size + 64),
                   For_Write  => True,
                   Token      => SSE.To_Address (1),
                   Error_Code => Error)
         then
            raise Program_Error
              with "native-AIO payload-fault submission failed";
         end if;
         Fault_Control.Arm (Point);
         while not Rejected loop
            begin
               if not Engine.Drain (Item, Values, Count) then
                  raise Program_Error
                    with "native-AIO payload-fault drain failed";
               end if;
            exception
               when Program_Error =>
                  if Fault_Control.Calls (Point) = 0 then
                     raise;
                  end if;
                  Rejected := True;
            end;
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error
                 with "native-AIO payload fault was not rejected";
            end if;
            if Count = 0 and then not Rejected then
               delay 0.001;
            end if;
         end loop;
         if Engine.Is_Quiescent (Item) then
            raise Program_Error
              with "native-AIO rejected payload released its request";
         end if;
         --  The kernel has completed, but validation deliberately retains
         --  the rejected request. Process exit owns this test-only cleanup.
      end;
   else
      Engine.Finalize (Item);
   end if;
   if Close (File_FD) /= 0 then
      raise Program_Error with "native-AIO test file close failed";
   end if;
   if Close (Wake_FD) /= 0 then
      raise Program_Error with "native-AIO test wake close failed";
   end if;
   if Unlink (C_Path) /= 0 then
      raise Program_Error with "native-AIO test file unlink failed";
   end if;
end Native_AIO_Slots_Smoke;
