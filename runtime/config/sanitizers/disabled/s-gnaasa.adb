package body System.Gnatevl.ASan is
   procedure Start_Switch
     (Source_Context     : System.Address;
      Destination_Bottom : System.Address;
      Destination_Size   : Interfaces.C.size_t)
   is
      pragma Unreferenced
        (Source_Context, Destination_Bottom, Destination_Size);
   begin
      null;
   end Start_Switch;

   procedure Finish_Switch
     (Source_Context : out System.Address;
      Source_Bottom  : out System.Address;
      Source_Size    : out Interfaces.C.size_t)
   is
   begin
      Source_Context := System.Null_Address;
      Source_Bottom := System.Null_Address;
      Source_Size := 0;
   end Finish_Switch;
end System.Gnatevl.ASan;
