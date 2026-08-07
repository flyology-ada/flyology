package body System.Flyology.Send_ZC_Policy
  with SPARK_Mode
is
   function Plan_Completion
     (Phase             : Completion_Phase;
      Kind              : Completion_Kind;
      More              : Boolean;
      Usage_Reporting   : Boolean;
      Kernel_Used_Copy  : Boolean) return Completion_Plan
   is
      Empty : constant Completion_Plan :=
        (Valid                      => False,
         Phase_After                => Phase,
         Store_Main_Result          => False,
         Emit_Terminal_Result       => False,
         Release_Unused_Reservation => False,
         Note_Copy_Fallback         => False);
   begin
      if Phase = Waiting_For_Main and then Kind = Main_Completion then
         return
           (Valid                      => True,
            Phase_After                =>
              (if More then Waiting_For_Notification else Terminal),
            Store_Main_Result          => True,
            Emit_Terminal_Result       => not More,
            Release_Unused_Reservation => not More,
            Note_Copy_Fallback         => False);
      elsif Phase = Waiting_For_Notification
        and then Kind = Notification_Completion
        and then not More
      then
         return
           (Valid                      => True,
            Phase_After                => Terminal,
            Store_Main_Result          => False,
            Emit_Terminal_Result       => True,
            Release_Unused_Reservation => False,
            Note_Copy_Fallback         =>
              Usage_Reporting and then Kernel_Used_Copy);
      else
         return Empty;
      end if;
   end Plan_Completion;

end System.Flyology.Send_ZC_Policy;
