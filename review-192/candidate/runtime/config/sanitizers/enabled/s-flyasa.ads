with Interfaces.C;

package System.Flyology.ASan is
   pragma Preelaborate;

   Enabled : constant Boolean := True;

   procedure Start_Switch
     (Source_Context     : System.Address;
      Destination_Bottom : System.Address;
      Destination_Size   : Interfaces.C.size_t);

   procedure Finish_Switch
     (Source_Context : out System.Address;
      Source_Bottom  : out System.Address;
      Source_Size    : out Interfaces.C.size_t);
end System.Flyology.ASan;
