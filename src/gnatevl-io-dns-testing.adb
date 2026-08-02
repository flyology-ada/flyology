package body Gnatevl.IO.DNS.Testing is

   procedure Use_Deterministic_Transaction_IDs (First : Natural) is
   begin
      Gnatevl.IO.DNS.Use_Deterministic_Transaction_IDs (First);
   end Use_Deterministic_Transaction_IDs;

   procedure Use_OS_Transaction_IDs is
   begin
      Gnatevl.IO.DNS.Use_OS_Transaction_IDs;
   end Use_OS_Transaction_IDs;

   procedure Validate_Response
     (Packet        : Ada.Streams.Stream_Element_Array;
      Expected_ID   : Natural;
      Expected_Name : String;
      For_IPv6      : Boolean := False) is
   begin
      Gnatevl.IO.DNS.Validate_Response_For_Testing
        (Packet, Expected_ID, Expected_Name, For_IPv6);
   end Validate_Response;

end Gnatevl.IO.DNS.Testing;
