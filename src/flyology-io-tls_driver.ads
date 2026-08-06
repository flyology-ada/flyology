with Ada.Streams;
with Flyology.IO.TLS;

--  Provider-step engine for ownership-aware TLS connections.
--  Callers retain descriptor ownership, serialization, deadlines, and
--  cancellation policy. The callbacks are invoked only for the duration of
--  the operation and must not escape.
--  @exclude
private package Flyology.IO.TLS_Driver is

   procedure Receive_Once
     (Item   : in out Flyology.IO.TLS.Session'Class;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Status : out Flyology.IO.TLS.Step_Status);

   procedure Send_Once
     (Item   : in out Flyology.IO.TLS.Session'Class;
      Data   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Status : out Flyology.IO.TLS.Step_Status);

   procedure Handshake
     (Item        : in out Flyology.IO.TLS.Session'Class;
      Check       : not null access procedure;
      Await_Ready : not null access procedure
        (Status : Flyology.IO.TLS.Step_Status));

   procedure Receive
     (Item        : in out Flyology.IO.TLS.Session'Class;
      Data        : out Ada.Streams.Stream_Element_Array;
      Last        : out Ada.Streams.Stream_Element_Offset;
      Check       : not null access procedure;
      Await_Ready : not null access procedure
        (Status : Flyology.IO.TLS.Step_Status));

   procedure Receive_Exactly
     (Item        : in out Flyology.IO.TLS.Session'Class;
      Data        : out Ada.Streams.Stream_Element_Array;
      Check       : not null access procedure;
      Await_Ready : not null access procedure
        (Status : Flyology.IO.TLS.Step_Status));

   procedure Send_All
     (Item        : in out Flyology.IO.TLS.Session'Class;
      Data        : Ada.Streams.Stream_Element_Array;
      Check       : not null access procedure;
      Await_Ready : not null access procedure
        (Status : Flyology.IO.TLS.Step_Status));

   procedure Shutdown
     (Item        : in out Flyology.IO.TLS.Session'Class;
      Check       : not null access procedure;
      Await_Ready : not null access procedure
        (Status : Flyology.IO.TLS.Step_Status));

end Flyology.IO.TLS_Driver;
