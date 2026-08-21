with Ada.Real_Time;
with Ada.Strings;
with Ada.Strings.Fixed;
with Flyology.Socket_Policy;
with Flyology.Operations.Drivers;
with Flyology.Time_Math;
with Flyology.Wait_Policy;
with GNAT.OS_Lib;
with System;
with System.Atomic_Primitives;
with System.Storage_Elements;

package body Flyology.IO.Sockets is

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.C.long;
   use type Interfaces.C.unsigned;
   use type Interfaces.C.unsigned_char;
   use type Flyology.Socket_Policy.Error_Kind;
   use type Flyology.Socket_Policy.IO_Error_Action;
   use type Flyology.Operations.Driver_Event;
   use type Flyology.Operations.Terminal_Outcome;
   use type System.Address;
   use System.Storage_Elements;

   package Atomics renames System.Atomic_Primitives;
   use type Atomics.uint32;

   Unprepared : constant Atomics.uint32 := 0;
   Prepared   : constant Atomics.uint32 := 1;

   generic
      type Atomic_Type is mod <>;
   procedure Atomic_Store
     (Address : System.Address;
      Value   : Atomic_Type;
      Model   : Atomics.Mem_Model := Atomics.Seq_Cst);
   pragma Import (Intrinsic, Atomic_Store, "__atomic_store_n");

   procedure Atomic_Store_32 is new Atomic_Store (Atomics.uint32);

   function C_Unix_Path_Max return Interfaces.C.unsigned;
   pragma Import
     (C, C_Unix_Path_Max, "flyology_socket_unix_path_max");

   function Maximum_Unix_Path_Length return Positive is
     (Positive (C_Unix_Path_Max));

   function Unix_Pathname (Path : String) return Unix_Path is
      Limit : constant Positive := Maximum_Unix_Path_Length;
      Result : Unix_Path;
   begin
      if Path'Length = 0 then
         raise Constraint_Error with "Unix socket pathname is empty";
      elsif Path'Length > Limit
        or else Path'Length > Unix_Path_Storage_Capacity
      then
         raise Constraint_Error with "Unix socket pathname is too long";
      end if;
      for Byte of Path loop
         if Byte = Character'Val (0) then
            raise Constraint_Error with "Unix socket pathname contains NUL";
         end if;
      end loop;
      Result.Length := Path'Length;
      Result.Bytes (1 .. Path'Length) := Path;
      return Result;
   end Unix_Pathname;

   function Image (Value : Unix_Path) return String is
     (Value.Bytes (1 .. Value.Length));

   function Preparation_State (Socket : Socket_Type) return Atomics.uint32 is
     (Atomics.Atomic_Load_32
        (Socket.Preparation'Address, Atomics.Acquire));

   procedure Set_Preparation_State
     (Address : System.Address; State : Atomics.uint32) is
   begin
      Atomic_Store_32 (Address, State, Atomics.Release);
   end Set_Preparation_State;

   function C_Errno_Would_Block return Interfaces.C.int;
   pragma Import
     (C, C_Errno_Would_Block, "flyology_socket_errno_would_block");

   function C_Errno_Interrupted return Interfaces.C.int;
   pragma Import
     (C, C_Errno_Interrupted, "flyology_socket_errno_interrupted");

   function C_Errno_In_Progress return Interfaces.C.int;
   pragma Import
     (C, C_Errno_In_Progress, "flyology_socket_errno_in_progress");

   function C_Errno_Already_In_Progress return Interfaces.C.int;
   pragma Import
     (C, C_Errno_Already_In_Progress,
      "flyology_socket_errno_already_in_progress");

   function C_Errno_Already_Connected return Interfaces.C.int;
   pragma Import
     (C, C_Errno_Already_Connected,
      "flyology_socket_errno_already_connected");

   function C_Errno_No_Buffer_Space return Interfaces.C.int;
   pragma Import
     (C, C_Errno_No_Buffer_Space,
      "flyology_socket_errno_no_buffer_space");

   function C_Errno_Address_Family_Not_Supported return Interfaces.C.int;
   pragma Import
     (C, C_Errno_Address_Family_Not_Supported,
      "flyology_socket_errno_address_family_not_supported");

   function C_Address_Family_Field_Size return Interfaces.C.int;
   pragma Import
     (C, C_Address_Family_Field_Size,
      "flyology_socket_address_family_field_size");

   function C_Socket_Level return Interfaces.C.int;
   pragma Import (C, C_Socket_Level, "flyology_socket_level");

   function C_Reuse_Address_Option return Interfaces.C.int;
   pragma Import
     (C, C_Reuse_Address_Option,
      "flyology_socket_reuse_address_option");

   function C_Reuse_Port_Option return Interfaces.C.int;
   pragma Import
     (C, C_Reuse_Port_Option, "flyology_socket_reuse_port_option");

   function C_Pending_Error_Option return Interfaces.C.int;
   pragma Import
     (C, C_Pending_Error_Option,
      "flyology_socket_pending_error_option");

   function C_No_Signal_Flag return Interfaces.C.int;
   pragma Import
     (C, C_No_Signal_Flag, "flyology_socket_no_signal_flag");

   function C_IPv4_Domain return Interfaces.C.int;
   pragma Import (C, C_IPv4_Domain, "flyology_socket_ipv4_domain");

   function C_IPv6_Domain return Interfaces.C.int;
   pragma Import (C, C_IPv6_Domain, "flyology_socket_ipv6_domain");

   function C_Local_Domain return Interfaces.C.int;
   pragma Import (C, C_Local_Domain, "flyology_socket_local_domain");

   function C_Stream_Kind return Interfaces.C.int;
   pragma Import (C, C_Stream_Kind, "flyology_socket_stream_kind");

   function C_Datagram_Kind return Interfaces.C.int;
   pragma Import (C, C_Datagram_Kind, "flyology_socket_datagram_kind");

   function C_Configure_Descriptor
     (Socket      : Interfaces.C.int;
      Nonblocking : Interfaces.C.int) return Interfaces.C.int;
   pragma Import
     (C, C_Configure_Descriptor,
      "flyology_socket_configure_descriptor");

   type Socket_Address_Storage is
     array (Natural range 0 .. 15) of Interfaces.C.unsigned_long_long
       with Convention => C;

   function C_Pack_Address
     (Family  : Interfaces.C.int;
      Address : System.Address;
      Port    : Interfaces.C.unsigned;
      Scope   : Interfaces.C.unsigned;
      Storage : System.Address;
      Length  : access Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import
     (C, C_Pack_Address, "flyology_socket_pack_address");

   function C_Pack_Unix_Path
     (Path    : System.Address;
      Length  : Interfaces.C.unsigned;
      Storage : System.Address;
      Size    : access Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import
     (C, C_Pack_Unix_Path, "flyology_socket_pack_unix_path");

   function C_Unpack_Address
     (Storage : System.Address;
      Length  : Interfaces.C.unsigned;
      Family  : access Interfaces.C.unsigned_char;
      Address : System.Address;
      Port    : access Interfaces.C.unsigned;
      Scope   : access Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import
     (C, C_Unpack_Address, "flyology_socket_unpack_address");

   function C_Enable_Datagram_Metadata_Impl
     (Socket : Interfaces.C.int) return Interfaces.C.int;
   pragma Import
     (C, C_Enable_Datagram_Metadata_Impl,
      "flyology_socket_enable_datagram_metadata_impl");

   function C_Socket
     (Domain, Kind, Protocol : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, C_Socket, "socket");

   function C_Socket_Pair_Raw
     (Domain, Kind, Protocol : Interfaces.C.int;
      Descriptors            : System.Address) return Interfaces.C.int;
   pragma Import (C, C_Socket_Pair_Raw, "socketpair");

   function C_Close_Raw (Socket : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, C_Close_Raw, "close");

   function C_Set_Socket_Option
     (Socket : Interfaces.C.int;
      Level  : Interfaces.C.int;
      Option : Interfaces.C.int;
      Value  : System.Address;
      Length : Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import (C, C_Set_Socket_Option, "setsockopt");

   function C_Get_Socket_Option
     (Socket : Interfaces.C.int;
      Level  : Interfaces.C.int;
      Option : Interfaces.C.int;
      Value  : System.Address;
      Length : access Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import (C, C_Get_Socket_Option, "getsockopt");

   function C_Bind_Raw
     (Socket : Interfaces.C.int;
      Storage : System.Address;
      Length : Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import (C, C_Bind_Raw, "bind");

   function C_Listen_Raw
     (Socket, Backlog : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, C_Listen_Raw, "listen");

   function C_Get_Socket_Name_Raw
     (Socket : Interfaces.C.int;
      Storage : System.Address;
      Length : access Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import (C, C_Get_Socket_Name_Raw, "getsockname");

   function C_Get_Peer_Name_Raw
     (Socket : Interfaces.C.int;
      Storage : System.Address;
      Length : access Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import (C, C_Get_Peer_Name_Raw, "getpeername");

   function C_Raw_Accept
     (Socket : Interfaces.C.int;
      Storage : System.Address;
      Length : access Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import (C, C_Raw_Accept, "flyology_accept");

   function C_Raw_Connect
     (Socket : Interfaces.C.int;
      Storage : System.Address;
      Length : Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import (C, C_Raw_Connect, "flyology_connect");

   function C_Recv
     (Socket : Interfaces.C.int;
      Buffer : System.Address;
      Length : Interfaces.C.size_t;
      Flags  : Interfaces.C.int) return Interfaces.C.long;
   pragma Import (C, C_Recv, "recv");

   function C_Recv_From_Raw
     (Socket : Interfaces.C.int;
      Buffer : System.Address;
      Length : Interfaces.C.size_t;
      Flags  : Interfaces.C.int;
      Storage : System.Address;
      Address_Length : access Interfaces.C.unsigned)
      return Interfaces.C.long;
   pragma Import (C, C_Recv_From_Raw, "recvfrom");

   function C_Send_Raw
     (Socket : Interfaces.C.int;
      Buffer : System.Address;
      Length : Interfaces.C.size_t;
      Flags  : Interfaces.C.int) return Interfaces.C.long;
   pragma Import (C, C_Send_Raw, "send");

   function C_Send_To_Raw
     (Socket : Interfaces.C.int;
      Buffer : System.Address;
      Length : Interfaces.C.size_t;
      Flags  : Interfaces.C.int;
      Storage : System.Address;
      Address_Length : Interfaces.C.unsigned) return Interfaces.C.long;
   pragma Import (C, C_Send_To_Raw, "sendto");

   function C_Memset
     (Target : System.Address;
      Value  : Interfaces.C.int;
      Length : Interfaces.C.size_t) return System.Address;
   pragma Import (C, C_Memset, "memset");

   function C_Create
     (Family : Interfaces.C.int;
      Mode   : Interfaces.C.int;
      Error  : access Interfaces.C.int) return Interfaces.C.int;

   function C_Pair
     (Mode  : Interfaces.C.int;
      Left  : access Interfaces.C.int;
      Right : access Interfaces.C.int;
      Error : access Interfaces.C.int) return Interfaces.C.int;

   function C_Prepare
     (Socket : Interfaces.C.int;
      Error  : access Interfaces.C.int) return Interfaces.C.int;

   --  Only the first task-aware operation for one owned descriptor generation
   --  enters this bridge. The protected action serializes concurrent first
   --  use and defers abort until descriptor setup and state publication agree.
   protected Preparation_Bridge is
      procedure Ensure
        (Socket : Interfaces.C.int;
         State  : System.Address;
         Error  : access Interfaces.C.int;
         Result : out Interfaces.C.int);
   end Preparation_Bridge;

   function C_Set_Nonblocking
     (Socket  : Interfaces.C.int;
      Enabled : Interfaces.C.int;
      Error   : access Interfaces.C.int) return Interfaces.C.int;

   function C_Close
     (Socket : Interfaces.C.int;
      Error  : access Interfaces.C.int) return Interfaces.C.int;

   function C_Set_Reuse_Address
     (Socket  : Interfaces.C.int;
      Enabled : Interfaces.C.int;
      Error   : access Interfaces.C.int) return Interfaces.C.int;

   function C_Set_Receive_Timeout
     (Socket  : Interfaces.C.int;
      Timeout : Interfaces.C.double;
      Error   : access Interfaces.C.int) return Interfaces.C.int;
   pragma Import
     (C, C_Set_Receive_Timeout, "flyology_socket_set_receive_timeout");

   function C_Bind
     (Socket  : Interfaces.C.int;
      Family  : Interfaces.C.int;
      Address : System.Address;
      Port    : Interfaces.C.unsigned;
      Scope   : Interfaces.C.unsigned;
      Error   : access Interfaces.C.int) return Interfaces.C.int;

   function C_Listen
     (Socket  : Interfaces.C.int;
      Backlog : Interfaces.C.int;
      Error   : access Interfaces.C.int) return Interfaces.C.int;

   function C_Name
     (Socket  : Interfaces.C.int;
      Peer    : Interfaces.C.int;
      Family  : access Interfaces.C.unsigned_char;
      Address : System.Address;
      Port    : access Interfaces.C.unsigned;
      Scope   : access Interfaces.C.unsigned;
      Error   : access Interfaces.C.int) return Interfaces.C.int;

   function C_Accept
     (Socket  : Interfaces.C.int;
      Decode_Address : Interfaces.C.int;
      Family  : access Interfaces.C.unsigned_char;
      Address : System.Address;
      Port    : access Interfaces.C.unsigned;
      Scope   : access Interfaces.C.unsigned;
      Error   : access Interfaces.C.int) return Interfaces.C.int;
   --  A nonnegative result is the accepted descriptor, -1 means accept(2)
   --  failed, and -2 means C_Accept closed a descriptor that accept(2)
   --  returned but descriptor configuration could not make usable.

#if FLYOLOGY_CONNECTION_TEST_HOOKS then
   procedure Test_Raw_Accept_Return_Barrier
     with Import,
          Convention => C,
          External_Name =>
            "flyology_test_connection_raw_accept_return_barrier";
#end if;

   --  A protected call defers abort from the C accept return through
   --  publication in the caller-owned handle. The listener is nonblocking,
   --  so the foreign call itself never waits for a connection.
   protected type Accept_Return_Bridge is
      procedure Invoke
        (Listener : Interfaces.C.int;
         Decode_Address : Interfaces.C.int;
         Family   : access Interfaces.C.unsigned_char;
         Address  : System.Address;
         Port     : access Interfaces.C.unsigned;
         Scope    : access Interfaces.C.unsigned;
         Error    : access Interfaces.C.int;
         Target   : in out Socket_Type;
         Result   : out Interfaces.C.int);
   end Accept_Return_Bridge;

   function C_Connect
     (Socket  : Interfaces.C.int;
      Family  : Interfaces.C.int;
      Address : System.Address;
      Port    : Interfaces.C.unsigned;
      Scope   : Interfaces.C.unsigned;
      Error   : access Interfaces.C.int) return Interfaces.C.int;

   function C_Connect
     (Socket : Interfaces.C.int;
      Path   : Unix_Path;
      Error  : access Interfaces.C.int) return Interfaces.C.int;

   function C_Pending_Error
     (Socket  : Interfaces.C.int;
      Pending : access Interfaces.C.int;
      Error   : access Interfaces.C.int) return Interfaces.C.int;

   function C_Receive
     (Socket : Interfaces.C.int;
      Buffer : System.Address;
      Length : Interfaces.C.size_t;
      Error  : access Interfaces.C.int) return Interfaces.C.long;

   function C_Receive_From
     (Socket  : Interfaces.C.int;
      Buffer  : System.Address;
      Length  : Interfaces.C.size_t;
      Family  : access Interfaces.C.unsigned_char;
      Address : System.Address;
      Port    : access Interfaces.C.unsigned;
      Scope   : access Interfaces.C.unsigned;
      Error   : access Interfaces.C.int) return Interfaces.C.long;

   function C_Enable_Datagram_Metadata
     (Socket : Interfaces.C.int;
      Error  : access Interfaces.C.int) return Interfaces.C.int;

   function C_Receive_Datagram
     (Socket              : Interfaces.C.int;
      Buffer              : System.Address;
      Length              : Interfaces.C.size_t;
      Source_Family       : access Interfaces.C.unsigned_char;
      Source_Address      : System.Address;
      Source_Port         : access Interfaces.C.unsigned;
      Source_Scope        : access Interfaces.C.unsigned;
      Destination_Family  : access Interfaces.C.unsigned_char;
      Destination_Address : System.Address;
      Destination_Port    : access Interfaces.C.unsigned;
      Destination_Scope   : access Interfaces.C.unsigned;
      ECN                  : access Interfaces.C.int;
      Error                : access Interfaces.C.int) return Interfaces.C.long;
   pragma Import
     (C, C_Receive_Datagram, "flyology_socket_receive_datagram");

   function C_Send
     (Socket : Interfaces.C.int;
      Buffer : System.Address;
      Length : Interfaces.C.size_t;
      Error  : access Interfaces.C.int) return Interfaces.C.long;

   function C_Send_To
     (Socket  : Interfaces.C.int;
      Buffer  : System.Address;
      Length  : Interfaces.C.size_t;
      Family  : Interfaces.C.int;
      Address : System.Address;
      Port    : Interfaces.C.unsigned;
      Scope   : Interfaces.C.unsigned;
      Error   : access Interfaces.C.int) return Interfaces.C.long;

   function C_Send_Datagram
     (Socket              : Interfaces.C.int;
      Buffer              : System.Address;
      Length              : Interfaces.C.size_t;
      Destination_Family  : Interfaces.C.int;
      Destination_Address : System.Address;
      Destination_Port    : Interfaces.C.unsigned;
      Destination_Scope   : Interfaces.C.unsigned;
      Select_Source       : Interfaces.C.int;
      Source_Family       : Interfaces.C.int;
      Source_Address      : System.Address;
      Source_Port         : Interfaces.C.unsigned;
      Source_Scope        : Interfaces.C.unsigned;
      Error                : access Interfaces.C.int) return Interfaces.C.long;
   pragma Import (C, C_Send_Datagram, "flyology_socket_send_datagram");

   function C_Bytes_To_Read
     (Socket : Interfaces.C.int;
      Count  : access Interfaces.C.unsigned_long;
      Error  : access Interfaces.C.int) return Interfaces.C.int;
   pragma Import
     (C, C_Bytes_To_Read, "flyology_socket_bytes_to_read");

   function C_Parse_Address
     (Family  : Interfaces.C.int;
      Text    : Interfaces.C.char_array;
      Address : System.Address) return Interfaces.C.int;
   pragma Import
     (C, C_Parse_Address, "flyology_socket_parse_address");

   function C_Image_Address
     (Family  : Interfaces.C.int;
      Address : System.Address;
      Text    : System.Address;
      Length  : Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import
     (C, C_Image_Address, "flyology_socket_image_address");

   function C_Errno_Connection_Aborted return Interfaces.C.int;
   pragma Import
     (C, C_Errno_Connection_Aborted,
      "flyology_errno_connection_aborted");
   function C_Errno_Protocol_Error return Interfaces.C.int;
   pragma Import
     (C, C_Errno_Protocol_Error, "flyology_errno_protocol_error");
   function C_Errno_Process_File_Limit return Interfaces.C.int;
   pragma Import
     (C, C_Errno_Process_File_Limit,
      "flyology_errno_process_file_limit");
   function C_Errno_System_File_Limit return Interfaces.C.int;
   pragma Import
     (C, C_Errno_System_File_Limit,
      "flyology_errno_system_file_limit");

   Connection_Aborted_Error : constant Interfaces.C.int :=
     C_Errno_Connection_Aborted;
   Would_Block_Error : constant Interfaces.C.int := C_Errno_Would_Block;
   Interrupted_Error : constant Interfaces.C.int := C_Errno_Interrupted;
   In_Progress_Error : constant Interfaces.C.int := C_Errno_In_Progress;
   Already_In_Progress_Error : constant Interfaces.C.int :=
     C_Errno_Already_In_Progress;
   Already_Connected_Error : constant Interfaces.C.int :=
     C_Errno_Already_Connected;
   No_Buffer_Space_Error : constant Interfaces.C.int :=
     C_Errno_No_Buffer_Space;
   Protocol_Error : constant Interfaces.C.int := C_Errno_Protocol_Error;
   Process_File_Limit_Error : constant Interfaces.C.int :=
     C_Errno_Process_File_Limit;
   System_File_Limit_Error : constant Interfaces.C.int :=
     C_Errno_System_File_Limit;
   Accept_Discarded : constant Interfaces.C.int := -2;

   function Family_Code (Family : Address_Family) return Interfaces.C.int is
     (Flyology.Socket_Policy.Family_Code (Family = IPv6));

   function Mode_Code (Mode : Socket_Mode) return Interfaces.C.int is
     (Flyology.Socket_Policy.Mode_Code (Mode = Socket_Datagram));

   function Native_Domain
     (Family : Interfaces.C.int) return Interfaces.C.int
   is
     (if Family = 6 then C_IPv6_Domain
      elsif Family = 4 then C_IPv4_Domain
      elsif Family = 0 then C_Local_Domain
      else -1);

   function Native_Kind (Mode : Interfaces.C.int) return Interfaces.C.int is
     (if Mode = 2 then C_Datagram_Kind
      elsif Mode = 1 then C_Stream_Kind
      else -1);

   function Current_Errno return Interfaces.C.int is
     (Interfaces.C.int (GNAT.OS_Lib.Errno));

   procedure Close_Ignoring_Errors (Socket : Interfaces.C.int) is
      Result : constant Interfaces.C.int := C_Close_Raw (Socket);
      pragma Unreferenced (Result);
   begin
      null;
   end Close_Ignoring_Errors;

   function C_Create
     (Family : Interfaces.C.int;
      Mode   : Interfaces.C.int;
      Error  : access Interfaces.C.int) return Interfaces.C.int
   is
      Socket : constant Interfaces.C.int :=
        C_Socket (Native_Domain (Family), Native_Kind (Mode), 0);
   begin
      if Socket < 0 then
         Error.all := Current_Errno;
         return -1;
      end if;
      if C_Configure_Descriptor (Socket, 0) < 0
        or else
          (Flyology.Socket_Policy.Should_Enable_Datagram_Metadata (Mode)
           and then C_Enable_Datagram_Metadata_Impl (Socket) < 0)
      then
         Error.all := Current_Errno;
         Close_Ignoring_Errors (Socket);
         return -1;
      end if;
      Error.all := 0;
      return Socket;
   end C_Create;

   function C_Pair
     (Mode  : Interfaces.C.int;
      Left  : access Interfaces.C.int;
      Right : access Interfaces.C.int;
      Error : access Interfaces.C.int) return Interfaces.C.int
   is
      type Descriptor_Array is
        array (Natural range 0 .. 1) of aliased Interfaces.C.int
          with Convention => C;
      Descriptors : aliased Descriptor_Array := (others => -1);
   begin
      if C_Socket_Pair_Raw
           (C_Local_Domain, Native_Kind (Mode), 0, Descriptors'Address) < 0
      then
         Error.all := Current_Errno;
         return -1;
      end if;
      if C_Configure_Descriptor (Descriptors (0), 0) < 0
        or else C_Configure_Descriptor (Descriptors (1), 0) < 0
      then
         Error.all := Current_Errno;
         Close_Ignoring_Errors (Descriptors (0));
         Close_Ignoring_Errors (Descriptors (1));
         return -1;
      end if;
      Left.all := Descriptors (0);
      Right.all := Descriptors (1);
      Error.all := 0;
      return 0;
   end C_Pair;

   function C_Prepare
     (Socket : Interfaces.C.int;
      Error  : access Interfaces.C.int) return Interfaces.C.int
   is
   begin
      if C_Configure_Descriptor (Socket, 1) < 0 then
         Error.all := Current_Errno;
         return -1;
      end if;
      Error.all := 0;
      return 0;
   end C_Prepare;

   protected body Preparation_Bridge is
      procedure Ensure
        (Socket : Interfaces.C.int;
         State  : System.Address;
         Error  : access Interfaces.C.int;
         Result : out Interfaces.C.int)
      is
      begin
         if Atomics.Atomic_Load_32 (State, Atomics.Acquire) = Prepared then
            Error.all := 0;
            Result := 0;
            return;
         end if;
         Result := C_Prepare (Socket, Error);
         if Result = 0 then
            Set_Preparation_State (State, Prepared);
         end if;
      end Ensure;
   end Preparation_Bridge;

   function C_Set_Nonblocking
     (Socket  : Interfaces.C.int;
      Enabled : Interfaces.C.int;
      Error   : access Interfaces.C.int) return Interfaces.C.int
   is
   begin
      if C_Configure_Descriptor
           (Socket, (if Enabled = 0 then 0 else 1)) < 0
      then
         Error.all := Current_Errno;
         return -1;
      end if;
      Error.all := 0;
      return 0;
   end C_Set_Nonblocking;

   function C_Close
     (Socket : Interfaces.C.int;
      Error  : access Interfaces.C.int) return Interfaces.C.int
   is
   begin
      if C_Close_Raw (Socket) < 0 then
         Error.all := Current_Errno;
         return -1;
      end if;
      Error.all := 0;
      return 0;
   end C_Close;

   function C_Set_Reuse_Address
     (Socket  : Interfaces.C.int;
      Enabled : Interfaces.C.int;
      Error   : access Interfaces.C.int) return Interfaces.C.int
   is
      Value : aliased Interfaces.C.int := Enabled;
   begin
      if C_Set_Socket_Option
           (Socket, C_Socket_Level, C_Reuse_Address_Option,
            Value'Address,
            Interfaces.C.unsigned (Interfaces.C.int'Size / 8)) < 0
      then
         Error.all := Current_Errno;
         return -1;
      end if;
      Error.all := 0;
      return 0;
   end C_Set_Reuse_Address;

   function C_Set_Reuse_Port
     (Socket  : Interfaces.C.int;
      Enabled : Interfaces.C.int;
      Error   : access Interfaces.C.int) return Interfaces.C.int
   is
      Value : aliased Interfaces.C.int := Enabled;
   begin
      if C_Set_Socket_Option
           (Socket, C_Socket_Level, C_Reuse_Port_Option,
            Value'Address,
            Interfaces.C.unsigned (Interfaces.C.int'Size / 8)) < 0
      then
         Error.all := Current_Errno;
         return -1;
      end if;
      Error.all := 0;
      return 0;
   end C_Set_Reuse_Port;

   function C_Bind
     (Socket  : Interfaces.C.int;
      Family  : Interfaces.C.int;
      Address : System.Address;
      Port    : Interfaces.C.unsigned;
      Scope   : Interfaces.C.unsigned;
      Error   : access Interfaces.C.int) return Interfaces.C.int
   is
      Storage : aliased Socket_Address_Storage := (others => 0);
      Length  : aliased Interfaces.C.unsigned := 0;
   begin
      if C_Pack_Address
           (Family, Address, Port, Scope, Storage'Address, Length'Access) < 0
        or else C_Bind_Raw (Socket, Storage'Address, Length) < 0
      then
         Error.all := Current_Errno;
         return -1;
      end if;
      Error.all := 0;
      return 0;
   end C_Bind;

   function C_Bind
     (Socket : Interfaces.C.int;
      Path   : Unix_Path;
      Error  : access Interfaces.C.int) return Interfaces.C.int
   is
      Storage : aliased Socket_Address_Storage := (others => 0);
      Length  : aliased Interfaces.C.unsigned := 0;
   begin
      if C_Pack_Unix_Path
           (Path.Bytes (Path.Bytes'First)'Address,
            Interfaces.C.unsigned (Path.Length), Storage'Address,
            Length'Access) < 0
        or else C_Bind_Raw (Socket, Storage'Address, Length) < 0
      then
         Error.all := Current_Errno;
         return -1;
      end if;
      Error.all := 0;
      return 0;
   end C_Bind;

   function C_Listen
     (Socket  : Interfaces.C.int;
      Backlog : Interfaces.C.int;
      Error   : access Interfaces.C.int) return Interfaces.C.int
   is
   begin
      if C_Listen_Raw (Socket, Backlog) < 0 then
         Error.all := Current_Errno;
         return -1;
      end if;
      Error.all := 0;
      return 0;
   end C_Listen;

   function C_Name
     (Socket  : Interfaces.C.int;
      Peer    : Interfaces.C.int;
      Family  : access Interfaces.C.unsigned_char;
      Address : System.Address;
      Port    : access Interfaces.C.unsigned;
      Scope   : access Interfaces.C.unsigned;
      Error   : access Interfaces.C.int) return Interfaces.C.int
   is
      Storage : aliased Socket_Address_Storage := (others => 0);
      Length  : aliased Interfaces.C.unsigned :=
        Interfaces.C.unsigned (Socket_Address_Storage'Size / 8);
      Result  : Interfaces.C.int;
   begin
      Result :=
        (if Peer = 0
         then C_Get_Socket_Name_Raw
           (Socket, Storage'Address, Length'Access)
         else C_Get_Peer_Name_Raw
           (Socket, Storage'Address, Length'Access));
      if Result < 0
        or else C_Unpack_Address
          (Storage'Address, Length, Family, Address, Port, Scope) < 0
      then
         Error.all := Current_Errno;
         return -1;
      end if;
      Error.all := 0;
      return 0;
   end C_Name;

   function Failed_Accept_Status
     (Stage : Flyology.Socket_Policy.Post_Accept_Failure_Stage)
      return Interfaces.C.int
   is
     (case Flyology.Socket_Policy.Classify_Post_Accept_Failure (Stage) is
         when Flyology.Socket_Policy.Fail_Listener => -1,
         when Flyology.Socket_Policy.Discard_Accepted_Peer =>
            Accept_Discarded);

   function C_Accept
     (Socket  : Interfaces.C.int;
      Decode_Address : Interfaces.C.int;
      Family  : access Interfaces.C.unsigned_char;
      Address : System.Address;
      Port    : access Interfaces.C.unsigned;
      Scope   : access Interfaces.C.unsigned;
      Error   : access Interfaces.C.int) return Interfaces.C.int
   is
      Storage : aliased Socket_Address_Storage := (others => 0);
      Length  : aliased Interfaces.C.unsigned :=
        Interfaces.C.unsigned (Socket_Address_Storage'Size / 8);
      Accepted : constant Interfaces.C.int :=
        C_Raw_Accept (Socket, Storage'Address, Length'Access);
   begin
      if Accepted < 0 then
         Error.all := Current_Errno;
         return -1;
      end if;
      if Decode_Address /= 0
        and then C_Unpack_Address
          (Storage'Address, Length, Family, Address, Port, Scope) < 0
      then
         Error.all := Current_Errno;
         Close_Ignoring_Errors (Accepted);
         return Failed_Accept_Status
           (Flyology.Socket_Policy.Peer_Address_Decode);
      elsif Decode_Address = 0 then
         Family.all := 0;
         Port.all := 0;
         Scope.all := 0;
      end if;
      if C_Configure_Descriptor (Accepted, 1) < 0 then
         Error.all := Current_Errno;
         Close_Ignoring_Errors (Accepted);
         return Failed_Accept_Status
           (Flyology.Socket_Policy.Descriptor_Configuration);
      end if;
      Error.all := 0;
      return Accepted;
   end C_Accept;

   function C_Connect
     (Socket  : Interfaces.C.int;
      Family  : Interfaces.C.int;
      Address : System.Address;
      Port    : Interfaces.C.unsigned;
      Scope   : Interfaces.C.unsigned;
      Error   : access Interfaces.C.int) return Interfaces.C.int
   is
      Storage : aliased Socket_Address_Storage := (others => 0);
      Length  : aliased Interfaces.C.unsigned := 0;
   begin
      if C_Pack_Address
           (Family, Address, Port, Scope, Storage'Address, Length'Access) < 0
        or else C_Raw_Connect (Socket, Storage'Address, Length) < 0
      then
         Error.all := Current_Errno;
         return -1;
      end if;
      Error.all := 0;
      return 0;
   end C_Connect;

   function C_Connect
     (Socket : Interfaces.C.int;
      Path   : Unix_Path;
      Error  : access Interfaces.C.int) return Interfaces.C.int
   is
      Storage : aliased Socket_Address_Storage := (others => 0);
      Length  : aliased Interfaces.C.unsigned := 0;
   begin
      if C_Pack_Unix_Path
           (Path.Bytes (Path.Bytes'First)'Address,
            Interfaces.C.unsigned (Path.Length), Storage'Address,
            Length'Access) < 0
        or else C_Raw_Connect (Socket, Storage'Address, Length) < 0
      then
         Error.all := Current_Errno;
         return -1;
      end if;
      Error.all := 0;
      return 0;
   end C_Connect;

   function C_Pending_Error
     (Socket  : Interfaces.C.int;
      Pending : access Interfaces.C.int;
      Error   : access Interfaces.C.int) return Interfaces.C.int
   is
      Length : aliased Interfaces.C.unsigned :=
        Interfaces.C.unsigned (Interfaces.C.int'Size / 8);
   begin
      if C_Get_Socket_Option
           (Socket, C_Socket_Level, C_Pending_Error_Option,
            Pending.all'Address, Length'Access) < 0
      then
         Error.all := Current_Errno;
         return -1;
      end if;
      Error.all := 0;
      return 0;
   end C_Pending_Error;

   function C_Receive
     (Socket : Interfaces.C.int;
      Buffer : System.Address;
      Length : Interfaces.C.size_t;
      Error  : access Interfaces.C.int) return Interfaces.C.long
   is
      Result : constant Interfaces.C.long :=
        C_Recv (Socket, Buffer, Length, 0);
   begin
      Error.all := (if Result < 0 then Current_Errno else 0);
      return Result;
   end C_Receive;

   function C_Receive_From
     (Socket  : Interfaces.C.int;
      Buffer  : System.Address;
      Length  : Interfaces.C.size_t;
      Family  : access Interfaces.C.unsigned_char;
      Address : System.Address;
      Port    : access Interfaces.C.unsigned;
      Scope   : access Interfaces.C.unsigned;
      Error   : access Interfaces.C.int) return Interfaces.C.long
   is
      Storage : aliased Socket_Address_Storage := (others => 0);
      Address_Length : aliased Interfaces.C.unsigned :=
        Interfaces.C.unsigned (Socket_Address_Storage'Size / 8);
      Result : Interfaces.C.long;
      Address_Present : Boolean;
      Decode_Succeeded : Boolean := False;
      Decode_Error : Interfaces.C.int := 0;
      Ignored : System.Address;
      pragma Unreferenced (Ignored);
   begin
      Family.all := 0;
      Ignored := C_Memset (Address, 0, 16);
      Port.all := 0;
      Scope.all := 0;
      Result := C_Recv_From_Raw
        (Socket, Buffer, Length, 0, Storage'Address, Address_Length'Access);
      if Result < 0 then
         Error.all := Current_Errno;
         return -1;
      end if;
      Address_Present :=
        Address_Length >= Interfaces.C.unsigned (C_Address_Family_Field_Size);
      if Address_Present then
         Decode_Succeeded := C_Unpack_Address
           (Storage'Address, Address_Length, Family, Address, Port, Scope) = 0;
         if not Decode_Succeeded then
            Decode_Error := Current_Errno;
         end if;
      end if;
      case Flyology.Socket_Policy.Classify_Received_Address
        (Address_Present,
         Decode_Succeeded,
         Decode_Error,
         C_Errno_Address_Family_Not_Supported)
      is
         when Flyology.Socket_Policy.Use_Endpoint |
              Flyology.Socket_Policy.Use_No_Endpoint =>
            Error.all := 0;
            return Result;
         when Flyology.Socket_Policy.Fail_Receive =>
            Error.all := Decode_Error;
            return -1;
      end case;
   end C_Receive_From;

   function C_Enable_Datagram_Metadata
     (Socket : Interfaces.C.int;
      Error  : access Interfaces.C.int) return Interfaces.C.int
   is
   begin
      if C_Enable_Datagram_Metadata_Impl (Socket) < 0 then
         Error.all := Current_Errno;
         return -1;
      end if;
      Error.all := 0;
      return 0;
   end C_Enable_Datagram_Metadata;

   function C_Send
     (Socket : Interfaces.C.int;
      Buffer : System.Address;
      Length : Interfaces.C.size_t;
      Error  : access Interfaces.C.int) return Interfaces.C.long
   is
      Result : constant Interfaces.C.long :=
        C_Send_Raw (Socket, Buffer, Length, C_No_Signal_Flag);
   begin
      Error.all := (if Result < 0 then Current_Errno else 0);
      return Result;
   end C_Send;

   function C_Send_To
     (Socket  : Interfaces.C.int;
      Buffer  : System.Address;
      Length  : Interfaces.C.size_t;
      Family  : Interfaces.C.int;
      Address : System.Address;
      Port    : Interfaces.C.unsigned;
      Scope   : Interfaces.C.unsigned;
      Error   : access Interfaces.C.int) return Interfaces.C.long
   is
      Storage : aliased Socket_Address_Storage := (others => 0);
      Address_Length : aliased Interfaces.C.unsigned := 0;
      Result : Interfaces.C.long;
   begin
      if C_Pack_Address
           (Family, Address, Port, Scope,
            Storage'Address, Address_Length'Access) < 0
      then
         Error.all := Current_Errno;
         return -1;
      end if;
      Result := C_Send_To_Raw
        (Socket, Buffer, Length, C_No_Signal_Flag,
         Storage'Address, Address_Length);
      Error.all := (if Result < 0 then Current_Errno else 0);
      return Result;
   end C_Send_To;

   protected body Accept_Return_Bridge is
      procedure Invoke
        (Listener : Interfaces.C.int;
         Decode_Address : Interfaces.C.int;
         Family   : access Interfaces.C.unsigned_char;
         Address  : System.Address;
         Port     : access Interfaces.C.unsigned;
         Scope    : access Interfaces.C.unsigned;
         Error    : access Interfaces.C.int;
         Target   : in out Socket_Type;
         Result   : out Interfaces.C.int)
      is
      begin
         Result := C_Accept
           (Listener, Decode_Address, Family, Address, Port, Scope, Error);
         if Result >= 0 then
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
            Test_Raw_Accept_Return_Barrier;
#end if;
            Target.Value := Result;
            Set_Preparation_State
              (Target.Preparation'Address, Prepared);
         end if;
      end Invoke;
   end Accept_Return_Bridge;

   function Address_Data (Value : IP_Address) return System.Address is
     (case Value.Family is
         when IPv4 => Value.V4 (Value.V4'First)'Address,
         when IPv6 => Value.V6 (Value.V6'First)'Address);

   function Make_Endpoint
     (Family  : Interfaces.C.unsigned_char;
      Address : IPv6_Octets;
      Port    : Interfaces.C.unsigned;
      Scope   : Interfaces.C.unsigned) return Endpoint
   is
   begin
      if Family = 4 then
         return
           (Family => IPv4,
            Address =>
              (Family => IPv4,
               V4 => (Address (1), Address (2), Address (3), Address (4))),
            Port => Flyology.IO.Sockets.Port (Port), Scope => 0);
      elsif Family = 6 then
         return
           (Family => IPv6, Address => (Family => IPv6, V6 => Address),
            Port => Flyology.IO.Sockets.Port (Port),
            Scope => Scope_ID (Scope));
      else
         raise Socket_Error with "datagram metadata has unsupported family";
      end if;
   end Make_Endpoint;

   function Policy_Error_Kind
     (Error : Interfaces.C.int) return Flyology.Socket_Policy.Error_Kind
   is
     (Flyology.Socket_Policy.Classify_Error
        (Error,
         Would_Block_Error,
         Interrupted_Error,
         In_Progress_Error,
         Already_In_Progress_Error,
         Already_Connected_Error,
         No_Buffer_Space_Error));

   function Classified (Error : Interfaces.C.int) return Error_Type is
      Kind : constant Flyology.Socket_Policy.Error_Kind :=
        Policy_Error_Kind (Error);
   begin
      return
        (case Kind is
            when Flyology.Socket_Policy.Success => Success,
            when Flyology.Socket_Policy.Would_Block =>
               Resource_Temporarily_Unavailable,
            when Flyology.Socket_Policy.Interrupted =>
               Interrupted_System_Call,
            when Flyology.Socket_Policy.In_Progress =>
               Operation_Now_In_Progress,
            when Flyology.Socket_Policy.Already_In_Progress =>
               Operation_Already_In_Progress,
            when Flyology.Socket_Policy.Already_Connected =>
               Transport_Endpoint_Already_Connected,
            when Flyology.Socket_Policy.No_Buffer_Space =>
               No_Buffer_Space_Available,
            when Flyology.Socket_Policy.Other_Error => Other_Error);
   end Classified;

   procedure Raise_Error
     (Operation : String; Error : Interfaces.C.int)
   is
   begin
      raise Socket_Error with
        Operation & " failed [errno="
        & Ada.Strings.Fixed.Trim (Error'Image, Ada.Strings.Both) & "]";
   end Raise_Error;

   function Resolve_Exception
     (Occurrence : Ada.Exceptions.Exception_Occurrence) return Error_Type
   is
      Message : constant String :=
        Ada.Exceptions.Exception_Message (Occurrence);
      Marker  : constant String := "[errno=";
      First   : Natural := 0;
   begin
      for Index in Message'Range loop
         if Index + Marker'Length - 1 <= Message'Last
           and then Message (Index .. Index + Marker'Length - 1) = Marker
         then
            First := Index + Marker'Length;
         end if;
      end loop;
      if First = 0 or else Message'Last < First + 1
        or else Message (Message'Last) /= ']'
      then
         return Other_Error;
      end if;
      return Classified
        (Interfaces.C.int'Value (Message (First .. Message'Last - 1)));
   exception
      when Constraint_Error =>
         return Other_Error;
   end Resolve_Exception;

   function Is_IP_Address
     (Text : String; Family : Address_Family) return Boolean
   is
      C_Text : constant Interfaces.C.char_array := Interfaces.C.To_C (Text);
      Bytes  : aliased IPv6_Octets := (others => 0);
   begin
      return C_Parse_Address
        (Family_Code (Family), C_Text, Bytes (Bytes'First)'Address) = 1;
   end Is_IP_Address;

   function Parse_IP_Address (Text : String) return IP_Address is
      C_Text : constant Interfaces.C.char_array := Interfaces.C.To_C (Text);
      Bytes  : aliased IPv6_Octets := (others => 0);
   begin
      if C_Parse_Address (4, C_Text, Bytes (Bytes'First)'Address) = 1 then
         return
           (Family => IPv4,
            V4 => (1 => Bytes (1), 2 => Bytes (2),
                   3 => Bytes (3), 4 => Bytes (4)));
      elsif C_Parse_Address (6, C_Text, Bytes (Bytes'First)'Address) = 1 then
         return (Family => IPv6, V6 => Bytes);
      else
         raise Constraint_Error with "invalid numeric IP address: " & Text;
      end if;
   end Parse_IP_Address;

   function Image (Value : IP_Address) return String is
      Buffer : aliased Interfaces.C.char_array (0 .. 63) :=
        (others => Interfaces.C.nul);
   begin
      if C_Image_Address
           (Family_Code (Value.Family), Address_Data (Value),
            Buffer (Buffer'First)'Address,
            Interfaces.C.unsigned (Buffer'Length)) /= 0
      then
         raise Constraint_Error with "cannot format IP address";
      end if;
      return Interfaces.C.To_Ada (Buffer);
   end Image;

   function Image (Value : Endpoint) return String is
      Port_Image : constant String :=
        Ada.Strings.Fixed.Trim (Value.Port'Image, Ada.Strings.Both);
      Scope_Image : constant String :=
        (if Value.Scope = 0 then ""
         else "%" & Ada.Strings.Fixed.Trim
           (Value.Scope'Image, Ada.Strings.Both));
   begin
      if Value.Family = IPv6 then
         return
           "[" & Image (Value.Address) & Scope_Image & "]:" & Port_Image;
      else
         return Image (Value.Address) & ":" & Port_Image;
      end if;
   end Image;

   function Network_Endpoint
     (Address : IP_Address;
      Port    : Flyology.IO.Sockets.Port;
      Scope   : Scope_ID := 0) return Endpoint
   is
     (Family  => Address.Family,
      Address => Address,
      Port    => Port,
      Scope   => Scope);

   function Is_Open (Socket : Socket_Type) return Boolean is
     (Socket.Value >= 0);

   function Native_Descriptor (Socket : Socket_Type) return Descriptor is
     (Descriptor (Socket.Value));

   procedure Move (Source : in out Socket_Type; Target : in out Socket_Type) is
   begin
      if Is_Open (Target) then
         raise Program_Error with "socket move target is open";
      end if;
      Target.Value := Source.Value;
      Set_Preparation_State
        (Target.Preparation'Address, Preparation_State (Source));
      Source.Value := -1;
      Set_Preparation_State (Source.Preparation'Address, Unprepared);
   end Move;

   procedure Adopt (Source : in out Descriptor; Target : in out Socket_Type) is
   begin
      if Source < 0 then
         raise Program_Error with "cannot adopt an invalid descriptor";
      elsif Is_Open (Target) then
         raise Program_Error with "socket adopt target is open";
      end if;
      Target.Value := Interfaces.C.int (Source);
      Set_Preparation_State (Target.Preparation'Address, Unprepared);
      Source := Invalid_Descriptor;
   end Adopt;

   procedure Release (Source : in out Socket_Type; Target : out Descriptor) is
   begin
      Target := Descriptor (Source.Value);
      Source.Value := -1;
      Set_Preparation_State (Source.Preparation'Address, Unprepared);
   end Release;

   procedure Create_Socket
     (Socket : in out Socket_Type;
      Family : Address_Family := IPv4;
      Mode   : Socket_Mode := Socket_Stream)
   is
      Error  : aliased Interfaces.C.int;
      Result : Interfaces.C.int;
   begin
      if Is_Open (Socket) then
         raise Program_Error with "socket creation target is open";
      end if;
      Result := C_Create
        (Family_Code (Family), Mode_Code (Mode), Error'Access);
      if Result < 0 then
         Socket.Value := -1;
         Set_Preparation_State (Socket.Preparation'Address, Unprepared);
         Raise_Error ("socket", Error);
      end if;
      Socket.Value := Result;
      Set_Preparation_State (Socket.Preparation'Address, Unprepared);
   end Create_Socket;

   procedure Create_Unix_Stream_Socket (Socket : in out Socket_Type) is
      Error  : aliased Interfaces.C.int;
      Result : Interfaces.C.int;
   begin
      if Is_Open (Socket) then
         raise Program_Error with "socket creation target is open";
      end if;
      Result := C_Create (0, Mode_Code (Socket_Stream), Error'Access);
      if Result < 0 then
         Socket.Value := -1;
         Set_Preparation_State (Socket.Preparation'Address, Unprepared);
         Raise_Error ("socket", Error);
      end if;
      Socket.Value := Result;
      Set_Preparation_State (Socket.Preparation'Address, Unprepared);
   end Create_Unix_Stream_Socket;

   procedure Create_Socket_Pair
     (Left  : in out Socket_Type;
      Right : in out Socket_Type;
      Mode  : Socket_Mode := Socket_Stream)
   is
      Error   : aliased Interfaces.C.int;
      C_Left  : aliased Interfaces.C.int;
      C_Right : aliased Interfaces.C.int;
   begin
      if Is_Open (Left) or else Is_Open (Right) then
         raise Program_Error with "socket pair target is open";
      elsif Left'Address = Right'Address then
         raise Program_Error with "socket pair targets alias";
      end if;
      if C_Pair (Mode_Code (Mode), C_Left'Access, C_Right'Access, Error'Access)
        /= 0
      then
         Left.Value := -1;
         Right.Value := -1;
         Set_Preparation_State (Left.Preparation'Address, Unprepared);
         Set_Preparation_State (Right.Preparation'Address, Unprepared);
         Raise_Error ("socketpair", Error);
      end if;
      Left.Value := C_Left;
      Right.Value := C_Right;
      Set_Preparation_State (Left.Preparation'Address, Unprepared);
      Set_Preparation_State (Right.Preparation'Address, Unprepared);
   end Create_Socket_Pair;

   procedure Close_Socket (Socket : in out Socket_Type) is
      Error  : aliased Interfaces.C.int;
      Result : Interfaces.C.int;
   begin
      if not Is_Open (Socket) then
         return;
      end if;
      Result := C_Close (Socket.Value, Error'Access);
      Socket.Value := -1;
      Set_Preparation_State (Socket.Preparation'Address, Unprepared);
      if Result /= 0 then
         Raise_Error ("close", Error);
      end if;
   end Close_Socket;

   procedure Prepare (Socket : Socket_Type) is
      Error  : aliased Interfaces.C.int;
      Result : Interfaces.C.int;
   begin
      if Preparation_State (Socket) = Prepared then
         return;
      end if;
      Preparation_Bridge.Ensure
        (Socket.Value, Socket.Preparation'Address, Error'Access, Result);
      if Result /= 0 then
         Raise_Error ("configure socket", Error);
      end if;
   end Prepare;

   procedure Enable_Datagram_Metadata (Socket : Socket_Type) is
      Error : aliased Interfaces.C.int;
   begin
      if C_Enable_Datagram_Metadata (Socket.Value, Error'Access) /= 0 then
         Raise_Error ("configure datagram metadata", Error);
      end if;
   end Enable_Datagram_Metadata;

   procedure Set_Socket_Option
     (Socket : Socket_Type; Option : Option_Type)
   is
      Error  : aliased Interfaces.C.int;
      Result : Interfaces.C.int;
   begin
      case Option.Name is
         when Reuse_Address =>
            Result := C_Set_Reuse_Address
              (Socket.Value, Boolean'Pos (Option.Enabled),
               Error'Access);
         when Reuse_Port =>
            Result := C_Set_Reuse_Port
              (Socket.Value, Boolean'Pos (Option.Enabled),
               Error'Access);
         when Receive_Timeout =>
            Result := C_Set_Receive_Timeout
              (Socket.Value,
               Interfaces.C.double (Option.Timeout), Error'Access);
      end case;
      if Result /= 0 then
         Raise_Error ("setsockopt", Error);
      end if;
   end Set_Socket_Option;

   procedure Set_Socket_Option
     (Socket : Socket_Type;
      Level  : Option_Level;
      Option : Option_Type)
   is
      pragma Unreferenced (Level);
   begin
      Set_Socket_Option (Socket, Option);
   end Set_Socket_Option;

   procedure Bind_Socket (Socket : Socket_Type; Address : Endpoint) is
      Error : aliased Interfaces.C.int;
   begin
      if C_Bind
           (Socket.Value, Family_Code (Address.Family),
            Address_Data (Address.Address),
            Interfaces.C.unsigned (Address.Port),
            Interfaces.C.unsigned (Address.Scope), Error'Access) /= 0
      then
         Raise_Error ("bind", Error);
      end if;
   end Bind_Socket;

   procedure Bind_Socket (Socket : Socket_Type; Address : Unix_Path) is
      Error : aliased Interfaces.C.int;
   begin
      if C_Bind (Socket.Value, Address, Error'Access) /= 0 then
         Raise_Error ("bind", Error);
      end if;
   end Bind_Socket;

   procedure Listen_Socket (Socket : Socket_Type; Length : Positive := 15) is
      Error : aliased Interfaces.C.int;
   begin
      if C_Listen
           (Socket.Value, Interfaces.C.int (Length), Error'Access)
        /= 0
      then
         Raise_Error ("listen", Error);
      end if;
   end Listen_Socket;

   function Read_Name (Socket : Socket_Type; Peer : Boolean) return Endpoint is
      Family  : aliased Interfaces.C.unsigned_char;
      Address : aliased IPv6_Octets := (others => 0);
      Port    : aliased Interfaces.C.unsigned;
      Scope   : aliased Interfaces.C.unsigned;
      Error   : aliased Interfaces.C.int;
   begin
      if C_Name
           (Socket.Value, Boolean'Pos (Peer), Family'Access,
            Address (Address'First)'Address, Port'Access, Scope'Access,
            Error'Access) /= 0
      then
         Raise_Error ((if Peer then "getpeername" else "getsockname"), Error);
      end if;
      if Family = 4 then
         return
           (Family => IPv4,
            Address =>
              (Family => IPv4,
               V4 => (Address (1), Address (2), Address (3), Address (4))),
            Port => Flyology.IO.Sockets.Port (Port), Scope => 0);
      elsif Family = 6 then
         return
           (Family => IPv6, Address => (Family => IPv6, V6 => Address),
            Port => Flyology.IO.Sockets.Port (Port),
            Scope => Scope_ID (Scope));
      else
         raise Socket_Error with "socket name has unsupported address family";
      end if;
   end Read_Name;

   function Get_Socket_Name (Socket : Socket_Type) return Endpoint is
     (Read_Name (Socket, False));

   function Get_Peer_Name (Socket : Socket_Type) return Endpoint is
     (Read_Name (Socket, True));

   --  Wait for a connection the kernel is still establishing and report the
   --  pending socket error it resolved to. Declared here because both the
   --  blocking setup path and the task-aware path need it; the body follows
   --  the readiness helper it uses.
   procedure Complete_Connection
     (Socket     : Socket_Type;
      Started    : Ada.Real_Time.Time;
      Timeout    : Duration;
      Interrupts : Interrupt_Set);

   procedure Connect_Socket (Socket : Socket_Type; Server : Endpoint) is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Error   : aliased Interfaces.C.int;
   begin
      if C_Connect
           (Socket.Value, Family_Code (Server.Family),
            Address_Data (Server.Address), Interfaces.C.unsigned (Server.Port),
            Interfaces.C.unsigned (Server.Scope), Error'Access) = 0
      then
         return;
      end if;
      case Flyology.Socket_Policy.Classify_Connect_Error
        (Policy_Error_Kind (Error))
      is
         when Flyology.Socket_Policy.Wait_For_Connection =>
            --  A signal that interrupts connect(2) does not abort the
            --  request: the kernel keeps establishing the connection. Await
            --  its outcome instead of reporting a failure that would make the
            --  caller close or duplicate a live handshake.
            Complete_Connection (Socket, Started, Infinite, No_Interrupts);
         when Flyology.Socket_Policy.Connected =>
            null;
         when Flyology.Socket_Policy.Fail_Connect =>
            Raise_Error ("connect", Error);
      end case;
   end Connect_Socket;

   procedure Receive_Socket
     (Socket : Socket_Type;
      Item   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset)
   is
      Error  : aliased Interfaces.C.int;
      Result : Interfaces.C.long;
   begin
      if Item'Length = 0 then
         Last := Item'First - 1;
         return;
      end if;
      Result := C_Receive
        (Socket.Value, Item (Item'First)'Address,
         Interfaces.C.size_t (Item'Length), Error'Access);
      if Result < 0 then
         Raise_Error ("recv", Error);
      elsif Result = 0 then
         Last := Item'First - 1;
      else
         Last := Item'First + Ada.Streams.Stream_Element_Offset (Result) - 1;
      end if;
   end Receive_Socket;

   procedure Receive_Socket
     (Socket : Socket_Type;
      Item   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      From   : out Endpoint)
   is
      Family  : aliased Interfaces.C.unsigned_char;
      Address : aliased IPv6_Octets := (others => 0);
      Port    : aliased Interfaces.C.unsigned;
      Scope   : aliased Interfaces.C.unsigned;
      Error   : aliased Interfaces.C.int;
      Result  : Interfaces.C.long;
   begin
      if Item'Length = 0 then
         Last := Item'First - 1;
         From := No_Endpoint;
         return;
      end if;
      Result := C_Receive_From
        (Socket.Value, Item (Item'First)'Address,
         Interfaces.C.size_t (Item'Length), Family'Access,
         Address (Address'First)'Address, Port'Access, Scope'Access,
         Error'Access);
      if Result < 0 then
         Raise_Error ("recvfrom", Error);
      end if;
      Last := Item'First + Ada.Streams.Stream_Element_Offset (Result) - 1;
      if Family = 4 then
         From :=
           (Family => IPv4,
            Address =>
              (Family => IPv4,
               V4 => (Address (1), Address (2), Address (3), Address (4))),
            Port => Flyology.IO.Sockets.Port (Port), Scope => 0);
      elsif Family = 6 then
         From :=
           (Family => IPv6, Address => (Family => IPv6, V6 => Address),
            Port => Flyology.IO.Sockets.Port (Port),
            Scope => Scope_ID (Scope));
      else
         From := No_Endpoint;
      end if;
   end Receive_Socket;

   procedure Send_Socket
     (Socket : Socket_Type;
      Item   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset)
   is
      Buffer : constant System.Address :=
        (if Item'Length = 0
         then System.Null_Address
         else Item (Item'First)'Address);
      Error  : aliased Interfaces.C.int;
      Result : Interfaces.C.long;
   begin
      Result := C_Send
        (Socket.Value, Buffer,
         Interfaces.C.size_t (Item'Length), Error'Access);
      if Result < 0 then
         Raise_Error ("send", Error);
      elsif Result = 0 then
         Last := Item'First - 1;
      else
         Last := Item'First + Ada.Streams.Stream_Element_Offset (Result) - 1;
      end if;
   end Send_Socket;

   procedure Send_Socket
     (Socket : Socket_Type;
      Item   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      To     : Endpoint)
   is
      Buffer : constant System.Address :=
        (if Item'Length = 0
         then System.Null_Address
         else Item (Item'First)'Address);
      Error  : aliased Interfaces.C.int;
      Result : Interfaces.C.long;
   begin
      Result := C_Send_To
        (Socket.Value, Buffer,
         Interfaces.C.size_t (Item'Length), Family_Code (To.Family),
         Address_Data (To.Address), Interfaces.C.unsigned (To.Port),
         Interfaces.C.unsigned (To.Scope), Error'Access);
      if Result < 0 then
         Raise_Error ("sendto", Error);
      elsif Result = 0 then
         Last := Item'First - 1;
      else
         Last := Item'First + Ada.Streams.Stream_Element_Offset (Result) - 1;
      end if;
   end Send_Socket;

   procedure Control_Socket
     (Socket : Socket_Type; Request : in out Request_Type)
   is
      Error  : aliased Interfaces.C.int;
      Result : Interfaces.C.int;
      Count  : aliased Interfaces.C.unsigned_long;
   begin
      case Request.Name is
         when Non_Blocking_IO =>
            Result := C_Set_Nonblocking
              (Socket.Value, Boolean'Pos (Request.Enabled),
               Error'Access);
            if Result = 0 then
               Set_Preparation_State
                 (Socket.Preparation'Address,
                  (if Request.Enabled then Prepared else Unprepared));
            end if;
         when N_Bytes_To_Read =>
            Result := C_Bytes_To_Read
              (Socket.Value, Count'Access, Error'Access);
            if Result = 0 then
               Request.Size := Natural (Count);
            end if;
      end case;
      if Result /= 0 then
         Raise_Error ("socket control", Error);
      end if;
   end Control_Socket;

   function Remaining
     (Started : Ada.Real_Time.Time; Timeout : Duration) return Duration
   is
      Elapsed : Duration;
   begin
      if Timeout < 0.0 then
         return Infinite;
      end if;
      Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
      return Time_Math.Remaining (Timeout, Elapsed);
   end Remaining;

   procedure Wait_For
     (Socket     : Socket_Type;
      Condition  : Wait_Kind;
      Started    : Ada.Real_Time.Time;
      Timeout    : Duration;
      Interrupts : Interrupt_Set)
   is
      Outcome : constant Wait_Outcome :=
        Wait_Interruptibly
          (Native_Descriptor (Socket), Condition,
           Remaining (Started, Timeout), Interrupts);
   begin
      case Outcome is
         when Ready => null;
         when Timed_Out =>
            raise Timeout_Error with "socket operation timed out";
         when Interrupted =>
            raise Operation_Interrupted with "socket operation interrupted";
      end case;
   end Wait_For;

   procedure Complete_Connection
     (Socket     : Socket_Type;
      Started    : Ada.Real_Time.Time;
      Timeout    : Duration;
      Interrupts : Interrupt_Set)
   is
      Error   : aliased Interfaces.C.int;
      Pending : aliased Interfaces.C.int;
   begin
      Wait_For (Socket, For_Write, Started, Timeout, Interrupts);
      if C_Pending_Error (Socket.Value, Pending'Access, Error'Access) /= 0 then
         Raise_Error ("getsockopt(SO_ERROR)", Error);
      elsif Pending /= 0 then
         Raise_Error ("connect", Pending);
      end if;
   end Complete_Connection;

   procedure Receive_Prepared
     (Socket     : Socket_Type;
      Item       : out Ada.Streams.Stream_Element_Array;
      Last       : out Ada.Streams.Stream_Element_Offset;
      Timeout    : Duration;
      Interrupts : Interrupt_Set)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Error   : aliased Interfaces.C.int;
      Result  : Interfaces.C.long;
   begin
      if Item'Length = 0 then
         Last := Item'First - 1;
         return;
      end if;
      loop
         Result := C_Receive
           (Socket.Value, Item (Item'First)'Address,
            Interfaces.C.size_t (Item'Length), Error'Access);
         if Result >= 0 then
            if Result = 0 then
               Last := Item'First - 1;
            else
               Last :=
                 Item'First + Ada.Streams.Stream_Element_Offset (Result) - 1;
            end if;
            return;
         end if;
         case Flyology.Socket_Policy.Classify_IO_Error
           (Policy_Error_Kind (Error))
         is
            when Flyology.Socket_Policy.Wait_For_Ready =>
               Wait_For (Socket, For_Read, Started, Timeout, Interrupts);
            when Flyology.Socket_Policy.Retry_Operation =>
               if Timeout >= 0.0 and then Remaining (Started, Timeout) <= 0.0
               then
                  raise Timeout_Error with "socket operation timed out";
               end if;
            when Flyology.Socket_Policy.Fail_Operation =>
               Raise_Error ("recv", Error);
         end case;
      end loop;
   end Receive_Prepared;

   procedure Receive
     (Socket     : Socket_Type;
      Item       : out Ada.Streams.Stream_Element_Array;
      Last       : out Ada.Streams.Stream_Element_Offset;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
   is
   begin
      Prepare (Socket);
      Receive_Prepared (Socket, Item, Last, Timeout, Interrupts);
   end Receive;

   procedure Receive_Datagram
     (Socket     : Socket_Type;
      Item       : out Ada.Streams.Stream_Element_Array;
      Last       : out Ada.Streams.Stream_Element_Offset;
      Metadata   : out Datagram_Metadata;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
   is
      Started             : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Source_Family       : aliased Interfaces.C.unsigned_char;
      Source_Address      : aliased IPv6_Octets := (others => 0);
      Source_Port         : aliased Interfaces.C.unsigned;
      Source_Scope        : aliased Interfaces.C.unsigned;
      Destination_Family  : aliased Interfaces.C.unsigned_char;
      Destination_Address : aliased IPv6_Octets := (others => 0);
      Destination_Port    : aliased Interfaces.C.unsigned;
      Destination_Scope   : aliased Interfaces.C.unsigned;
      C_ECN               : aliased Interfaces.C.int;
      Error               : aliased Interfaces.C.int;
      Result              : Interfaces.C.long;
      Buffer              : constant System.Address :=
        (if Item'Length = 0
         then System.Null_Address
         else Item (Item'First)'Address);
      Copied              : Natural;
   begin
      Prepare (Socket);
      loop
         Result := C_Receive_Datagram
           (Socket.Value, Buffer, Interfaces.C.size_t (Item'Length),
            Source_Family'Access,
            Source_Address (Source_Address'First)'Address,
            Source_Port'Access, Source_Scope'Access,
            Destination_Family'Access,
            Destination_Address (Destination_Address'First)'Address,
            Destination_Port'Access, Destination_Scope'Access,
            C_ECN'Access, Error'Access);
         if Result >= 0 then
            Copied := Natural'Min (Natural (Result), Item'Length);
            Last :=
              (if Copied = 0
               then Item'First - 1
               else Item'First
                 + Ada.Streams.Stream_Element_Offset (Copied) - 1);
            Metadata :=
              (Source =>
                 Make_Endpoint
                   (Source_Family, Source_Address, Source_Port, Source_Scope),
               Destination =>
                 Make_Endpoint
                   (Destination_Family, Destination_Address,
                    Destination_Port, Destination_Scope),
               Original_Length => Natural (Result),
               Truncated => Natural (Result) > Item'Length,
               ECN =>
                 (case C_ECN is
                     when 0 => Not_ECT,
                     when 1 => ECT_One,
                     when 2 => ECT_Zero,
                     when 3 => Congestion_Experienced,
                     when others => ECN_Unavailable));
            return;
         end if;
         case Flyology.Socket_Policy.Classify_IO_Error
           (Policy_Error_Kind (Error))
         is
            when Flyology.Socket_Policy.Wait_For_Ready =>
               Wait_For (Socket, For_Read, Started, Timeout, Interrupts);
            when Flyology.Socket_Policy.Retry_Operation =>
               if Timeout >= 0.0 and then Remaining (Started, Timeout) <= 0.0
               then
                  raise Timeout_Error with "socket operation timed out";
               end if;
            when Flyology.Socket_Policy.Fail_Operation =>
               Raise_Error ("recvmsg", Error);
         end case;
      end loop;
   end Receive_Datagram;

   procedure Receive
     (Socket     : Socket_Type;
      Item       : in out Flyology.Buffers.Unique_Buffer;
      Received   : out Natural;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
   is
      procedure Borrow
        (Data   : in out Ada.Streams.Stream_Element_Array;
         Length : in out Natural)
      is
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Receive (Socket, Data, Last, Timeout, Interrupts);
         Length :=
           (if Last < Data'First
            then 0
            else Natural (Last - Data'First + 1));
         Received := Length;
      end Borrow;
   begin
      Received := 0;
      Flyology.Buffers.With_Writable_Data (Item, Borrow'Access);
   end Receive;

   procedure Receive_Exactly
     (Socket     : Socket_Type;
      Item       : out Ada.Streams.Stream_Element_Array;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      First   : Ada.Streams.Stream_Element_Offset := Item'First;
      Last    : Ada.Streams.Stream_Element_Offset;
   begin
      Prepare (Socket);
      while First <= Item'Last loop
         Receive_Prepared
           (Socket, Item (First .. Item'Last), Last,
            Remaining (Started, Timeout), Interrupts);
         if Last < First then
            raise Device_Error with "socket closed while receiving";
         end if;
         First := Last + 1;
      end loop;
   end Receive_Exactly;

   procedure Send_Prepared
     (Socket     : Socket_Type;
      Item       : Ada.Streams.Stream_Element_Array;
      Last       : out Ada.Streams.Stream_Element_Offset;
      Timeout    : Duration;
      Interrupts : Interrupt_Set)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Error   : aliased Interfaces.C.int;
      Result  : Interfaces.C.long;
   begin
      if Item'Length = 0 then
         Last := Item'First - 1;
         return;
      end if;
      loop
         Result := C_Send
           (Socket.Value, Item (Item'First)'Address,
            Interfaces.C.size_t (Item'Length), Error'Access);
         if Result >= 0 then
            if Result = 0 then
               Last := Item'First - 1;
            else
               Last :=
                 Item'First + Ada.Streams.Stream_Element_Offset (Result) - 1;
            end if;
            return;
         end if;
         case Flyology.Socket_Policy.Classify_IO_Error
           (Policy_Error_Kind (Error))
         is
            when Flyology.Socket_Policy.Wait_For_Ready =>
               Wait_For (Socket, For_Write, Started, Timeout, Interrupts);
            when Flyology.Socket_Policy.Retry_Operation =>
               if Timeout >= 0.0 and then Remaining (Started, Timeout) <= 0.0
               then
                  raise Timeout_Error with "socket operation timed out";
               end if;
            when Flyology.Socket_Policy.Fail_Operation =>
               Raise_Error ("send", Error);
         end case;
      end loop;
   end Send_Prepared;

   procedure Send
     (Socket     : Socket_Type;
      Item       : Ada.Streams.Stream_Element_Array;
      Last       : out Ada.Streams.Stream_Element_Offset;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
   is
   begin
      Prepare (Socket);
      Send_Prepared (Socket, Item, Last, Timeout, Interrupts);
   end Send;

   procedure Send_Datagram_Common
     (Socket        : Socket_Type;
      Item          : Ada.Streams.Stream_Element_Array;
      Last          : out Ada.Streams.Stream_Element_Offset;
      Destination   : Endpoint;
      Source        : Endpoint;
      Select_Source : Boolean;
      Timeout       : Duration;
      Interrupts    : Interrupt_Set)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Error   : aliased Interfaces.C.int;
      Result  : Interfaces.C.long;
      Buffer  : constant System.Address :=
        (if Item'Length = 0
         then System.Null_Address
         else Item (Item'First)'Address);
   begin
      Prepare (Socket);
      loop
         Result := C_Send_Datagram
           (Socket.Value, Buffer, Interfaces.C.size_t (Item'Length),
            Family_Code (Destination.Family),
            Address_Data (Destination.Address),
            Interfaces.C.unsigned (Destination.Port),
            Interfaces.C.unsigned (Destination.Scope),
            Boolean'Pos (Select_Source), Family_Code (Source.Family),
            Address_Data (Source.Address), Interfaces.C.unsigned (Source.Port),
            Interfaces.C.unsigned (Source.Scope), Error'Access);
         if Result >= 0 then
            if Result /= Interfaces.C.long (Item'Length) then
               raise Device_Error with "partial datagram send";
            end if;
            Last :=
              (if Result = 0
               then Item'First - 1
               else Item'First
                 + Ada.Streams.Stream_Element_Offset (Result) - 1);
            return;
         end if;
         case Flyology.Socket_Policy.Classify_IO_Error
           (Policy_Error_Kind (Error))
         is
            when Flyology.Socket_Policy.Wait_For_Ready =>
               Wait_For (Socket, For_Write, Started, Timeout, Interrupts);
            when Flyology.Socket_Policy.Retry_Operation =>
               if Timeout >= 0.0 and then Remaining (Started, Timeout) <= 0.0
               then
                  raise Timeout_Error with "socket operation timed out";
               end if;
            when Flyology.Socket_Policy.Fail_Operation =>
               Raise_Error ("sendmsg", Error);
         end case;
      end loop;
   end Send_Datagram_Common;

   procedure Send_Datagram
     (Socket      : Socket_Type;
      Item        : Ada.Streams.Stream_Element_Array;
      Last        : out Ada.Streams.Stream_Element_Offset;
      Destination : Endpoint;
      Timeout     : Duration := Infinite;
      Interrupts  : Interrupt_Set := No_Interrupts)
   is
   begin
      Send_Datagram_Common
        (Socket, Item, Last, Destination, Destination, False, Timeout,
         Interrupts);
   end Send_Datagram;

   procedure Send_Datagram
     (Socket      : Socket_Type;
      Item        : Ada.Streams.Stream_Element_Array;
      Last        : out Ada.Streams.Stream_Element_Offset;
      Destination : Endpoint;
      Source      : Endpoint;
      Timeout     : Duration := Infinite;
      Interrupts  : Interrupt_Set := No_Interrupts)
   is
   begin
      Send_Datagram_Common
        (Socket, Item, Last, Destination, Source, True, Timeout, Interrupts);
   end Send_Datagram;

   procedure Send
     (Socket     : Socket_Type;
      Item       : Flyology.Buffers.Unique_Buffer;
      Sent       : out Natural;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
   is
      procedure Borrow (Data : Ada.Streams.Stream_Element_Array) is
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Send (Socket, Data, Last, Timeout, Interrupts);
         Sent :=
           (if Last < Data'First
            then 0
            else Natural (Last - Data'First + 1));
      end Borrow;
   begin
      Sent := 0;
      Flyology.Buffers.With_Readable_Data (Item, Borrow'Access);
   end Send;

   procedure Send_All
     (Socket     : Socket_Type;
      Item       : Ada.Streams.Stream_Element_Array;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      First   : Ada.Streams.Stream_Element_Offset := Item'First;
      Last    : Ada.Streams.Stream_Element_Offset;
   begin
      Prepare (Socket);
      while First <= Item'Last loop
         Send_Prepared
           (Socket, Item (First .. Item'Last), Last,
            Remaining (Started, Timeout), Interrupts);
         if Last < First then
            raise Device_Error with "socket closed while sending";
         end if;
         First := Last + 1;
      end loop;
   end Send_All;

   procedure Send_All
     (Socket     : Socket_Type;
      Item       : Flyology.Buffers.Unique_Buffer;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
   is
      procedure Borrow (Data : Ada.Streams.Stream_Element_Array) is
      begin
         Send_All (Socket, Data, Timeout, Interrupts);
      end Borrow;
   begin
      Flyology.Buffers.With_Readable_Data (Item, Borrow'Access);
   end Send_All;

   procedure Start_Scoped
     (Item        : in out Socket_Operation'Class;
      Kind        : Scoped_IO_Kind;
      Socket      : not null access Socket_Type;
      Array_Item  : access Ada.Streams.Stream_Element_Array;
      Buffer_Item : access Flyology.Buffers.Unique_Buffer;
      Timeout     : Duration)
   is
   begin
      Prepare (Socket.all);
      Item.Kind := Kind;
      Item.Socket := Socket.all'Unchecked_Access;
      Item.Array_Item :=
        (if Array_Item = null
         then null
         else Array_Item.all'Unchecked_Access);
      Item.Buffer_Item :=
        (if Buffer_Item = null
         then null
         else Buffer_Item.all'Unchecked_Access);
      Item.Cursor :=
        (if Array_Item = null then 1 else Array_Item.all'First);
      Item.Transferred := 0;
      Item.Error_Code := 0;
      Item.Failure := No_Failure;
      Flyology.Operations.Drivers.Start (Item);
      if Timeout >= 0.0 then
         Flyology.Operations.Drivers.Arm_Deadline (Item, Timeout);
      end if;
      Flyology.Operations.Drive
        (Flyology.Operations.Operation'Class (Item),
         Flyology.Operations.Start_Operation);
   exception
      when others =>
         if Flyology.Operations.Is_Active (Item) then
            Flyology.Operations.Cancel (Item);
         end if;
         if Flyology.Operations.Is_Terminal (Item) then
            Flyology.Operations.Consume (Item);
         end if;
         raise;
   end Start_Scoped;

   overriding procedure Drive
     (Item  : in out Socket_Operation;
      Event : Flyology.Operations.Driver_Event)
   is
      procedure Fail
        (Reason : Scoped_Failure;
         Error  : Interfaces.C.int := 0)
      is
      begin
         Item.Failure := Reason;
         Item.Error_Code := Error;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Failed);
      end Fail;

      procedure Attempt
        (Data_First : Ada.Streams.Stream_Element_Offset;
         Data_Last  : Ada.Streams.Stream_Element_Offset;
         Address    : System.Address)
      is
         Sending : constant Boolean :=
           Item.Kind in Send_One | Send_Complete |
             Buffer_Send_One | Buffer_Send_Complete;
         Complete_All : constant Boolean :=
           Item.Kind in Receive_Exact | Send_Complete |
             Buffer_Send_Complete;
         First : constant Ada.Streams.Stream_Element_Offset :=
           (if Complete_All then Item.Cursor else Data_First);
         Count : Natural;
         Error : aliased Interfaces.C.int := 0;
         Result : Interfaces.C.long;
         Result_Address : System.Address;
         Retry_Attempt : Natural := 0;
      begin
         if First > Data_Last then
            Flyology.Operations.Drivers.Complete
              (Item, Flyology.Operations.Succeeded);
            return;
         end if;
         Count := Natural (Data_Last - First + 1);
         Result_Address := Address
           + System.Storage_Elements.Storage_Offset
               (First - Data_First);
         loop
            if Sending then
               Result := C_Send
                 (Item.Socket.Value,
                  Result_Address,
                  Interfaces.C.size_t (Count),
                  Error'Access);
            else
               Result := C_Receive
                 (Item.Socket.Value,
                  Result_Address,
                  Interfaces.C.size_t (Count),
                  Error'Access);
            end if;
            exit when Result >= 0;
            declare
               Action : constant Flyology.Socket_Policy.IO_Error_Action :=
                 Flyology.Socket_Policy.Classify_IO_Error
                   (Policy_Error_Kind (Error));
            begin
               exit when Action /= Flyology.Socket_Policy.Retry_Operation;
               Retry_Attempt := Retry_Attempt + 1;
               if not Flyology.Socket_Policy.Retry_IO_Immediately
                 (Retry_Attempt)
               then
                  Flyology.Operations.Drivers.Arm_Readiness
                    (Item, Item.Socket.Value, Sending);
                  return;
               end if;
            end;
         end loop;

         if Result < 0 then
            case Flyology.Socket_Policy.Classify_IO_Error
              (Policy_Error_Kind (Error))
            is
               when Flyology.Socket_Policy.Wait_For_Ready =>
                  Flyology.Operations.Drivers.Arm_Readiness
                    (Item, Item.Socket.Value, Sending);
               when Flyology.Socket_Policy.Retry_Operation =>
                  raise Program_Error with
                    "socket driver retained an interrupted result";
               when Flyology.Socket_Policy.Fail_Operation =>
                  Fail (Socket_Failure, Error);
            end case;
            return;
         end if;

         if Result > 0 then
            Item.Transferred := Item.Transferred + Natural (Result);
         end if;
         if not Complete_All then
            Flyology.Operations.Drivers.Complete
              (Item, Flyology.Operations.Succeeded);
         elsif Result = 0 then
            Fail
              ((if Sending
                then No_Progress_Failure
                else Peer_Closed_Failure));
         else
            Item.Cursor := First
              + Ada.Streams.Stream_Element_Offset (Result);
            if Item.Cursor > Data_Last then
               Flyology.Operations.Drivers.Complete
                 (Item, Flyology.Operations.Succeeded);
            else
               Flyology.Operations.Drivers.Arm_Readiness
                 (Item, Item.Socket.Value, Sending);
            end if;
         end if;
      end Attempt;

      procedure Borrow_Writable
        (Data   : in out Ada.Streams.Stream_Element_Array;
         Length : in out Natural)
      is
         pragma Unreferenced (Length);
      begin
         Attempt
           (Data'First,
            Data'Last,
            (if Data'Length = 0
             then System.Null_Address
             else Data (Data'First)'Address));
      end Borrow_Writable;

      procedure Borrow_Readable
        (Data : Ada.Streams.Stream_Element_Array)
      is
      begin
         Attempt
           (Data'First,
            Data'Last,
            (if Data'Length = 0
             then System.Null_Address
             else Data (Data'First)'Address));
      end Borrow_Readable;
   begin
      if Event = Flyology.Operations.Deadline_Reached then
         Fail (Deadline_Failure);
      elsif Item.Array_Item /= null then
         Attempt
           (Item.Array_Item.all'First,
            Item.Array_Item.all'Last,
            (if Item.Array_Item.all'Length = 0
             then System.Null_Address
             else Item.Array_Item.all
               (Item.Array_Item.all'First)'Address));
      elsif Item.Buffer_Item /= null then
         case Item.Kind is
            when Buffer_Receive_One =>
               Flyology.Buffers.With_Writable_Data
                 (Item.Buffer_Item.all, Borrow_Writable'Access);
            when Buffer_Send_One | Buffer_Send_Complete =>
               Flyology.Buffers.With_Readable_Data
                 (Item.Buffer_Item.all, Borrow_Readable'Access);
            when others =>
               raise Program_Error with "invalid socket buffer operation";
         end case;
      else
         raise Program_Error with "socket operation has no buffer";
      end if;
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Socket_Operation)
   is
   begin
      Flyology.Operations.Drivers.Complete
        (Item, Flyology.Operations.Cancelled);
   end Request_Cancellation;

   procedure Receive
     (Socket    : not null access Socket_Type;
      Item      : not null access Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Infinite;
      Operation : in out Receive_Operation)
   is
   begin
      Start_Scoped
        (Operation, Receive_One, Socket, Item, null, Timeout);
   end Receive;

   function Receive
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Socket  : not null access Socket_Type;
      Item    : not null access Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite) return Receive_Operation
   is
   begin
      return Result : Receive_Operation (Set) do
         Receive (Socket, Item, Timeout, Result);
      end return;
   end Receive;

   procedure Receive_Exactly
     (Socket    : not null access Socket_Type;
      Item      : not null access Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Infinite;
      Operation : in out Receive_Exactly_Operation)
   is
   begin
      Start_Scoped
        (Operation, Receive_Exact, Socket, Item, null, Timeout);
   end Receive_Exactly;

   function Receive_Exactly
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Socket  : not null access Socket_Type;
      Item    : not null access Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite) return Receive_Exactly_Operation
   is
   begin
      return Result : Receive_Exactly_Operation (Set) do
         Receive_Exactly (Socket, Item, Timeout, Result);
      end return;
   end Receive_Exactly;

   procedure Send
     (Socket    : not null access Socket_Type;
      Item      : not null access Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Infinite;
      Operation : in out Send_Operation)
   is
   begin
      Start_Scoped (Operation, Send_One, Socket, Item, null, Timeout);
   end Send;

   function Send
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Socket  : not null access Socket_Type;
      Item    : not null access Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite) return Send_Operation
   is
   begin
      return Result : Send_Operation (Set) do
         Send (Socket, Item, Timeout, Result);
      end return;
   end Send;

   procedure Send_All
     (Socket    : not null access Socket_Type;
      Item      : not null access Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Infinite;
      Operation : in out Send_All_Operation)
   is
   begin
      Start_Scoped
        (Operation, Send_Complete, Socket, Item, null, Timeout);
   end Send_All;

   function Send_All
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Socket  : not null access Socket_Type;
      Item    : not null access Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite) return Send_All_Operation
   is
   begin
      return Result : Send_All_Operation (Set) do
         Send_All (Socket, Item, Timeout, Result);
      end return;
   end Send_All;

   procedure Receive
     (Socket    : not null access Socket_Type;
      Item      : not null access Flyology.Buffers.Unique_Buffer;
      Timeout   : Duration := Infinite;
      Operation : in out Buffer_Receive_Operation)
   is
   begin
      Start_Scoped
        (Operation, Buffer_Receive_One, Socket, null, Item, Timeout);
   end Receive;

   function Receive
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Socket  : not null access Socket_Type;
      Item    : not null access Flyology.Buffers.Unique_Buffer;
      Timeout : Duration := Infinite) return Buffer_Receive_Operation
   is
   begin
      return Result : Buffer_Receive_Operation (Set) do
         Receive (Socket, Item, Timeout, Result);
      end return;
   end Receive;

   procedure Send
     (Socket    : not null access Socket_Type;
      Item      : not null access Flyology.Buffers.Unique_Buffer;
      Timeout   : Duration := Infinite;
      Operation : in out Buffer_Send_Operation)
   is
   begin
      Start_Scoped
        (Operation, Buffer_Send_One, Socket, null, Item, Timeout);
   end Send;

   function Send
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Socket  : not null access Socket_Type;
      Item    : not null access Flyology.Buffers.Unique_Buffer;
      Timeout : Duration := Infinite) return Buffer_Send_Operation
   is
   begin
      return Result : Buffer_Send_Operation (Set) do
         Send (Socket, Item, Timeout, Result);
      end return;
   end Send;

   procedure Send_All
     (Socket    : not null access Socket_Type;
      Item      : not null access Flyology.Buffers.Unique_Buffer;
      Timeout   : Duration := Infinite;
      Operation : in out Buffer_Send_All_Operation)
   is
   begin
      Start_Scoped
        (Operation, Buffer_Send_Complete, Socket, null, Item, Timeout);
   end Send_All;

   function Send_All
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Socket  : not null access Socket_Type;
      Item    : not null access Flyology.Buffers.Unique_Buffer;
      Timeout : Duration := Infinite) return Buffer_Send_All_Operation
   is
   begin
      return Result : Buffer_Send_All_Operation (Set) do
         Send_All (Socket, Item, Timeout, Result);
      end return;
   end Send_All;

   procedure Finish_Common
     (Operation : in out Socket_Operation'Class)
   is
      Outcome : constant Flyology.Operations.Terminal_Outcome :=
        Flyology.Operations.Outcome (Operation);
      Failure : constant Scoped_Failure := Operation.Failure;
      Error   : constant Interfaces.C.int := Operation.Error_Code;
      Sending : constant Boolean :=
        Operation.Kind in Send_One | Send_Complete |
          Buffer_Send_One | Buffer_Send_Complete;
   begin
      Flyology.Operations.Consume (Operation);
      case Outcome is
         when Flyology.Operations.Succeeded =>
            null;
         when Flyology.Operations.Cancelled =>
            raise Flyology.Operations.Operation_Cancelled;
         when Flyology.Operations.Failed =>
            case Failure is
               when Deadline_Failure =>
                  raise Timeout_Error with "socket operation timed out";
               when Peer_Closed_Failure =>
                  raise Device_Error with
                    "socket closed while receiving";
               when No_Progress_Failure =>
                  raise Device_Error with
                    "socket closed while sending";
               when Socket_Failure =>
                  Raise_Error ((if Sending then "send" else "recv"), Error);
               when No_Failure =>
                  raise Device_Error with "socket operation failed";
            end case;
      end case;
   end Finish_Common;

   procedure Finish
     (Operation : in out Receive_Operation;
      Last      : out Ada.Streams.Stream_Element_Offset)
   is
   begin
      Last := Operation.Array_Item.all'First - 1;
      if Operation.Transferred > 0 then
         Last := Operation.Array_Item.all'First
           + Ada.Streams.Stream_Element_Offset (Operation.Transferred) - 1;
      end if;
      Finish_Common (Operation);
   end Finish;

   procedure Finish (Operation : in out Receive_Exactly_Operation) is
   begin
      Finish_Common (Operation);
   end Finish;

   procedure Finish
     (Operation : in out Send_Operation;
      Last      : out Ada.Streams.Stream_Element_Offset)
   is
   begin
      Last := Operation.Array_Item.all'First - 1;
      if Operation.Transferred > 0 then
         Last := Operation.Array_Item.all'First
           + Ada.Streams.Stream_Element_Offset (Operation.Transferred) - 1;
      end if;
      Finish_Common (Operation);
   end Finish;

   procedure Finish (Operation : in out Send_All_Operation) is
   begin
      Finish_Common (Operation);
   end Finish;

   procedure Finish
     (Operation : in out Buffer_Receive_Operation;
      Received  : out Natural)
   is
      procedure Commit
        (Data   : in out Ada.Streams.Stream_Element_Array;
         Length : in out Natural)
      is
         pragma Unreferenced (Data);
      begin
         Length := Operation.Transferred;
      end Commit;
   begin
      Received := Operation.Transferred;
      if Flyology.Operations.Outcome (Operation) =
        Flyology.Operations.Succeeded
      then
         Flyology.Buffers.With_Writable_Data
           (Operation.Buffer_Item.all, Commit'Access);
      end if;
      Finish_Common (Operation);
   end Finish;

   procedure Finish
     (Operation : in out Buffer_Send_Operation;
      Sent      : out Natural)
   is
   begin
      Sent := Operation.Transferred;
      Finish_Common (Operation);
   end Finish;

   procedure Finish (Operation : in out Buffer_Send_All_Operation) is
   begin
      Finish_Common (Operation);
   end Finish;

   procedure Accept_Internal
     (Server     : Socket_Type;
      Socket     : in out Socket_Type;
      Address    : out Endpoint;
      Timeout    : Duration;
      Interrupts : Interrupt_Set;
      Decode_Address : Boolean)
   is
      Started  : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Pressure_Backoff : Duration := 0.001;
      Bridge : Accept_Return_Bridge;

      procedure Pause_Before_Retry (Requested : Duration) is
         Requests : Wait_Request_Array (Interrupts'Range);
         Left     : constant Duration := Remaining (Started, Timeout);
         Pause    : Duration;
      begin
         if Timeout >= 0.0 and then Left <= 0.0 then
            raise Timeout_Error with "socket operation timed out";
         end if;
         Pause :=
           (if Requested <= 0.0 then 0.0
            elsif Timeout < 0.0 then Requested
            else Duration'Min (Requested, Left));
         for Index in Interrupts'Range loop
            Requests (Index) :=
              (FD => Interrupts (Index), Condition => For_Read);
         end loop;
         if Requests'Length > 0 then
            if Wait_Any (Requests, Pause) /= 0 then
               raise Operation_Interrupted with "socket operation interrupted";
            end if;
         elsif Pause > 0.0 then
            delay Pause;
         end if;
         if Pause = 0.0 then
            delay 0.0;
         end if;
         if Timeout >= 0.0 and then Remaining (Started, Timeout) <= 0.0 then
            raise Timeout_Error with "socket operation timed out";
         end if;
      end Pause_Before_Retry;
   begin
      if Is_Open (Socket) then
         raise Program_Error with "accept target is open";
      end if;
      Socket.Value := -1;
      Address := No_Endpoint;
      Prepare (Server);
      loop
         declare
            Family  : aliased Interfaces.C.unsigned_char;
            Bytes   : aliased IPv6_Octets := (others => 0);
            Port    : aliased Interfaces.C.unsigned;
            Scope   : aliased Interfaces.C.unsigned;
            Error   : aliased Interfaces.C.int;
            Result : Interfaces.C.int;
         begin
            Bridge.Invoke
              (Server.Value,
               Boolean'Pos (Decode_Address),
               Family'Access,
               Bytes (Bytes'First)'Address,
               Port'Access,
               Scope'Access,
               Error'Access,
               Socket,
               Result);
            if Result = Accept_Discarded then
               --  accept(2) succeeded, but the peer became unusable before
               --  descriptor configuration completed.  The C boundary has
               --  already closed that connection; retry without classifying
               --  the setup errno as a listener failure.
               Pause_Before_Retry (0.0);
            elsif Result < 0 then
               case Wait_Policy.Classify_Accept_Error
                 (Error,
                  Would_Block_Error,
                  Interrupted_Error,
                  Connection_Aborted_Error,
                  Protocol_Error,
                  Process_File_Limit_Error,
                  System_File_Limit_Error)
               is
                  when Wait_Policy.Wait_For_Connection =>
                     Wait_For (Server, For_Read, Started, Timeout, Interrupts);
                  when Wait_Policy.Retry_Accept |
                       Wait_Policy.Retry_Transient =>
                     Pause_Before_Retry (0.0);
                  when Wait_Policy.Backoff_Descriptor_Pressure =>
                     Pause_Before_Retry (Pressure_Backoff);
                     Pressure_Backoff :=
                       Duration'Min (Pressure_Backoff * 2, 0.050);
                  when Wait_Policy.Fail_Accept =>
                     Raise_Error ("accept", Error);
               end case;
            else
               if Family = 4 then
                  Address :=
                    (Family => IPv4,
                     Address =>
                       (Family => IPv4,
                        V4 => (Bytes (1), Bytes (2), Bytes (3), Bytes (4))),
                     Port => Flyology.IO.Sockets.Port (Port), Scope => 0);
               elsif Family = 6 then
                  Address :=
                    (Family => IPv6,
                     Address => (Family => IPv6, V6 => Bytes),
                     Port => Flyology.IO.Sockets.Port (Port),
                     Scope => Scope_ID (Scope));
               else
                  Address := No_Endpoint;
               end if;
               return;
            end if;
         end;
      end loop;
   exception
      when others =>
         if Is_Open (Socket) then
            Close_Socket (Socket);
         end if;
         raise;
   end Accept_Internal;

   procedure Accept_Connection
     (Server     : Socket_Type;
      Socket     : in out Socket_Type;
      Address    : out Endpoint;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts) is
   begin
      Accept_Internal
        (Server, Socket, Address, Timeout, Interrupts,
         Decode_Address => True);
   end Accept_Connection;

   procedure Accept_Connection
     (Server     : Socket_Type;
      Socket     : in out Socket_Type;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
   is
      Ignored : Endpoint;
   begin
      Accept_Internal
        (Server, Socket, Ignored, Timeout, Interrupts,
         Decode_Address => False);
   end Accept_Connection;

   procedure Accept_Socket
     (Server  : Socket_Type;
      Socket  : in out Socket_Type;
      Address : out Endpoint;
      Timeout : Duration;
      Status  : out Selector_Status)
   is
      Blocking : Request_Type (Non_Blocking_IO) :=
        (Name => Non_Blocking_IO, Enabled => False);
   begin
      Accept_Connection (Server, Socket, Address, Timeout);
      begin
         Control_Socket (Socket, Blocking);
      exception
         when others =>
            begin
               Close_Socket (Socket);
            exception
               when others =>
                  null;
            end;
            raise;
      end;
      Status := Completed;
   exception
      when Timeout_Error =>
         Address := No_Endpoint;
         Status := Expired;
   end Accept_Socket;

   procedure Connect
     (Socket     : Socket_Type;
      Server     : Endpoint;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Error   : aliased Interfaces.C.int;
      Result  : Interfaces.C.int;
   begin
      Prepare (Socket);
      Result := C_Connect
        (Socket.Value, Family_Code (Server.Family),
         Address_Data (Server.Address), Interfaces.C.unsigned (Server.Port),
         Interfaces.C.unsigned (Server.Scope), Error'Access);
      if Result = 0 then
         return;
      end if;
      case Flyology.Socket_Policy.Classify_Connect_Error
        (Policy_Error_Kind (Error))
      is
         when Flyology.Socket_Policy.Wait_For_Connection =>
            null;
         when Flyology.Socket_Policy.Connected =>
            return;
         when Flyology.Socket_Policy.Fail_Connect =>
            Raise_Error ("connect", Error);
      end case;

      Complete_Connection (Socket, Started, Timeout, Interrupts);
   end Connect;

   procedure Connect
     (Socket     : Socket_Type;
      Server     : Unix_Path;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Error   : aliased Interfaces.C.int;
      Result  : Interfaces.C.int;

      procedure Pause_Before_Retry is
         Requests : Wait_Request_Array (Interrupts'Range);
         Left     : constant Duration := Remaining (Started, Timeout);
         Pause    : constant Duration :=
           (if Timeout < 0.0 then 0.001 else Duration'Min (0.001, Left));
      begin
         if Timeout >= 0.0 and then Left <= 0.0 then
            raise Timeout_Error with "socket operation timed out";
         end if;
         for Index in Interrupts'Range loop
            Requests (Index) :=
              (FD => Interrupts (Index), Condition => For_Read);
         end loop;
         if Requests'Length > 0 then
            if Wait_Any (Requests, Pause) /= 0 then
               raise Operation_Interrupted with "socket operation interrupted";
            end if;
         else
            delay Pause;
         end if;
         if Timeout >= 0.0 and then Remaining (Started, Timeout) <= 0.0 then
            raise Timeout_Error with "socket operation timed out";
         end if;
      end Pause_Before_Retry;
   begin
      Prepare (Socket);
      loop
         Result := C_Connect (Socket.Value, Server, Error'Access);
         if Result = 0 then
            return;
         end if;
         if Policy_Error_Kind (Error) = Flyology.Socket_Policy.Would_Block then
            --  Linux reports a full AF_UNIX listen queue as EAGAIN rather
            --  than EINPROGRESS.  No connection is pending in that case, so
            --  retry under the original deadline while still observing every
            --  caller interrupt descriptor.
            Pause_Before_Retry;
         else
            case Flyology.Socket_Policy.Classify_Connect_Error
              (Policy_Error_Kind (Error))
            is
               when Flyology.Socket_Policy.Wait_For_Connection =>
                  Complete_Connection
                    (Socket, Started, Timeout, Interrupts);
                  return;
               when Flyology.Socket_Policy.Connected =>
                  return;
               when Flyology.Socket_Policy.Fail_Connect =>
                  Raise_Error ("connect", Error);
            end case;
         end if;
      end loop;

   end Connect;

end Flyology.IO.Sockets;
