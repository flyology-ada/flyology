package body Flyology.Adaptive_Pool_Test_Hooks is

   protected Observations is
      procedure Reset;
      procedure Arm_Release_Contention (After_Releases : Natural);
      procedure Consume_Release_Contention (Armed : out Boolean);
      procedure Record_Chunk_State (Chunk : Positive; Live : Boolean);
      function Chunk_Is_Live (Chunk : Positive) return Boolean;
   private
      Chunk_1_Live               : Boolean := False;
      Chunk_2_Live               : Boolean := False;
      Release_Contention_Armed   : Boolean := False;
      Releases_Before_Contention : Natural := 0;
   end Observations;

   protected body Observations is
      procedure Reset is
      begin
         Chunk_1_Live := False;
         Chunk_2_Live := False;
         Release_Contention_Armed := False;
         Releases_Before_Contention := 0;
      end Reset;

      procedure Arm_Release_Contention (After_Releases : Natural) is
      begin
         Release_Contention_Armed := True;
         Releases_Before_Contention := After_Releases;
      end Arm_Release_Contention;

      procedure Consume_Release_Contention (Armed : out Boolean) is
      begin
         Armed := Release_Contention_Armed and then Releases_Before_Contention = 0;
         if Armed then
            Release_Contention_Armed := False;
         elsif Release_Contention_Armed then
            Releases_Before_Contention := Releases_Before_Contention - 1;
         end if;
      end Consume_Release_Contention;

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

   procedure Arm_Release_Contention (After_Releases : Natural := 0) is
   begin
      Observations.Arm_Release_Contention (After_Releases);
   end Arm_Release_Contention;

   procedure Consume_Release_Contention (Armed : out Boolean) is
   begin
      Observations.Consume_Release_Contention (Armed);
   end Consume_Release_Contention;

   procedure Record_Chunk_State (Chunk : Positive; Live : Boolean) is
   begin
      Observations.Record_Chunk_State (Chunk, Live);
   end Record_Chunk_State;

   function Chunk_Is_Live (Chunk : Positive) return Boolean
   is (Observations.Chunk_Is_Live (Chunk));

end Flyology.Adaptive_Pool_Test_Hooks;
