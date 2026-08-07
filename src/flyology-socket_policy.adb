package body Flyology.Socket_Policy
  with SPARK_Mode => On
is
   function Family_Code (IPv6 : Boolean) return C.int is
     (if IPv6 then 6 else 4);

   function Mode_Code (Datagram : Boolean) return C.int is
     (if Datagram then 2 else 1);

   function Classify_Error
     (Error_Code                : C.int;
      Would_Block_Error        : C.int;
      Interrupted_Error        : C.int;
      In_Progress_Error        : C.int;
      Already_In_Progress_Error : C.int;
      Already_Connected_Error  : C.int;
      No_Buffer_Space_Error    : C.int) return Error_Kind
   is
   begin
      if Error_Code = 0 then
         return Success;
      elsif Error_Code = Would_Block_Error then
         return Would_Block;
      elsif Error_Code = Interrupted_Error then
         return Interrupted;
      elsif Error_Code = In_Progress_Error then
         return In_Progress;
      elsif Error_Code = Already_In_Progress_Error then
         return Already_In_Progress;
      elsif Error_Code = Already_Connected_Error then
         return Already_Connected;
      elsif Error_Code = No_Buffer_Space_Error then
         return No_Buffer_Space;
      else
         return Other_Error;
      end if;
   end Classify_Error;

   function Classify_IO_Error (Kind : Error_Kind) return IO_Error_Action is
   begin
      case Kind is
         when Would_Block =>
            return Wait_For_Ready;
         when Interrupted =>
            return Retry_Operation;
         when others =>
            return Fail_Operation;
      end case;
   end Classify_IO_Error;

   function Classify_Connect_Error
     (Kind : Error_Kind) return Connect_Error_Action
   is
   begin
      case Kind is
         when Interrupted | In_Progress | Already_In_Progress =>
            return Wait_For_Connection;
         when Already_Connected =>
            return Connected;
         when others =>
            return Fail_Connect;
      end case;
   end Classify_Connect_Error;

end Flyology.Socket_Policy;
