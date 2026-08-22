package System.Flyology.Send_ZC_Policy
  with Preelaborate, SPARK_Mode
is
   type Completion_Phase is (Waiting_For_Main, Waiting_For_Notification, Terminal);
   type Completion_Kind is (Main_Completion, Notification_Completion);

   type Completion_Plan is record
      Valid                      : Boolean;
      Phase_After                : Completion_Phase;
      Store_Main_Result          : Boolean;
      Emit_Terminal_Result       : Boolean;
      Release_Unused_Reservation : Boolean;
      Note_Copy_Fallback         : Boolean;
   end record;

   --  SEND_ZC owns its buffer until a main CQE without MORE or the following
   --  notification CQE. The second CQ slot is reserved before submission and
   --  is released explicitly when MORE is absent. Copy-fallback accounting is
   --  meaningful only when the submission requested kernel usage reporting.
   function Plan_Completion
     (Phase            : Completion_Phase;
      Kind             : Completion_Kind;
      More             : Boolean;
      Usage_Reporting  : Boolean;
      Kernel_Used_Copy : Boolean) return Completion_Plan
   with
     Global => null,
     Post   =>
       (if Phase = Waiting_For_Main and then Kind = Main_Completion
        then
          Plan_Completion'Result.Valid
          and then Plan_Completion'Result.Store_Main_Result
          and then (if More
                    then
                      Plan_Completion'Result.Phase_After = Waiting_For_Notification
                      and then not Plan_Completion'Result.Emit_Terminal_Result
                      and then not Plan_Completion'Result.Release_Unused_Reservation
                    else
                      Plan_Completion'Result.Phase_After = Terminal
                      and then Plan_Completion'Result.Emit_Terminal_Result
                      and then Plan_Completion'Result.Release_Unused_Reservation)
        elsif Phase = Waiting_For_Notification and then Kind = Notification_Completion and then not More
        then
          Plan_Completion'Result.Valid
          and then Plan_Completion'Result.Phase_After = Terminal
          and then Plan_Completion'Result.Emit_Terminal_Result
          and then not Plan_Completion'Result.Store_Main_Result
          and then Plan_Completion'Result.Note_Copy_Fallback = (Usage_Reporting and then Kernel_Used_Copy)
        else not Plan_Completion'Result.Valid);

end System.Flyology.Send_ZC_Policy;
