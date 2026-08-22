with Ada.Command_Line;
with Ada.Strings;
with Ada.Strings.Fixed;

package body Flyology.Process_Generations.Command_Lines is
   Coordinator_Prefix : constant String := "--flyology-coordinator=";
   Upgrade_Prefix     : constant String := "--flyology-upgrade=";
   Candidate_Prefix   : constant String := "--flyology-candidate=";

   function Decimal (Value : Coordinator_Id) return String
   is (Ada.Strings.Fixed.Trim (Coordinator_Id'Image (Value), Ada.Strings.Both));

   function Decimal (Value : Upgrade_Id) return String
   is (Ada.Strings.Fixed.Trim (Upgrade_Id'Image (Value), Ada.Strings.Both));

   function Decimal (Value : Image_Generation) return String
   is (Ada.Strings.Fixed.Trim (Image_Generation'Image (Value), Ada.Strings.Both));

   procedure Append_Authority (Item : in out Flyology.Subprocesses.Command; Authority : Upgrade_Handle) is
   begin
      Flyology.Subprocesses.Append_Argument (Item, Coordinator_Prefix & Decimal (Authority.Coordinator));
      Flyology.Subprocesses.Append_Argument (Item, Upgrade_Prefix & Decimal (Authority.Upgrade));
      Flyology.Subprocesses.Append_Argument (Item, Candidate_Prefix & Decimal (Authority.Candidate));
   end Append_Authority;

   function Read_Authority return Upgrade_Handle is
      Coordinator     : Coordinator_Id := 1;
      Upgrade         : Upgrade_Id := 1;
      Candidate       : Image_Generation := 1;
      Has_Coordinator : Boolean := False;
      Has_Upgrade     : Boolean := False;
      Has_Candidate   : Boolean := False;
   begin
      for Index in 1 .. Ada.Command_Line.Argument_Count loop
         declare
            Argument : constant String := Ada.Command_Line.Argument (Index);
         begin
            if Argument'Length > Coordinator_Prefix'Length
              and then Argument (Argument'First .. Argument'First + Coordinator_Prefix'Length - 1)
                       = Coordinator_Prefix
            then
               if Has_Coordinator then
                  raise Authority_Error with "duplicate Flyology coordinator authority";
               end if;
               Coordinator :=
                 Coordinator_Id'Value
                   (Argument (Argument'First + Coordinator_Prefix'Length .. Argument'Last));
               Has_Coordinator := True;
            elsif Argument'Length > Upgrade_Prefix'Length
              and then Argument (Argument'First .. Argument'First + Upgrade_Prefix'Length - 1)
                       = Upgrade_Prefix
            then
               if Has_Upgrade then
                  raise Authority_Error with "duplicate Flyology upgrade authority";
               end if;
               Upgrade :=
                 Upgrade_Id'Value (Argument (Argument'First + Upgrade_Prefix'Length .. Argument'Last));
               Has_Upgrade := True;
            elsif Argument'Length > Candidate_Prefix'Length
              and then Argument (Argument'First .. Argument'First + Candidate_Prefix'Length - 1)
                       = Candidate_Prefix
            then
               if Has_Candidate then
                  raise Authority_Error with "duplicate Flyology candidate authority";
               end if;
               Candidate :=
                 Image_Generation'Value
                   (Argument (Argument'First + Candidate_Prefix'Length .. Argument'Last));
               Has_Candidate := True;
            end if;
         exception
            when Constraint_Error =>
               raise Authority_Error with "invalid Flyology process-generation authority";
         end;
      end loop;
      if not Has_Coordinator or else not Has_Upgrade or else not Has_Candidate then
         raise Authority_Error with "missing Flyology process-generation authority";
      end if;
      return (Coordinator, Upgrade, Candidate);
   end Read_Authority;
end Flyology.Process_Generations.Command_Lines;
