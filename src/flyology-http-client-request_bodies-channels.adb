with Flyology.IO;

package body Flyology.HTTP.Client.Request_Bodies.Channels is
   use type Ada.Streams.Stream_Element_Offset;

   procedure Validate_Pool (Item : Channel_Source) is
   begin
      if Item.Input.Owner /= Item.Pool then
         raise Program_Error with
           "HTTP request body channel and buffer pool do not match";
      end if;
   end Validate_Pool;

   procedure Set_Declared_Length
     (Item : in out Channel_Source; Length : Body_Length) is
   begin
      if Item.Started then
         raise Program_Error with
           "HTTP request body channel length changed after reading started";
      end if;
      Item.Framing := Length;
   end Set_Declared_Length;

   overriding function Declared_Length
     (Item : Channel_Source) return Body_Length is
   begin
      Validate_Pool (Item);
      return Item.Framing;
   end Declared_Length;

   overriding procedure Read
     (Item     : in out Channel_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token)
   is
      Used : Natural := 0;

      procedure Copy_Current
        (Payload : Ada.Streams.Stream_Element_Array)
      is
         Available : constant Natural :=
           Flyology.Buffers.Length (Item.Current) - Item.Position;
         Count : constant Natural := Natural'Min
           (Natural (Data'Length) - Used, Available);
      begin
         if Count > 0 then
            for Offset in 0 .. Count - 1 loop
               Data
                 (Data'First
                    + Ada.Streams.Stream_Element_Offset (Used + Offset)) :=
                   Payload
                     (Payload'First
                        + Ada.Streams.Stream_Element_Offset
                          (Item.Position + Offset));
            end loop;
         end if;
         Used := Used + Count;
         Item.Position := Item.Position + Count;
      end Copy_Current;
   begin
      Validate_Pool (Item);
      Item.Started := True;
      Last := Data'First - 1;
      if Item.Ended then
         Finished := True;
         return;
      end if;

      while Used < Natural (Data'Length) and then not Item.Ended loop
         if Flyology.Buffers.Has_Buffer (Item.Current) then
            Flyology.Buffers.With_Readable_Data
              (Item.Current, Copy_Current'Access);
            if Item.Position = Flyology.Buffers.Length (Item.Current) then
               Flyology.Buffers.Release (Item.Current);
               Item.Position := 0;
            end if;
            --  Return a produced channel buffer promptly instead of waiting
            --  for another producer item merely to fill the staging array.
            exit when Used > 0;
         else
            begin
               Flyology.Buffers.Channels.Timed_Receive_Move
                 (Item.Input.all, Item.Current, Timeout, Token);
               Item.Position := 0;
               if Flyology.Buffers.Length (Item.Current) = 0 then
                  Flyology.Buffers.Release (Item.Current);
               end if;
            exception
               when Flyology.Buffers.Channels.Channel_Closed =>
                  Item.Ended := True;
               when Flyology.Buffers.Channels.Timeout_Error =>
                  raise Flyology.IO.Timeout_Error;
            end;
         end if;
      end loop;

      if Used > 0 then
         Last := Data'First
           + Ada.Streams.Stream_Element_Offset (Used) - 1;
      end if;
      Finished := Item.Ended;
   end Read;

end Flyology.HTTP.Client.Request_Bodies.Channels;
