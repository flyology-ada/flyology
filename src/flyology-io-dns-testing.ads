with Ada.Streams;

--  Exposes deterministic hooks for DNS protocol tests, not application use.
--
--  Example:
--
--     Flyology.IO.DNS.Testing.Use_Deterministic_Transaction_IDs (16#1234#);
package Flyology.IO.DNS.Testing is

   --  Select a process-global deterministic transaction-ID sequence.
   --  Concurrent resolver calls must be stopped while changing this test mode.
   --  @param First First identifier in the deterministic sequence
   procedure Use_Deterministic_Transaction_IDs (First : Natural);
   --  Restore the process-global production OS-entropy mode.
   procedure Use_OS_Transaction_IDs;

   --  Reset the receive-wait observations collected by a test-hooks build.
   --  A normal production build compiles this operation to a no-op.
   procedure Reset_Receive_Waits;

   --  Return receive waits attempted after the UDP socket was closed. The
   --  value is zero in a normal production build.
   --  @return Number of invalid post-close receive waits
   function Post_Close_Receive_Waits return Natural;

   --  Exercise the production response parser without network I/O.
   --  @param Packet Wire-format DNS response
   --  @param Expected_ID Expected transaction identifier
   --  @param Expected_Name Expected canonical question name
   --  @param For_IPv6 Parse an AAAA response when True, otherwise A
   --  @exception Malformed_Response Flyology.IO.DNS.Malformed_Response is
   --     raised when packet validation fails
   procedure Validate_Response
     (Packet        : Ada.Streams.Stream_Element_Array;
      Expected_ID   : Natural;
      Expected_Name : String;
      For_IPv6      : Boolean := False);

end Flyology.IO.DNS.Testing;
