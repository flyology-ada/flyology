with GNAT.OS_Lib;
with Flyology_Config;
with Flyology.File_Open_Policy;
with Flyology.File_Timeout_Policy;
with Flyology.Operations.Drivers;
with System.OS_Constants;

package body Flyology.IO.Files is
   package C renames Interfaces.C;

   use type Ada.Streams.Stream_Element_Offset;
   use type Flyology.Operations.Terminal_Outcome;
   use type C.int;
   use type C.long;
   use type C.long_long;

   Is_Darwin : constant Boolean := Flyology_Config.Alire_Host_OS = "macos";

   function C_Open (Path : System.Address; Flags : C.int; Permissions : C.int) return C.int;
   --  open(2)'s third parameter is variadic. That distinction matters on
   --  AArch64 Darwin, where variadic arguments use a different ABI.
   pragma Import (C_Variadic_2, C_Open, "open");

   function C_Pread
     (FD : C.int; Buffer : System.Address; Length : C.size_t; Offset : C.long_long) return C.long;
   pragma Import (C, C_Pread, "pread");

   function C_Pwrite
     (FD : C.int; Buffer : System.Address; Length : C.size_t; Offset : C.long_long) return C.long;
   pragma Import (C, C_Pwrite, "pwrite");

   function Event_File_IO
     (Descriptor  : C.int;
      Buffer      : System.Address;
      Length      : C.size_t;
      Offset      : C.long_long;
      For_Write   : C.int;
      Cancel_FD   : C.int;
      Transferred : access C.long_long;
      Error_Code  : access C.int;
      Cancelled   : access C.int) return C.int;
   pragma Import (C, Event_File_IO, "flyology_runtime_file_io");
   --  Result of Event_File_IO when the calling lightweight task is inside a
   --  protected action. The value is fixed by the documented result of
   --  System.Flyology.Scheduler.File_IO.
   Runtime_Blocked_In_Protected_Action : constant C.int := -2;

   function Start_Async_File
     (Node       : System.Address;
      Node_Size  : C.size_t;
      Descriptor : C.int;
      Buffer     : System.Address;
      Length     : C.size_t;
      Offset     : C.long_long;
      For_Write  : C.int;
      Signal_FD  : C.int) return C.int;
   pragma Import (C, Start_Async_File, "flyology_runtime_start_async_file");

   function Cancel_Async_File (Node : System.Address; Node_Size : C.size_t) return C.int;
   pragma Import (C, Cancel_Async_File, "flyology_runtime_cancel_async_file");

   Async_File_Node_Size : constant C.size_t := C.size_t (Async_File_Node'Size / System.Storage_Unit);

   function Current_Errno return C.int
   is (C.int (GNAT.OS_Lib.Errno));

   procedure Cancellation_Source
     (Token : access Cancellation_Token; Lightweight : Boolean; Descriptor : out C.int)
   is
      Already_Requested : Boolean := False;
   begin
      if Token = null then
         Descriptor := -1;
      elsif not Lightweight then
         --  Native file calls cannot be interrupted once inside pread/pwrite.
         --  Observe an already-requested token without allocating an
         --  event-loop wake source that this lane could never wait on.
         Descriptor := -1;
         if Token.Requested then
            raise Operation_Cancelled;
         end if;
      else
         Token.Wait_Source (Descriptor, Already_Requested);
         if Already_Requested then
            raise Operation_Cancelled;
         end if;
      end if;
   end Cancellation_Source;

   procedure Raise_IO_Error (Operation : String; Error_Code : C.int) is
   begin
      raise Device_Error with Operation & " failed, errno=" & Error_Code'Image;
   end Raise_IO_Error;

   function Open
     (Path : String; Mode : Open_Mode := Read_Only; Create : Boolean := False; Truncate : Boolean := False)
      return File_Descriptor
   is
      C_Path      : aliased String (1 .. Path'Length + 1);
      Policy_Mode : constant File_Open_Policy.Access_Mode :=
        (case Mode is
           when Read_Only  => File_Open_Policy.Read_Only,
           when Write_Only => File_Open_Policy.Write_Only,
           when Read_Write => File_Open_Policy.Read_Write);
      Flags       : constant C.int := File_Open_Policy.Compose (Policy_Mode, Create, Truncate);
      Result      : C.int;
   begin
      if not File_Open_Policy.Valid (Policy_Mode, Truncate) then
         raise Device_Error with "open failed: Truncate requires Write_Only or Read_Write mode";
      end if;

      C_Path (1 .. Path'Length) := Path;
      C_Path (C_Path'Last) := ASCII.NUL;
      Result := C_Open (C_Path'Address, Flags, 8#666#);
      if Result < 0 then
         Raise_IO_Error ("open", Current_Errno);
      end if;
      return File_Descriptor (Result);
   end Open;

   procedure Close (File : in out File_Descriptor) is
      Status : Boolean;
   begin
      if File = Invalid_File then
         return;
      end if;
      GNAT.OS_Lib.Close (GNAT.OS_Lib.File_Descriptor (File), Status);
      File := Invalid_File;
      if not Status then
         Raise_IO_Error ("close", Current_Errno);
      end if;
   end Close;

   procedure Rearm_Completion (Item : in out File_Operation'Class) is
      Read_Descriptor   : C.int;
      Signal_Descriptor : C.int;
   begin
      Flyology.Operations.Drivers.Completion_Source (Item, Read_Descriptor, Signal_Descriptor);
      Flyology.Operations.Drivers.Arm_Readiness (Item, Read_Descriptor, False);
   end Rearm_Completion;

   procedure Publish_File_Terminal (Item : in out File_Operation'Class) is
   begin
      if Item.Node.State /= Async_File_Terminal then
         Rearm_Completion (Item);
      elsif Item.Node.Cancelled /= 0 or else Item.Cancellation_Requested then
         if Item.Timed_Out then
            Item.Failure := Deadline_Failure;
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
         else
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Cancelled);
         end if;
      elsif Item.Node.Error_Code /= 0
        or else Item.Node.Result < 0
        or else Item.Node.Result > C.long_long (Item.Buffer_Length)
      then
         Item.Failure := Completion_Failure;
         Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
      else
         Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Succeeded);
      end if;
   end Publish_File_Terminal;

   procedure Start_Scoped_File
     (Item      : in out File_Operation'Class;
      File      : File_Descriptor;
      Offset    : File_Offset;
      Buffer    : System.Address;
      First     : Ada.Streams.Stream_Element_Offset;
      Length    : Natural;
      For_Write : Boolean;
      Timeout   : Duration)
   is
      Read_Descriptor   : C.int := -1;
      Signal_Descriptor : C.int := -1;
      Status            : C.int;
   begin
      Item.Node.Version := Async_File_Node_Version;
      Item.Node.State := Async_File_Unused;
      Item.Node.Owner := System.Null_Address;
      Item.Node.Descriptor := -1;
      Item.Node.Buffer := System.Null_Address;
      Item.Node.Length := 0;
      Item.Node.Offset := 0;
      Item.Node.For_Write := 0;
      Item.Node.Signal_FD := -1;
      Item.Node.Result := 0;
      Item.Node.Error_Code := 0;
      Item.Node.Cancelled := 0;
      Item.Node.Cancel_Requested := 0;
      Item.Node.Next := System.Null_Address;
      Item.Buffer_First := First;
      Item.Buffer_Length := Length;
      Item.Failure := No_Failure;
      Item.Timed_Out := False;
      Item.Cancellation_Requested := False;

      Flyology.Operations.Drivers.Start (Item);
      if Length = 0 then
         Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Succeeded);
         return;
      elsif not Flyology.IO.Is_Lightweight_Task then
         Item.Failure := Wrong_Lane_Failure;
         Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
         return;
      end if;

      Flyology.Operations.Drivers.Completion_Source (Item, Read_Descriptor, Signal_Descriptor);
      --  A positional file operation has no would-block result to abandon.
      --  As in the synchronous overload, zero requests the one operation
      --  attempt itself and therefore carries no competing deadline.
      if Timeout > 0.0 then
         Flyology.Operations.Drivers.Arm_Deadline (Item, Timeout);
      end if;
      --  Publish the completion source before submission. This leaves every
      --  expected exception on the rollback-safe side of kernel ownership;
      --  the wake source retains an early completion signal until the set
      --  next waits.
      Flyology.Operations.Drivers.Arm_Readiness (Item, Read_Descriptor, False);
      Status :=
        Start_Async_File
          (Item.Node'Address,
           Async_File_Node_Size,
           C.int (File),
           Buffer,
           C.size_t (Length),
           C.long_long (Offset),
           Boolean'Pos (For_Write),
           Signal_Descriptor);
      if Status /= 0 then
         Item.Failure := Submission_Failure;
         Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
      end if;
   exception
      when others =>
         if Flyology.Operations.Is_Active (Item) and then Item.Node.State = Async_File_Unused then
            Flyology.Operations.Drivers.Rollback_Start (Item);
         end if;
         raise;
   end Start_Scoped_File;

   overriding
   procedure Drive (Item : in out File_Operation; Event : Flyology.Operations.Driver_Event) is
      Status : C.int;
   begin
      case Event is
         when Flyology.Operations.Start_Operation                                             =>
            raise Program_Error with "file operation was already submitted";

         when Flyology.Operations.Source_Ready                                                =>
            Publish_File_Terminal (Item);

         when Flyology.Operations.Deadline_Reached                                            =>
            if Item.Cancellation_Requested then
               Rearm_Completion (Item);
               return;
            end if;
            Item.Timed_Out := True;
            if Is_Darwin and then Item.Node.State = Async_File_Submitted then
               --  Darwin POSIX AIO notifications are keyed by the aiocb
               --  address. Reaping an immediate aio_cancel result and then
               --  reusing that address can suppress a later EVFILT_AIO
               --  notification. Keep the request registered and turn its
               --  natural completion into the terminal timeout instead.
               Item.Cancellation_Requested := True;
               Rearm_Completion (Item);
               return;
            end if;
            Status := Cancel_Async_File (Item.Node'Address, Async_File_Node_Size);
            if Status /= 0 then
               --  Do not release the borrow on a rejected cancellation. The
               --  original completion remains the only safe terminal event.
               Rearm_Completion (Item);
            else
               Publish_File_Terminal (Item);
            end if;

         when Flyology.Operations.Dependency_Changed | Flyology.Operations.Continue_Operation =>
            raise Program_Error with "file operation received a dependency event";
      end case;
   end Drive;

   overriding
   procedure Request_Cancellation (Item : in out File_Operation) is
      Status : C.int;
   begin
      if Item.Node.State = Async_File_Unused then
         Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Cancelled);
         return;
      elsif Is_Darwin and then Item.Node.State = Async_File_Submitted then
         --  A submitted Darwin request remains kernel-owned until its normal
         --  completion notification. Delayed cancellation is already part of
         --  the public buffer-safety contract.
         Item.Cancellation_Requested := True;
         return;
      end if;
      Status := Cancel_Async_File (Item.Node'Address, Async_File_Node_Size);
      if Status = 0 and then Item.Node.State = Async_File_Terminal then
         Publish_File_Terminal (Item);
      end if;
   end Request_Cancellation;

   procedure Read_At
     (File      : File_Descriptor;
      Offset    : File_Offset;
      Item      : not null access Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Flyology.IO.Infinite;
      Operation : in out Read_Operation)
   is
      Address : constant System.Address :=
        (if Item.all'Length = 0 then System.Null_Address else Item.all (Item.all'First)'Address);
   begin
      Start_Scoped_File (Operation, File, Offset, Address, Item.all'First, Item.all'Length, False, Timeout);
   end Read_At;

   function Read_At
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      File    : File_Descriptor;
      Offset  : File_Offset;
      Item    : not null access Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Flyology.IO.Infinite) return Read_Operation is
   begin
      return Result : Read_Operation (Set) do
         Read_At (File, Offset, Item, Timeout, Result);
      end return;
   end Read_At;

   procedure Write_At
     (File      : File_Descriptor;
      Offset    : File_Offset;
      Item      : not null access constant Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Flyology.IO.Infinite;
      Operation : in out Write_Operation)
   is
      Address : constant System.Address :=
        (if Item.all'Length = 0 then System.Null_Address else Item.all (Item.all'First)'Address);
   begin
      Start_Scoped_File (Operation, File, Offset, Address, Item.all'First, Item.all'Length, True, Timeout);
   end Write_At;

   function Write_At
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      File    : File_Descriptor;
      Offset  : File_Offset;
      Item    : not null access constant Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Flyology.IO.Infinite) return Write_Operation is
   begin
      return Result : Write_Operation (Set) do
         Write_At (File, Offset, Item, Timeout, Result);
      end return;
   end Write_At;

   procedure Read_At
     (File      : File_Descriptor;
      Offset    : File_Offset;
      Item      : in out Flyology.Buffers.Unique_Buffer;
      Timeout   : Duration := Flyology.IO.Infinite;
      Operation : in out Read_Operation) is
   begin
      Flyology.Buffers.Drivers.Move_From (Item, Operation.Owned);
      begin
         Start_Scoped_File
           (Operation,
            File,
            Offset,
            Flyology.Buffers.Drivers.Address (Operation.Owned),
            1,
            Flyology.Buffers.Drivers.Capacity (Operation.Owned),
            False,
            Timeout);
      exception
         when others =>
            Flyology.Buffers.Drivers.Move_To (Operation.Owned, Item);
            raise;
      end;
   end Read_At;

   function Read_At
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      File    : File_Descriptor;
      Offset  : File_Offset;
      Item    : in out Flyology.Buffers.Unique_Buffer;
      Timeout : Duration := Flyology.IO.Infinite) return Read_Operation is
   begin
      return Result : Read_Operation (Set) do
         Read_At (File, Offset, Item, Timeout, Result);
      end return;
   end Read_At;

   procedure Write_At
     (File      : File_Descriptor;
      Offset    : File_Offset;
      Item      : in out Flyology.Buffers.Unique_Buffer;
      Timeout   : Duration := Flyology.IO.Infinite;
      Operation : in out Write_Operation) is
   begin
      Flyology.Buffers.Drivers.Move_From (Item, Operation.Owned);
      begin
         Start_Scoped_File
           (Operation,
            File,
            Offset,
            Flyology.Buffers.Drivers.Address (Operation.Owned),
            1,
            Flyology.Buffers.Drivers.Length (Operation.Owned),
            True,
            Timeout);
      exception
         when others =>
            Flyology.Buffers.Drivers.Move_To (Operation.Owned, Item);
            raise;
      end;
   end Write_At;

   function Write_At
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      File    : File_Descriptor;
      Offset  : File_Offset;
      Item    : in out Flyology.Buffers.Unique_Buffer;
      Timeout : Duration := Flyology.IO.Infinite) return Write_Operation is
   begin
      return Result : Write_Operation (Set) do
         Write_At (File, Offset, Item, Timeout, Result);
      end return;
   end Write_At;

   procedure Raise_Finish_Status
     (Outcome : Flyology.Operations.Terminal_Outcome; Failure : Scoped_File_Failure; Error : C.int) is
   begin
      case Outcome is
         when Flyology.Operations.Succeeded =>
            null;

         when Flyology.Operations.Cancelled =>
            raise Flyology.Operations.Operation_Cancelled;

         when Flyology.Operations.Failed    =>
            case Failure is
               when Deadline_Failure   =>
                  raise Timeout_Error with "file operation timed out";

               when Wrong_Lane_Failure =>
                  raise Device_Error with "scoped file operations require a lightweight task";

               when Submission_Failure =>
                  Raise_IO_Error ("file submission", Error);

               when Completion_Failure =>
                  Raise_IO_Error ("file completion", Error);

               when No_Failure         =>
                  raise Device_Error with "file operation failed";
            end case;
      end case;
   end Raise_Finish_Status;

   procedure Finish_Common (Operation : in out File_Operation'Class) is
      Outcome : constant Flyology.Operations.Terminal_Outcome := Flyology.Operations.Outcome (Operation);
      Failure : constant Scoped_File_Failure := Operation.Failure;
      Error   : constant C.int := Operation.Node.Error_Code;
   begin
      if Flyology.Buffers.Drivers.Has_Buffer (Operation.Owned) then
         raise Program_Error with "owning file operation requires buffer-returning Finish";
      end if;
      Flyology.Operations.Consume (Operation);
      Raise_Finish_Status (Outcome, Failure, Error);
   end Finish_Common;

   procedure Finish (Operation : in out Read_Operation; Last : out Ada.Streams.Stream_Element_Offset) is
      Result : constant C.long_long := Operation.Node.Result;
      First  : constant Ada.Streams.Stream_Element_Offset := Operation.Buffer_First;
   begin
      Finish_Common (Operation);
      Last := (if Result = 0 then First - 1 else First + Ada.Streams.Stream_Element_Offset (Result) - 1);
   end Finish;

   procedure Finish
     (Operation : in out Read_Operation; Item : in out Flyology.Buffers.Unique_Buffer; Read : out Natural)
   is
      Result  : constant C.long_long := Operation.Node.Result;
      Outcome : constant Flyology.Operations.Terminal_Outcome := Flyology.Operations.Outcome (Operation);
      Failure : constant Scoped_File_Failure := Operation.Failure;
      Error   : constant C.int := Operation.Node.Error_Code;
   begin
      if Flyology.Buffers.Has_Buffer (Item) then
         raise Program_Error with "file operation finish buffer is occupied";
      elsif not Flyology.Buffers.Drivers.Same_Pool (Operation.Owned, Item) then
         raise Program_Error with "file operation buffer pool mismatch";
      end if;
      Flyology.Operations.Consume (Operation);
      if Outcome = Flyology.Operations.Succeeded then
         Flyology.Buffers.Drivers.Set_Length (Operation.Owned, Natural (Result));
      end if;
      Flyology.Buffers.Drivers.Move_To (Operation.Owned, Item);
      Raise_Finish_Status (Outcome, Failure, Error);
      Read := Natural (Result);
   end Finish;

   procedure Finish
     (Operation : in out Write_Operation; Item : in out Flyology.Buffers.Unique_Buffer; Written : out Natural)
   is
      Result  : constant C.long_long := Operation.Node.Result;
      Outcome : constant Flyology.Operations.Terminal_Outcome := Flyology.Operations.Outcome (Operation);
      Failure : constant Scoped_File_Failure := Operation.Failure;
      Error   : constant C.int := Operation.Node.Error_Code;
   begin
      if Flyology.Buffers.Has_Buffer (Item) then
         raise Program_Error with "file operation finish buffer is occupied";
      elsif not Flyology.Buffers.Drivers.Same_Pool (Operation.Owned, Item) then
         raise Program_Error with "file operation buffer pool mismatch";
      end if;
      Flyology.Operations.Consume (Operation);
      Flyology.Buffers.Drivers.Move_To (Operation.Owned, Item);
      Raise_Finish_Status (Outcome, Failure, Error);
      Written := Natural (Result);
   end Finish;

   procedure Finish (Operation : in out Write_Operation; Last : out Ada.Streams.Stream_Element_Offset) is
      Result : constant C.long_long := Operation.Node.Result;
      First  : constant Ada.Streams.Stream_Element_Offset := Operation.Buffer_First;
   begin
      Finish_Common (Operation);
      Last := (if Result = 0 then First - 1 else First + Ada.Streams.Stream_Element_Offset (Result) - 1);
   end Finish;

   procedure Native_Read
     (File        : File_Descriptor;
      Offset      : File_Offset;
      Item        : out Ada.Streams.Stream_Element_Array;
      Transferred : out C.long_long;
      Error_Code  : out C.int)
   is
      Result : C.long;
   begin
      loop
         Result := C_Pread (C.int (File), Item'Address, C.size_t (Item'Length), C.long_long (Offset));
         exit when Result >= 0 or else Current_Errno /= C.int (System.OS_Constants.EINTR);
      end loop;
      if Result < 0 then
         Transferred := 0;
         Error_Code := Current_Errno;
      else
         Transferred := C.long_long (Result);
         Error_Code := 0;
      end if;
   end Native_Read;

   procedure Native_Write
     (File        : File_Descriptor;
      Offset      : File_Offset;
      Item        : Ada.Streams.Stream_Element_Array;
      Transferred : out C.long_long;
      Error_Code  : out C.int)
   is
      Result : C.long;
   begin
      loop
         Result := C_Pwrite (C.int (File), Item'Address, C.size_t (Item'Length), C.long_long (Offset));
         exit when Result >= 0 or else Current_Errno /= C.int (System.OS_Constants.EINTR);
      end loop;
      if Result < 0 then
         Transferred := 0;
         Error_Code := Current_Errno;
      else
         Transferred := C.long_long (Result);
         Error_Code := 0;
      end if;
   end Native_Write;

   procedure Read_At
     (File   : File_Descriptor;
      Offset : File_Offset;
      Item   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Token  : access Cancellation_Token := null)
   is
      Transferred : aliased C.long_long := 0;
      Error_Code  : aliased C.int := 0;
      Cancelled   : aliased C.int := 0;
      Status      : C.int := 0;
      Cancel_FD   : C.int := -1;
   begin
      Last := Item'First - 1;
      if Item'Length = 0 then
         return;
      end if;
      declare
         Lightweight : constant Boolean := Is_Lightweight_Task;
      begin
         Cancellation_Source (Token, Lightweight, Cancel_FD);
         if Lightweight then
            Status :=
              Event_File_IO
                (C.int (File),
                 Item'Address,
                 C.size_t (Item'Length),
                 C.long_long (Offset),
                 0,
                 Cancel_FD,
                 Transferred'Access,
                 Error_Code'Access,
                 Cancelled'Access);
         else
            Native_Read (File, Offset, Item, Transferred, Error_Code);
         end if;
      end;
      if Status = Runtime_Blocked_In_Protected_Action then
         --  GNARL's wording at every RM 9.5.1 detection site. Item was never
         --  submitted, and the normal unwinding releases the protected
         --  object's lock on the thread that holds it.
         raise Program_Error with "potentially blocking operation";
      elsif Status /= 0 and then Error_Code = 0 then
         raise Device_Error with "lightweight pread submission failed";
      elsif Cancelled /= 0 then
         raise Operation_Cancelled;
      elsif Error_Code /= 0 then
         Raise_IO_Error ("pread", Error_Code);
      elsif Transferred < 0 or else Transferred > C.long_long (Item'Length) then
         raise Device_Error with "pread returned an invalid length";
      elsif Transferred > 0 then
         Last := Item'First + Ada.Streams.Stream_Element_Offset (Transferred) - 1;
      end if;
   end Read_At;

   procedure Read_At
     (File    : File_Descriptor;
      Offset  : File_Offset;
      Item    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Cancellation_Token := null)
   is
      use type Flyology.File_Timeout_Policy.Read_Disposition;
   begin
      Last := Item'First - 1;
      if Item'Length = 0 then
         return;
      elsif Token /= null and then Token.Requested then
         raise Operation_Cancelled;
      elsif Flyology.File_Timeout_Policy.Classify (Timeout) = Flyology.File_Timeout_Policy.Read_Immediately
      then
         --  A negative Timeout waits without a deadline. Zero is the
         --  library-wide immediate attempt, and a positional read has no
         --  readiness wait to abandon: the kernel either transfers bytes or
         --  reports end of file or an error. Arming a deadline around that
         --  attempt could only discard a result the caller asked for, so both
         --  cases run the untimed read and let its outcome win.
         Read_At (File, Offset, Item, Last, Token);
      else
         select
            delay Timeout;
            raise Timeout_Error;
         then abort
            Read_At (File, Offset, Item, Last, Token);
         end select;
      end if;
   end Read_At;

   procedure Read_At
     (File   : File_Descriptor;
      Offset : File_Offset;
      Item   : in out Flyology.Buffers.Unique_Buffer;
      Read   : out Natural;
      Token  : access Cancellation_Token := null)
   is
      procedure Borrow (Data : in out Ada.Streams.Stream_Element_Array; Length : in out Natural) is
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Read_At (File, Offset, Data, Last, Token);
         Length := (if Last < Data'First then 0 else Natural (Last - Data'First + 1));
         Read := Length;
      end Borrow;
   begin
      Read := 0;
      Flyology.Buffers.With_Writable_Data (Item, Borrow'Access);
   end Read_At;

   procedure Read_At
     (File    : File_Descriptor;
      Offset  : File_Offset;
      Item    : in out Flyology.Buffers.Unique_Buffer;
      Read    : out Natural;
      Timeout : Duration;
      Token   : access Cancellation_Token := null)
   is
      procedure Borrow (Data : in out Ada.Streams.Stream_Element_Array; Length : in out Natural) is
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Read_At (File, Offset, Data, Last, Timeout, Token);
         Length := (if Last < Data'First then 0 else Natural (Last - Data'First + 1));
         Read := Length;
      end Borrow;
   begin
      Read := 0;
      Flyology.Buffers.With_Writable_Data (Item, Borrow'Access);
   end Read_At;

   procedure Write_At
     (File   : File_Descriptor;
      Offset : File_Offset;
      Item   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Token  : access Cancellation_Token := null)
   is
      Transferred : aliased C.long_long := 0;
      Error_Code  : aliased C.int := 0;
      Cancelled   : aliased C.int := 0;
      Status      : C.int := 0;
      Cancel_FD   : C.int := -1;
   begin
      Last := Item'First - 1;
      if Item'Length = 0 then
         return;
      end if;
      declare
         Lightweight : constant Boolean := Is_Lightweight_Task;
      begin
         Cancellation_Source (Token, Lightweight, Cancel_FD);
         if Lightweight then
            Status :=
              Event_File_IO
                (C.int (File),
                 Item'Address,
                 C.size_t (Item'Length),
                 C.long_long (Offset),
                 1,
                 Cancel_FD,
                 Transferred'Access,
                 Error_Code'Access,
                 Cancelled'Access);
         else
            Native_Write (File, Offset, Item, Transferred, Error_Code);
         end if;
      end;
      if Status = Runtime_Blocked_In_Protected_Action then
         raise Program_Error with "potentially blocking operation";
      elsif Status /= 0 and then Error_Code = 0 then
         raise Device_Error with "lightweight pwrite submission failed";
      elsif Cancelled /= 0 then
         raise Operation_Cancelled;
      elsif Error_Code /= 0 then
         Raise_IO_Error ("pwrite", Error_Code);
      elsif Transferred < 0 or else Transferred > C.long_long (Item'Length) then
         raise Device_Error with "pwrite returned an invalid length";
      elsif Transferred > 0 then
         Last := Item'First + Ada.Streams.Stream_Element_Offset (Transferred) - 1;
      end if;
   end Write_At;

   procedure Write_At
     (File    : File_Descriptor;
      Offset  : File_Offset;
      Item    : Flyology.Buffers.Unique_Buffer;
      Written : out Natural;
      Token   : access Cancellation_Token := null)
   is
      procedure Borrow (Data : Ada.Streams.Stream_Element_Array) is
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Write_At (File, Offset, Data, Last, Token);
         Written := (if Last < Data'First then 0 else Natural (Last - Data'First + 1));
      end Borrow;
   begin
      Written := 0;
      Flyology.Buffers.With_Readable_Data (Item, Borrow'Access);
   end Write_At;

end Flyology.IO.Files;
