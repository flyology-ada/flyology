package body System.Flyology.ASan is
   Switching_From : System.Address := System.Null_Address;
   pragma Thread_Local_Storage (Switching_From);

   procedure Sanitizer_Start_Switch_Fiber
     (Fake_Stack_Save    : System.Address;
      Destination_Bottom : System.Address;
      Destination_Size   : Interfaces.C.size_t);
   pragma Import (C, Sanitizer_Start_Switch_Fiber, "__sanitizer_start_switch_fiber");

   procedure Sanitizer_Finish_Switch_Fiber
     (Fake_Stack_Save : System.Address;
      Source_Bottom   : access System.Address;
      Source_Size     : access Interfaces.C.size_t);
   pragma Import (C, Sanitizer_Finish_Switch_Fiber, "__sanitizer_finish_switch_fiber");

   procedure Start_Switch
     (Source_Context     : System.Address;
      Destination_Bottom : System.Address;
      Destination_Size   : Interfaces.C.size_t) is
   begin
      if Source_Context = System.Null_Address or else Switching_From /= System.Null_Address then
         raise Program_Error with "nested Flyology ASan fiber switch";
      end if;
      Switching_From := Source_Context;
      --  A fake-stack handle is intentionally not saved. ASan fake stacks
      --  belong to an OS thread, while Flyology permits a task context to move
      --  to another event-loop pthread. LLVM documents null handles as the
      --  supported mode when stack-use-after-return tracking is not required.
      Sanitizer_Start_Switch_Fiber (System.Null_Address, Destination_Bottom, Destination_Size);
   end Start_Switch;

   procedure Finish_Switch
     (Source_Context : out System.Address;
      Source_Bottom  : out System.Address;
      Source_Size    : out Interfaces.C.size_t)
   is
      Bottom : aliased System.Address := System.Null_Address;
      Size   : aliased Interfaces.C.size_t := 0;
   begin
      if Switching_From = System.Null_Address then
         raise Program_Error with "Flyology ASan switch has no source context";
      end if;
      Sanitizer_Finish_Switch_Fiber (System.Null_Address, Bottom'Access, Size'Access);
      Source_Context := Switching_From;
      Switching_From := System.Null_Address;
      Source_Bottom := Bottom;
      Source_Size := Size;
   end Finish_Switch;
end System.Flyology.ASan;
