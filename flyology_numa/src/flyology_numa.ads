--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with System.Multiprocessors;

--  Reports the memory-node structure of the host.
--
--  Node and processor numbers are the host's own. They match sysfs paths,
--  /proc/self/status, and numactl output, and they are sparse: a host with
--  three nodes may number them 0, 2, and 5. Iterate a reported set rather
--  than a numeric range.
--
--  Every query here is total. A host with no memory-node structure reports
--  one node holding every processor, because a host whose memory is uniform
--  genuinely has one memory domain. Placement is a separate question that
--  this package does not answer.
--
--  A process may be permitted fewer nodes than the host has online. Reading
--  the host's description does not establish permission, because a container
--  sees the whole host description while a control group restricts what it
--  may use. Allowed_Nodes reports the usable set and Online_Nodes reports the
--  host's set.
--
--  Discovery runs once, while this package elaborates, and is kept for the
--  life of the process. Nodes that appear or disappear afterwards are not
--  observed. Discovery reads host description files and raises nothing: a
--  host that answers nothing is reported as one node.
package Flyology_NUMA is

   --  Highest memory-node number this package represents.
   Max_Node : constant := 63;

   --  Highest logical-processor number this package represents.
   Max_Processor : constant := 4095;

   --  Memory-node number as reported by the host.
   type Node_Id is range 0 .. Max_Node;

   --  Logical-processor number as reported by the host, counting from zero.
   type Processor_Id is range 0 .. Max_Processor;

   --  Relative access cost between two nodes, as declared by host firmware.
   --
   --  Ten names a node's distance to itself. The values order node pairs and
   --  are not latencies. Firmware declares them and often declares them
   --  poorly. A host that divides one processor package into several nodes
   --  reports small non-local values such as 11, so a value above ten does
   --  not mean a different package. Compare Package_Of for package identity.
   type Distance is range 0 .. 255;

   --  A quantity of bytes.
   type Byte_Count is range 0 .. 2 ** 62 - 1;

   ---------------------------------------------------------------------
   --  Query results
   ---------------------------------------------------------------------

   --  Result of a node query the host may not answer.
   --
   --  @field Available True when the host supplied a node.
   --  @field Node The reported memory node.
   type Node_Query (Available : Boolean := False) is record
      case Available is
         when True =>
            Node : Node_Id;
         when False =>
            null;
      end case;
   end record;

   --  A node query with no host answer.
   No_Node : constant Node_Query := (Available => False);

   --  Result of a byte-quantity query the host may not answer.
   --
   --  @field Available True when the host supplied a quantity.
   --  @field Bytes The reported quantity in bytes.
   type Byte_Query (Available : Boolean := False) is record
      case Available is
         when True =>
            Bytes : Byte_Count;
         when False =>
            null;
      end case;
   end record;

   --  A byte-quantity query with no host answer.
   No_Bytes : constant Byte_Query := (Available => False);

   --  Result of a distance query the host may not answer.
   --
   --  @field Available True when the host supplied a distance.
   --  @field Value The reported distance.
   type Distance_Query (Available : Boolean := False) is record
      case Available is
         when True =>
            Value : Distance;
         when False =>
            null;
      end case;
   end record;

   --  A distance query with no host answer.
   No_Distance : constant Distance_Query := (Available => False);

   --  Result of a plain numeric query the host may not answer.
   --
   --  @field Available True when the host supplied a value.
   --  @field Value The reported value.
   type Value_Query (Available : Boolean := False) is record
      case Available is
         when True =>
            Value : Natural;
         when False =>
            null;
      end case;
   end record;

   --  A numeric query with no host answer.
   No_Value : constant Value_Query := (Available => False);

   --  Explicitly choose a fallback for an unanswered byte query.
   --  @param Result The query result to inspect.
   --  @param Fallback The quantity to return when Result is unanswered.
   --  @return Result.Bytes when available, otherwise Fallback.
   function Value_Or
     (Result   : Byte_Query;
      Fallback : Byte_Count) return Byte_Count;

   --  Explicitly choose a fallback for an unanswered distance query.
   --  @param Result The query result to inspect.
   --  @param Fallback The distance to return when Result is unanswered.
   --  @return Result.Value when available, otherwise Fallback.
   function Value_Or
     (Result   : Distance_Query;
      Fallback : Distance) return Distance;

   --  Explicitly choose a fallback for an unanswered numeric query.
   --  @param Result The query result to inspect.
   --  @param Fallback The value to return when Result is unanswered.
   --  @return Result.Value when available, otherwise Fallback.
   function Value_Or
     (Result   : Value_Query;
      Fallback : Natural) return Natural;

   ---------------------------------------------------------------------
   --  Sets
   ---------------------------------------------------------------------

   --  Position of a node within a node set iteration.
   subtype Node_Cursor is Natural range 0 .. Max_Node + 1;

   --  Position of a processor within a processor set iteration.
   subtype Processor_Cursor is Natural range 0 .. Max_Processor + 1;

   --  A set of memory nodes.
   --
   --  Iterating a node set visits its members in increasing node order.
   type Node_Set is private
     with Iterable => (First       => First,
                       Next        => Next,
                       Has_Element => Has_Element,
                       Element     => Element);

   --  A set of logical processors.
   --
   --  Iterating a processor set visits its members in increasing processor
   --  order.
   type Processor_Set is private
     with Iterable => (First       => First,
                       Next        => Next,
                       Has_Element => Has_Element,
                       Element     => Element);

   --  Report whether Node belongs to Set.
   --  @param Set The set to inspect.
   --  @param Node The node to look for.
   --  @return True when Node belongs to Set.
   function Contains (Set : Node_Set; Node : Node_Id) return Boolean;

   --  Report whether Processor belongs to Set.
   --  @param Set The set to inspect.
   --  @param Processor The processor to look for.
   --  @return True when Processor belongs to Set.
   function Contains
     (Set : Processor_Set; Processor : Processor_Id) return Boolean;

   --  Return the number of nodes in Set.
   --  @param Set The set to inspect.
   --  @return The member count.
   function Count (Set : Node_Set) return Natural;

   --  Return the number of processors in Set.
   --  @param Set The set to inspect.
   --  @return The member count.
   function Count (Set : Processor_Set) return Natural;

   --  Return the first position in a node set iteration.
   --  @param Set The set being iterated.
   --  @return The position of the lowest-numbered member.
   --  @exclude
   function First (Set : Node_Set) return Node_Cursor;

   --  Advance a node set iteration.
   --  @param Set The set being iterated.
   --  @param Position The current position.
   --  @return The position of the next member.
   --  @exclude
   function Next (Set : Node_Set; Position : Node_Cursor) return Node_Cursor;

   --  Report whether a node set iteration has a member at Position.
   --  @param Set The set being iterated.
   --  @param Position The position to test.
   --  @return True while the iteration has a member.
   --  @exclude
   function Has_Element
     (Set : Node_Set; Position : Node_Cursor) return Boolean;

   --  Return the node at Position.
   --
   --  Reading a position that Has_Element rejects is meaningless: a position
   --  past the last member raises Constraint_Error, and a position that is
   --  simply not a member reports itself.
   --  @param Set The set being iterated.
   --  @param Position The position to read.
   --  @return The member node.
   --  @exclude
   function Element (Set : Node_Set; Position : Node_Cursor) return Node_Id;

   --  Return the first position in a processor set iteration.
   --  @param Set The set being iterated.
   --  @return The position of the lowest-numbered member.
   --  @exclude
   function First (Set : Processor_Set) return Processor_Cursor;

   --  Advance a processor set iteration.
   --  @param Set The set being iterated.
   --  @param Position The current position.
   --  @return The position of the next member.
   --  @exclude
   function Next
     (Set : Processor_Set; Position : Processor_Cursor)
      return Processor_Cursor;

   --  Report whether a processor set iteration has a member at Position.
   --  @param Set The set being iterated.
   --  @param Position The position to test.
   --  @return True while the iteration has a member.
   --  @exclude
   function Has_Element
     (Set : Processor_Set; Position : Processor_Cursor) return Boolean;

   --  Return the processor at Position.
   --  @param Set The set being iterated.
   --  @param Position The position to read.
   --  @return The member processor.
   --  @exclude
   function Element
     (Set : Processor_Set; Position : Processor_Cursor) return Processor_Id;

   ---------------------------------------------------------------------
   --  Discovery outcome
   ---------------------------------------------------------------------

   --  How the reported node structure was established.
   --
   --  @enum Host_Report The host described its own memory nodes.
   --  @enum Single_Domain The host describes no memory-node structure, so
   --     one node holding every processor is reported.
   type Discovery_Source is (Host_Report, Single_Domain);

   --  What discovery established about this host and this process.
   --
   --  @field Source How the node structure was established.
   --  @field Restricted True when this process may use fewer nodes than the
   --     host has online, which a control-group memory-node restriction
   --     causes.
   --  @field Complete True when the host's whole description was read and
   --     represented. A false value means some part of it was not: numbers
   --     above Max_Node or Max_Processor, a list naming more ranges than
   --     this package holds, or a description this package could not parse.
   --     The reported sets are then partial rather than wrong.
   --  @field Consecutive_Processors True when the host numbers its
   --     processors consecutively from zero. To_CPU answers only then.
   type Support_Report is record
      Source                : Discovery_Source;
      Restricted            : Boolean;
      Complete              : Boolean;
      Consecutive_Processors : Boolean;
   end record;

   --  Return what discovery established about this host.
   --  @return The discovery outcome.
   function Support return Support_Report;

   ---------------------------------------------------------------------
   --  Topology
   ---------------------------------------------------------------------

   --  Return the memory nodes the host reports as online.
   --  @return The host's online node set, never empty.
   function Online_Nodes return Node_Set;

   --  Return the memory nodes this process may allocate on.
   --
   --  This is the set to act on. It is a subset of Online_Nodes and is
   --  smaller when a control group restricts the process.
   --  @return The usable node set, never empty.
   function Allowed_Nodes return Node_Set;

   --  Return the number of memory nodes the host reports as online.
   --  @return The online node count, at least one.
   function Node_Count return Positive;

   --  Return the processors attached to Node.
   --
   --  The set is empty for a node that carries memory but no processor,
   --  which a memory expander or a high-bandwidth memory tier produces.
   --  @param Node The node to inspect.
   --  @return The node's processor set, possibly empty.
   function Processors_Of (Node : Node_Id) return Processor_Set;

   --  Return the node Processor belongs to.
   --  @param Processor The processor to inspect.
   --  @return The processor's node, or No_Node when the host does not say.
   function Node_Of (Processor : Processor_Id) return Node_Query;

   --  Return the memory Node carries.
   --  @param Node The node to inspect.
   --  @return The node's memory in bytes, or No_Bytes.
   function Memory_Bytes (Node : Node_Id) return Byte_Query;

   --  Return the firmware-declared distance from one node to another.
   --  @param From The node being measured from.
   --  @param To The node being measured to.
   --  @return The declared distance, or No_Distance.
   function Node_Distance (From : Node_Id; To : Node_Id) return Distance_Query;

   --  Return the processor package Node's processors sit on.
   --
   --  Two nodes sharing a package number are two memory domains of one
   --  processor package. This is the reliable way to tell that apart from
   --  two packages, because firmware-declared distances do not distinguish
   --  the cases consistently.
   --  @param Node The node to inspect.
   --  @return The package number, or No_Value when the node has no processor
   --     attached or the host does not name the package of the one it has.
   function Package_Of (Node : Node_Id) return Value_Query;

   --  Report whether the host lists Node as online.
   --  @param Node The node to test.
   --  @return True when the host lists Node as online.
   function Is_Online (Node : Node_Id) return Boolean;

   --  Report whether this process may allocate on Node.
   --  @param Node The node to test.
   --  @return True when Node is available to this process.
   function Is_Allowed (Node : Node_Id) return Boolean;

   --  Report whether Node carries memory.
   --  @param Node The node to test.
   --  @return True when Node carries memory.
   function Has_Memory (Node : Node_Id) return Boolean;

   --  Report whether Node has any processor attached.
   --  @param Node The node to test.
   --  @return True when at least one processor is attached to Node.
   function Has_Processors (Node : Node_Id) return Boolean;

   ---------------------------------------------------------------------
   --  Ada interoperation
   ---------------------------------------------------------------------

   --  Return the Ada processor number that names Processor.
   --
   --  Ada numbers processors from one and the host numbers them from zero,
   --  so the mapping is Processor + 1. GNAT applies that arithmetic without
   --  checking it, which is correct only while the host numbers its
   --  processors consecutively from zero. A host with an offline processor
   --  breaks that, and the arithmetic then names a processor the caller did
   --  not intend.
   --
   --  This function returns Not_A_Specific_CPU when discovery saw processor
   --  numbering that the mapping cannot carry, so that a caller pinning a
   --  task can tell the difference instead of pinning to the wrong place.
   --  @param Processor The host processor number to convert.
   --  @return The Ada processor number, or Not_A_Specific_CPU.
   function To_CPU
     (Processor : Processor_Id) return System.Multiprocessors.CPU_Range;

private

   Bits_Per_Word : constant := 64;

   type Word is mod 2 ** Bits_Per_Word;

   Node_Word_Count      : constant := (Max_Node / Bits_Per_Word) + 1;
   Processor_Word_Count : constant := (Max_Processor / Bits_Per_Word) + 1;

   type Node_Words is array (0 .. Node_Word_Count - 1) of Word;
   type Processor_Words is array (0 .. Processor_Word_Count - 1) of Word;

   type Node_Set is record
      Bits : Node_Words := (others => 0);
   end record;

   type Processor_Set is record
      Bits : Processor_Words := (others => 0);
   end record;

   Empty_Nodes      : constant Node_Set := (Bits => (others => 0));
   Empty_Processors : constant Processor_Set := (Bits => (others => 0));

   type Distance_Row is array (Node_Id) of Distance_Query;

   No_Distances : constant Distance_Row := (others => (Available => False));

   --  Everything discovery established about one node.
   type Node_Facts is record
      Processors : Processor_Set := Empty_Processors;
      Memory     : Byte_Query    := No_Bytes;
      Packaging  : Value_Query   := No_Value;
      Distances  : Distance_Row  := No_Distances;
   end record;

   type Node_Facts_Array is array (Node_Id) of Node_Facts;

   type Processor_Nodes is array (Processor_Id) of Node_Query;

   No_Processor_Nodes : constant Processor_Nodes :=
     (others => (Available => False));

   --  Everything discovery established about the host.
   type Machine_Facts is record
      Source                 : Discovery_Source := Single_Domain;
      Restricted             : Boolean          := False;
      Complete               : Boolean          := True;
      Consecutive_Processors : Boolean          := True;
      Online                 : Node_Set         := Empty_Nodes;
      Allowed                : Node_Set         := Empty_Nodes;
      With_Memory            : Node_Set         := Empty_Nodes;
      Nodes                  : Node_Facts_Array;
      Owner                  : Processor_Nodes  := No_Processor_Nodes;
   end record;

end Flyology_NUMA;
