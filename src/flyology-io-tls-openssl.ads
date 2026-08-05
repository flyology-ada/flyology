with Interfaces.C;
with Interfaces.C.Strings;
with System;

--  Adapts OpenSSL 3.x to Flyology's provider-neutral nonblocking TLS engine.
--
--  The adapter loads OpenSSL at run time; Flyology has no link-time crypto
--  dependency. Initialize_Client uses system trust by default and requires
--  hostname verification for every session. Initialize_Server requires a
--  certificate chain and private key. Code modules and contexts are retained
--  while a provider or one of its sessions still refers to them.
--
--  Example:
--
--     Initialize_Client (Backend);
--     Take (Backend, Socket, Client, "example.com", Secure);
package Flyology.IO.TLS.OpenSSL is

   --  OpenSSL configuration and session factory. Initialize once before use.
   --  Session creation and read-only queries are task-safe. Initialization can
   --  load code, trust stores, certificates, and keys synchronously; run it
   --  before starting event loops or from a native task. Do not start a new
   --  call on a provider after its finalization begins. Sessions already
   --  created remain usable after provider finalization.
   type OpenSSL_Provider is
     new Ada.Finalization.Limited_Controlled and Provider with private;

   --  Configure a client provider. An empty CA_File selects OpenSSL's default
   --  trust paths. Peer-chain and DNS hostname verification are always on;
   --  this API intentionally has no insecure mode. Library_Directory may name
   --  one OpenSSL 3 installation containing both libssl and libcrypto; empty
   --  selects supported platform locations. OpenSSL 1.x and 4.x are rejected.
   --  @param Item Provider to initialize
   --  @param CA_File Optional PEM trust bundle or CA certificate
   --  @param Library_Directory Optional directory containing a matched pair
   --  @exception TLS_Error Loading or secure configuration fails
   --  @exception Program_Error Item is already initialized or a path contains
   --     an embedded NUL
   procedure Initialize_Client
     (Item              : in out OpenSSL_Provider;
      CA_File           : String := "";
      Library_Directory : String := "");

   --  Configure a server provider using PEM files. Library selection matches
   --  Initialize_Client. The key is read by OpenSSL and is never copied into
   --  Flyology-managed storage. The server requests no client certificate;
   --  applications needing mutual TLS require another provider or extension.
   --  @param Item Provider to initialize
   --  @param Certificate_File PEM leaf certificate and optional chain
   --  @param Private_Key_File PEM private key matching Certificate_File
   --  @param Library_Directory Optional directory containing a matched pair
   --  @exception TLS_Error Loading or credential validation fails
   --  @exception Program_Error Item is initialized, a required path is empty,
   --     or a path contains an embedded NUL
   procedure Initialize_Server
     (Item              : in out OpenSSL_Provider;
      Certificate_File  : String;
      Private_Key_File  : String;
      Library_Directory : String := "");

   --  Return the loaded OpenSSL version text, or an empty String before
   --  initialization.
   --  @param Item Provider to inspect
   --  @return Provider-reported version
   function Version (Item : OpenSSL_Provider) return String;

   --  Return the stable adapter name used in diagnostics.
   --  @param Item Provider to identify
   --  @return `OpenSSL 3`
   overriding function Name (Item : OpenSSL_Provider) return String;
   --  Report whether Item has an initialized OpenSSL context.
   --  @param Item Provider to inspect
   --  @return True after successful initialization and before finalization
   overriding function Is_Available
     (Item : OpenSSL_Provider) return Boolean;
   --  Retain the refcounted OpenSSL module and configured context.
   --  @param Item Initialized provider to retain
   --  @return Independently owned provider reference
   --  @exception TLS_Error Item is unavailable
   overriding function Retain
     (Item : in out OpenSSL_Provider) return Provider_Access;
   --  Allocate a nonblocking OpenSSL session borrowing FD. Side must match the
   --  provider configuration; clients apply Server_Name to SNI and hostname
   --  verification.
   --  @param Item Initialized provider
   --  @param FD Borrowed connected descriptor
   --  @param Side Role matching the provider configuration
   --  @param Server_Name Verified client DNS name, or empty for a server
   --  @return Provider session retained across readiness retries
   --  @exception TLS_Error OpenSSL session setup fails
   --  @exception Program_Error Server_Name contains an embedded NUL
   overriding function Create_Session
     (Item        : in out OpenSSL_Provider;
      FD          : Descriptor;
      Side        : Role;
      Server_Name : String) return Session_Access;

private
   --  Serializes access to the refcounted C provider across creation, queries,
   --  and controlled finalization.
   protected type Provider_State is
      --  Publish a newly configured provider handle.
      procedure Install
        (Value : System.Address;
         Side  : Role);
      --  Remove and release the published provider handle.
      procedure Release;
      --  Copy the loaded provider version while retaining its handle.
      function Version return String;
      --  Report whether a provider handle is published.
      function Is_Available return Boolean;
      --  Create a C session while finalization is excluded by this monitor.
      procedure Create_Session
        (FD          : Interfaces.C.int;
         Side        : Role;
         Server_Name : Interfaces.C.Strings.chars_ptr;
         Error       : System.Address;
         Error_Size  : Interfaces.C.size_t;
         Value       : out System.Address);
      --  Retain the C provider handle while finalization is excluded.
      procedure Retain
        (Value : out System.Address;
         Side  : out Role);
   private
      Handle : System.Address := System.Null_Address;
      Side   : Role := Client;
   end Provider_State;

   --  Controlled public provider state guarded by Provider_State.
   type OpenSSL_Provider is
     new Ada.Finalization.Limited_Controlled and Provider with record
      State : Provider_State;
   end record;

   --  Release one provider reference during controlled cleanup.
   --  @param Item Provider being finalized
   overriding procedure Finalize (Item : in out OpenSSL_Provider);

   --  Owning handle for one C adapter session.
   type OpenSSL_Session is new Session with record
      Handle : System.Address := System.Null_Address;
   end record;

   --  Advance one OpenSSL handshake operation.
   --  @param Item Session to advance
   --  @return Nonblocking provider status
   overriding function Handshake_Step
     (Item : in out OpenSSL_Session) return Step_Status;
   --  Decrypt one available record fragment.
   --  @param Item Session to read
   --  @param Data Destination buffer
   --  @param Last Last element produced when Complete
   --  @return Nonblocking provider status
   overriding function Receive_Step
      (Item : in out OpenSSL_Session;
      Data : out Ada.Streams.Stream_Element_Array;
      Last : in out Ada.Streams.Stream_Element_Offset) return Step_Status;
   --  Encrypt one available application-data fragment.
   --  @param Item Session to write
   --  @param Data Source buffer
   --  @param Last Last element consumed when Complete
   --  @return Nonblocking provider status
   overriding function Send_Step
     (Item : in out OpenSSL_Session;
      Data : Ada.Streams.Stream_Element_Array;
      Last : in out Ada.Streams.Stream_Element_Offset) return Step_Status;
   --  Advance the OpenSSL close_notify exchange.
   --  @param Item Session to shut down
   --  @return Nonblocking provider status
   overriding function Shutdown_Step
     (Item : in out OpenSSL_Session) return Step_Status;
   --  Copy the last provider failure into Ada storage.
   --  @param Item Failed session
   --  @return Stable diagnostic copy
   overriding function Error_Message (Item : OpenSSL_Session) return String;
   --  Release OpenSSL session state without closing its borrowed descriptor.
   --  @param Item Session being finalized
   overriding procedure Finalize (Item : in out OpenSSL_Session);

end Flyology.IO.TLS.OpenSSL;
