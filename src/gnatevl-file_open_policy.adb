package body Gnatevl.File_Open_Policy
  with SPARK_Mode
is
   function Valid
     (Mode     : Access_Mode;
      Truncate : Boolean) return Boolean
   is
     (not (Mode = Read_Only and then Truncate));

   function Access_Flags (Mode : Access_Mode) return C.int is
     (case Mode is
        when Read_Only  => O_RDONLY,
        when Write_Only => O_WRONLY,
        when Read_Write => O_RDWR);

   function Compose
     (Mode     : Access_Mode;
      Create   : Boolean;
      Truncate : Boolean) return C.int
   is
     (Access_Flags (Mode)
      + (if Create then O_CREAT else 0)
      + (if Truncate then O_TRUNC else 0));

end Gnatevl.File_Open_Policy;
