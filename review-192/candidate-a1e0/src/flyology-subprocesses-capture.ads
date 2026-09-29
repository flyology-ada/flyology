with Flyology.Cancellation;
with Ada.Strings.Unbounded;

--  Runs a subprocess while concurrently draining bounded stdout and
--  stderr.
--  Bytes beyond each retained bound are discarded until EOF, so truncation
--  cannot fill a child pipe and deadlock the command. Timeout or cancellation
--  attempts hard structured cleanup and closes the parent descriptors before
--  propagating the corresponding exception. Cleanup failures are suppressed
--  in favor of that original exception. Cleanup is not part of the
--  command-progress deadline and can delay exception delivery.

package Flyology.Subprocesses.Capture is

   --  Complete bounded command result.
   type Result is private;

   --  Run Item with optional stdin bytes and bounded output retention. The
   --  child stdin, stdout, and stderr pipes are progressed together; large
   --  input therefore cannot deadlock against simultaneous child output. If
   --  the child closes stdin before consuming the complete payload, Run ends
   --  the input phase and continues collecting output and exit status.
   --  @param Item Typed command to spawn
   --  @param Standard_Input Complete stdin payload; EOF follows the payload
   --  @param Maximum_Output Maximum retained stdout bytes
   --  @param Maximum_Error Maximum retained stderr bytes
   --  @param Timeout Shared monotonic command-progress deadline in seconds;
   --     negative is unlimited, synchronous spawn cannot be interrupted, and
   --     structured cleanup can extend return time
   --  @param Token Optional cancellation source that must outlive the call
   --  @return Reaped status and bounded output
   --  @exception Spawn_Error Command cannot be spawned
   --  @exception Timeout_Error The shared deadline expires
   --  @exception Operation_Cancelled Token is requested
   --  @exception Process_Error Process cleanup or observation fails
   --  @exception Pipe_Error Standard-stream progress fails
   --  @exception Device_Error Readiness polling fails
   function Run
     (Item           : Command;
      Standard_Input : String := "";
      Maximum_Output : Natural := 64 * 1_024;
      Maximum_Error  : Natural := 64 * 1_024;
      Timeout        : Duration := 30.0;
      Token          : access Flyology.Cancellation.Token := null) return Result;

   --  Return the root process status.
   --  @param Item Completed capture result
   --  @return Reaped exit status
   function Status (Item : Result) return Exit_Status;

   --  Return retained stdout bytes.
   --  @param Item Completed capture result
   --  @return At most Maximum_Output bytes
   function Standard_Output (Item : Result) return String;

   --  Return retained stderr bytes.
   --  @param Item Completed capture result
   --  @return At most Maximum_Error bytes
   function Standard_Error (Item : Result) return String;

   --  Report whether stdout exceeded its retention bound.
   --  @param Item Completed capture result
   --  @return True when stdout bytes were drained and discarded
   function Output_Truncated (Item : Result) return Boolean;

   --  Report whether stderr exceeded its retention bound.
   --  @param Item Completed capture result
   --  @return True when stderr bytes were drained and discarded
   function Error_Truncated (Item : Result) return Boolean;

private
   type Result is record
      Child_Status   : Exit_Status;
      Output_State   : Ada.Strings.Unbounded.Unbounded_String;
      Error_State    : Ada.Strings.Unbounded.Unbounded_String;
      Output_Was_Cut : Boolean := False;
      Error_Was_Cut  : Boolean := False;
   end record;

end Flyology.Subprocesses.Capture;
