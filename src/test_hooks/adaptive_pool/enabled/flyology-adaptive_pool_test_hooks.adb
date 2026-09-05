package body Flyology.Adaptive_Pool_Test_Hooks is

   protected Observations is
      procedure Reset;
      procedure Record_Chunk_State (Chunk : Positive; Live : Boolean);
      function Chunk_Is_Live (Chunk : Positive) return Boolean;
   private
      Chunk_1_Live : Boolean := False;
      Chunk_2_Live : Boolean := False;
   end Observations;

   protected body Observations is
      procedure Reset is
      begin
         Chunk_1_Live := False;
         Chunk_2_Live := False;
      end Reset;

      procedure Record_Chunk_State (Chunk : Positive; Live : Boolean) is
      begin
         case Chunk is
            when 1      =>
               Chunk_1_Live := Live;

            when 2      =>
               Chunk_2_Live := Live;

            when others =>
               null;
         end case;
      end Record_Chunk_State;

      function Chunk_Is_Live (Chunk : Positive) return Boolean is
      begin
         return
           (case Chunk is
              when 1      => Chunk_1_Live,
              when 2      => Chunk_2_Live,
              when others => False);
      end Chunk_Is_Live;
   end Observations;

   procedure Reset is
   begin
      Observations.Reset;
   end Reset;

   procedure Record_Chunk_State (Chunk : Positive; Live : Boolean) is
   begin
      Observations.Record_Chunk_State (Chunk, Live);
   end Record_Chunk_State;

   function Chunk_Is_Live (Chunk : Positive) return Boolean
   is (Observations.Chunk_Is_Live (Chunk));

end Flyology.Adaptive_Pool_Test_Hooks;
