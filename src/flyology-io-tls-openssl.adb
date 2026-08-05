package body Flyology.IO.TLS.OpenSSL is
   package C renames Interfaces.C;
   package CS renames Interfaces.C.Strings;

   use type Ada.Streams.Stream_Element_Offset;
   use type C.int;
   use type C.long;
   use type System.Address;

   Error_Capacity : constant := 1_024;
   subtype Error_Buffer is
     C.char_array (0 .. C.size_t (Error_Capacity - 1));

   function C_Provider_Create
     (Side        : C.int;
      CA_File     : CS.chars_ptr;
      Certificate : CS.chars_ptr;
      Private_Key : CS.chars_ptr;
      Directory   : CS.chars_ptr;
      Error       : System.Address;
      Error_Size  : C.size_t) return System.Address;
   pragma Import
     (C, C_Provider_Create, "flyology_tls_openssl_provider_create");

   procedure C_Provider_Release (Handle : System.Address);
   pragma Import
     (C, C_Provider_Release, "flyology_tls_openssl_provider_release");

   function C_Provider_Retain
     (Handle : System.Address) return System.Address;
   pragma Import
     (C, C_Provider_Retain, "flyology_tls_openssl_provider_retain");

   procedure C_Provider_Version
     (Handle : System.Address;
      Buffer : System.Address;
      Size   : C.size_t);
   pragma Import
     (C, C_Provider_Version, "flyology_tls_openssl_provider_version");

   function C_Session_Create
     (Provider    : System.Address;
      FD          : C.int;
      Side        : C.int;
      Server_Name : CS.chars_ptr;
      Error       : System.Address;
      Error_Size  : C.size_t) return System.Address;
   pragma Import
     (C, C_Session_Create, "flyology_tls_openssl_session_create");

   procedure C_Session_Free (Handle : System.Address);
   pragma Import
     (C, C_Session_Free, "flyology_tls_openssl_session_free");

   function C_Handshake (Handle : System.Address) return C.int;
   pragma Import (C, C_Handshake, "flyology_tls_openssl_handshake");

   function C_Receive
     (Handle : System.Address;
      Buffer : System.Address;
      Count  : C.int) return C.long;
   pragma Import (C, C_Receive, "flyology_tls_openssl_receive");

   function C_Send
     (Handle : System.Address;
      Buffer : System.Address;
      Count  : C.int) return C.long;
   pragma Import (C, C_Send, "flyology_tls_openssl_send");

   function C_Shutdown (Handle : System.Address) return C.int;
   pragma Import (C, C_Shutdown, "flyology_tls_openssl_shutdown");

   procedure C_Session_Error
     (Handle : System.Address;
      Buffer : System.Address;
      Size   : C.size_t);
   pragma Import (C, C_Session_Error, "flyology_tls_openssl_session_error");

   function Image (Buffer : Error_Buffer) return String is
     (C.To_Ada (Buffer, Trim_Nul => True));

   function Contains_Nul (Value : String) return Boolean is
   begin
      for Element of Value loop
         if Element = Character'Val (0) then
            return True;
         end if;
      end loop;
      return False;
   end Contains_Nul;

   procedure Reject_Nul (Value : String; Label : String) is
   begin
      if Contains_Nul (Value) then
         raise Program_Error with Label & " contains an embedded NUL";
      end if;
   end Reject_Nul;

   function Status (Value : C.long) return Step_Status is
   begin
      case Value is
         when 0  => return Complete;
         when -2 => return Want_Read;
         when -3 => return Want_Write;
         when -4 => return Peer_Closed;
         when others => return Failed;
      end case;
   end Status;

   protected body Provider_State is
      procedure Install
        (Value : System.Address;
         Side  : Role)
      is
      begin
         if Handle /= System.Null_Address then
            raise Program_Error with "OpenSSL provider is already initialized";
         end if;
         Handle := Value;
         Provider_State.Side := Side;
      end Install;

      procedure Release is
         Value : constant System.Address := Handle;
      begin
         Handle := System.Null_Address;
         if Value /= System.Null_Address then
            C_Provider_Release (Value);
         end if;
      end Release;

      function Version return String is
         Buffer : aliased Error_Buffer := (others => C.nul);
      begin
         C_Provider_Version (Handle, Buffer'Address, Buffer'Length);
         return Image (Buffer);
      end Version;

      function Is_Available return Boolean is
        (Handle /= System.Null_Address);

      procedure Create_Session
        (FD          : C.int;
         Side        : Role;
         Server_Name : CS.chars_ptr;
         Error       : System.Address;
         Error_Size  : C.size_t;
         Value       : out System.Address)
      is
      begin
         if Handle = System.Null_Address then
            raise TLS_Error with "OpenSSL provider is not initialized";
         elsif Provider_State.Side /= Side then
            raise TLS_Error with
              "OpenSSL provider role does not match session";
         end if;
         Value := C_Session_Create
           (Handle, FD, (if Side = Client then 0 else 1), Server_Name,
            Error, Error_Size);
      end Create_Session;

      procedure Retain
        (Value : out System.Address;
         Side  : out Role) is
      begin
         Value := C_Provider_Retain (Handle);
         Side := Provider_State.Side;
         if Value = System.Null_Address then
            raise TLS_Error with "OpenSSL provider is not initialized";
         end if;
      end Retain;
   end Provider_State;

   procedure Initialize
     (Item              : in out OpenSSL_Provider;
      Side              : Role;
      CA_File           : String;
      Certificate_File  : String;
      Private_Key_File  : String;
      Library_Directory : String)
   is
      CA          : CS.chars_ptr := CS.Null_Ptr;
      Certificate : CS.chars_ptr := CS.Null_Ptr;
      Private_Key : CS.chars_ptr := CS.Null_Ptr;
      Directory   : CS.chars_ptr := CS.Null_Ptr;
      Error       : aliased Error_Buffer := (others => C.nul);
      Value       : System.Address := System.Null_Address;
   begin
      if Item.State.Is_Available then
         raise Program_Error with "OpenSSL provider is already initialized";
      end if;
      Reject_Nul (CA_File, "OpenSSL CA path");
      Reject_Nul (Certificate_File, "OpenSSL certificate path");
      Reject_Nul (Private_Key_File, "OpenSSL private-key path");
      Reject_Nul (Library_Directory, "OpenSSL library directory");

      CA := CS.New_String (CA_File);
      Certificate := CS.New_String (Certificate_File);
      Private_Key := CS.New_String (Private_Key_File);
      Directory := CS.New_String (Library_Directory);
      Value := C_Provider_Create
        ((if Side = Client then 0 else 1),
         CA, Certificate, Private_Key, Directory,
         Error'Address, Error'Length);
      CS.Free (CA);
      CS.Free (Certificate);
      CS.Free (Private_Key);
      CS.Free (Directory);
      if Value = System.Null_Address then
         raise TLS_Error with "OpenSSL: " & Image (Error);
      end if;
      begin
         Item.State.Install (Value, Side);
      exception
         when others =>
            C_Provider_Release (Value);
            raise;
      end;
   exception
      when others =>
         CS.Free (CA);
         CS.Free (Certificate);
         CS.Free (Private_Key);
         CS.Free (Directory);
         raise;
   end Initialize;

   procedure Initialize_Client
     (Item              : in out OpenSSL_Provider;
      CA_File           : String := "";
      Library_Directory : String := "")
   is
   begin
      Initialize (Item, Client, CA_File, "", "", Library_Directory);
   end Initialize_Client;

   procedure Initialize_Server
     (Item              : in out OpenSSL_Provider;
      Certificate_File  : String;
      Private_Key_File  : String;
      Library_Directory : String := "")
   is
   begin
      if Certificate_File'Length = 0 or else Private_Key_File'Length = 0 then
         raise Program_Error with
           "OpenSSL server requires certificate and key";
      end if;
      Initialize
        (Item, Server, "", Certificate_File, Private_Key_File,
         Library_Directory);
   end Initialize_Server;

   function Version (Item : OpenSSL_Provider) return String is
   begin
      return Item.State.Version;
   end Version;

   overriding function Name (Item : OpenSSL_Provider) return String is
      pragma Unreferenced (Item);
   begin
      return "OpenSSL 3";
   end Name;

   overriding function Is_Available
     (Item : OpenSSL_Provider) return Boolean is
     (Item.State.Is_Available);

   overriding function Retain
     (Item : in out OpenSSL_Provider) return Provider_Access
   is
      Result : Provider_Access := null;
      Handle : System.Address := System.Null_Address;
      Side   : Role;
   begin
      Item.State.Retain (Handle, Side);
      Result := new OpenSSL_Provider;
      OpenSSL_Provider (Result.all).State.Install (Handle, Side);
      Handle := System.Null_Address;
      return Result;
   exception
      when others =>
         if Handle /= System.Null_Address then
            C_Provider_Release (Handle);
         end if;
         Flyology.IO.TLS.Release (Result);
         raise;
   end Retain;

   overriding function Create_Session
     (Item        : in out OpenSSL_Provider;
      FD          : Descriptor;
      Side        : Role;
      Server_Name : String) return Session_Access
   is
      Name  : CS.chars_ptr := CS.Null_Ptr;
      Error : aliased Error_Buffer := (others => C.nul);
      Value : System.Address := System.Null_Address;
   begin
      Reject_Nul (Server_Name, "TLS server name");
      Name := CS.New_String (Server_Name);
      Item.State.Create_Session
        (C.int (FD), Side, Name, Error'Address, Error'Length, Value);
      CS.Free (Name);
      if Value = System.Null_Address then
         raise TLS_Error with "OpenSSL: " & Image (Error);
      end if;
      begin
         return new OpenSSL_Session'(Session with Handle => Value);
      exception
         when others =>
            C_Session_Free (Value);
            raise;
      end;
   exception
      when others =>
         CS.Free (Name);
         raise;
   end Create_Session;

   overriding function Handshake_Step
     (Item : in out OpenSSL_Session) return Step_Status is
   begin
      return Status (C.long (C_Handshake (Item.Handle)));
   end Handshake_Step;

   overriding function Receive_Step
      (Item : in out OpenSSL_Session;
      Data : out Ada.Streams.Stream_Element_Array;
      Last : in out Ada.Streams.Stream_Element_Offset) return Step_Status
   is
      Result : C.long;
      Count  : constant C.int :=
        (if Data'Length > C.int'Last
         then C.int'Last
         else C.int (Data'Length));
   begin
      Result := C_Receive (Item.Handle, Data'Address, Count);
      if Result > 0 then
         Last := Data'First + Ada.Streams.Stream_Element_Offset (Result) - 1;
         return Complete;
      end if;
      return Status (Result);
   end Receive_Step;

   overriding function Send_Step
     (Item : in out OpenSSL_Session;
      Data : Ada.Streams.Stream_Element_Array;
      Last : in out Ada.Streams.Stream_Element_Offset) return Step_Status
   is
      Result : C.long;
      Count  : constant C.int :=
        (if Data'Length > C.int'Last
         then C.int'Last
         else C.int (Data'Length));
   begin
      Result := C_Send (Item.Handle, Data'Address, Count);
      if Result > 0 then
         Last := Data'First + Ada.Streams.Stream_Element_Offset (Result) - 1;
         return Complete;
      end if;
      return Status (Result);
   end Send_Step;

   overriding function Shutdown_Step
     (Item : in out OpenSSL_Session) return Step_Status is
   begin
      return Status (C.long (C_Shutdown (Item.Handle)));
   end Shutdown_Step;

   overriding function Error_Message (Item : OpenSSL_Session) return String is
      Buffer : aliased Error_Buffer := (others => C.nul);
   begin
      C_Session_Error (Item.Handle, Buffer'Address, Buffer'Length);
      return "OpenSSL: " & Image (Buffer);
   end Error_Message;

   overriding procedure Finalize (Item : in out OpenSSL_Session) is
   begin
      if Item.Handle /= System.Null_Address then
         C_Session_Free (Item.Handle);
         Item.Handle := System.Null_Address;
      end if;
   end Finalize;

   overriding procedure Finalize (Item : in out OpenSSL_Provider) is
   begin
      Item.State.Release;
   end Finalize;

end Flyology.IO.TLS.OpenSSL;
