with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings;
with Ada.Strings.Fixed;
with Flyology.File_Transfer_Policy;
with Flyology.Sendfile_Bridge;
with Flyology.Time_Math;
with System.OS_Constants;

package body Flyology.IO.Files.Transfers is
   package C renames Interfaces.C;
   package Sockets renames Flyology.IO.Sockets;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type C.int;
   use type C.long;
   use type C.long_long;

   Send_ZC_Minimum       : constant Natural := 16 * 1_024;
   Send_ZC_Observed      : C.int := 0
   with Atomic;
   C_Errno_Would_Block   : constant C.int := C.int (System.OS_Constants.EAGAIN);
   C_Errno_Interrupted   : constant C.int := C.int (System.OS_Constants.EINTR);
   C_Errno_Not_Supported : constant C.int := C.int (System.OS_Constants.EOPNOTSUPP);

   function Observed_Send_ZC return C.int
   is (Send_ZC_Observed);
   pragma Export (C, Observed_Send_ZC, "flyology_transfer_send_zc_observed");

   function Event_File_IO
     (Descriptor  : C.int;
      Buffer      : System.Address;
      Length      : C.size_t;
      Offset      : C.long_long;
      For_Write   : C.int;
      Cancel_FD   : C.int;
      Transferred : access C.long_long;
      Error_Code  : access C.int;
      Cancelled   : access C.int) return C.int;
   pragma Import (C, Event_File_IO, "flyology_runtime_file_io");

   function Remaining (Started : Ada.Real_Time.Time; Timeout : Duration) return Duration is
      Elapsed : Duration;
   begin
      if Timeout < 0.0 then
         return Infinite;
      end if;
      Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
      return Flyology.Time_Math.Remaining (Timeout, Elapsed);
   end Remaining;

   procedure Raise_Socket_Error (Error : C.int) is
   begin
      raise Sockets.Socket_Error
        with "sendfile failed [errno=" & Ada.Strings.Fixed.Trim (Error'Image, Ada.Strings.Both) & "]";
   end Raise_Socket_Error;

   procedure Check_Cancelled (Token : access Cancellation_Token) is
   begin
      if Token /= null and then Token.Requested then
         raise Operation_Cancelled;
      end if;
   end Check_Cancelled;

   procedure Native_Send
     (File    : File_Descriptor;
      Socket  : Sockets.Socket_Type;
      Offset  : File_Offset;
      Count   : Byte_Count;
      Sent    : out Byte_Count;
      Started : Ada.Real_Time.Time;
      Timeout : Duration;
      Token   : access Cancellation_Token)
   is
      Error             : aliased C.int := 0;
      Result            : C.long;
      Cancel_Descriptor : C.int := -1;
      Already_Cancelled : Boolean := False;
      Outcome           : Wait_Outcome;
      Interrupts        : Interrupt_Set (1 .. 1);
   begin
      Sent := 0;
      Check_Cancelled (Token);
      if Count = 0 then
         return;
      end if;

      Sockets.Prepare (Socket);
      if Token /= null then
         Token.Wait_Source (Cancel_Descriptor, Already_Cancelled);
         if Already_Cancelled then
            raise Operation_Cancelled;
         end if;
         Interrupts (1) := Cancel_Descriptor;
      end if;

      loop
         Result :=
           Flyology.Sendfile_Bridge.Send_File
             (Sockets.Native_Descriptor (Socket),
              C.int (File),
              C.long_long (Offset),
              C.size_t (Count),
              Error'Access);
         if Result >= 0 and then C.long_long (Result) <= C.long_long (Count) then
            Sent := Byte_Count (Result);
            return;
         elsif Result >= 0 then
            raise Device_Error with "sendfile returned an invalid length";
         elsif Error = C_Errno_Would_Block then
            if Cancel_Descriptor >= 0 then
               Outcome :=
                 Wait_Interruptibly
                   (Sockets.Native_Descriptor (Socket), For_Write, Remaining (Started, Timeout), Interrupts);
            else
               if Wait (Sockets.Native_Descriptor (Socket), For_Write, Remaining (Started, Timeout)) then
                  Outcome := Ready;
               else
                  Outcome := Timed_Out;
               end if;
            end if;
            case Outcome is
               when Ready       =>
                  null;

               when Timed_Out   =>
                  raise Timeout_Error with "file transfer timed out";

               when Interrupted =>
                  raise Operation_Cancelled;
            end case;
         elsif Error = C_Errno_Interrupted then
            Check_Cancelled (Token);
            if Timeout >= 0.0 and then Remaining (Started, Timeout) <= 0.0 then
               raise Timeout_Error with "file transfer timed out";
            end if;
         else
            Raise_Socket_Error (Error);
         end if;
      end loop;
   end Native_Send;

   procedure Buffered_Send
     (File    : File_Descriptor;
      Socket  : Sockets.Socket_Type;
      Offset  : File_Offset;
      Count   : Byte_Count;
      Scratch : in out Flyology.Buffers.Unique_Buffer;
      Sent    : out Byte_Count;
      Started : Ada.Real_Time.Time;
      Timeout : Duration;
      Token   : access Cancellation_Token)
   is
      Read_Count : Natural := 0;

      procedure Fill (Data : in out Ada.Streams.Stream_Element_Array; Length : in out Natural) is
         Limit : constant Natural :=
           Natural'Min (Data'Length, Natural (Byte_Count'Min (Count, Byte_Count (Natural'Last))));
         Last  : Ada.Streams.Stream_Element_Offset;
      begin
         Length := 0;
         if Limit = 0 then
            return;
         end if;
         Read_At
           (File,
            Offset,
            Data (Data'First .. Data'First + Ada.Streams.Stream_Element_Offset (Limit) - 1),
            Last,
            Remaining (Started, Timeout),
            Token);
         if Last >= Data'First then
            Length := Natural (Last - Data'First + 1);
         end if;
         Read_Count := Length;
      end Fill;

      procedure Send_Data (Data : Ada.Streams.Stream_Element_Array) is
         Cancel_Descriptor : C.int := -1;
         Already_Cancelled : Boolean := False;
         Transferred       : aliased C.long_long := 0;
         Error_Code        : aliased C.int := 0;
         Cancelled         : aliased C.int := 0;
         Status            : C.int := 1;
         Interrupts        : Interrupt_Set (1 .. 1);
         Last              : Ada.Streams.Stream_Element_Offset;
         Action            : Flyology.File_Transfer_Policy.Completion_Action;
         Limit             : constant C.long_long := C.long_long (Data'Length);

         procedure Submit_Send_ZC is
         begin
            Status :=
              Event_File_IO
                (Sockets.Native_Descriptor (Socket),
                 Data (Data'First)'Address,
                 C.size_t (Data'Length),
                 0,
                 2,
                 Cancel_Descriptor,
                 Transferred'Access,
                 Error_Code'Access,
                 Cancelled'Access);
         end Submit_Send_ZC;
      begin
         if Token /= null then
            Token.Wait_Source (Cancel_Descriptor, Already_Cancelled);
            if Already_Cancelled then
               raise Operation_Cancelled;
            end if;
            Interrupts (1) := Cancel_Descriptor;
         end if;

         Sent := 0;
         if Data'Length >= Send_ZC_Minimum and then Timeout /= 0.0 then
            if Timeout < 0.0 then
               Submit_Send_ZC;
            else
               select
                  delay Remaining (Started, Timeout);
                  raise Timeout_Error with "file transfer timed out";
               then abort
                  Submit_Send_ZC;
               end select;
            end if;
            Action :=
              Flyology.File_Transfer_Policy.Classify
                (Status, Transferred, Error_Code, Cancelled, Limit, C_Errno_Not_Supported);
            case Action is
               when Flyology.File_Transfer_Policy.Return_Progress          =>
                  --  A positive completion wins over a concurrently observed
                  --  cancellation. The socket has accepted these bytes, so
                  --  raising instead would make a retry duplicate them.
                  Send_ZC_Observed := 1;
                  Sent := Byte_Count (Transferred);
                  return;

               when Flyology.File_Transfer_Policy.Raise_Cancelled          =>
                  raise Operation_Cancelled;

               when Flyology.File_Transfer_Policy.Use_Buffered_Fallback    =>
                  null;

               when Flyology.File_Transfer_Policy.Raise_Socket_Error       =>
                  Raise_Socket_Error (Error_Code);

               when Flyology.File_Transfer_Policy.Raise_Invalid_Completion =>
                  raise Device_Error with "zero-copy send returned an invalid completion";
            end case;
         end if;

         --  Match Send_Chunk's progress contract with one ordinary send.
         --  Send_All could make a prefix visible and then raise, leaving no
         --  valid Sent value with which the caller could avoid replay.
         begin
            if Cancel_Descriptor >= 0 then
               Sockets.Send (Socket, Data, Last, Remaining (Started, Timeout), Interrupts);
            else
               Sockets.Send (Socket, Data, Last, Remaining (Started, Timeout));
            end if;
         exception
            when Sockets.Operation_Interrupted =>
               raise Operation_Cancelled;
         end;
         if Last < Data'First then
            raise Device_Error with "socket send made no progress";
         end if;
         Sent := Byte_Count (Last - Data'First + 1);
      end Send_Data;
   begin
      Sent := 0;
      Check_Cancelled (Token);
      if Count = 0 then
         return;
      end if;
      Flyology.Buffers.With_Writable_Data (Scratch, Fill'Access);
      if Read_Count = 0 then
         return;
      end if;
      Flyology.Buffers.With_Readable_Data (Scratch, Send_Data'Access);
   end Buffered_Send;

   procedure Send_Chunk
     (File    : File_Descriptor;
      Socket  : Sockets.Socket_Type;
      Offset  : File_Offset;
      Count   : Byte_Count;
      Scratch : in out Flyology.Buffers.Unique_Buffer;
      Sent    : out Byte_Count;
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      if Is_Lightweight_Task then
         Buffered_Send (File, Socket, Offset, Count, Scratch, Sent, Started, Timeout, Token);
      else
         Native_Send (File, Socket, Offset, Count, Sent, Started, Timeout, Token);
      end if;
   end Send_Chunk;

end Flyology.IO.Files.Transfers;
