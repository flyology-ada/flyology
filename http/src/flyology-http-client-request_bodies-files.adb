package body Flyology.HTTP.Client.Request_Bodies.Files is
   use type Ada.Streams.Stream_Element_Offset;
   use type Flyology.IO.Files.File_Offset;

   procedure Validate_Range (Item : Range_Source) is
   begin
      if Item.Count > 0
        and then Item.Count - 1 >
          Body_Size (Flyology.IO.Files.File_Offset'Last - Item.Offset)
      then
         raise Constraint_Error with
           "HTTP request body file range exceeds File_Offset";
      end if;
   end Validate_Range;

   overriding function Declared_Length
     (Item : Range_Source) return Body_Length is
   begin
      Validate_Range (Item);
      return Known_Length (Item.Count);
   end Declared_Length;

   overriding procedure Read
     (Item     : in out Range_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token)
   is
      Remaining : Body_Size;
      Count     : Natural;
      Read_Last : Ada.Streams.Stream_Element_Offset;
   begin
      Last := Data'First - 1;
      if Item.Position >= Item.Count then
         Finished := True;
         return;
      end if;

      Remaining := Item.Count - Item.Position;
      Count :=
        (if Remaining > Body_Size (Data'Length)
         then Natural (Data'Length)
         else Natural (Remaining));
      Flyology.IO.Files.Read_At
        (Item.File.all,
         Item.Offset + Flyology.IO.Files.File_Offset (Item.Position),
         Data
           (Data'First ..
              Data'First + Ada.Streams.Stream_Element_Offset (Count) - 1),
         Read_Last,
         Timeout,
         Token);
      if Read_Last < Data'First then
         Finished := True;
         return;
      end if;

      declare
         Read_Count : constant Natural :=
           Natural (Read_Last - Data'First + 1);
      begin
         Item.Position := Item.Position + Body_Size (Read_Count);
         Last := Data'First
           + Ada.Streams.Stream_Element_Offset (Read_Count) - 1;
      end;
      Finished := Item.Position = Item.Count;
   end Read;

   overriding procedure Rewind (Item : in out Range_Source) is
   begin
      Item.Position := 0;
   end Rewind;

end Flyology.HTTP.Client.Request_Bodies.Files;
