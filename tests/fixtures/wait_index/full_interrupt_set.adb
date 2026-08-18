with Flyology.IO;

--  This program must not compile. An interruptible wait spends request
--  position 1 on its primary descriptor, so Interrupt_Index stops one
--  position below Wait_Index and cannot reach Max_Wait_Requests.
procedure Full_Interrupt_Set is
   use type Flyology.IO.Wait_Outcome;
   Sources : constant Flyology.IO.Interrupt_Set
     (1 .. Flyology.IO.Max_Wait_Requests) :=
       [others => Flyology.IO.Invalid_Descriptor];
begin
   if Flyology.IO.Wait_Interruptibly
        (Flyology.IO.Invalid_Descriptor,
         Flyology.IO.For_Read,
         0.0,
         Sources) /= Flyology.IO.Timed_Out
   then
      raise Program_Error;
   end if;
end Full_Interrupt_Set;
