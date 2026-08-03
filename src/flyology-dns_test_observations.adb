package body Flyology.DNS_Test_Observations is

   protected Observations is
      procedure Reset;
      procedure Record_Receive_Wait (After_Close : Boolean);
      function Post_Close_Receive_Waits return Natural;
   private
      Post_Close_Count : Natural := 0;
   end Observations;

   protected body Observations is
      procedure Reset is
      begin
         Post_Close_Count := 0;
      end Reset;

      procedure Record_Receive_Wait (After_Close : Boolean) is
      begin
         if After_Close and then Post_Close_Count < Natural'Last then
            Post_Close_Count := Post_Close_Count + 1;
         end if;
      end Record_Receive_Wait;

      function Post_Close_Receive_Waits return Natural is
        (Post_Close_Count);
   end Observations;

   procedure Reset is
   begin
      Observations.Reset;
   end Reset;

   procedure Record_Receive_Wait
     (After_Close : Boolean)
   is
   begin
      Observations.Record_Receive_Wait (After_Close);
   end Record_Receive_Wait;

   function Post_Close_Receive_Waits return Natural is
     (Observations.Post_Close_Receive_Waits);

end Flyology.DNS_Test_Observations;
