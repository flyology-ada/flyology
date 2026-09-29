with Interfaces;
with Interfaces.C;
with Interfaces.C.Strings;
with System;

--  Private OS/ABI mechanisms for shared memory. Each operation is either one
--  directly imported fixed-signature syscall or one narrow C leaf required by
--  a variadic call, preprocessor-only constant, or host C structure layout.
--  Retry, validation, cleanup, ownership, and lifecycle policy stay in Ada.

private package Flyology.Shared_Memory_Native
  with Preelaborate
is
   package C renames Interfaces.C;
   package C_Strings renames Interfaces.C.Strings;

   type Stat_Fields is record
      Size   : C.long_long := 0;
      Device : C.unsigned_long_long := 0;
      Inode  : C.unsigned_long_long := 0;
      Mode   : C.unsigned := 0;
   end record;

   type Descriptor_Array is array (C.size_t range <>) of aliased C.int with Convention => C;

   function Is_Linux return Boolean;
   function POSIX_Identity_Supported return Boolean;
   function Untrusted_Handoff_Supported return Boolean;

   function Error_Interrupted return C.int;
   function Error_Invalid return C.int;
   function Error_Exists return C.int;
   function Error_IO return C.int;
   function Error_Not_Socket return C.int;
   function Error_Not_Connected return C.int;

   function Open_Read_Only return C.int;
   function Open_Read_Write return C.int;
   function Open_Create return C.int;
   function Open_Exclusive return C.int;
   function Open_Close_On_Exec return C.int;
   function Shared_Open_Close_On_Exec return C.int;
   function Open_No_Follow return C.int;
   function Descriptor_Close_On_Exec return C.int;
   function Access_Mode_Mask return C.int;
   function Status_Read_Write return C.int;
   function File_Type_Mask return Interfaces.Unsigned_32;
   function Regular_File_Type return Interfaces.Unsigned_32;
   function Owner_Only_Mask return Interfaces.Unsigned_32;

   function Seal_Seal return C.int;
   function Seal_Shrink return C.int;
   function Seal_Grow return C.int;
   function Seal_Execute return C.int;
   function Memfd_Close_On_Exec return C.unsigned;
   function Memfd_Allow_Sealing return C.unsigned;
   function Memfd_No_Execute_Seal return C.unsigned;

   function Message_Close_On_Exec return C.int;
   function Message_Control_Truncated return C.int;
   function Message_Truncated return C.int;

   function Shared_Open (Name : C_Strings.chars_ptr; Flags : C.int; Mode : C.unsigned) return C.int;
   function Shared_Unlink (Name : C_Strings.chars_ptr) return C.int;
   function File_Open (Path : C_Strings.chars_ptr; Flags : C.int; Mode : C.unsigned) return C.int;
   function File_Unlink (Path : C_Strings.chars_ptr) return C.int;
   function Truncate (Descriptor : C.int; Length : C.long_long) return C.int;
   function Close (Descriptor : C.int) return C.int;
   function Flush_File (Descriptor : C.int) return C.int;
   function Map_Shared (Descriptor : C.int; Length : C.size_t) return System.Address;
   function Failed_Mapping return System.Address;
   function Unmap (Base : System.Address; Length : C.size_t) return C.int;
   function Flush_Mapping (Base : System.Address; Length : C.size_t; Synchronous : Boolean) return C.int;

   function Descriptor_Stat (Descriptor : C.int; Fields : out Stat_Fields) return C.int;
   function Path_Stat (Path : C_Strings.chars_ptr; Fields : out Stat_Fields) return C.int;
   function Get_Descriptor_Flags (Descriptor : C.int) return C.int;
   function Set_Descriptor_Flags (Descriptor : C.int; Flags : C.int) return C.int;
   function Get_Status_Flags (Descriptor : C.int) return C.int;
   function Get_Seals (Descriptor : C.int) return C.int;
   function Add_Seals (Descriptor : C.int; Seals : C.int) return C.int;
   function Memfd_Create (Flags : C.unsigned) return C.int;
   function Fill_Random (Target : System.Address; Length : C.size_t) return C.int;

   function Socket_Type (Descriptor : C.int; Value : out C.int) return C.int;
   function Socket_Accepting (Descriptor : C.int; Value : out C.int) return C.int;
   function Local_Socket_Family (Descriptor : C.int; Family : out C.int) return C.int;
   function Peer_Socket_Family (Descriptor : C.int; Family : out C.int) return C.int;
   function Unix_Socket_Family return C.int;
   function Stream_Socket_Type return C.int;
   function Enable_No_SIGPIPE (Descriptor : C.int) return C.int;

   function Send_Descriptor_Once (Socket : C.int; Descriptor : C.int) return C.long;
   function Receive_Descriptors_Once
     (Socket                 : C.int;
      Flags                  : C.int;
      Descriptors            : in out Descriptor_Array;
      Count                  : out C.size_t;
      Payload                : out Interfaces.Unsigned_8;
      Message_Flags          : out C.int;
      Structurally_Malformed : out Boolean) return C.long;
end Flyology.Shared_Memory_Native;
