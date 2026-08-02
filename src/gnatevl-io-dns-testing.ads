with Ada.Streams;

package Gnatevl.IO.DNS.Testing is

   --  These process-global hooks exist only for deterministic protocol tests.
   --  Applications must leave the resolver in its default OS-entropy mode.
   procedure Use_Deterministic_Transaction_IDs (First : Natural);
   procedure Use_OS_Transaction_IDs;

   --  Exercise the production parser without network I/O. Success means the
   --  packet parsed to any valid DNS outcome; malformed input raises the
   --  parent's Malformed_Response exception.
   procedure Validate_Response
     (Packet        : Ada.Streams.Stream_Element_Array;
      Expected_ID   : Natural;
      Expected_Name : String;
      For_IPv6      : Boolean := False);

end Gnatevl.IO.DNS.Testing;
