package HTTP_Client_RFC_Seeds is

   type Expected_Result is (Accept_Input, Reject_Input);
   subtype Seed_Index is Positive range 1 .. 42;

   function Name (Index : Seed_Index) return String;
   function Reference (Index : Seed_Index) return String;
   function Expected (Index : Seed_Index) return Expected_Result;
   function Payload (Index : Seed_Index) return String;

end HTTP_Client_RFC_Seeds;
