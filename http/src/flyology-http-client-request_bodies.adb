package body Flyology.HTTP.Client.Request_Bodies is
   use type Ada.Streams.Stream_Element_Offset;

   procedure Finish_Read
     (First    : Ada.Streams.Stream_Element_Offset;
      Count    : Natural;
      Complete : Boolean;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean) is
   begin
      Last :=
        (if Count = 0 then First - 1
         else First + Ada.Streams.Stream_Element_Offset (Count) - 1);
      Finished := Complete;
   end Finish_Read;

   overriding function Declared_Length
     (Item : Array_Source) return Body_Length is
     (Known_Length (Body_Size (Item.Data.all'Length)));

   overriding procedure Read
     (Item     : in out Array_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
      Remaining : constant Natural := Item.Data.all'Length - Item.Position;
      Count     : constant Natural :=
        Natural'Min (Natural (Data'Length), Remaining);
   begin
      if Count > 0 then
         for Offset in 0 .. Count - 1 loop
            Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
              Item.Data.all
                (Item.Data.all'First
                   + Ada.Streams.Stream_Element_Offset
                     (Item.Position + Offset));
         end loop;
      end if;
      Item.Position := Item.Position + Count;
      Finish_Read
        (Data'First, Count, Item.Position = Item.Data.all'Length,
         Last, Finished);
   end Read;

   overriding procedure Rewind (Item : in out Array_Source) is
   begin
      Item.Position := 0;
   end Rewind;

   overriding function Declared_Length
     (Item : Byte_String_Source) return Body_Length is
     (Known_Length (Body_Size (Item.Data.all'Length)));

   overriding procedure Read
     (Item     : in out Byte_String_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
      Remaining : constant Natural := Item.Data.all'Length - Item.Position;
      Count     : constant Natural :=
        Natural'Min (Natural (Data'Length), Remaining);
   begin
      if Count > 0 then
         for Offset in 0 .. Count - 1 loop
            Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
              Ada.Streams.Stream_Element
                (Character'Pos
                   (Item.Data.all
                      (Item.Data.all'First + Item.Position + Offset)));
         end loop;
      end if;
      Item.Position := Item.Position + Count;
      Finish_Read
        (Data'First, Count, Item.Position = Item.Data.all'Length,
         Last, Finished);
   end Read;

   overriding procedure Rewind (Item : in out Byte_String_Source) is
   begin
      Item.Position := 0;
   end Rewind;

   overriding function Declared_Length
     (Item : Bytes_Source) return Body_Length is
     (Known_Length (Body_Size (Flyology.Bytes.Length (Item.Data.all))));

   overriding procedure Read
     (Item     : in out Bytes_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
      Total     : constant Natural := Flyology.Bytes.Length (Item.Data.all);
      Remaining : constant Natural := Total - Item.Position;
      Count     : constant Natural :=
        Natural'Min (Natural (Data'Length), Remaining);
   begin
      if Count > 0 then
         for Offset in 0 .. Count - 1 loop
            Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
              Flyology.Bytes.Element
                (Item.Data.all, Positive (Item.Position + Offset + 1));
         end loop;
      end if;
      Item.Position := Item.Position + Count;
      Finish_Read
        (Data'First, Count, Item.Position = Total, Last, Finished);
   end Read;

   overriding procedure Rewind (Item : in out Bytes_Source) is
   begin
      Item.Position := 0;
   end Rewind;

   overriding function Declared_Length
     (Item : Buffer_Source) return Body_Length is
   begin
      if not Flyology.Buffers.Has_Buffer (Item.Data.all) then
         raise Program_Error with
           "HTTP request body buffer does not own storage";
      end if;
      return Known_Length
        (Body_Size (Flyology.Buffers.Length (Item.Data.all)));
   end Declared_Length;

   overriding procedure Read
     (Item     : in out Buffer_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
      Total : constant Natural := Flyology.Buffers.Length (Item.Data.all);
      Count : Natural := 0;

      procedure Copy (Payload : Ada.Streams.Stream_Element_Array) is
      begin
         Count := Natural'Min
           (Natural (Data'Length), Total - Item.Position);
         if Count > 0 then
            for Offset in 0 .. Count - 1 loop
               Data
                 (Data'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
                   Payload
                     (Payload'First
                        + Ada.Streams.Stream_Element_Offset
                          (Item.Position + Offset));
            end loop;
         end if;
      end Copy;
   begin
      Flyology.Buffers.With_Readable_Data (Item.Data.all, Copy'Access);
      Item.Position := Item.Position + Count;
      Finish_Read
        (Data'First, Count, Item.Position = Total, Last, Finished);
   end Read;

   overriding procedure Rewind (Item : in out Buffer_Source) is
   begin
      Item.Position := 0;
   end Rewind;

end Flyology.HTTP.Client.Request_Bodies;
