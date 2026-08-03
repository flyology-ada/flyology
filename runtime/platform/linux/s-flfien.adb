with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with Interfaces;
with System.Atomic_Primitives;
with System.Flyology.Faults;
with System.Flyology.Time_ABI;
with System.OS_Interface;
with System.Storage_Elements;

package body System.Flyology.File_Engine is
   package AP renames System.Atomic_Primitives;
   package C renames Interfaces.C;
   package Faults renames System.Flyology.Faults;
   package Time_ABI renames System.Flyology.Time_ABI;
   package OSI renames System.OS_Interface;
   package SSE renames System.Storage_Elements;

   use type C.int;
   use type C.long;
   use type C.size_t;
   use type C.unsigned_long;
   use type Interfaces.Integer_32;
   use type Interfaces.Integer_64;
   use type AP.uint32;
   use System.Storage_Elements;

   subtype U8 is AP.uint8;
   subtype U16 is AP.uint16;
   subtype U32 is AP.uint32;
   subtype U64 is AP.uint64;
   subtype S32 is Interfaces.Integer_32;
   subtype S64 is Interfaces.Integer_64;

   Ring_Entries : constant U32 := 1_024;
   ENOSYS : constant C.int := 38;
   EPERM  : constant C.int := 1;
   EINVAL : constant C.int := 22;
   ENOMEM : constant C.int := 12;
   EAGAIN : constant C.int := 11;
   EBUSY  : constant C.int := 16;
   ENOENT : constant C.int := 2;

   PROT_READ  : constant C.int := 1;
   PROT_WRITE : constant C.int := 2;
   MAP_SHARED : constant C.int := 1;

   IORING_OFF_SQ_RING : constant C.long_long := 16#0000_0000#;
   IORING_OFF_CQ_RING : constant C.long_long := 16#0800_0000#;
   IORING_OFF_SQES    : constant C.long_long := 16#1000_0000#;

   IORING_FEAT_SINGLE_MMAP       : constant U32 := 1;
   IORING_SQ_CQ_OVERFLOW         : constant U32 := 2;
   IORING_ENTER_GETEVENTS        : constant C.unsigned := 1;
   IORING_REGISTER_EVENTFD       : constant U32 := 4;
   IORING_REGISTER_EVENTFD_ASYNC : constant U32 := 7;
   IORING_OP_READ                : constant U8 := 22;
   IORING_OP_WRITE               : constant U8 := 23;
   IORING_OP_ASYNC_CANCEL        : constant U8 := 14;

   IOCB_CMD_PREAD  : constant U16 := 0;
   IOCB_CMD_PWRITE : constant U16 := 1;
   IOCB_FLAG_RESFD : constant U32 := 1;

   type SQ_Ring_Offsets is record
      Head         : U32;
      Tail         : U32;
      Ring_Mask    : U32;
      Ring_Entries : U32;
      Flags        : U32;
      Dropped      : U32;
      Array_Offset : U32;
      Reserved     : U32;
      User_Address : U64;
   end record
     with Convention => C, Size => 320, Alignment => 8;
   for SQ_Ring_Offsets use record
      Head         at 0  range 0 .. 31;
      Tail         at 4  range 0 .. 31;
      Ring_Mask    at 8  range 0 .. 31;
      Ring_Entries at 12 range 0 .. 31;
      Flags        at 16 range 0 .. 31;
      Dropped      at 20 range 0 .. 31;
      Array_Offset at 24 range 0 .. 31;
      Reserved     at 28 range 0 .. 31;
      User_Address at 32 range 0 .. 63;
   end record;

   type CQ_Ring_Offsets is record
      Head         : U32;
      Tail         : U32;
      Ring_Mask    : U32;
      Ring_Entries : U32;
      Overflow     : U32;
      CQEs         : U32;
      Flags        : U32;
      Reserved     : U32;
      User_Address : U64;
   end record
     with Convention => C, Size => 320, Alignment => 8;
   for CQ_Ring_Offsets use record
      Head         at 0  range 0 .. 31;
      Tail         at 4  range 0 .. 31;
      Ring_Mask    at 8  range 0 .. 31;
      Ring_Entries at 12 range 0 .. 31;
      Overflow     at 16 range 0 .. 31;
      CQEs         at 20 range 0 .. 31;
      Flags        at 24 range 0 .. 31;
      Reserved     at 28 range 0 .. 31;
      User_Address at 32 range 0 .. 63;
   end record;

   type Reserved_Array is array (1 .. 3) of U32
     with Convention => C;

   type Ring_Parameters is record
      SQ_Entries     : U32;
      CQ_Entries     : U32;
      Flags          : U32;
      SQ_Thread_CPU  : U32;
      SQ_Thread_Idle : U32;
      Features       : U32;
      Workqueue_FD   : U32;
      Reserved       : Reserved_Array;
      SQ_Offsets     : SQ_Ring_Offsets;
      CQ_Offsets     : CQ_Ring_Offsets;
   end record
     with Convention => C, Size => 960, Alignment => 8;
   for Ring_Parameters use record
      SQ_Entries     at 0  range 0 .. 31;
      CQ_Entries     at 4  range 0 .. 31;
      Flags          at 8  range 0 .. 31;
      SQ_Thread_CPU  at 12 range 0 .. 31;
      SQ_Thread_Idle at 16 range 0 .. 31;
      Features       at 20 range 0 .. 31;
      Workqueue_FD   at 24 range 0 .. 31;
      Reserved       at 28 range 0 .. 95;
      SQ_Offsets     at 40 range 0 .. 319;
      CQ_Offsets     at 80 range 0 .. 319;
   end record;

   type Submission_Entry is record
      Opcode       : U8;
      Flags        : U8;
      IO_Priority  : U16;
      Descriptor   : S32;
      Offset       : U64;
      Buffer       : U64;
      Length       : U32;
      Read_Flags   : U32;
      User_Data    : U64;
      Buffer_Index : U16;
      Personality  : U16;
      Input_FD     : S32;
      Address_3    : U64;
      Padding      : U64;
   end record
     with Convention => C, Size => 512, Alignment => 8;
   for Submission_Entry use record
      Opcode       at 0  range 0 .. 7;
      Flags        at 1  range 0 .. 7;
      IO_Priority  at 2  range 0 .. 15;
      Descriptor   at 4  range 0 .. 31;
      Offset       at 8  range 0 .. 63;
      Buffer       at 16 range 0 .. 63;
      Length       at 24 range 0 .. 31;
      Read_Flags   at 28 range 0 .. 31;
      User_Data    at 32 range 0 .. 63;
      Buffer_Index at 40 range 0 .. 15;
      Personality  at 42 range 0 .. 15;
      Input_FD     at 44 range 0 .. 31;
      Address_3    at 48 range 0 .. 63;
      Padding      at 56 range 0 .. 63;
   end record;

   type Completion_Entry is record
      User_Data : U64;
      Result    : S32;
      Flags     : U32;
   end record
     with Convention => C, Size => 128, Alignment => 8;
   for Completion_Entry use record
      User_Data at 0 range 0 .. 63;
      Result    at 8 range 0 .. 31;
      Flags     at 12 range 0 .. 31;
   end record;

   type IOCB is record
      Data        : U64;
      Key         : U32;
      Read_Flags  : U32;
      Opcode      : U16;
      Priority    : Interfaces.Integer_16;
      Descriptor  : U32;
      Buffer      : U64;
      Length      : U64;
      Offset      : S64;
      Reserved    : U64;
      Flags       : U32;
      Result_FD   : U32;
   end record
     with Convention => C, Size => 512, Alignment => 8;
   for IOCB use record
      Data       at 0  range 0 .. 63;
      Key        at 8  range 0 .. 31;
      Read_Flags at 12 range 0 .. 31;
      Opcode     at 16 range 0 .. 15;
      Priority   at 18 range 0 .. 15;
      Descriptor at 20 range 0 .. 31;
      Buffer     at 24 range 0 .. 63;
      Length     at 32 range 0 .. 63;
      Offset     at 40 range 0 .. 63;
      Reserved   at 48 range 0 .. 63;
      Flags      at 56 range 0 .. 31;
      Result_FD  at 60 range 0 .. 31;
   end record;

   type IO_Event is record
      Data   : U64;
      Object : U64;
      Result : S64;
      Extra  : S64;
   end record
     with Convention => C, Size => 256, Alignment => 8;
   for IO_Event use record
      Data   at 0  range 0 .. 63;
      Object at 8  range 0 .. 63;
      Result at 16 range 0 .. 63;
      Extra  at 24 range 0 .. 63;
   end record;

   type Native_AIO_Request;
   type Native_AIO_Request_Access is access all Native_AIO_Request;

   type Native_AIO_Request is record
      Control   : aliased IOCB;
      Next_Free : Native_AIO_Request_Access;
      Token     : System.Address;
      Next_Active : Native_AIO_Request_Access;
   end record
     with Size => 704, Alignment => 8;
   for Native_AIO_Request use record
      Control   at 0  range 0 .. 511;
      Next_Free at 64 range 0 .. 63;
      Token     at 72 range 0 .. 63;
      Next_Active at 80 range 0 .. 63;
   end record;

   --  io_uring cancellation has two independent completions: one for the
   --  data operation and one for the administrative cancel request. Keep a
   --  request identity alive until both have arrived. A fiber address is not
   --  a request identity because the fiber may submit another operation as
   --  soon as the data completion resumes it.
   type IO_Uring_Request;
   type IO_Uring_Request_Access is access all IO_Uring_Request;

   type IO_Uring_Request is record
      Token             : System.Address;
      Cancel_Submitted  : Boolean;
      Operation_Complete : Boolean;
      Admin_Complete    : Boolean;
      Admin_Submit_Deferred : Boolean;
      Next_Free         : IO_Uring_Request_Access;
      Next_Active       : IO_Uring_Request_Access;
      Next_Deferred     : IO_Uring_Request_Access;
   end record
     with Alignment => 8;

   type Backend_Kind is (IO_Uring, Native_AIO);

   type Engine_State is record
      Backend           : Backend_Kind := IO_Uring;
      AIO_Context       : C.unsigned_long := 0;
      Wake_FD           : C.int := -1;
      Ring_FD           : C.int := -1;
      SQ_Mapping        : System.Address := System.Null_Address;
      CQ_Mapping        : System.Address := System.Null_Address;
      SQEs_Mapping      : System.Address := System.Null_Address;
      SQ_Mapping_Size   : C.size_t := 0;
      CQ_Mapping_Size   : C.size_t := 0;
      SQEs_Mapping_Size : C.size_t := 0;
      SQ_Head           : System.Address := System.Null_Address;
      SQ_Tail           : System.Address := System.Null_Address;
      SQ_Mask           : System.Address := System.Null_Address;
      SQ_Entries        : System.Address := System.Null_Address;
      SQ_Flags          : System.Address := System.Null_Address;
      SQ_Array          : System.Address := System.Null_Address;
      SQEs              : System.Address := System.Null_Address;
      CQ_Head           : System.Address := System.Null_Address;
      CQ_Tail           : System.Address := System.Null_Address;
      CQ_Mask           : System.Address := System.Null_Address;
      CQ_Overflow       : System.Address := System.Null_Address;
      CQEs              : System.Address := System.Null_Address;
      CQ_Capacity       : U32 := 0;
      CQ_Overflow_Seen  : U32 := 0;
      --  Count every submitted SQE whose CQE has not yet been consumed.
      --  Administrative cancellation SQEs count independently from their
      --  data requests because each produces its own CQE.
      Uring_In_Flight   : U32 := 0;
      Test_Backpressure_Observed : Boolean := False;
      Free_Requests     : Native_AIO_Request_Access;
      Active_Requests   : Native_AIO_Request_Access;
      Active_Count      : Natural := 0 with Atomic;
      Free_Uring_Requests   : IO_Uring_Request_Access;
      Active_Uring_Requests : IO_Uring_Request_Access;
      Deferred_Admin_Submit_Head : IO_Uring_Request_Access;
   end record;
   type Engine_State_Access is access all Engine_State;

   type Submission_Entry_Access is access all Submission_Entry;
   type Completion_Entry_Access is access all Completion_Entry;

   type IOCB_Address_Array is array (Positive range <>) of System.Address
     with Convention => C;
   type IO_Event_Array is array (Positive range <>) of aliased IO_Event
     with Convention => C;

   function To_State is new Ada.Unchecked_Conversion
     (System.Address, Engine_State_Access);
   function State_Address is new Ada.Unchecked_Conversion
     (Engine_State_Access, System.Address);
   function To_Native_Request is new Ada.Unchecked_Conversion
     (System.Address, Native_AIO_Request_Access);
   function To_Uring_Request is new Ada.Unchecked_Conversion
     (System.Address, IO_Uring_Request_Access);
   function To_Submission_Entry is new Ada.Unchecked_Conversion
     (System.Address, Submission_Entry_Access);
   function To_Completion_Entry is new Ada.Unchecked_Conversion
     (System.Address, Completion_Entry_Access);

   procedure Free_State is new Ada.Unchecked_Deallocation
     (Engine_State, Engine_State_Access);
   procedure Free_Native_Request is new Ada.Unchecked_Deallocation
     (Native_AIO_Request, Native_AIO_Request_Access);
   procedure Free_Uring_Request is new Ada.Unchecked_Deallocation
     (IO_Uring_Request, IO_Uring_Request_Access);

   function Mmap
     (Address : System.Address;
      Length  : C.size_t;
      Prot    : C.int;
      Flags   : C.int;
      File    : C.int;
      Offset  : C.long_long) return System.Address;
   pragma Import (C, Mmap, "mmap");

   function Munmap
     (Address : System.Address; Length : C.size_t) return C.int;
   pragma Import (C, Munmap, "munmap");

   function Close (Descriptor : C.int) return C.int;
   pragma Import (C, Close, "close");

   function Write
     (Descriptor : C.int;
      Buffer     : System.Address;
      Length     : C.size_t) return C.long;
   pragma Import (C, Write, "write");

   function Linux_IO_Setup
     (Entries : C.unsigned; Context : System.Address)
      return C.long;
   pragma Import (C, Linux_IO_Setup, "flyology_linux_io_setup");

   function Linux_IO_Destroy (Context : C.unsigned_long) return C.long;
   pragma Import (C, Linux_IO_Destroy, "flyology_linux_io_destroy");

   function Linux_IO_Submit
     (Context  : C.unsigned_long;
      Count    : C.long;
      Controls : System.Address) return C.long;
   pragma Import (C, Linux_IO_Submit, "flyology_linux_io_submit");

   function Linux_IO_Getevents
     (Context : C.unsigned_long;
      Minimum : C.long;
      Count   : C.long;
      Events  : System.Address;
      Timeout : System.Address) return C.long;
   pragma Import (C, Linux_IO_Getevents, "flyology_linux_io_getevents");

   function Linux_IO_Cancel
     (Context : C.unsigned_long;
      Control : System.Address;
      Event   : System.Address) return C.long;
   pragma Import (C, Linux_IO_Cancel, "flyology_linux_io_cancel");

   function Linux_IO_Uring_Register
     (Descriptor : C.int;
      Opcode     : C.unsigned;
      Argument   : System.Address;
      Count      : C.unsigned) return C.long;
   pragma Import
     (C, Linux_IO_Uring_Register, "flyology_linux_io_uring_register");

   function Linux_IO_Uring_Enter
     (Descriptor   : C.int;
      To_Submit    : C.unsigned;
      Minimum      : C.unsigned;
      Flags        : C.unsigned;
      Signal_Mask  : System.Address;
      Signal_Size  : C.size_t) return C.long;
   pragma Import (C, Linux_IO_Uring_Enter, "flyology_linux_io_uring_enter");

   function Linux_IO_Uring_Setup
     (Entries : C.unsigned; Parameters : System.Address) return C.long;
   pragma Import (C, Linux_IO_Uring_Setup, "flyology_linux_io_uring_setup");

   procedure Note_Backend (Backend : C.int);
   pragma Import (C, Note_Backend, "flyology_linux_note_file_backend");

   procedure Note_Cancellation
     (Backend     : C.int;
      Disposition : C.int;
      Terminal    : C.int);
   pragma Import
     (C, Note_Cancellation, "flyology_test_note_file_cancel");

   procedure Note_Uring_Identity (Reused : C.int);
   pragma Import
     (C, Note_Uring_Identity, "flyology_test_note_uring_identity");

   procedure Note_Uring_Admin_Complete;
   pragma Import
     (C, Note_Uring_Admin_Complete,
      "flyology_test_note_uring_admin_complete");

   procedure Note_Uring_CQ_Capacity (Capacity : C.unsigned);
   pragma Import
     (C, Note_Uring_CQ_Capacity, "flyology_test_note_uring_cq_capacity");

   procedure Note
     (State       : not null Engine_State_Access;
      Disposition : Cancellation_Disposition;
      Terminal    : Boolean);

   procedure Note
     (State       : not null Engine_State_Access;
      Disposition : Cancellation_Disposition;
      Terminal    : Boolean) is
   begin
      if Faults.Enabled then
         Note_Cancellation
           ((if State.Backend = IO_Uring then 2 else 3),
            C.int (Cancellation_Disposition'Pos (Disposition) + 1),
            Boolean'Pos (Terminal));
      end if;
   end Note;

   function Load
     (Address : System.Address;
      Model   : AP.Mem_Model := AP.Acquire) return U32;

   procedure Atomic_Store_32
     (Address : System.Address;
      Value   : U32;
      Model   : AP.Mem_Model := AP.Release);
   pragma Import (C, Atomic_Store_32, "flyology_atomic_store_u32");

   procedure Store
     (Address : System.Address;
      Value   : U32;
      Model   : AP.Mem_Model := AP.Release);

   function Acquire_Request
     (State : not null Engine_State_Access) return Native_AIO_Request_Access;

   procedure Recycle_Request
     (State   : not null Engine_State_Access;
      Request : in out Native_AIO_Request_Access);

   procedure Unlink_Active
     (State   : not null Engine_State_Access;
      Request : not null Native_AIO_Request_Access);

   function Acquire_Uring_Request
     (State : not null Engine_State_Access) return IO_Uring_Request_Access;

   procedure Recycle_Uring_Request
     (State   : not null Engine_State_Access;
      Request : in out IO_Uring_Request_Access);

   procedure Unlink_Active_Uring
     (State   : not null Engine_State_Access;
      Request : not null IO_Uring_Request_Access);

   function Submit_Uring_Cancel
     (State      : not null Engine_State_Access;
      Request    : not null IO_Uring_Request_Access;
      Error_Code : out C.int) return Boolean;

   procedure Submit_Deferred_Admin
     (State : not null Engine_State_Access);

   function Retryable_Submit_Error (Error_Code : C.int) return C.int;

   function Has_Overflow_Backlog
     (State : not null Engine_State_Access) return Boolean;

   procedure Release_State (State : in out Engine_State_Access);

   function Failed_Mapping return System.Address is
     (SSE.To_Address (SSE.Integer_Address'Last));

   function Address_At
     (Base : System.Address; Offset : U32) return System.Address
   is (Base + Storage_Offset (Offset));

   function Retryable_Submit_Error (Error_Code : C.int) return C.int is
     (if Error_Code in EAGAIN | EBUSY then EAGAIN else Error_Code);

   function Load
     (Address : System.Address;
      Model   : AP.Mem_Model := AP.Acquire) return U32
   --  Atomic_Primitives imports GCC's __atomic_load_n intrinsic directly.
   is (AP.Atomic_Load_32 (Address, Model));

   procedure Store
     (Address : System.Address;
      Value   : U32;
      Model   : AP.Mem_Model := AP.Release)
   --  The release store publishes SQ entries to the kernel and advances the
   --  CQ head after Ada has consumed completion fields.
   is
   begin
      Atomic_Store_32 (Address, Value, Model);
   end Store;

   function Has_Overflow_Backlog
     (State : not null Engine_State_Access) return Boolean
   is
     ((Load (State.SQ_Flags, AP.Acquire) and IORING_SQ_CQ_OVERFLOW) /= 0
      or else
        Load (State.CQ_Overflow, AP.Acquire) /= State.CQ_Overflow_Seen);

   function Acquire_Request
     (State : not null Engine_State_Access) return Native_AIO_Request_Access
   is
      Request : constant Native_AIO_Request_Access := State.Free_Requests;
   begin
      if Request = null then
         return new Native_AIO_Request;
      end if;
      State.Free_Requests := Request.Next_Free;
      Request.Next_Free := null;
      Request.Next_Active := null;
      return Request;
   end Acquire_Request;

   procedure Recycle_Request
     (State   : not null Engine_State_Access;
      Request : in out Native_AIO_Request_Access)
   is
   begin
      Request.Next_Free := State.Free_Requests;
      State.Free_Requests := Request;
      Request := null;
   end Recycle_Request;

   procedure Unlink_Active
     (State   : not null Engine_State_Access;
      Request : not null Native_AIO_Request_Access)
   is
      Position : Native_AIO_Request_Access := State.Active_Requests;
      Previous : Native_AIO_Request_Access;
   begin
      while Position /= null and then Position /= Request loop
         Previous := Position;
         Position := Position.Next_Active;
      end loop;
      if Position = null then
         raise Program_Error with "unknown Linux native-AIO completion";
      elsif Previous = null then
         State.Active_Requests := Request.Next_Active;
      else
         Previous.Next_Active := Request.Next_Active;
      end if;
      Request.Next_Active := null;
   end Unlink_Active;

   function Acquire_Uring_Request
     (State : not null Engine_State_Access) return IO_Uring_Request_Access
   is
      Request : constant IO_Uring_Request_Access := State.Free_Uring_Requests;
   begin
      if Request = null then
         return new IO_Uring_Request;
      end if;
      State.Free_Uring_Requests := Request.Next_Free;
      Request.Next_Free := null;
      Request.Next_Active := null;
      Request.Next_Deferred := null;
      return Request;
   end Acquire_Uring_Request;

   procedure Recycle_Uring_Request
     (State   : not null Engine_State_Access;
      Request : in out IO_Uring_Request_Access)
   is
   begin
      Request.Next_Free := State.Free_Uring_Requests;
      State.Free_Uring_Requests := Request;
      Request := null;
   end Recycle_Uring_Request;

   procedure Unlink_Active_Uring
     (State   : not null Engine_State_Access;
      Request : not null IO_Uring_Request_Access)
   is
      Position : IO_Uring_Request_Access := State.Active_Uring_Requests;
      Previous : IO_Uring_Request_Access;
   begin
      while Position /= null and then Position /= Request loop
         Previous := Position;
         Position := Position.Next_Active;
      end loop;
      if Position = null then
         raise Program_Error with "unknown Linux io_uring completion";
      elsif Previous = null then
         State.Active_Uring_Requests := Request.Next_Active;
      else
         Previous.Next_Active := Request.Next_Active;
      end if;
      Request.Next_Active := null;
   end Unlink_Active_Uring;

   function Submit_Uring_Cancel
     (State      : not null Engine_State_Access;
      Request    : not null IO_Uring_Request_Access;
      Error_Code : out C.int) return Boolean
   is
      Target     : constant SSE.Integer_Address :=
        SSE.To_Integer (Request.all'Address);
      Head       : constant U32 := Load (State.SQ_Head, AP.Acquire);
      Tail       : constant U32 := Load (State.SQ_Tail, AP.Relaxed);
      Entries    : constant U32 := Load (State.SQ_Entries, AP.Acquire);
      Mask       : constant U32 := Load (State.SQ_Mask, AP.Acquire);
      Index      : U32;
      Submission : Submission_Entry_Access;
      Result     : C.long;
   begin
      if Target mod 2 /= 0 then
         Error_Code := EINVAL;
         return False;
      elsif Has_Overflow_Backlog (State)
        or else State.Uring_In_Flight >= State.CQ_Capacity
        or else Tail - Head >= Entries
      then
         Error_Code := EAGAIN;
         return False;
      end if;
      Index := Tail and Mask;
      Submission := To_Submission_Entry
        (State.SQEs
           + Storage_Offset (Index)
               * Storage_Offset (Submission_Entry'Size / 8));
      Submission.all :=
        (Opcode       => IORING_OP_ASYNC_CANCEL,
         Flags        => 0,
         IO_Priority  => 0,
         Descriptor   => -1,
         Offset       => 0,
         Buffer       => U64 (Target),
         Length       => 0,
         Read_Flags   => 0,
         User_Data    => U64 (Target + 1),
         Buffer_Index => 0,
         Personality  => 0,
         Input_FD     => 0,
         Address_3    => 0,
         Padding      => 0);
      Store
        (State.SQ_Array
           + Storage_Offset (Index) * Storage_Offset (U32'Size / 8),
         Index,
         AP.Relaxed);
      Store (State.SQ_Tail, Tail + 1, AP.Release);
      loop
         Result := Linux_IO_Uring_Enter
           (State.Ring_FD,
            1,
            0,
            0,
            System.Null_Address,
            0);
         exit when Result >= 0 or else OSI.errno /= OSI.EINTR;
      end loop;
      if Result /= 1 then
         Store (State.SQ_Tail, Tail, AP.Release);
         Error_Code :=
           (if Result < 0
            then Retryable_Submit_Error (C.int (OSI.errno))
            else EAGAIN);
         return False;
      end if;
      State.Uring_In_Flight := State.Uring_In_Flight + 1;
      Error_Code := 0;
      return True;
   end Submit_Uring_Cancel;

   procedure Submit_Deferred_Admin
     (State : not null Engine_State_Access)
   is
      Request    : IO_Uring_Request_Access :=
        State.Deferred_Admin_Submit_Head;
      Error_Code : C.int;
   begin
      if Request = null
        or else
          (Faults.Enabled
           and then Faults.Fail (Faults.File_Cancel_Admin_Delay))
      then
         return;
      end if;
      State.Deferred_Admin_Submit_Head := Request.Next_Deferred;
      Request.Next_Deferred := null;
      Request.Admin_Submit_Deferred := False;
      if not Submit_Uring_Cancel (State, Request, Error_Code) then
         if Error_Code = EAGAIN then
            Request.Admin_Submit_Deferred := True;
            Request.Next_Deferred := State.Deferred_Admin_Submit_Head;
            State.Deferred_Admin_Submit_Head := Request;
            return;
         end if;
         --  This queue exists only in a fault-enabled runtime. If submitting
         --  the deliberately delayed administrative request fails, there is
         --  no administrative CQE to retain the identity for. The ordinary
         --  data completion still determines when the user buffer is safe.
         Request.Admin_Complete := True;
         if Request.Operation_Complete then
            Unlink_Active_Uring (State, Request);
            State.Active_Count := State.Active_Count - 1;
            Recycle_Uring_Request (State, Request);
         end if;
      end if;
   end Submit_Deferred_Admin;

   procedure Release_State (State : in out Engine_State_Access) is
      Ignored : C.int;
      Result  : C.long;
      Request : Native_AIO_Request_Access;
      Uring_Request : IO_Uring_Request_Access;
   begin
      if State = null then
         return;
      elsif State.Active_Requests /= null
        or else State.Active_Uring_Requests /= null
        or else State.Deferred_Admin_Submit_Head /= null
        or else State.Uring_In_Flight /= 0
      then
         raise Program_Error with
           "FLYOLOGY finalized with active Linux file requests";
      elsif State.Backend = Native_AIO then
         if State.AIO_Context /= 0 then
            Result := Linux_IO_Destroy (State.AIO_Context);
            pragma Unreferenced (Result);
         end if;
      else
         if State.SQEs_Mapping /= System.Null_Address
           and then State.SQEs_Mapping /= Failed_Mapping
         then
            Ignored := Munmap (State.SQEs_Mapping, State.SQEs_Mapping_Size);
         end if;
         if State.CQ_Mapping /= State.SQ_Mapping
           and then State.CQ_Mapping /= System.Null_Address
           and then State.CQ_Mapping /= Failed_Mapping
         then
            Ignored := Munmap (State.CQ_Mapping, State.CQ_Mapping_Size);
         end if;
         if State.SQ_Mapping /= System.Null_Address
           and then State.SQ_Mapping /= Failed_Mapping
         then
            Ignored := Munmap (State.SQ_Mapping, State.SQ_Mapping_Size);
         end if;
         if State.Ring_FD >= 0 then
            Ignored := Close (State.Ring_FD);
         end if;
      end if;
      while State.Free_Requests /= null loop
         Request := State.Free_Requests;
         State.Free_Requests := Request.Next_Free;
         Free_Native_Request (Request);
      end loop;
      while State.Free_Uring_Requests /= null loop
         Uring_Request := State.Free_Uring_Requests;
         State.Free_Uring_Requests := Uring_Request.Next_Free;
         Free_Uring_Request (Uring_Request);
      end loop;
      pragma Unreferenced (Ignored);
      Free_State (State);
   end Release_State;

   function Initialize
     (Item      : in out Engine;
      Poller_FD : C.int;
      Wake_FD   : C.int) return Boolean
   is
      pragma Unreferenced (Poller_FD);
      State       : Engine_State_Access := null;
      Parameters  : aliased Ring_Parameters :=
        (Reserved   => (others => 0),
         SQ_Offsets =>
           (Head         => 0,
            Tail         => 0,
            Ring_Mask    => 0,
            Ring_Entries => 0,
            Flags        => 0,
            Dropped      => 0,
            Array_Offset => 0,
            Reserved     => 0,
            User_Address => 0),
         CQ_Offsets =>
           (Head         => 0,
            Tail         => 0,
            Ring_Mask    => 0,
            Ring_Entries => 0,
            Overflow     => 0,
            CQEs         => 0,
            Flags        => 0,
            Reserved     => 0,
            User_Address => 0),
         others     => 0);
      Wake_Copy   : aliased C.int := Wake_FD;
      Result      : C.long;
      Shared_Size : C.size_t;
   begin
      State := new Engine_State;
      State.Wake_FD := Wake_FD;
      Result :=
        Linux_IO_Uring_Setup
          (C.unsigned (Ring_Entries),
           Parameters'Address);
      if Result < 0 then
         if C.int (OSI.errno) not in ENOSYS | EPERM then
            Release_State (State);
            return False;
         end if;
         State.Backend := Native_AIO;
         State.AIO_Context := 0;
         Result :=
           Linux_IO_Setup
             (C.unsigned (Ring_Entries),
              State.AIO_Context'Address);
         if Result < 0 then
            Release_State (State);
            return False;
         end if;
         Item.State := State_Address (State);
         Note_Backend (2);
         return True;
      end if;

      State.Ring_FD := C.int (Result);
      State.SQ_Mapping_Size :=
        C.size_t (Parameters.SQ_Offsets.Array_Offset)
          + C.size_t (Parameters.SQ_Entries) * C.size_t (U32'Size / 8);
      State.CQ_Mapping_Size :=
        C.size_t (Parameters.CQ_Offsets.CQEs)
          + C.size_t (Parameters.CQ_Entries)
              * C.size_t (Completion_Entry'Size / 8);
      if (Parameters.Features and IORING_FEAT_SINGLE_MMAP) /= 0 then
         Shared_Size := C.size_t'Max
           (State.SQ_Mapping_Size, State.CQ_Mapping_Size);
         State.SQ_Mapping_Size := Shared_Size;
         State.CQ_Mapping_Size := Shared_Size;
      end if;

      State.SQ_Mapping :=
        Mmap
          (System.Null_Address,
           State.SQ_Mapping_Size,
           PROT_READ + PROT_WRITE,
           MAP_SHARED,
           State.Ring_FD,
           IORING_OFF_SQ_RING);
      if State.SQ_Mapping = Failed_Mapping then
         Release_State (State);
         return False;
      end if;

      if (Parameters.Features and IORING_FEAT_SINGLE_MMAP) /= 0 then
         State.CQ_Mapping := State.SQ_Mapping;
      else
         State.CQ_Mapping :=
           Mmap
             (System.Null_Address,
              State.CQ_Mapping_Size,
              PROT_READ + PROT_WRITE,
              MAP_SHARED,
              State.Ring_FD,
              IORING_OFF_CQ_RING);
         if State.CQ_Mapping = Failed_Mapping then
            Release_State (State);
            return False;
         end if;
      end if;

      State.SQEs_Mapping_Size :=
        C.size_t (Parameters.SQ_Entries)
          * C.size_t (Submission_Entry'Size / 8);
      State.SQEs_Mapping :=
        Mmap
          (System.Null_Address,
           State.SQEs_Mapping_Size,
           PROT_READ + PROT_WRITE,
           MAP_SHARED,
           State.Ring_FD,
           IORING_OFF_SQES);
      if State.SQEs_Mapping = Failed_Mapping then
         Release_State (State);
         return False;
      end if;

      State.SQ_Head := Address_At
        (State.SQ_Mapping, Parameters.SQ_Offsets.Head);
      State.SQ_Tail := Address_At
        (State.SQ_Mapping, Parameters.SQ_Offsets.Tail);
      State.SQ_Mask := Address_At
        (State.SQ_Mapping, Parameters.SQ_Offsets.Ring_Mask);
      State.SQ_Entries := Address_At
        (State.SQ_Mapping, Parameters.SQ_Offsets.Ring_Entries);
      State.SQ_Flags := Address_At
        (State.SQ_Mapping, Parameters.SQ_Offsets.Flags);
      State.SQ_Array := Address_At
        (State.SQ_Mapping, Parameters.SQ_Offsets.Array_Offset);
      State.SQEs := State.SQEs_Mapping;
      State.CQ_Head := Address_At
        (State.CQ_Mapping, Parameters.CQ_Offsets.Head);
      State.CQ_Tail := Address_At
        (State.CQ_Mapping, Parameters.CQ_Offsets.Tail);
      State.CQ_Mask := Address_At
        (State.CQ_Mapping, Parameters.CQ_Offsets.Ring_Mask);
      State.CQ_Overflow := Address_At
        (State.CQ_Mapping, Parameters.CQ_Offsets.Overflow);
      State.CQEs := Address_At
        (State.CQ_Mapping, Parameters.CQ_Offsets.CQEs);
      State.CQ_Capacity := Parameters.CQ_Entries;
      if State.CQ_Capacity = 0 then
         Release_State (State);
         return False;
      end if;
      State.CQ_Overflow_Seen := Load (State.CQ_Overflow, AP.Acquire);
      if Faults.Enabled then
         Note_Uring_CQ_Capacity (C.unsigned (State.CQ_Capacity));
      end if;

      Result :=
        Linux_IO_Uring_Register
          (State.Ring_FD,
           C.unsigned (IORING_REGISTER_EVENTFD_ASYNC),
           Wake_Copy'Address,
           1);
      if Result < 0 and then C.int (OSI.errno) = EINVAL then
         Result :=
           Linux_IO_Uring_Register
             (State.Ring_FD,
              C.unsigned (IORING_REGISTER_EVENTFD),
              Wake_Copy'Address,
              1);
      end if;
      if Result < 0 then
         Release_State (State);
         return False;
      end if;

      Item.State := State_Address (State);
      Note_Backend (1);
      return True;
   exception
      when Storage_Error =>
         Release_State (State);
         return False;
   end Initialize;

   procedure Finalize (Item : in out Engine) is
      State : Engine_State_Access := To_State (Item.State);
   begin
      Release_State (State);
      Item.State := System.Null_Address;
   end Finalize;

   function Submit
     (Item        : in out Engine;
      Descriptor  : C.int;
      Buffer      : System.Address;
      Length      : C.size_t;
      Offset      : C.long_long;
      For_Write   : Boolean;
      Token       : System.Address;
      Error_Code  : out C.int) return Boolean
   is
      State         : constant Engine_State_Access := To_State (Item.State);
      Result        : C.long;
      Uring_Request : IO_Uring_Request_Access;
   begin
      if State = null then
         Error_Code := EINVAL;
         return False;
      elsif State.Backend = Native_AIO then
         declare
            Request : Native_AIO_Request_Access := Acquire_Request (State);
            Controls : aliased IOCB_Address_Array (1 .. 1) :=
              [1 => Request.Control'Address];
         begin
            Request.all :=
              (Control =>
                 (Data        => U64 (SSE.To_Integer (Token)),
                  Key         => 0,
                  Read_Flags  => 0,
                  Opcode      =>
                    (if For_Write
                     then IOCB_CMD_PWRITE
                     else IOCB_CMD_PREAD),
                  Priority    => 0,
                  Descriptor  => U32 (Descriptor),
                  Buffer      => U64 (SSE.To_Integer (Buffer)),
                  Length      => U64 (Length),
                  Offset      => S64 (Offset),
                  Reserved    => 0,
                  Flags       => IOCB_FLAG_RESFD,
                  Result_FD   => U32 (State.Wake_FD)),
               Next_Free => null,
               Token => Token,
               Next_Active => null);
            loop
               Result :=
                 Linux_IO_Submit
                   (State.AIO_Context,
                    1,
                    Controls'Address);
               exit when Result >= 0 or else OSI.errno /= OSI.EINTR;
            end loop;
            if Result /= 1 then
               Error_Code :=
                 (if Result < 0 then C.int (OSI.errno) else EAGAIN);
               Recycle_Request (State, Request);
               return False;
            end if;
            Request.Next_Active := State.Active_Requests;
            State.Active_Requests := Request;
            State.Active_Count := State.Active_Count + 1;
            Error_Code := 0;
            return True;
         end;
      end if;

      if Length > C.size_t (U32'Last) then
         Error_Code := EINVAL;
         return False;
      end if;

      declare
         Head       : constant U32 := Load (State.SQ_Head, AP.Acquire);
         Tail       : constant U32 := Load (State.SQ_Tail, AP.Relaxed);
         Entries    : constant U32 := Load (State.SQ_Entries, AP.Acquire);
         Mask       : constant U32 := Load (State.SQ_Mask, AP.Acquire);
         Index      : U32;
         Submission : Submission_Entry_Access;
         Entry_Addr : System.Address;
         Identity   : SSE.Integer_Address;
         Older      : IO_Uring_Request_Access;
      begin
         if Has_Overflow_Backlog (State) then
            Error_Code := EAGAIN;
            return False;
         elsif State.Uring_In_Flight >= State.CQ_Capacity then
            if Faults.Enabled then
               State.Test_Backpressure_Observed := True;
               if Faults.Fail (Faults.File_Uring_Backpressure) then
                  null;
               end if;
            end if;
            Error_Code := EAGAIN;
            return False;
         end if;
         Uring_Request := Acquire_Uring_Request (State);
         Uring_Request.all :=
           (Token              => Token,
            Cancel_Submitted   => False,
            Operation_Complete => False,
            Admin_Complete     => False,
            Admin_Submit_Deferred => False,
            Next_Free          => null,
            Next_Active        => null,
            Next_Deferred      => null);
         Identity := SSE.To_Integer (Uring_Request.all'Address);
         if Faults.Enabled then
            Older := State.Active_Uring_Requests;
            while Older /= null loop
               if Older.Operation_Complete
                 and then Older.Cancel_Submitted
                 and then not Older.Admin_Complete
               then
                  Note_Uring_Identity
                    (Boolean'Pos
                       (SSE.To_Integer (Older.all'Address) = Identity));
               end if;
               Older := Older.Next_Active;
            end loop;
         end if;
         if Tail - Head >= Entries then
            Error_Code := EAGAIN;
            Recycle_Uring_Request (State, Uring_Request);
            return False;
         elsif Identity mod 2 /= 0 then
            Error_Code := EINVAL;
            Recycle_Uring_Request (State, Uring_Request);
            return False;
         end if;
         Index := Tail and Mask;
         Entry_Addr :=
           State.SQEs
             + Storage_Offset (Index)
                 * Storage_Offset (Submission_Entry'Size / 8);
         Submission := To_Submission_Entry (Entry_Addr);
         Submission.all :=
           (Opcode       =>
              (if For_Write then IORING_OP_WRITE else IORING_OP_READ),
            Flags        => 0,
            IO_Priority  => 0,
            Descriptor   => S32 (Descriptor),
            Offset       => U64 (Offset),
            Buffer       => U64 (SSE.To_Integer (Buffer)),
            Length       => U32 (Length),
            Read_Flags   => 0,
            User_Data    => U64 (Identity),
            Buffer_Index => 0,
            Personality  => 0,
            Input_FD     => 0,
            Address_3    => 0,
            Padding      => 0);
         Store
           (State.SQ_Array
              + Storage_Offset (Index) * Storage_Offset (U32'Size / 8),
            Index,
            AP.Relaxed);
         Store (State.SQ_Tail, Tail + 1, AP.Release);

         if Faults.Enabled
           and then Faults.Fail (Faults.File_Uring_Submit_EBUSY)
         then
            Store (State.SQ_Tail, Tail, AP.Release);
            Error_Code := Retryable_Submit_Error (EBUSY);
            Recycle_Uring_Request (State, Uring_Request);
            return False;
         end if;
         loop
            Result :=
              Linux_IO_Uring_Enter
                (State.Ring_FD,
                 1,
                 0,
                 0,
                 System.Null_Address,
                 0);
            exit when Result >= 0 or else OSI.errno /= OSI.EINTR;
         end loop;
         if Result /= 1 then
            Store (State.SQ_Tail, Tail, AP.Release);
            Error_Code :=
              (if Result < 0
               then Retryable_Submit_Error (C.int (OSI.errno))
               else EAGAIN);
            Recycle_Uring_Request (State, Uring_Request);
            return False;
         end if;
         Uring_Request.Next_Active := State.Active_Uring_Requests;
         State.Active_Uring_Requests := Uring_Request;
         State.Active_Count := State.Active_Count + 1;
         State.Uring_In_Flight := State.Uring_In_Flight + 1;
         Uring_Request := null;
      end;
      Error_Code := 0;
      return True;
   exception
      when Storage_Error =>
         if Uring_Request /= null then
            Recycle_Uring_Request (State, Uring_Request);
         end if;
         Error_Code := ENOMEM;
         return False;
   end Submit;

   function Cancel
     (Item           : in out Engine;
      Descriptor     : C.int;
      Token          : System.Address;
      Value          : out Completion;
      Has_Completion : out Boolean;
      Error_Code     : out C.int)
      return Cancellation_Disposition
   is
      State  : constant Engine_State_Access := To_State (Item.State);
      Result : C.long;
   begin
      pragma Unreferenced (Descriptor);
      Value := (others => <>);
      Has_Completion := False;
      Error_Code := 0;
      if State = null or else Token = System.Null_Address then
         Error_Code := EINVAL;
         return Cancellation_Failed;
      elsif State.Backend = Native_AIO then
         declare
            Request : Native_AIO_Request_Access := State.Active_Requests;
            Event   : aliased IO_Event;
         begin
            while Request /= null and then Request.Token /= Token loop
               Request := Request.Next_Active;
            end loop;
            if Request = null then
               Note (State, Already_Completing, False);
               return Already_Completing;
            end if;
            loop
               Result := Linux_IO_Cancel
                 (State.AIO_Context,
                  Request.Control'Address,
                  Event'Address);
               exit when Result >= 0 or else OSI.errno /= OSI.EINTR;
            end loop;
            if Result = 0 then
               Value :=
                 (Token      => Request.Token,
                  Result     =>
                    (if Event.Result >= 0
                     then C.long_long (Event.Result)
                     else 0),
                  Error_Code =>
                    (if Event.Result < 0
                     then C.int (-Event.Result)
                     elsif Event.Extra < 0
                     then C.int (-Event.Extra)
                     else 0));
               Unlink_Active (State, Request);
               State.Active_Count := State.Active_Count - 1;
               Recycle_Request (State, Request);
               Has_Completion := True;
               Note (State, Cancellation_Submitted, True);
               return Cancellation_Submitted;
            elsif C.int (OSI.errno) in EAGAIN | ENOENT then
               Note (State, Already_Completing, False);
               return Already_Completing;
            else
               Error_Code := C.int (OSI.errno);
               Note (State, Cancellation_Failed, False);
               return Cancellation_Failed;
            end if;
         end;
      end if;

      --  io_uring cancellation is itself asynchronous. The aligned request
      --  address is the operation identity and its odd neighbor identifies
      --  the administrative CQE. The request remains allocated until both
      --  CQEs have arrived, so a resumed fiber cannot reuse the target value.
      declare
         Request : IO_Uring_Request_Access := State.Active_Uring_Requests;
      begin
         while Request /= null and then Request.Token /= Token loop
            Request := Request.Next_Active;
         end loop;
         if Request = null or else Request.Operation_Complete then
            Note (State, Already_Completing, False);
            return Already_Completing;
         elsif Request.Cancel_Submitted then
            Note (State, Already_Completing, False);
            return Already_Completing;
         end if;
         if Faults.Enabled
           and then Faults.Fail (Faults.File_Cancel_Admin_Delay)
         then
            --  Hold the administrative SQE itself, not a consumed CQE. This
            --  creates a deterministic test window in which the operation has
            --  completed but its request identity is still reserved.
            Request.Cancel_Submitted := True;
            Request.Admin_Submit_Deferred := True;
            Request.Next_Deferred := State.Deferred_Admin_Submit_Head;
            State.Deferred_Admin_Submit_Head := Request;
         elsif not Submit_Uring_Cancel (State, Request, Error_Code) then
            Note
              (State,
               (if Error_Code = EAGAIN
                then Not_Cancelable
                else Cancellation_Failed),
               False);
            return
              (if Error_Code = EAGAIN
               then Not_Cancelable
               else Cancellation_Failed);
         else
            Request.Cancel_Submitted := True;
         end if;
      end;
      Note (State, Cancellation_Submitted, False);
      return Cancellation_Submitted;
   end Cancel;

   function Complete_Event
     (Item            : in out Engine;
      Request_Address : System.Address;
      Kernel_Result   : C.long_long;
      Kernel_Error    : C.int;
      Value           : out Completion) return Event_Completion_Disposition
   is
   begin
      pragma Unreferenced
        (Item, Request_Address, Kernel_Result, Kernel_Error);
      Value := (others => <>);
      return Completion_Failed;
   end Complete_Event;

   function Is_Quiescent (Item : Engine) return Boolean is
      State : constant Engine_State_Access := To_State (Item.State);
   begin
      return
        State = null
        or else
          (State.Active_Count = 0 and then State.Uring_In_Flight = 0);
   end Is_Quiescent;

   function Drain
     (Item   : in out Engine;
      Values : out Completion_Array;
      Count  : out Natural) return Boolean
   is
      State : constant Engine_State_Access := To_State (Item.State);
   begin
      Values := (others => <>);
      Count := 0;
      if State = null then
         return False;
      elsif State.Backend = Native_AIO then
         declare
            Events  : aliased IO_Event_Array
              (1 .. Natural'Max (1, Values'Length));
            Timeout : aliased Time_ABI.Timespec :=
              Time_ABI.To_Timespec (0.0);
            Result  : C.long;
         begin
            loop
               Result :=
                 Linux_IO_Getevents
                   (State.AIO_Context,
                    0,
                    C.long (Values'Length),
                    Events'Address,
                    Timeout'Address);
               exit when Result >= 0 or else OSI.errno /= OSI.EINTR;
            end loop;
            if Result < 0 or else Result > C.long (Values'Length) then
               return False;
            end if;
            Count := Natural (Result);
            for Index in 1 .. Count loop
               Values (Values'First + Index - 1) :=
                 (Token => SSE.To_Address
                    (SSE.Integer_Address (Events (Index).Data)),
                  Result =>
                    (if Events (Index).Result >= 0
                     then C.long_long (Events (Index).Result)
                     else 0),
                  Error_Code =>
                    (if Events (Index).Result < 0
                     then C.int (-Events (Index).Result)
                     elsif Events (Index).Extra < 0
                     then C.int (-Events (Index).Extra)
                     else 0));
               declare
                  Request : Native_AIO_Request_Access := To_Native_Request
                    (SSE.To_Address
                       (SSE.Integer_Address (Events (Index).Object)));
               begin
                  Unlink_Active (State, Request);
                  State.Active_Count := State.Active_Count - 1;
                  Recycle_Request (State, Request);
               end;
            end loop;
            return True;
         end;
      end if;

      if Faults.Enabled
        and then not State.Test_Backpressure_Observed
        and then Faults.Fail (Faults.File_Uring_Drain_Pause)
      then
         return True;
      end if;

      declare
         type Flush_Disposition is (No_Flush, Flushed, Retry, Failed);

         function Overflow_Pending return Boolean;
         function Flush_Overflow return Flush_Disposition;
         function Signal_Flush_Retry return Boolean;
         procedure Drain_Visible;

         function Overflow_Pending return Boolean is
         begin
            if Faults.Enabled
              and then Faults.Fail (Faults.File_Uring_Overflow_Flush)
            then
               return True;
            end if;
            return Has_Overflow_Backlog (State);
         end Overflow_Pending;

         function Flush_Overflow return Flush_Disposition is
            Result : C.long;
            Error  : C.int;
         begin
            if not Overflow_Pending then
               return No_Flush;
            elsif Faults.Enabled
              and then Faults.Fail (Faults.File_Uring_Flush_EBUSY)
            then
               return Retry;
            end if;
            loop
               Result := Linux_IO_Uring_Enter
                 (State.Ring_FD,
                  0,
                  0,
                  IORING_ENTER_GETEVENTS,
                  System.Null_Address,
                  0);
               exit when Result >= 0 or else OSI.errno /= OSI.EINTR;
            end loop;
            if Result >= 0 then
               State.CQ_Overflow_Seen :=
                 Load (State.CQ_Overflow, AP.Acquire);
               return Flushed;
            end if;
            Error := C.int (OSI.errno);
            if Error in EAGAIN | EBUSY then
               --  EBUSY means the kernel could not move every overflow CQE
               --  into the userspace ring yet. The persistent overflow flag
               --  makes the next drain retry after more CQEs are consumed.
               return Retry;
            end if;
            return Failed;
         end Flush_Overflow;

         function Signal_Flush_Retry return Boolean is
            Value  : aliased C.unsigned_long_long := 1;
            Result : C.long;
         begin
            loop
               Result := Write
                 (State.Wake_FD,
                  Value'Address,
                  C.size_t (C.unsigned_long_long'Size / 8));
               if Result >= 0 then
                  return True;
               elsif OSI.errno = EAGAIN then
                  --  A saturated eventfd is already readable by epoll.
                  return True;
               elsif OSI.errno /= OSI.EINTR then
                  return False;
               end if;
            end loop;
         end Signal_Flush_Retry;

         procedure Drain_Visible is
            Head : U32 := Load (State.CQ_Head, AP.Relaxed);
            Tail : constant U32 := Load (State.CQ_Tail, AP.Acquire);
            Mask : constant U32 := Load (State.CQ_Mask, AP.Acquire);
         begin
            while Head /= Tail and then Count < Values'Length loop
               declare
                  Index : constant U32 := Head and Mask;
                  CQ_Item : constant Completion_Entry_Access :=
                    To_Completion_Entry
                      (State.CQEs
                         + Storage_Offset (Index)
                             * Storage_Offset (Completion_Entry'Size / 8));
               begin
                  if State.Uring_In_Flight = 0 then
                     raise Program_Error with
                       "io_uring completion exceeds submitted request count";
                  end if;
                  State.Uring_In_Flight := State.Uring_In_Flight - 1;
                  declare
                     Raw : constant SSE.Integer_Address :=
                       SSE.Integer_Address (CQ_Item.User_Data);
                     Administrative : constant Boolean := Raw mod 2 /= 0;
                     Base : constant SSE.Integer_Address :=
                       Raw - (if Administrative then 1 else 0);
                     Request : IO_Uring_Request_Access :=
                       To_Uring_Request (SSE.To_Address (Base));
                  begin
                     if Administrative then
                        Request.Admin_Complete := True;
                        if Faults.Enabled then
                           Note_Uring_Admin_Complete;
                        end if;
                        if Request.Operation_Complete then
                           Unlink_Active_Uring (State, Request);
                           State.Active_Count := State.Active_Count - 1;
                           Recycle_Uring_Request (State, Request);
                        end if;
                     else
                        Count := Count + 1;
                        Values (Values'First + Count - 1) :=
                          (Token => Request.Token,
                           Result =>
                             (if CQ_Item.Result >= 0
                              then C.long_long (CQ_Item.Result)
                              else 0),
                           Error_Code =>
                             (if CQ_Item.Result < 0
                              then C.int (-CQ_Item.Result)
                              else 0));
                        Request.Operation_Complete := True;
                        if not Request.Cancel_Submitted
                          or else Request.Admin_Complete
                        then
                           Unlink_Active_Uring (State, Request);
                           State.Active_Count := State.Active_Count - 1;
                           Recycle_Uring_Request (State, Request);
                        end if;
                     end if;
                  end;
                  Head := Head + 1;
               end;
            end loop;
            Store (State.CQ_Head, Head, AP.Release);
         end Drain_Visible;

         Flush : Flush_Disposition;
      begin
         Drain_Visible;
         Flush := Flush_Overflow;
         if Flush = Failed then
            return False;
         elsif Flush = Retry then
            --  EBUSY can still have moved part of the overflow list into the
            --  userspace CQ. Reap that progress, then make another drain
            --  inevitable even if the kernel emitted no new eventfd edge.
            Drain_Visible;
            if not Signal_Flush_Retry then
               return False;
            end if;
         elsif Flush = Flushed and then Count < Values'Length then
            --  GETEVENTS may have copied backlog entries into the CQ after
            --  the first tail snapshot. Consume them in this same drain.
            Drain_Visible;
         end if;

         --  Delayed cancellation SQEs also consume CQ capacity. Submit one
         --  only after visible completions have released that capacity.
         Submit_Deferred_Admin (State);
      end;
      return True;
   end Drain;

end System.Flyology.File_Engine;
