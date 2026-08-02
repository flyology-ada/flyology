with Ada.Streams;
with GNAT.Sockets;

package Flyology.IO.DNS is

   type Family_Preference is (Any_Family, IPv4_Only, IPv6_Only);

   type Address_Array is
     array (Positive range <>) of GNAT.Sockets.Inet_Addr_Type;

   type Name_Server_Array is
     array (Positive range <>) of GNAT.Sockets.Sock_Addr_Type;

   Name_Not_Found     : exception;
   Resolution_Failed  : exception;
   Malformed_Response : exception;
   Operation_Cancelled : exception;

   --  Resolve through the numeric name servers in the host's resolv.conf.
   --  Search/ndots, retry, rotation, positive/negative caching, numeric names,
   --  and localhost are handled without calling blocking libc name services.
   function Resolve
     (Name        : String;
      Family      : Family_Preference := Any_Family;
      Timeout     : Duration := 5.0;
      Interrupt_1 : Descriptor := Invalid_Descriptor;
      Interrupt_2 : Descriptor := Invalid_Descriptor;
      Interrupt_3 : Descriptor := Invalid_Descriptor;
      Configuration_Path : String := "/etc/resolv.conf")
      return Address_Array;

   --  Resolve through an explicit set of numeric DNS endpoints.  This form
   --  bypasses search-domain expansion but otherwise has identical transport,
   --  validation, caching, timeout, and cancellation behavior.  It is useful
   --  for split-DNS applications and deterministic local testing.
   function Resolve_Using
     (Name         : String;
      Name_Servers : Name_Server_Array;
      Family       : Family_Preference := Any_Family;
      Timeout      : Duration := 5.0;
      Attempts     : Positive := 2;
      Retry_Interval : Duration := 1.0;
      Interrupt_1  : Descriptor := Invalid_Descriptor;
      Interrupt_2  : Descriptor := Invalid_Descriptor;
      Interrupt_3  : Descriptor := Invalid_Descriptor) return Address_Array;

   --  Remove all positive and negative entries. The cache is process-local,
   --  bounded, and owns no descriptors or background tasks.
   procedure Clear_Cache;

private
   --  Test-only child operations use these hooks to make transaction-ID
   --  assertions deterministic. Production calls always use OS entropy.
   procedure Use_Deterministic_Transaction_IDs (First : Natural);
   procedure Use_OS_Transaction_IDs;
   procedure Validate_Response_For_Testing
     (Packet       : Ada.Streams.Stream_Element_Array;
      Expected_ID  : Natural;
      Expected_Name : String;
      For_IPv6     : Boolean := False);

end Flyology.IO.DNS;
