package body Flyology.TLS_OpenSSL_Policy
  with SPARK_Mode
is
   use type C.int;
   use type C.unsigned_long;

   SSL_Error_Want_Read   : constant C.int := 2;
   SSL_Error_Want_Write  : constant C.int := 3;
   SSL_Error_Syscall     : constant C.int := 5;
   SSL_Error_Zero_Return : constant C.int := 6;

   Fly_Complete    : constant C.int := 0;
   Fly_Failed      : constant C.int := -1;
   Fly_Want_Read   : constant C.int := -2;
   Fly_Want_Write  : constant C.int := -3;
   Fly_Peer_Closed : constant C.int := -4;

   OpenSSL_Major_Shift : constant := 16#1000_0000#;

   function Inspect_Item
     (Total_Length : Wire_Length; Cursor : Wire_Length; Encoded_Length : Wire_Byte) return Item_View
   is
      Value_Offset : constant Wire_Length := Cursor + 1;
      Value_Length : constant Wire_Length := Wire_Length (Encoded_Length);
   begin
      if Encoded_Length = 0 or else Value_Length > Total_Length - Value_Offset then
         return (others => <>);
      end if;
      return
        (Valid        => True,
         Value_Offset => Value_Offset,
         Value_Length => Value_Length,
         Next_Offset  => Value_Offset + Value_Length);
   end Inspect_Item;

   function Valid_ALPN_List (Data : Wire_Bytes) return Boolean is
      Data_Length : constant Long_Long_Integer := Data'Length;
      Cursor      : Long_Long_Integer := 0;
   begin
      while Cursor < Data_Length loop
         pragma Loop_Invariant (Cursor in 0 .. Data_Length);
         pragma Loop_Variant (Increases => Cursor);
         declare
            Item_Length  : constant Long_Long_Integer :=
              Long_Long_Integer (Data (Data'First + Natural (Cursor)));
            Value_Offset : constant Long_Long_Integer := Cursor + 1;
         begin
            if Item_Length = 0 or else Item_Length > Data_Length - Value_Offset then
               return False;
            end if;
            Cursor := Value_Offset + Item_Length;
         end;
      end loop;
      return Cursor = Data_Length;
   end Valid_ALPN_List;

   function Select_ALPN (Server : Wire_Bytes; Offered : Wire_Bytes) return ALPN_Selection is
      Server_Total  : constant Long_Long_Integer := Server'Length;
      Offered_Total : constant Long_Long_Integer := Offered'Length;
      Server_Cursor : Long_Long_Integer := 0;
   begin
      if not Valid_ALPN_List (Server) or else not Valid_ALPN_List (Offered) then
         return (others => <>);
      end if;

      while Server_Cursor < Server_Total loop
         pragma Loop_Invariant (Server_Cursor in 0 .. Server_Total);
         pragma Loop_Variant (Increases => Server_Cursor);
         declare
            Server_Length       : constant Long_Long_Integer :=
              Long_Long_Integer (Server (Server'First + Natural (Server_Cursor)));
            Server_Value_Offset : constant Long_Long_Integer := Server_Cursor + 1;
            Client_Cursor       : Long_Long_Integer := 0;
         begin
            if Server_Length = 0 or else Server_Length > Server_Total - Server_Value_Offset then
               return (others => <>);
            end if;

            while Client_Cursor < Offered_Total loop
               pragma Loop_Invariant (Client_Cursor in 0 .. Offered_Total);
               pragma Loop_Variant (Increases => Client_Cursor);
               declare
                  Client_Length       : constant Long_Long_Integer :=
                    Long_Long_Integer (Offered (Offered'First + Natural (Client_Cursor)));
                  Client_Value_Offset : constant Long_Long_Integer := Client_Cursor + 1;
               begin
                  if Client_Length = 0 or else Client_Length > Offered_Total - Client_Value_Offset then
                     return (others => <>);
                  end if;

                  if Client_Length = Server_Length then
                     declare
                        Same : Boolean := True;
                     begin
                        for Offset in 0 .. Server_Length - 1 loop
                           if Server (Server'First + Natural (Server_Value_Offset + Offset))
                             /= Offered (Offered'First + Natural (Client_Value_Offset + Offset))
                           then
                              Same := False;
                           end if;
                        end loop;
                        if Same then
                           return
                             (Found        => True,
                              Value_Offset => Natural (Client_Value_Offset),
                              Value_Length => Natural (Client_Length));
                        end if;
                     end;
                  end if;
                  Client_Cursor := Client_Value_Offset + Client_Length;
               end;
            end loop;
            Server_Cursor := Server_Value_Offset + Server_Length;
         end;
      end loop;
      return (others => <>);
   end Select_ALPN;

   function Classify_Provider_Result (Value : C.long) return Provider_Result
   is (case Value is
         when 0      => Provider_Complete,
         when -2     => Provider_Want_Read,
         when -3     => Provider_Want_Write,
         when -4     => Provider_Peer_Closed,
         when others => Provider_Failed);

   function Classify_SSL_Error (Error : C.int; Peer_Close_OK : C.int) return C.int
   is (if Error = SSL_Error_Want_Read
       then Fly_Want_Read
       elsif Error = SSL_Error_Want_Write
       then Fly_Want_Write
       elsif Error = SSL_Error_Zero_Return and then Peer_Close_OK /= 0
       then Fly_Peer_Closed
       else Fly_Failed);

   function Error_Is_Transport_End (Error : C.int) return C.int
   is (if Error = SSL_Error_Syscall then 1 else 0);

   function Versions_Match
     (Symbols_Match : C.int;
      Dependency    : C.unsigned_long;
      Explicit      : C.unsigned_long;
      Major_Source  : C.unsigned_long) return C.int
   is (if Symbols_Match /= 0 and then Dependency = Explicit and then Major_Source / OpenSSL_Major_Shift = 3
       then 1
       else 0);

   function Classify_Shutdown (Result : C.int) return C.int
   is (if Result = 1 then Fly_Complete elsif Result = 0 then Fly_Want_Read else Fly_Failed);
end Flyology.TLS_OpenSSL_Policy;
