with Flyology.Subprocesses;

--  Reserved command-line bootstrap for binding a spawned image to the exact
--  coordinator transaction before it reads the control stream.
package Flyology.Process_Generations.Command_Lines is
   --  Reserved authority arguments are absent, duplicated, or malformed.
   Authority_Error : exception;

   --  Append the exact reserved authority arguments to one child command.
   --  @param Item Command to extend
   --  @param Authority Transaction authority encoded as decimal arguments
   procedure Append_Authority
     (Item      : in out Flyology.Subprocesses.Command;
      Authority : Upgrade_Handle);

   --  Read exactly one complete authority from the current process arguments.
   --  @return Parsed transaction authority
   --  @exception Authority_Error Reserved arguments are missing or invalid
   function Read_Authority return Upgrade_Handle;
end Flyology.Process_Generations.Command_Lines;
