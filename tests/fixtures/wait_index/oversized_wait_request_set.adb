with Flyology.IO;

--  This program must not compile. Wait_Index constrains caller index
--  positions rather than element counts, so this six-element request set is
--  out of range because its positions sit above Max_Wait_Requests.
procedure Oversized_Wait_Request_Set is
   Requests : constant Flyology.IO.Wait_Request_Array (100 .. 105) :=
     [others => (Flyology.IO.Invalid_Descriptor, Flyology.IO.For_Read)];
begin
   if Flyology.IO.Wait_Any (Requests, 0.0) /= 0 then
      raise Program_Error;
   end if;
end Oversized_Wait_Request_Set;
