with Flyology.TLS_OpenSSL_Raw;
with Interfaces;
with Interfaces.C;
with System;

procedure Flyology.TLS_OpenSSL_Policy.Smoke is
   package C renames Interfaces.C;
   package Raw renames Flyology.TLS_OpenSSL_Raw;

   use type C.int;
   use type Interfaces.Unsigned_64;

   H     : constant Wire_Byte := Character'Pos ('h');
   T     : constant Wire_Byte := Character'Pos ('t');
   P     : constant Wire_Byte := Character'Pos ('p');
   Slash : constant Wire_Byte := Character'Pos ('/');
   One   : constant Wire_Byte := Character'Pos ('1');
   Dot   : constant Wire_Byte := Character'Pos ('.');

   Server                  : aliased Wire_Bytes :=
     [2, H, Character'Pos ('2'), 8, H, T, T, P, Slash, One, Dot, One];
   Offered                 : aliased Wire_Bytes :=
     [8, H, T, T, P, Slash, One, Dot, One, 2, H, Character'Pos ('2')];
   No_Overlap              : aliased Wire_Bytes := [8, H, T, T, P, Slash, One, Dot, Character'Pos ('0')];
   Empty                   : aliased Wire_Bytes (1 .. 0);
   Zero_Length             : aliased Wire_Bytes := [0];
   Truncated               : aliased Wire_Bytes := [2, H];
   Matching_Then_Malformed : aliased Wire_Bytes := [2, H, Character'Pos ('2'), 0];

   Selection     : ALPN_Selection;
   Raw_Selection : Interfaces.Unsigned_64;
begin
   pragma Assert (Classify_Provider_Result (0) = Provider_Complete);
   pragma Assert (Classify_Provider_Result (-2) = Provider_Want_Read);
   pragma Assert (Classify_Provider_Result (-3) = Provider_Want_Write);
   pragma Assert (Classify_Provider_Result (-4) = Provider_Peer_Closed);
   pragma Assert (Classify_Provider_Result (-1) = Provider_Failed);
   pragma Assert (Classify_Provider_Result (1) = Provider_Failed);

   pragma Assert (Classify_SSL_Error (2, 0) = -2);
   pragma Assert (Classify_SSL_Error (3, 0) = -3);
   pragma Assert (Classify_SSL_Error (6, 1) = -4);
   pragma Assert (Classify_SSL_Error (6, 0) = -1);
   pragma Assert (Classify_SSL_Error (1, 1) = -1);
   pragma Assert (Error_Is_Transport_End (5) = 1);
   pragma Assert (Error_Is_Transport_End (1) = 0);

   pragma Assert (Versions_Match (1, 16#3000_0000#, 16#3000_0000#, 16#3000_0000#) = 1);
   pragma Assert (Versions_Match (0, 16#3000_0000#, 16#3000_0000#, 16#3000_0000#) = 0);
   pragma Assert (Versions_Match (1, 16#3000_0001#, 16#3000_0002#, 16#3000_0002#) = 0);
   pragma Assert (Versions_Match (1, 16#2000_0000#, 16#2000_0000#, 16#2000_0000#) = 0);
   pragma Assert (Versions_Match (1, 16#4000_0000#, 16#4000_0000#, 16#4000_0000#) = 0);

   pragma Assert (Classify_Shutdown (1) = 0);
   pragma Assert (Classify_Shutdown (0) = -2);
   pragma Assert (Classify_Shutdown (-1) = -1);
   pragma Assert (Classify_Shutdown (2) = -1);

   pragma Assert (Inspect_Item (3, 0, 2).Valid);
   pragma Assert (Inspect_Item (3, 0, 2).Value_Offset = 1);
   pragma Assert (Inspect_Item (3, 0, 2).Next_Offset = 3);
   pragma Assert (not Inspect_Item (1, 0, 0).Valid);
   pragma Assert (not Inspect_Item (2, 0, 2).Valid);

   pragma Assert (Valid_ALPN_List (Empty));
   pragma Assert (Valid_ALPN_List (Server));
   pragma Assert (Valid_ALPN_List (Offered));
   pragma Assert (not Valid_ALPN_List (Zero_Length));
   pragma Assert (not Valid_ALPN_List (Truncated));

   Selection := Select_ALPN (Server, Offered);
   pragma Assert (Selection.Found);
   pragma Assert (Selection.Value_Offset = 10);
   pragma Assert (Selection.Value_Length = 2);
   pragma Assert (not Select_ALPN (Server, No_Overlap).Found);
   pragma Assert (not Select_ALPN (Zero_Length, Offered).Found);
   pragma Assert (not Select_ALPN (Server, Truncated).Found);
   pragma Assert (not Select_ALPN (Server, Matching_Then_Malformed).Found);

   pragma Assert (Raw.Valid_ALPN_List (Empty'Address, 0) = 1);
   pragma Assert (Raw.Valid_ALPN_List (System.Null_Address, 0) = 1);
   pragma Assert (Raw.Valid_ALPN_List (System.Null_Address, 1) = 0);
   pragma Assert (Raw.Valid_ALPN_List (Server'Address, C.unsigned (Server'Length)) = 1);
   pragma Assert (Raw.Valid_ALPN_List (Zero_Length'Address, C.unsigned (Zero_Length'Length)) = 0);
   pragma Assert (Raw.Valid_ALPN_List (Truncated'Address, C.unsigned (Truncated'Length)) = 0);

   Raw_Selection :=
     Raw.Select_ALPN
       (Server'Address, C.unsigned (Server'Length), Offered'Address, C.unsigned (Offered'Length));
   pragma Assert (Raw_Selection = (Interfaces.Shift_Left (Interfaces.Unsigned_64'(10), 8) or 2));
   pragma
     Assert
       (Raw.Select_ALPN
          (Server'Address, C.unsigned (Server'Length), No_Overlap'Address, C.unsigned (No_Overlap'Length))
          = 0);
   pragma
     Assert
       (Raw.Select_ALPN
          (Server'Address,
           C.unsigned (Server'Length),
           Matching_Then_Malformed'Address,
           C.unsigned (Matching_Then_Malformed'Length))
          = 0);
end Flyology.TLS_OpenSSL_Policy.Smoke;
