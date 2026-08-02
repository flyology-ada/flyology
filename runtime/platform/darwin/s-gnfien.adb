with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with System.OS_Interface;

package body System.Gnatevl.File_Engine is
   package C renames Interfaces.C;
   package OSI renames System.OS_Interface;

   use type C.int;
   use type C.long_long;

   SIGEV_KEVENT : constant C.int := 4;

   type Signal_Event is record
      Notify            : C.int;
      Signo             : C.int;
      Value             : System.Address;
      Notify_Function   : System.Address;
      Notify_Attributes : System.Address;
   end record
     with Convention => C, Size => 256, Alignment => 8;
   for Signal_Event use record
      Notify            at 0  range 0 .. 31;
      Signo             at 4  range 0 .. 31;
      Value             at 8  range 0 .. 63;
      Notify_Function   at 16 range 0 .. 63;
      Notify_Attributes at 24 range 0 .. 63;
   end record;

   type AIO_Control_Block is record
      Descriptor   : C.int;
      Offset       : C.long_long;
      Buffer       : System.Address;
      Length       : C.size_t;
      Priority     : C.int;
      Signal       : Signal_Event;
      List_Opcode  : C.int;
   end record
     with Convention => C, Size => 640, Alignment => 8;
   for AIO_Control_Block use record
      Descriptor  at 0  range 0 .. 31;
      Offset      at 8  range 0 .. 63;
      Buffer      at 16 range 0 .. 63;
      Length      at 24 range 0 .. 63;
      Priority    at 32 range 0 .. 31;
      Signal      at 40 range 0 .. 255;
      List_Opcode at 72 range 0 .. 31;
   end record;

   type AIO_Request is record
      Control : aliased AIO_Control_Block;
      Token   : System.Address;
   end record
     with Size => 704, Alignment => 8;
   for AIO_Request use record
      Control at 0  range 0 .. 639;
      Token   at 80 range 0 .. 63;
   end record;

   type AIO_Request_Access is access all AIO_Request;

   type Engine_State is record
      Kqueue_FD : C.int := -1;
   end record;
   type Engine_State_Access is access all Engine_State;

   function To_State is new Ada.Unchecked_Conversion
     (System.Address, Engine_State_Access);
   function To_Address is new Ada.Unchecked_Conversion
     (Engine_State_Access, System.Address);
   function To_Request is new Ada.Unchecked_Conversion
     (System.Address, AIO_Request_Access);
   procedure Free_State is new Ada.Unchecked_Deallocation
     (Engine_State, Engine_State_Access);
   procedure Free_Request is new Ada.Unchecked_Deallocation
     (AIO_Request, AIO_Request_Access);

   function AIO_Read (Control : access AIO_Control_Block) return C.int;
   pragma Import (C, AIO_Read, "aio_read");

   function AIO_Write (Control : access AIO_Control_Block) return C.int;
   pragma Import (C, AIO_Write, "aio_write");

   function Initialize
     (Item      : in out Engine;
      Poller_FD : C.int;
      Wake_FD   : C.int) return Boolean
   is
      State : Engine_State_Access;
   begin
      pragma Unreferenced (Wake_FD);
      State := new Engine_State'(Kqueue_FD => Poller_FD);
      Item.State := To_Address (State);
      return True;
   exception
      when Storage_Error =>
         return False;
   end Initialize;

   procedure Finalize (Item : in out Engine) is
      State : Engine_State_Access := To_State (Item.State);
   begin
      if State /= null then
         Free_State (State);
         Item.State := System.Null_Address;
      end if;
   end Finalize;

   function Submit
     (Item        : in out Engine;
      Descriptor  : C.int;
      Buffer      : System.Address;
      Length      : C.size_t;
      Offset      : C.long_long;
      For_Write   : Boolean;
      Token       : System.Address;
      Error_Code  : out C.int) return Boolean
   is
      State   : constant Engine_State_Access := To_State (Item.State);
      Request : AIO_Request_Access;
      Result  : C.int;
   begin
      if State = null then
         Error_Code := C.int (OSI.EINVAL);
         return False;
      end if;

      Request :=
        new AIO_Request'
          (Control =>
             (Descriptor  => Descriptor,
              Offset      => Offset,
              Buffer      => Buffer,
              Length      => Length,
              Priority    => 0,
              Signal      =>
                (Notify            => SIGEV_KEVENT,
                 Signo             => State.Kqueue_FD,
                 Value             => Token,
                 Notify_Function   => System.Null_Address,
                 Notify_Attributes => System.Null_Address),
              List_Opcode => 0),
           Token => Token);
      Result :=
        (if For_Write
         then AIO_Write (Request.Control'Access)
         else AIO_Read (Request.Control'Access));
      if Result /= 0 then
         Error_Code := C.int (OSI.errno);
         Free_Request (Request);
         return False;
      end if;
      Error_Code := 0;
      return True;
   exception
      when Storage_Error =>
         Error_Code := C.int (OSI.ENOMEM);
         return False;
   end Submit;

   function Complete_Event
     (Item            : in out Engine;
      Request_Address : System.Address;
      Kernel_Result   : C.long_long;
      Kernel_Error    : C.int;
      Value           : out Completion) return Boolean
   is
      Request : AIO_Request_Access := To_Request (Request_Address);
   begin
      pragma Unreferenced (Item);
      if Request = null then
         return False;
      end if;
      Value :=
        (Token      => Request.Token,
         Result     => (if Kernel_Result >= 0 then Kernel_Result else 0),
         Error_Code => Kernel_Error);
      Free_Request (Request);
      return True;
   end Complete_Event;

   function Drain
     (Item   : in out Engine;
      Values : out Completion_Array;
      Count  : out Natural) return Boolean
   is
   begin
      pragma Unreferenced (Item);
      Values := (others => <>);
      Count := 0;
      return True;
   end Drain;

end System.Gnatevl.File_Engine;
