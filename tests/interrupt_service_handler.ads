package Interrupt_Service_Handler is
   protected Handler is
      procedure Handle;
      pragma Interrupt_Handler (Handle);
   end Handler;
end Interrupt_Service_Handler;
