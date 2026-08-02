with Interfaces.C;
with Gnatevl_Config;

private package Gnatevl.File_Open_Policy
  with SPARK_Mode
is
   package C renames Interfaces.C;

   use type C.int;

   type Access_Mode is (Read_Only, Write_Only, Read_Write);

   Is_Darwin : constant Boolean := Gnatevl_Config.Alire_Host_OS = "macos";
   Is_Linux  : constant Boolean := Gnatevl_Config.Alire_Host_OS = "linux";
   pragma Assert
     (Is_Darwin or Is_Linux, "unsupported GNATEVL host OS");

   O_RDONLY : constant C.int := 16#0000#;
   O_WRONLY : constant C.int := 16#0001#;
   O_RDWR   : constant C.int := 16#0002#;
   O_CREAT  : constant C.int :=
     (if Is_Linux then 16#0040# else 16#0200#);
   O_TRUNC  : constant C.int :=
     (if Is_Linux then 16#0200# else 16#0400#);

   function Valid
     (Mode     : Access_Mode;
      Truncate : Boolean) return Boolean
   with Inline,
        Post =>
          Valid'Result = not (Mode = Read_Only and then Truncate);

   function Access_Flags (Mode : Access_Mode) return C.int
   with Inline,
        Post =>
          Access_Flags'Result =
            (case Mode is
               when Read_Only  => O_RDONLY,
               when Write_Only => O_WRONLY,
               when Read_Write => O_RDWR);

   function Compose
     (Mode     : Access_Mode;
      Create   : Boolean;
      Truncate : Boolean) return C.int
   with Pre  => Valid (Mode, Truncate),
        Post =>
          Compose'Result =
            Access_Flags (Mode)
            + (if Create then O_CREAT else 0)
            + (if Truncate then O_TRUNC else 0);

end Gnatevl.File_Open_Policy;
