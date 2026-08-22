with Ada.Unchecked_Conversion;

package body Flyology.Shared_Memory_Native is
   use type C.int;

   O_RDONLY   : constant C.int := 16#0000#;
   O_RDWR     : constant C.int := 16#0002#;
   O_CREAT    : constant C.int := 16#0200#;
   O_EXCL     : constant C.int := 16#0800#;
   O_CLOEXEC  : constant C.int := 16#0100_0000#;
   O_NOFOLLOW : constant C.int := 16#0100#;
   FD_CLOEXEC : constant C.int := 1;
   O_ACCMODE  : constant C.int := 3;
   S_IFMT     : constant Interfaces.Unsigned_32 := 8#170000#;
   S_IFREG    : constant Interfaces.Unsigned_32 := 8#100000#;

   function C_Shared_Open
     (Name : C_Strings.chars_ptr; Flags : C.int; Mode : C.unsigned)
      return C.int;
   pragma Import (C_Variadic_2, C_Shared_Open, "shm_open");
   function C_Shared_Unlink (Name : C_Strings.chars_ptr) return C.int;
   pragma Import (C, C_Shared_Unlink, "shm_unlink");
   function C_File_Open
     (Path : C_Strings.chars_ptr; Flags : C.int; Mode : C.unsigned)
      return C.int;
   pragma Import (C_Variadic_2, C_File_Open, "open");
   function C_File_Unlink (Path : C_Strings.chars_ptr) return C.int;
   pragma Import (C, C_File_Unlink, "unlink");
   function C_Truncate
     (Descriptor : C.int; Length : C.long_long) return C.int;
   pragma Import (C, C_Truncate, "ftruncate");
   function C_Close (Descriptor : C.int) return C.int;
   pragma Import (C, C_Close, "close");
   function C_Fsync (Descriptor : C.int) return C.int;
   pragma Import (C, C_Fsync, "fsync");
   function C_Mmap
     (Address : System.Address;
      Length : C.size_t;
      Protection, Flags, Descriptor : C.int;
      Offset : C.long_long) return System.Address;
   pragma Import (C, C_Mmap, "mmap");
   function C_Munmap
     (Base : System.Address; Length : C.size_t) return C.int;
   pragma Import (C, C_Munmap, "munmap");
   function C_Msync
     (Base : System.Address; Length : C.size_t; Flags : C.int) return C.int;
   pragma Import (C, C_Msync, "msync");
   procedure Arc4random_Buf (Target : System.Address; Length : C.size_t);
   pragma Import (C, Arc4random_Buf, "arc4random_buf");
   function C_Getsockopt
     (Socket, Level, Option : C.int;
      Value : System.Address;
      Length : access C.unsigned) return C.int;
   pragma Import (C, C_Getsockopt, "getsockopt");
   function C_Setsockopt
     (Socket, Level, Option : C.int;
      Value : System.Address;
      Length : C.unsigned) return C.int;
   pragma Import (C, C_Setsockopt, "setsockopt");

   function C_Descriptor_Stat
     (Descriptor : C.int;
      Size : access C.long_long;
      Device, Inode : access C.unsigned_long_long;
      Mode : access C.unsigned) return C.int;
   pragma Import (C, C_Descriptor_Stat, "flyology_shm_fstat_fields");
   function C_Path_Stat
     (Path : C_Strings.chars_ptr;
      Size : access C.long_long;
      Device, Inode : access C.unsigned_long_long;
      Mode : access C.unsigned) return C.int;
   pragma Import (C, C_Path_Stat, "flyology_shm_lstat_fields");
   function C_Get_FD (Descriptor : C.int) return C.int;
   pragma Import (C, C_Get_FD, "flyology_shm_fcntl_getfd");
   function C_Set_FD (Descriptor, Flags : C.int) return C.int;
   pragma Import (C, C_Set_FD, "flyology_shm_fcntl_setfd");
   function C_Get_FL (Descriptor : C.int) return C.int;
   pragma Import (C, C_Get_FL, "flyology_shm_fcntl_getfl");
   function C_Get_Seals (Descriptor : C.int) return C.int;
   pragma Import (C, C_Get_Seals, "flyology_shm_fcntl_get_seals");
   function C_Add_Seals (Descriptor, Seals : C.int) return C.int;
   pragma Import (C, C_Add_Seals, "flyology_shm_fcntl_add_seals");
   function C_Memfd_Create (Flags : C.unsigned) return C.int;
   pragma Import (C, C_Memfd_Create, "flyology_shm_memfd_create");
   function C_Local_Family
     (Descriptor : C.int; Family : access C.int) return C.int;
   pragma Import (C, C_Local_Family, "flyology_shm_getsockname_family");
   function C_Peer_Family
     (Descriptor : C.int; Family : access C.int) return C.int;
   pragma Import (C, C_Peer_Family, "flyology_shm_getpeername_family");
   function C_Socket_Accepting
     (Descriptor : C.int; Accepting : access C.int) return C.int;
   pragma Import (C, C_Socket_Accepting, "flyology_shm_socket_accepting");
   function C_Send_Once (Socket, Descriptor : C.int) return C.long;
   pragma Import (C, C_Send_Once, "flyology_shm_send_fd_once");
   function C_Receive_Once
     (Socket, Flags : C.int;
      Descriptors : System.Address;
      Capacity : C.size_t;
      Count : access C.size_t;
      Payload : access Interfaces.Unsigned_8;
      Message_Flags, Malformed : access C.int) return C.long;
   pragma Import (C, C_Receive_Once, "flyology_shm_receive_fds_once");

   function To_Address is new Ada.Unchecked_Conversion
     (C.unsigned_long_long, System.Address);

   function Is_Linux return Boolean is (False);
   function POSIX_Identity_Supported return Boolean is (False);
   function Untrusted_Handoff_Supported return Boolean is (False);
   function Error_Interrupted return C.int is (4);
   function Error_Invalid return C.int is (22);
   function Error_Exists return C.int is (17);
   function Error_IO return C.int is (5);
   function Error_Not_Socket return C.int is (38);
   function Error_Not_Connected return C.int is (57);
   function Open_Read_Only return C.int is (O_RDONLY);
   function Open_Read_Write return C.int is (O_RDWR);
   function Open_Create return C.int is (O_CREAT);
   function Open_Exclusive return C.int is (O_EXCL);
   function Open_Close_On_Exec return C.int is (O_CLOEXEC);
   function Shared_Open_Close_On_Exec return C.int is (0);
   function Open_No_Follow return C.int is (O_NOFOLLOW);
   function Descriptor_Close_On_Exec return C.int is (FD_CLOEXEC);
   function Access_Mode_Mask return C.int is (O_ACCMODE);
   function Status_Read_Write return C.int is (O_RDWR);
   function File_Type_Mask return Interfaces.Unsigned_32 is (S_IFMT);
   function Regular_File_Type return Interfaces.Unsigned_32 is (S_IFREG);
   function Owner_Only_Mask return Interfaces.Unsigned_32 is (8#77#);
   function Seal_Seal return C.int is (1);
   function Seal_Shrink return C.int is (2);
   function Seal_Grow return C.int is (4);
   function Seal_Execute return C.int is (16#20#);
   function Memfd_Close_On_Exec return C.unsigned is (1);
   function Memfd_Allow_Sealing return C.unsigned is (2);
   function Memfd_No_Execute_Seal return C.unsigned is (8);
   function Message_Close_On_Exec return C.int is (0);
   function Message_Control_Truncated return C.int is (16#20#);
   function Message_Truncated return C.int is (16#10#);

   function Shared_Open
     (Name : C_Strings.chars_ptr; Flags : C.int; Mode : C.unsigned)
      return C.int is (C_Shared_Open (Name, Flags, Mode));
   function Shared_Unlink (Name : C_Strings.chars_ptr) return C.int is
     (C_Shared_Unlink (Name));
   function File_Open
     (Path : C_Strings.chars_ptr; Flags : C.int; Mode : C.unsigned)
      return C.int is (C_File_Open (Path, Flags, Mode));
   function File_Unlink (Path : C_Strings.chars_ptr) return C.int is
     (C_File_Unlink (Path));
   function Truncate
     (Descriptor : C.int; Length : C.long_long) return C.int is
     (C_Truncate (Descriptor, Length));
   function Close (Descriptor : C.int) return C.int is (C_Close (Descriptor));
   function Flush_File (Descriptor : C.int) return C.int is
     (C_Fsync (Descriptor));
   function Map_Shared
     (Descriptor : C.int; Length : C.size_t) return System.Address is
     (C_Mmap (System.Null_Address, Length, 3, 1, Descriptor, 0));
   function Failed_Mapping return System.Address is
     (To_Address (C.unsigned_long_long'Last));
   function Unmap
     (Base : System.Address; Length : C.size_t) return C.int is
     (C_Munmap (Base, Length));
   function Flush_Mapping
     (Base : System.Address; Length : C.size_t; Synchronous : Boolean)
      return C.int is
     (C_Msync (Base, Length, (if Synchronous then 16#10# else 1)));

   function Descriptor_Stat
     (Descriptor : C.int; Fields : out Stat_Fields) return C.int
   is
      Size : aliased C.long_long;
      Device, Inode : aliased C.unsigned_long_long;
      Mode : aliased C.unsigned;
      Result : C.int;
   begin
      Result := C_Descriptor_Stat
        (Descriptor, Size'Access, Device'Access, Inode'Access, Mode'Access);
      Fields := (Size, Device, Inode, Mode);
      return Result;
   end Descriptor_Stat;

   function Path_Stat
     (Path : C_Strings.chars_ptr; Fields : out Stat_Fields) return C.int
   is
      Size : aliased C.long_long;
      Device, Inode : aliased C.unsigned_long_long;
      Mode : aliased C.unsigned;
      Result : C.int;
   begin
      Result := C_Path_Stat
        (Path, Size'Access, Device'Access, Inode'Access, Mode'Access);
      Fields := (Size, Device, Inode, Mode);
      return Result;
   end Path_Stat;

   function Get_Descriptor_Flags (Descriptor : C.int) return C.int is
     (C_Get_FD (Descriptor));
   function Set_Descriptor_Flags
     (Descriptor : C.int; Flags : C.int) return C.int is
     (C_Set_FD (Descriptor, Flags));
   function Get_Status_Flags (Descriptor : C.int) return C.int is
     (C_Get_FL (Descriptor));
   function Get_Seals (Descriptor : C.int) return C.int is
     (C_Get_Seals (Descriptor));
   function Add_Seals (Descriptor : C.int; Seals : C.int) return C.int is
     (C_Add_Seals (Descriptor, Seals));
   function Memfd_Create (Flags : C.unsigned) return C.int is
     (C_Memfd_Create (Flags));
   function Fill_Random
     (Target : System.Address; Length : C.size_t) return C.int is
   begin
      Arc4random_Buf (Target, Length);
      return 0;
   end Fill_Random;

   function Socket_Type (Descriptor : C.int; Value : out C.int) return C.int
   is
      Local : aliased C.int;
      Length : aliased C.unsigned := C.unsigned (C.int'Size / 8);
      Result : constant C.int :=
        C_Getsockopt (Descriptor, 16#FFFF#, 16#1008#,
                      Local'Address, Length'Access);
   begin
      Value := Local;
      return Result;
   end Socket_Type;
   function Socket_Accepting
     (Descriptor : C.int; Value : out C.int) return C.int
   is
      Local  : aliased C.int;
      Result : constant C.int :=
        C_Socket_Accepting (Descriptor, Local'Access);
   begin
      Value := Local;
      return Result;
   end Socket_Accepting;
   function Local_Socket_Family
     (Descriptor : C.int; Family : out C.int) return C.int
   is
      Local : aliased C.int;
      Result : constant C.int := C_Local_Family (Descriptor, Local'Access);
   begin
      Family := Local;
      return Result;
   end Local_Socket_Family;
   function Peer_Socket_Family
     (Descriptor : C.int; Family : out C.int) return C.int
   is
      Local : aliased C.int;
      Result : constant C.int := C_Peer_Family (Descriptor, Local'Access);
   begin
      Family := Local;
      return Result;
   end Peer_Socket_Family;
   function Unix_Socket_Family return C.int is (1);
   function Stream_Socket_Type return C.int is (1);
   function Enable_No_SIGPIPE (Descriptor : C.int) return C.int
   is
      Enabled : aliased C.int := 1;
   begin
      return C_Setsockopt
        (Descriptor, 16#FFFF#, 16#1022#, Enabled'Address,
         C.unsigned (C.int'Size / 8));
   end Enable_No_SIGPIPE;
   function Send_Descriptor_Once
     (Socket : C.int; Descriptor : C.int) return C.long is
     (C_Send_Once (Socket, Descriptor));
   function Receive_Descriptors_Once
     (Socket : C.int;
      Flags : C.int;
      Descriptors : in out Descriptor_Array;
      Count : out C.size_t;
      Payload : out Interfaces.Unsigned_8;
      Message_Flags : out C.int;
      Structurally_Malformed : out Boolean) return C.long
   is
      Local_Count : aliased C.size_t;
      Local_Payload : aliased Interfaces.Unsigned_8;
      Local_Flags, Local_Malformed : aliased C.int;
      Result : C.long;
   begin
      Result := C_Receive_Once
        (Socket, Flags, Descriptors'Address, Descriptors'Length,
         Local_Count'Access, Local_Payload'Access,
         Local_Flags'Access, Local_Malformed'Access);
      Count := Local_Count;
      Payload := Local_Payload;
      Message_Flags := Local_Flags;
      Structurally_Malformed := Local_Malformed /= 0;
      return Result;
   end Receive_Descriptors_Once;
end Flyology.Shared_Memory_Native;
