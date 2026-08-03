#if FLYOLOGY_DNS_TEST_HOOKS then
with Flyology.DNS_Test_Observations;
#end if;

package body Flyology.IO.DNS.Testing is

   procedure Use_Deterministic_Transaction_IDs (First : Natural) is
   begin
      Flyology.IO.DNS.Use_Deterministic_Transaction_IDs (First);
   end Use_Deterministic_Transaction_IDs;

   procedure Use_OS_Transaction_IDs is
   begin
      Flyology.IO.DNS.Use_OS_Transaction_IDs;
   end Use_OS_Transaction_IDs;

   procedure Reset_Receive_Waits is
   begin
#if FLYOLOGY_DNS_TEST_HOOKS then
      Flyology.DNS_Test_Observations.Reset;
#else
      null;
#end if;
   end Reset_Receive_Waits;

   function Post_Close_Receive_Waits return Natural is
   begin
#if FLYOLOGY_DNS_TEST_HOOKS then
      return Flyology.DNS_Test_Observations.Post_Close_Receive_Waits;
#else
      return 0;
#end if;
   end Post_Close_Receive_Waits;

   procedure Validate_Response
     (Packet        : Ada.Streams.Stream_Element_Array;
      Expected_ID   : Natural;
      Expected_Name : String;
      For_IPv6      : Boolean := False) is
   begin
      Flyology.IO.DNS.Validate_Response_For_Testing
        (Packet, Expected_ID, Expected_Name, For_IPv6);
   end Validate_Response;

end Flyology.IO.DNS.Testing;
