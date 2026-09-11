with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;
with Flyology;
with Flyology.Subprocesses;
with Flyology.Subprocesses.Capture;
with Interfaces.C;

procedure Linux_Poller_Cloexec_Smoke is
   package C renames Interfaces.C;
   package Capture renames Flyology.Subprocesses.Capture;
   package Subprocesses renames Flyology.Subprocesses;

   use type C.int;

   function Eventpoll_FD_Count return C.int;
   pragma
     Import (C, Eventpoll_FD_Count, "flyology_test_linux_eventpoll_fd_count");

   function Eventfd_FD_Count return C.int;
   pragma Import (C, Eventfd_FD_Count, "flyology_test_linux_eventfd_fd_count");

   function Executable return String is
   begin
      return Ada.Directories.Full_Name (Ada.Command_Line.Command_Name);
   end Executable;

begin
   if Ada.Command_Line.Argument_Count = 1
     and then Ada.Command_Line.Argument (1) = "inspect"
   then
      declare
         Eventpoll_Count : constant C.int := Eventpoll_FD_Count;
         Eventfd_Count   : constant C.int := Eventfd_FD_Count;
      begin
         if Eventpoll_Count < 0 or else Eventfd_Count < 0 then
            raise Program_Error
              with "failed to inspect Linux process descriptors";
         end if;
         Ada.Text_IO.Put_Line
           ("eventpoll="
            & C.int'Image (Eventpoll_Count)
            & " eventfd="
            & C.int'Image (Eventfd_Count));
      end;
      return;
   end if;

   declare
      task Lightweight is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Lightweight;

      task body Lightweight is
      begin
         null;
      end Lightweight;

      Command : Subprocesses.Command := Subprocesses.To_Command (Executable);
      Result  : Capture.Result;
   begin
      Subprocesses.Append_Argument (Command, "inspect");
      Result :=
        Capture.Run
          (Command,
           Maximum_Output => 128,
           Maximum_Error  => 128,
           Timeout        => 10.0);

      if not Subprocesses.Successful (Capture.Status (Result)) then
         raise Program_Error
           with
             "descriptor inspection child failed: "
             & Capture.Standard_Error (Result);
      elsif Capture.Standard_Output (Result)
        /= "eventpoll= 0 eventfd= 0" & ASCII.LF
      then
         raise Program_Error
           with
             "runtime descriptor inherited across exec: "
             & Capture.Standard_Output (Result);
      end if;
   end;
end Linux_Poller_Cloexec_Smoke;
