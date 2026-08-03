with Ada.Streams;
with Flyology;
with Flyology.IO.Sockets;
with Interfaces.C;
with Context_ABI_Support;

procedure Context_ABI_Matrix is
   package Support renames Context_ABI_Support;

   use type Interfaces.C.unsigned;

   Reader : aliased Flyology.IO.Sockets.Socket_Type;
   Writer : Flyology.IO.Sockets.Socket_Type;

   protected Results is
      procedure Report_Lightweight (Mask : Interfaces.C.unsigned);
      procedure Report_Native (Mask : Interfaces.C.unsigned);
      procedure Report_Sender (Passed : Boolean);
      entry Wait;
      function Passed return Boolean;
      function Lightweight_Mask return Interfaces.C.unsigned;
      function Native_Mask return Interfaces.C.unsigned;
   private
      Count       : Natural := 0;
      OK          : Boolean := True;
      Light_Mask  : Interfaces.C.unsigned := 0;
      Native_Bits : Interfaces.C.unsigned := 0;
   end Results;

   protected body Results is
      procedure Report_Lightweight (Mask : Interfaces.C.unsigned) is
      begin
         Light_Mask := Mask;
         OK := OK and then Mask = 0;
         Count := Count + 1;
      end Report_Lightweight;

      procedure Report_Native (Mask : Interfaces.C.unsigned) is
      begin
         Native_Bits := Mask;
         OK := OK and then Mask = 0;
         Count := Count + 1;
      end Report_Native;

      procedure Report_Sender (Passed : Boolean) is
      begin
         OK := OK and then Passed;
         Count := Count + 1;
      end Report_Sender;

      entry Wait when Count = 3 is
      begin
         null;
      end Wait;

      function Passed return Boolean is (OK);

      function Lightweight_Mask return Interfaces.C.unsigned is (Light_Mask);

      function Native_Mask return Interfaces.C.unsigned is (Native_Bits);
   end Results;

begin
   Flyology.IO.Sockets.Create_Socket_Pair (Reader, Writer);
   Support.Configure (Reader);

   declare
      task Lightweight with CPU => 0 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Lightweight;

      task Native_Control is
         pragma Task_Info (Flyology.Native_Task);
      end Native_Control;

      task Lightweight_Sender with CPU => 0 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Lightweight_Sender;

      task body Lightweight is
         Mask : Interfaces.C.unsigned := 0;
      begin
         for Action in
           Support.Cooperative_Yield .. Support.Cross_Group_Move
         loop
            Mask := Mask or Support.Probe (Action);
         end loop;
         Results.Report_Lightweight (Mask);
      exception
         when others =>
            Results.Report_Lightweight (Interfaces.C.unsigned'Last);
      end Lightweight;

      task body Native_Control is
      begin
         Results.Report_Native (Support.Probe (Support.No_Switch));
      exception
         when others =>
            Results.Report_Native (Interfaces.C.unsigned'Last);
      end Native_Control;

      task body Lightweight_Sender is
      begin
         --  Request makes this same-group task ready, but cooperative
         --  scheduling cannot run it until the probe task suspends on the
         --  still-empty descriptor. The send therefore follows a real
         --  readiness-wait context switch without wall-clock ordering.
         Support.Wait_For_Descriptor_Request;
         Flyology.IO.Sockets.Send_All
           (Writer, Ada.Streams.Stream_Element_Array'[1 => 16#5A#],
            Timeout => 1.0);
         Results.Report_Sender (True);
      exception
         when others =>
            Results.Report_Sender (False);
      end Lightweight_Sender;
   begin
      Results.Wait;
   end;

   Flyology.IO.Sockets.Close_Socket (Reader);
   Flyology.IO.Sockets.Close_Socket (Writer);

   if not Results.Passed then
      raise Program_Error with
        "context ABI probe failed: lightweight="
        & Interfaces.C.unsigned'Image (Results.Lightweight_Mask)
        & ", native="
        & Interfaces.C.unsigned'Image (Results.Native_Mask);
   end if;
end Context_ABI_Matrix;
