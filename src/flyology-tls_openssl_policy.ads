with Interfaces;
with Interfaces.C;

--  Pure OpenSSL-adapter decisions. Dynamic loading, foreign dispatch, error
--  queues, callback pointers, and resource destruction stay in the ABI bridge.
private package Flyology.TLS_OpenSSL_Policy
  with Preelaborate,
       SPARK_Mode
is
   package C renames Interfaces.C;

   subtype Wire_Byte is Interfaces.Unsigned_8;
   subtype Wire_Length is Interfaces.Unsigned_32;

   use type C.long;
   use type Wire_Byte;
   use type Wire_Length;

   type Item_View is record
      Valid        : Boolean := False;
      Value_Offset : Wire_Length := 0;
      Value_Length : Wire_Length := 0;
      Next_Offset  : Wire_Length := 0;
   end record;

   --  Validate one ALPN length-prefixed item without overflowing the cursor.
   function Inspect_Item
     (Total_Length   : Wire_Length;
      Cursor         : Wire_Length;
      Encoded_Length : Wire_Byte) return Item_View
   with
     Pre  => Cursor < Total_Length,
     Post =>
       Inspect_Item'Result.Valid =
         (Encoded_Length /= 0
          and then Wire_Length (Encoded_Length) <= Total_Length - Cursor - 1)
       and then
         (if Inspect_Item'Result.Valid then
             Inspect_Item'Result.Value_Offset = Cursor + 1
             and then Inspect_Item'Result.Value_Length =
               Wire_Length (Encoded_Length)
             and then Inspect_Item'Result.Next_Offset =
               Cursor + 1 + Wire_Length (Encoded_Length)
             and then Inspect_Item'Result.Next_Offset <= Total_Length
             and then Inspect_Item'Result.Next_Offset > Cursor);

   type Wire_Bytes is array (Natural range <>) of Wire_Byte;

   function Valid_ALPN_List (Data : Wire_Bytes) return Boolean;

   type ALPN_Selection is record
      Found        : Boolean := False;
      Value_Offset : Natural := 0;
      Value_Length : Natural := 0;
   end record;

   --  Select the first server-preferred identifier also present in Offered.
   --  Value_Offset is relative to Offered's first element.
   function Select_ALPN
     (Server  : Wire_Bytes;
      Offered : Wire_Bytes) return ALPN_Selection
   with Post =>
     (if Select_ALPN'Result.Found then
         Select_ALPN'Result.Value_Length in 1 .. 255
         and then Long_Long_Integer (Select_ALPN'Result.Value_Offset) <
           Long_Long_Integer (Offered'Length)
         and then Long_Long_Integer (Select_ALPN'Result.Value_Length) <=
           Long_Long_Integer (Offered'Length)
             - Long_Long_Integer (Select_ALPN'Result.Value_Offset));

   type Provider_Result is
     (Provider_Complete,
      Provider_Want_Read,
      Provider_Want_Write,
      Provider_Peer_Closed,
      Provider_Failed);

   function Classify_Provider_Result
     (Value : C.long) return Provider_Result
   with Post =>
     (if Value = 0 then
         Classify_Provider_Result'Result = Provider_Complete
      elsif Value = -2 then
         Classify_Provider_Result'Result = Provider_Want_Read
      elsif Value = -3 then
         Classify_Provider_Result'Result = Provider_Want_Write
      elsif Value = -4 then
         Classify_Provider_Result'Result = Provider_Peer_Closed
      else Classify_Provider_Result'Result = Provider_Failed);

   --  C ABI policy entry points used after foreign OpenSSL calls.
   function Classify_SSL_Error
     (Error         : C.int;
      Peer_Close_OK : C.int) return C.int
   with
     Export,
     Convention    => C,
     External_Name => "flyology_tls_openssl_policy_classify_error";

   function Error_Is_Transport_End (Error : C.int) return C.int
   with
     Export,
     Convention    => C,
     External_Name => "flyology_tls_openssl_policy_transport_end";

   function Versions_Match
     (Symbols_Match : C.int;
      Dependency    : C.unsigned_long;
      Explicit      : C.unsigned_long;
      Major_Source  : C.unsigned_long) return C.int
   with
     Export,
     Convention    => C,
     External_Name => "flyology_tls_openssl_policy_versions_match";

   function Classify_Shutdown (Result : C.int) return C.int
   with
     Export,
     Convention    => C,
     External_Name => "flyology_tls_openssl_policy_classify_shutdown";
end Flyology.TLS_OpenSSL_Policy;
