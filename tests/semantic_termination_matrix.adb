with Ada.Synchronous_Task_Control;
with Ada.Text_IO;
with Flyology;
with Flyology.Execution_Groups;
with Semantic_Termination_Lightweight_Lightweight;
with Semantic_Termination_Lightweight_Native;
with Semantic_Termination_Native_Lightweight;
with Semantic_Termination_Native_Native;

procedure Semantic_Termination_Matrix is
   package STC renames Ada.Synchronous_Task_Control;
   package Groups renames Flyology.Execution_Groups;

   package Native_Native renames Semantic_Termination_Native_Native;
   package Native_Lightweight renames
     Semantic_Termination_Native_Lightweight;
   package Lightweight_Native renames
     Semantic_Termination_Lightweight_Native;
   package Lightweight_Lightweight renames
     Semantic_Termination_Lightweight_Lightweight;

   procedure Check (Name : String; Values : Native_Native.Results) is
   begin
      for Item in Values'Range loop
         if not Values (Item) then
            raise Program_Error with
              Name & " failed " & Native_Native.Check_Id'Image (Item);
         end if;
      end loop;
   end Check;

   procedure Check (Name : String; Values : Native_Lightweight.Results) is
   begin
      for Item in Values'Range loop
         if not Values (Item) then
            raise Program_Error with
              Name & " failed " & Native_Lightweight.Check_Id'Image (Item);
         end if;
      end loop;
   end Check;

   procedure Check (Name : String; Values : Lightweight_Native.Results) is
   begin
      for Item in Values'Range loop
         if not Values (Item) then
            raise Program_Error with
              Name & " failed " & Lightweight_Native.Check_Id'Image (Item);
         end if;
      end loop;
   end Check;

   procedure Check (Name : String; Values : Lightweight_Lightweight.Results) is
   begin
      for Item in Values'Range loop
         if not Values (Item) then
            raise Program_Error with
              Name & " failed "
              & Lightweight_Lightweight.Check_Id'Image (Item);
         end if;
      end loop;
   end Check;

   procedure Check_Cross_Group_Entry_Family is
      Result : Natural := 0;
      Open   : STC.Suspension_Object;

      protected Done is
         procedure Set;
         entry Wait;
      private
         Finished : Boolean := False;
      end Done;

      protected body Done is
         procedure Set is
         begin
            Finished := True;
         end Set;

         entry Wait when Finished is
         begin
            null;
         end Wait;
      end Done;

      task Server with CPU => 1 is
         pragma Task_Info (Flyology.Lightweight_Task);
         entry Transform (Positive range 1 .. 2)
           (Input : Natural; Output : out Natural);
      end Server;

      task body Server is
      begin
         STC.Suspend_Until_True (Open);
         accept Transform (2) (Input : Natural; Output : out Natural) do
            Output := Input * 2;
         end Transform;
      end Server;

      task Caller with CPU => 2 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Caller;

      task body Caller is
      begin
         Server.Transform (2) (21, Result);
         Done.Set;
      end Caller;
   begin
      STC.Set_True (Open);
      Done.Wait;
      pragma Assert (Result = 42);
   end Check_Cross_Group_Entry_Family;

begin
   Check ("native/native", Native_Native.Run);
   Check ("native/lightweight", Native_Lightweight.Run);
   Check ("lightweight/native", Lightweight_Native.Run);
   Check ("lightweight/lightweight", Lightweight_Lightweight.Run);
   pragma Assert (Groups.Configured_Pool_Size >= 3);
   Check_Cross_Group_Entry_Family;
   Ada.Text_IO.Put_Line
     ("semantic termination matrix: 28 lane-pair checks and one "
      & "cross-group entry-family check passed");
end Semantic_Termination_Matrix;
