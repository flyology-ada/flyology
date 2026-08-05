with Ada.Real_Time;
with Ada.Strings;
with Ada.Strings.Fixed;
with Flyology.Socket_Policy;
with Flyology.Time_Math;
with Flyology.Wait_Policy;
with System;

package body Flyology.IO.Sockets is

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.C.long;
   use type Interfaces.C.unsigned_char;
   use type System.Address;

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

   function C_Create
     (Family : Interfaces.C.int;
      Mode   : Interfaces.C.int;
      Error  : access Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, C_Create, "flyology_socket_create");

   function C_Pair
     (Mode  : Interfaces.C.int;
      Left  : access Interfaces.C.int;
      Right : access Interfaces.C.int;
      Error : access Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, C_Pair, "flyology_socket_pair");

   function C_Prepare
     (Socket : Interfaces.C.int;
      Error  : access Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, C_Prepare, "flyology_socket_prepare");

   function C_Set_Nonblocking
     (Socket  : Interfaces.C.int;
      Enabled : Interfaces.C.int;
      Error   : access Interfaces.C.int) return Interfaces.C.int;
   pragma Import
     (C, C_Set_Nonblocking, "flyology_socket_set_nonblocking");

   function C_Close
     (Socket : Interfaces.C.int;
      Error  : access Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, C_Close, "flyology_socket_close");

   function C_Set_Reuse_Address
     (Socket  : Interfaces.C.int;
      Enabled : Interfaces.C.int;
      Error   : access Interfaces.C.int) return Interfaces.C.int;
   pragma Import
     (C, C_Set_Reuse_Address, "flyology_socket_set_reuse_address");

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
   pragma Import (C, C_Bind, "flyology_socket_bind");

   function C_Listen
     (Socket  : Interfaces.C.int;
      Backlog : Interfaces.C.int;
      Error   : access Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, C_Listen, "flyology_socket_listen");

   function C_Name
     (Socket  : Interfaces.C.int;
      Peer    : Interfaces.C.int;
      Family  : access Interfaces.C.unsigned_char;
      Address : System.Address;
      Port    : access Interfaces.C.unsigned;
      Scope   : access Interfaces.C.unsigned;
      Error   : access Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, C_Name, "flyology_socket_name");

   function C_Accept
     (Socket  : Interfaces.C.int;
      Family  : access Interfaces.C.unsigned_char;
      Address : System.Address;
      Port    : access Interfaces.C.unsigned;
      Scope   : access Interfaces.C.unsigned;
      Error   : access Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, C_Accept, "flyology_socket_accept");

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
   pragma Import (C, C_Connect, "flyology_socket_connect");

   function C_Pending_Error
     (Socket  : Interfaces.C.int;
      Pending : access Interfaces.C.int;
      Error   : access Interfaces.C.int) return Interfaces.C.int;
   pragma Import
     (C, C_Pending_Error, "flyology_socket_pending_error");

   function C_Receive
     (Socket : Interfaces.C.int;
      Buffer : System.Address;
      Length : Interfaces.C.size_t;
      Error  : access Interfaces.C.int) return Interfaces.C.long;
   pragma Import (C, C_Receive, "flyology_socket_receive");

   function C_Receive_From
     (Socket  : Interfaces.C.int;
      Buffer  : System.Address;
      Length  : Interfaces.C.size_t;
      Family  : access Interfaces.C.unsigned_char;
      Address : System.Address;
      Port    : access Interfaces.C.unsigned;
      Scope   : access Interfaces.C.unsigned;
      Error   : access Interfaces.C.int) return Interfaces.C.long;
   pragma Import
     (C, C_Receive_From, "flyology_socket_receive_from");

   function C_Send
     (Socket : Interfaces.C.int;
      Buffer : System.Address;
      Length : Interfaces.C.size_t;
      Error  : access Interfaces.C.int) return Interfaces.C.long;
   pragma Import (C, C_Send, "flyology_socket_send");

   function C_Send_To
     (Socket  : Interfaces.C.int;
      Buffer  : System.Address;
      Length  : Interfaces.C.size_t;
      Family  : Interfaces.C.int;
      Address : System.Address;
      Port    : Interfaces.C.unsigned;
      Scope   : Interfaces.C.unsigned;
      Error   : access Interfaces.C.int) return Interfaces.C.long;
   pragma Import (C, C_Send_To, "flyology_socket_send_to");

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

   function Family_Code (Family : Address_Family) return Interfaces.C.int is
     (Flyology.Socket_Policy.Family_Code (Family = IPv6));

   function Mode_Code (Mode : Socket_Mode) return Interfaces.C.int is
     (Flyology.Socket_Policy.Mode_Code (Mode = Socket_Datagram));

   protected body Accept_Return_Bridge is
      procedure Invoke
        (Listener : Interfaces.C.int;
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
           (Listener, Family, Address, Port, Scope, Error);
         if Result >= 0 then
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
            Test_Raw_Accept_Return_Barrier;
#end if;
            Target.Value := Result;
         end if;
      end Invoke;
   end Accept_Return_Bridge;

   function Address_Data (Value : IP_Address) return System.Address is
     (case Value.Family is
         when IPv4 => Value.V4 (Value.V4'First)'Address,
         when IPv6 => Value.V6 (Value.V6'First)'Address);

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
      Source.Value := -1;
   end Move;

   procedure Adopt (Source : in out Descriptor; Target : in out Socket_Type) is
   begin
      if Source < 0 then
         raise Program_Error with "cannot adopt an invalid descriptor";
      elsif Is_Open (Target) then
         raise Program_Error with "socket adopt target is open";
      end if;
      Target.Value := Interfaces.C.int (Source);
      Source := Invalid_Descriptor;
   end Adopt;

   procedure Release (Source : in out Socket_Type; Target : out Descriptor) is
   begin
      Target := Descriptor (Source.Value);
      Source.Value := -1;
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
         Raise_Error ("socket", Error);
      end if;
      Socket.Value := Result;
   end Create_Socket;

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
         Raise_Error ("socketpair", Error);
      end if;
      Left.Value := C_Left;
      Right.Value := C_Right;
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
      if Result /= 0 then
         Raise_Error ("close", Error);
      end if;
   end Close_Socket;

   procedure Prepare (Socket : Socket_Type) is
      Error : aliased Interfaces.C.int;
   begin
      if C_Prepare (Socket.Value, Error'Access) /= 0 then
         Raise_Error ("configure socket", Error);
      end if;
   end Prepare;

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

   procedure Connect_Socket (Socket : Socket_Type; Server : Endpoint) is
      Error : aliased Interfaces.C.int;
   begin
      if C_Connect
           (Socket.Value, Family_Code (Server.Family),
            Address_Data (Server.Address), Interfaces.C.unsigned (Server.Port),
            Interfaces.C.unsigned (Server.Scope), Error'Access) /= 0
      then
         Raise_Error ("connect", Error);
      end if;
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

   procedure Accept_Connection
     (Server     : Socket_Type;
      Socket     : in out Socket_Type;
      Address    : out Endpoint;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
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
               Family'Access,
               Bytes (Bytes'First)'Address,
               Port'Access,
               Scope'Access,
               Error'Access,
               Socket,
               Result);
            if Result < 0 then
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
               else
                  Address :=
                    (Family => IPv6,
                     Address => (Family => IPv6, V6 => Bytes),
                     Port => Flyology.IO.Sockets.Port (Port),
                     Scope => Scope_ID (Scope));
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

      Wait_For (Socket, For_Write, Started, Timeout, Interrupts);
      declare
         Pending : aliased Interfaces.C.int;
      begin
         if C_Pending_Error
              (Socket.Value, Pending'Access, Error'Access) /= 0
         then
            Raise_Error ("getsockopt(SO_ERROR)", Error);
         elsif Pending /= 0 then
            Raise_Error ("connect", Pending);
         end if;
      end;
   end Connect;

end Flyology.IO.Sockets;
