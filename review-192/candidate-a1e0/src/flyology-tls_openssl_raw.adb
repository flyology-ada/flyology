with Flyology.TLS_OpenSSL_Policy;
with System.Address_To_Access_Conversions;
with System.Storage_Elements;

package body Flyology.TLS_OpenSSL_Raw is
   package C renames Interfaces.C;
   package Policy renames Flyology.TLS_OpenSSL_Policy;
   package Byte_Addresses is new System.Address_To_Access_Conversions (C.unsigned_char);

   use type C.int;
   use type C.unsigned;
   use type Interfaces.Unsigned_64;
   use type Policy.Wire_Byte;
   use type Policy.Wire_Length;
   use type System.Address;
   use System.Storage_Elements;

   function Byte_At (Base : System.Address; Offset : Policy.Wire_Length) return Policy.Wire_Byte
   is (Policy.Wire_Byte (Byte_Addresses.To_Pointer (Base + Storage_Offset (Offset)).all));

   function Valid_ALPN_List (Protocols : System.Address; Length : C.unsigned) return C.int is
      Total  : constant Policy.Wire_Length := Policy.Wire_Length (Length);
      Cursor : Policy.Wire_Length := 0;
   begin
      if Length /= 0 and then Protocols = System.Null_Address then
         return 0;
      end if;
      while Cursor < Total loop
         declare
            Item : constant Policy.Item_View :=
              Policy.Inspect_Item (Total, Cursor, Byte_At (Protocols, Cursor));
         begin
            if not Item.Valid then
               return 0;
            end if;
            Cursor := Item.Next_Offset;
         end;
      end loop;
      return (if Cursor = Total then 1 else 0);
   end Valid_ALPN_List;

   function Items_Equal
     (Left         : System.Address;
      Left_Offset  : Policy.Wire_Length;
      Right        : System.Address;
      Right_Offset : Policy.Wire_Length;
      Length       : Policy.Wire_Length) return Boolean is
   begin
      for Offset in Policy.Wire_Length range 0 .. Length - 1 loop
         if Byte_At (Left, Left_Offset + Offset) /= Byte_At (Right, Right_Offset + Offset) then
            return False;
         end if;
      end loop;
      return True;
   end Items_Equal;

   function Select_ALPN
     (Server         : System.Address;
      Server_Length  : C.unsigned;
      Offered        : System.Address;
      Offered_Length : C.unsigned) return Interfaces.Unsigned_64
   is
      Server_Total  : constant Policy.Wire_Length := Policy.Wire_Length (Server_Length);
      Offered_Total : constant Policy.Wire_Length := Policy.Wire_Length (Offered_Length);
      Server_Cursor : Policy.Wire_Length := 0;
   begin
      if Valid_ALPN_List (Server, Server_Length) = 0 or else Valid_ALPN_List (Offered, Offered_Length) = 0
      then
         return 0;
      end if;

      while Server_Cursor < Server_Total loop
         declare
            Server_Item   : constant Policy.Item_View :=
              Policy.Inspect_Item (Server_Total, Server_Cursor, Byte_At (Server, Server_Cursor));
            Client_Cursor : Policy.Wire_Length := 0;
         begin
            while Client_Cursor < Offered_Total loop
               declare
                  Client_Item : constant Policy.Item_View :=
                    Policy.Inspect_Item (Offered_Total, Client_Cursor, Byte_At (Offered, Client_Cursor));
               begin
                  if Client_Item.Value_Length = Server_Item.Value_Length
                    and then Items_Equal
                               (Server,
                                Server_Item.Value_Offset,
                                Offered,
                                Client_Item.Value_Offset,
                                Server_Item.Value_Length)
                  then
                     return
                       Interfaces.Shift_Left (Interfaces.Unsigned_64 (Client_Item.Value_Offset), 8)
                       or Interfaces.Unsigned_64 (Client_Item.Value_Length);
                  end if;
                  Client_Cursor := Client_Item.Next_Offset;
               end;
            end loop;
            Server_Cursor := Server_Item.Next_Offset;
         end;
      end loop;
      return 0;
   end Select_ALPN;
end Flyology.TLS_OpenSSL_Raw;
