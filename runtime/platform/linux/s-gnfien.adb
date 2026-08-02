with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with Interfaces;
with System.Atomic_Primitives;
with System.Gnatevl.Time_ABI;
with System.OS_Interface;
with System.Storage_Elements;

package body System.Gnatevl.File_Engine is
   package AP renames System.Atomic_Primitives;
   package C renames Interfaces.C;
   package Time_ABI renames System.Gnatevl.Time_ABI;
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

   --  GNATEVL's supported Linux target is x86-64. These are the stable
   --  x86-64 syscall numbers from asm/unistd_64.h; the io_uring UAPI record
   --  layouts below come from linux/io_uring.h and linux/aio_abi.h.
   SYS_IO_Setup          : constant C.long := 206;
   SYS_IO_Destroy        : constant C.long := 207;
   SYS_IO_Getevents      : constant C.long := 208;
   SYS_IO_Submit         : constant C.long := 209;
   SYS_IO_Uring_Setup    : constant C.long := 425;
   SYS_IO_Uring_Enter    : constant C.long := 426;
   SYS_IO_Uring_Register : constant C.long := 427;

   ENOSYS : constant C.int := 38;
   EPERM  : constant C.int := 1;
   EINVAL : constant C.int := 22;
   ENOMEM : constant C.int := 12;
   EAGAIN : constant C.int := 11;

   PROT_READ  : constant C.int := 1;
   PROT_WRITE : constant C.int := 2;
   MAP_SHARED : constant C.int := 1;

   IORING_OFF_SQ_RING : constant C.long_long := 16#0000_0000#;
   IORING_OFF_CQ_RING : constant C.long_long := 16#0800_0000#;
   IORING_OFF_SQES    : constant C.long_long := 16#1000_0000#;

   IORING_FEAT_SINGLE_MMAP       : constant U32 := 1;
   IORING_REGISTER_EVENTFD       : constant U32 := 4;
   IORING_REGISTER_EVENTFD_ASYNC : constant U32 := 7;
   IORING_OP_READ                : constant U8 := 22;
   IORING_OP_WRITE               : constant U8 := 23;

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
   end record
     with Size => 576, Alignment => 8;
   for Native_AIO_Request use record
      Control   at 0  range 0 .. 511;
      Next_Free at 64 range 0 .. 63;
   end record;

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
      SQ_Array          : System.Address := System.Null_Address;
      SQEs              : System.Address := System.Null_Address;
      CQ_Head           : System.Address := System.Null_Address;
      CQ_Tail           : System.Address := System.Null_Address;
      CQ_Mask           : System.Address := System.Null_Address;
      CQEs              : System.Address := System.Null_Address;
      Free_Requests     : Native_AIO_Request_Access;
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
   function To_Submission_Entry is new Ada.Unchecked_Conversion
     (System.Address, Submission_Entry_Access);
   function To_Completion_Entry is new Ada.Unchecked_Conversion
     (System.Address, Completion_Entry_Access);

   procedure Free_State is new Ada.Unchecked_Deallocation
     (Engine_State, Engine_State_Access);
   procedure Free_Native_Request is new Ada.Unchecked_Deallocation
     (Native_AIO_Request, Native_AIO_Request_Access);

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

   function Syscall_Setup
     (Number : C.long; Entries : C.unsigned; Parameters : System.Address)
      return C.long;
   pragma Import (C_Variadic_1, Syscall_Setup, "syscall");

   function Syscall_Destroy
     (Number : C.long; Context : C.unsigned_long) return C.long;
   pragma Import (C_Variadic_1, Syscall_Destroy, "syscall");

   function Syscall_Submit
     (Number   : C.long;
      Context  : C.unsigned_long;
      Count    : C.long;
      Controls : System.Address) return C.long;
   pragma Import (C_Variadic_1, Syscall_Submit, "syscall");

   function Syscall_Getevents
     (Number  : C.long;
      Context : C.unsigned_long;
      Minimum : C.long;
      Count   : C.long;
      Events  : System.Address;
      Timeout : System.Address) return C.long;
   pragma Import (C_Variadic_1, Syscall_Getevents, "syscall");

   function Syscall_Uring_Register
     (Number     : C.long;
      Descriptor : C.int;
      Opcode     : C.unsigned;
      Argument   : System.Address;
      Count      : C.unsigned) return C.long;
   pragma Import (C_Variadic_1, Syscall_Uring_Register, "syscall");

   function Syscall_Uring_Enter
     (Number       : C.long;
      Descriptor   : C.int;
      To_Submit    : C.unsigned;
      Minimum      : C.unsigned;
      Flags        : C.unsigned;
      Signal_Mask  : System.Address;
      Signal_Size  : C.size_t) return C.long;
   pragma Import (C_Variadic_1, Syscall_Uring_Enter, "syscall");

   function Load
     (Address : System.Address;
      Model   : AP.Mem_Model := AP.Acquire) return U32;

   procedure Atomic_Store_32
     (Address : System.Address;
      Value   : U32;
      Model   : AP.Mem_Model := AP.Release);
   pragma Import (C, Atomic_Store_32, "gnatevl_atomic_store_u32");

   procedure Store
     (Address : System.Address;
      Value   : U32;
      Model   : AP.Mem_Model := AP.Release);

   function Acquire_Request
     (State : not null Engine_State_Access) return Native_AIO_Request_Access;

   procedure Recycle_Request
     (State   : not null Engine_State_Access;
      Request : in out Native_AIO_Request_Access);

   procedure Release_State (State : in out Engine_State_Access);

   function Failed_Mapping return System.Address is
     (SSE.To_Address (SSE.Integer_Address'Last));

   function Address_At
     (Base : System.Address; Offset : U32) return System.Address
   is (Base + Storage_Offset (Offset));

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

   procedure Release_State (State : in out Engine_State_Access) is
      Ignored : C.int;
      Result  : C.long;
      Request : Native_AIO_Request_Access;
   begin
      if State = null then
         return;
      elsif State.Backend = Native_AIO then
         if State.AIO_Context /= 0 then
            Result := Syscall_Destroy (SYS_IO_Destroy, State.AIO_Context);
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
        Syscall_Setup
          (SYS_IO_Uring_Setup,
           C.unsigned (Ring_Entries),
           Parameters'Address);
      if Result < 0 then
         if C.int (OSI.errno) not in ENOSYS | EPERM then
            Release_State (State);
            return False;
         end if;
         State.Backend := Native_AIO;
         State.AIO_Context := 0;
         Result :=
           Syscall_Setup
             (SYS_IO_Setup,
              C.unsigned (Ring_Entries),
              State.AIO_Context'Address);
         if Result < 0 then
            Release_State (State);
            return False;
         end if;
         Item.State := State_Address (State);
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
      State.SQ_Array := Address_At
        (State.SQ_Mapping, Parameters.SQ_Offsets.Array_Offset);
      State.SQEs := State.SQEs_Mapping;
      State.CQ_Head := Address_At
        (State.CQ_Mapping, Parameters.CQ_Offsets.Head);
      State.CQ_Tail := Address_At
        (State.CQ_Mapping, Parameters.CQ_Offsets.Tail);
      State.CQ_Mask := Address_At
        (State.CQ_Mapping, Parameters.CQ_Offsets.Ring_Mask);
      State.CQEs := Address_At
        (State.CQ_Mapping, Parameters.CQ_Offsets.CQEs);

      Result :=
        Syscall_Uring_Register
          (SYS_IO_Uring_Register,
           State.Ring_FD,
           C.unsigned (IORING_REGISTER_EVENTFD_ASYNC),
           Wake_Copy'Address,
           1);
      if Result < 0 and then C.int (OSI.errno) = EINVAL then
         Result :=
           Syscall_Uring_Register
             (SYS_IO_Uring_Register,
              State.Ring_FD,
              C.unsigned (IORING_REGISTER_EVENTFD),
              Wake_Copy'Address,
              1);
      end if;
      if Result < 0 then
         Release_State (State);
         return False;
      end if;

      Item.State := State_Address (State);
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
      State   : constant Engine_State_Access := To_State (Item.State);
      Result  : C.long;
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
               Next_Free => null);
            loop
               Result :=
                 Syscall_Submit
                   (SYS_IO_Submit,
                    State.AIO_Context,
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
      begin
         if Tail - Head >= Entries then
            Error_Code := EAGAIN;
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
            User_Data    => U64 (SSE.To_Integer (Token)),
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
            Result :=
              Syscall_Uring_Enter
                (SYS_IO_Uring_Enter,
                 State.Ring_FD,
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
              (if Result < 0 then C.int (OSI.errno) else EAGAIN);
            return False;
         end if;
      end;
      Error_Code := 0;
      return True;
   exception
      when Storage_Error =>
         Error_Code := ENOMEM;
         return False;
   end Submit;

   function Complete_Event
     (Item            : in out Engine;
      Request_Address : System.Address;
      Kernel_Result   : C.long_long;
      Kernel_Error    : C.int;
      Value           : out Completion) return Boolean
   is
   begin
      pragma Unreferenced
        (Item, Request_Address, Kernel_Result, Kernel_Error);
      Value := (others => <>);
      return False;
   end Complete_Event;

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
                 Syscall_Getevents
                   (SYS_IO_Getevents,
                    State.AIO_Context,
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
                  Recycle_Request (State, Request);
               end;
            end loop;
            return True;
         end;
      end if;

      declare
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
               Count := Count + 1;
               Values (Values'First + Count - 1) :=
                 (Token => SSE.To_Address
                    (SSE.Integer_Address (CQ_Item.User_Data)),
                  Result =>
                    (if CQ_Item.Result >= 0
                     then C.long_long (CQ_Item.Result)
                     else 0),
                  Error_Code =>
                    (if CQ_Item.Result < 0
                     then C.int (-CQ_Item.Result)
                     else 0));
               Head := Head + 1;
            end;
         end loop;
         Store (State.CQ_Head, Head, AP.Release);
      end;
      return True;
   end Drain;

end System.Gnatevl.File_Engine;
