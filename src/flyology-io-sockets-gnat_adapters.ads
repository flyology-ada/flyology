with GNAT.Sockets;

--  Explicit ownership transfers between GNAT.Sockets and Flyology sockets.
--  These adapters never leave both handle types owning the same descriptor.
package Flyology.IO.Sockets.GNAT_Adapters is

   --  Transfer Source into a closed Flyology Target. Source becomes
   --  GNAT.Sockets.No_Socket on return.
   --  @param Source Sole GNAT socket owner whose descriptor transfers
   --  @param Target Closed Flyology handle that receives ownership
   --  @exception Program_Error Source is invalid or Target is open
   procedure Adopt
     (Source : in out GNAT.Sockets.Socket_Type;
      Target : in out Flyology.IO.Sockets.Socket_Type)
     with Pre =>
       GNAT.Sockets.To_C (Source) >= 0 and then
       not Flyology.IO.Sockets.Is_Open (Target),
       Post =>
         GNAT.Sockets.To_C (Source) < 0 and then
         Flyology.IO.Sockets.Is_Open (Target);

   --  Transfer Source into a GNAT socket handle without closing it. Source is
   --  closed on return; a closed Source produces GNAT.Sockets.No_Socket.
   --  @param Source Flyology socket owner whose descriptor transfers
   --  @param Target GNAT socket handle that receives ownership
   procedure Release
     (Source : in out Flyology.IO.Sockets.Socket_Type;
      Target : out GNAT.Sockets.Socket_Type)
     with Post => not Flyology.IO.Sockets.Is_Open (Source);

end Flyology.IO.Sockets.GNAT_Adapters;
