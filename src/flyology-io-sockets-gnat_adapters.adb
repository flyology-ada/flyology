package body Flyology.IO.Sockets.GNAT_Adapters is

   procedure Adopt
     (Source : in out GNAT.Sockets.Socket_Type;
      Target : in out Flyology.IO.Sockets.Socket_Type)
   is
      FD : Flyology.IO.Descriptor :=
        Flyology.IO.Descriptor (GNAT.Sockets.To_C (Source));
   begin
      Flyology.IO.Sockets.Adopt (FD, Target);
      Source := GNAT.Sockets.No_Socket;
   end Adopt;

   procedure Release
     (Source : in out Flyology.IO.Sockets.Socket_Type;
      Target : out GNAT.Sockets.Socket_Type)
   is
      FD : Flyology.IO.Descriptor;
   begin
      Flyology.IO.Sockets.Release (Source, FD);
      Target := GNAT.Sockets.To_Ada (Integer (FD));
   end Release;

end Flyology.IO.Sockets.GNAT_Adapters;
