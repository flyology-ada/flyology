with Ada.Real_Time;
with Ada.Streams;
with Flyology.IO;

package body Flyology.Subprocesses.Capture is
   package US renames Ada.Strings.Unbounded;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;

   Chunk_Size : constant := 4_096;

   function Status (Item : Result) return Exit_Status
   is (Item.Child_Status);

   function Standard_Output (Item : Result) return String
   is (US.To_String (Item.Output_State));

   function Standard_Error (Item : Result) return String
   is (US.To_String (Item.Error_State));

   function Output_Truncated (Item : Result) return Boolean
   is (Item.Output_Was_Cut);

   function Error_Truncated (Item : Result) return Boolean
   is (Item.Error_Was_Cut);

   function Run
     (Item           : Command;
      Standard_Input : String := "";
      Maximum_Output : Natural := 64 * 1_024;
      Maximum_Error  : Natural := 64 * 1_024;
      Timeout        : Duration := 30.0;
      Token          : access Flyology.Cancellation.Token := null) return Result
   is
      Started           : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Child             : Process;
      Value             : Result;
      Input_Offset      : Natural := 0;
      Process_Done      : Boolean := False;
      Wake_FD           : Flyology.IO.Descriptor := -1;
      Already_Cancelled : Boolean := False;
      First_Wait        : Boolean := True;
      Next_First        : Natural range 0 .. 3 := 0;

      function Time_Left return Duration is
         Elapsed : constant Duration := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
      begin
         if Timeout < 0.0 then
            return Flyology.IO.Infinite;
         elsif Elapsed >= Timeout then
            return 0.0;
         else
            return Timeout - Elapsed;
         end if;
      end Time_Left;

      procedure Retain
        (Bytes     : Ada.Streams.Stream_Element_Array;
         Last      : Ada.Streams.Stream_Element_Offset;
         Maximum   : Natural;
         Storage   : in out US.Unbounded_String;
         Truncated : in out Boolean)
      is
         Received  : constant Natural := (if Last < Bytes'First then 0 else Natural (Last - Bytes'First + 1));
         Available : constant Natural :=
           (if US.Length (Storage) >= Maximum then 0 else Maximum - US.Length (Storage));
         Kept      : constant Natural := Natural'Min (Received, Available);
      begin
         if Kept > 0 then
            declare
               Text : String (1 .. Kept);
            begin
               for Index in Text'Range loop
                  Text (Index) :=
                    Character'Val (Bytes (Bytes'First + Ada.Streams.Stream_Element_Offset (Index - 1)));
               end loop;
               US.Append (Storage, Text);
            end;
         end if;
         Truncated := Truncated or else Received > Kept;
      end Retain;

      procedure Cleanup_After_Failure is
         Ignored_Status : Exit_Status;
      begin
         if Is_Open (Child) then
            Close_Standard_Input (Child);
            begin
               Kill (Child);
            exception
               when others =>
                  null;
            end;
            begin
               Wait (Child, Ignored_Status);
            exception
               when others =>
                  null;
            end;
            Close_Standard_Output (Child);
            Close_Standard_Error (Child);
            begin
               Close (Child);
            exception
               when others =>
                  null;
            end;
         end if;
      end Cleanup_After_Failure;
   begin
      if Token /= null and then Token.Requested then
         raise Flyology.Cancellation.Operation_Cancelled;
      end if;

      Spawn (Item, Child);
      if Standard_Input'Length = 0 then
         Close_Standard_Input (Child);
      end if;
      if Token /= null then
         Token.Wait_Source (Wake_FD, Already_Cancelled);
         if Already_Cancelled then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
      end if;

      while Standard_Output_Is_Open (Child) or else Standard_Error_Is_Open (Child) or else not Process_Done
      loop
         if Token /= null and then Token.Requested then
            raise Flyology.Cancellation.Operation_Cancelled;
         elsif not First_Wait and then Timeout >= 0.0 and then Time_Left <= 0.0 then
            raise Flyology.IO.Timeout_Error with "subprocess capture deadline expired";
         end if;
         First_Wait := False;
         declare
            Requests    : Flyology.IO.Wait_Request_Array (1 .. 5);
            Count       : Natural := 0;
            Output_Slot : Natural := 0;
            Error_Slot  : Natural := 0;
            Input_Slot  : Natural := 0;
            Exit_Slot   : Natural := 0;
            Cancel_Slot : Natural := 0;

            procedure Add
              (Descriptor : Flyology.IO.Descriptor; Condition : Flyology.IO.Wait_Kind; Slot : out Natural) is
            begin
               Count := Count + 1;
               Requests (Count) := (FD => Descriptor, Condition => Condition);
               Slot := Count;
            end Add;

            Ready_Slot : Natural;
         begin
            for Offset in 0 .. 3 loop
               declare
                  Slot_Class : constant Natural range 0 .. 3 := (Next_First + Offset) mod 4;
               begin
                  case Slot_Class is
                     when 0 =>
                        if Standard_Output_Is_Open (Child) then
                           Add (Child.Output_FD, Flyology.IO.For_Read, Output_Slot);
                        end if;

                     when 1 =>
                        if Standard_Error_Is_Open (Child) then
                           Add (Child.Error_FD, Flyology.IO.For_Read, Error_Slot);
                        end if;

                     when 2 =>
                        if Standard_Input_Is_Open (Child) then
                           Add (Child.Input_FD, Flyology.IO.For_Write, Input_Slot);
                        end if;

                     when 3 =>
                        if not Process_Done then
                           Add (Child.Exit_State.Wait_Descriptor, Flyology.IO.For_Read, Exit_Slot);
                        end if;
                  end case;
               end;
            end loop;
            Next_First := (Next_First + 1) mod 4;
            if Token /= null then
               Add (Wake_FD, Flyology.IO.For_Read, Cancel_Slot);
            end if;

            Ready_Slot := Flyology.IO.Wait_Any (Requests (1 .. Count), Time_Left);
            if Ready_Slot = 0 then
               raise Flyology.IO.Timeout_Error with "subprocess capture deadline expired";
            elsif Ready_Slot = Cancel_Slot and then Cancel_Slot /= 0 then
               raise Flyology.Cancellation.Operation_Cancelled;
            elsif Ready_Slot = Output_Slot and then Output_Slot /= 0 then
               declare
                  Buffer : Ada.Streams.Stream_Element_Array (1 .. Chunk_Size);
                  Last   : Ada.Streams.Stream_Element_Offset;
               begin
                  Read_Standard_Output (Child, Buffer, Last, Timeout => 0.0);
                  Retain (Buffer, Last, Maximum_Output, Value.Output_State, Value.Output_Was_Cut);
               exception
                  when Flyology.IO.Timeout_Error =>
                     null;
               end;
            elsif Ready_Slot = Error_Slot and then Error_Slot /= 0 then
               declare
                  Buffer : Ada.Streams.Stream_Element_Array (1 .. Chunk_Size);
                  Last   : Ada.Streams.Stream_Element_Offset;
               begin
                  Read_Standard_Error (Child, Buffer, Last, Timeout => 0.0);
                  Retain (Buffer, Last, Maximum_Error, Value.Error_State, Value.Error_Was_Cut);
               exception
                  when Flyology.IO.Timeout_Error =>
                     null;
               end;
            elsif Ready_Slot = Input_Slot and then Input_Slot /= 0 then
               declare
                  Remaining_Input : constant Natural := Standard_Input'Length - Input_Offset;
                  Length          : constant Natural := Natural'Min (Chunk_Size, Remaining_Input);
                  Buffer          :
                    Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (Length));
                  Last            : Ada.Streams.Stream_Element_Offset;
                  Input_Closed    : Boolean;
               begin
                  for Index in Buffer'Range loop
                     Buffer (Index) :=
                       Ada.Streams.Stream_Element
                         (Character'Pos
                            (Standard_Input (Standard_Input'First + Input_Offset + Natural (Index) - 1)));
                  end loop;
                  Try_Write_Standard_Input (Child, Buffer, Last, Input_Closed, Timeout => 0.0);
                  if Input_Closed then
                     Close_Standard_Input (Child);
                  else
                     Input_Offset := Input_Offset + Natural (Last - Buffer'First + 1);
                     if Input_Offset = Standard_Input'Length then
                        Close_Standard_Input (Child);
                     end if;
                  end if;
               exception
                  when Flyology.IO.Timeout_Error =>
                     null;
               end;
            elsif Ready_Slot = Exit_Slot and then Exit_Slot /= 0 then
               Wait (Child, Value.Child_Status, Timeout => 0.0);
               Process_Done := True;
            end if;
         end;
      end loop;

      Close (Child);
      return Value;
   exception
      when others =>
         Cleanup_After_Failure;
         raise;
   end Run;

end Flyology.Subprocesses.Capture;
