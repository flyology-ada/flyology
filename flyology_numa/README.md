# flyology_numa

Reports the memory-node structure of the host to Ada programs.

A machine with more than one processor package usually attaches memory to
each of them. Memory attached to the package a thread runs on is reached
faster than memory attached to another. This crate reports which memory
nodes the host has, which processors are attached to each, how far apart the
host declares them to be, and which of them the running process may use.

This crate is standalone. It does not depend on the Flyology runtime, and the
runtime does not depend on it.

`Flyology_NUMA` reports the structure. `Flyology_NUMA.Placement` acts on it.

Flyology is experimental. See [Boundaries](#boundaries).

## Reading the host

```ada
with Ada.Text_IO;
with Flyology_NUMA;

procedure Show_Nodes is
   package NUMA renames Flyology_NUMA;
begin
   for Node of NUMA.Allowed_Nodes loop
      Ada.Text_IO.Put_Line
        ("node"  & NUMA.Node_Id'Image (Node)
         & " has" & Natural'Image (NUMA.Count (NUMA.Processors_Of (Node)))
         & " processors");
   end loop;
end Show_Nodes;
```

Every query is answerable on every supported host. A host with no
memory-node structure reports one node holding every processor, because such
a host genuinely has one memory domain. `Support` reports whether the
structure was read from the host or is that single-domain description:

```ada
if NUMA.Support.Source = NUMA.Single_Domain then
   --  Nothing here to place memory across.
   null;
end if;
```

## What the host may not answer

Individual facts can be missing even when the node structure was read. A
query that the host does not answer reports that, rather than a plausible
number:

```ada
type Byte_Query (Available : Boolean := False) is record
   case Available is
      when True  => Bytes : Byte_Count;
      when False => null;
   end case;
end record;
```

`Value_Or` makes the caller name the fallback it wants:

```ada
Size : constant NUMA.Byte_Count :=
  NUMA.Value_Or (NUMA.Memory_Bytes (Node), Fallback => 0);
```

## Online nodes and permitted nodes

`Online_Nodes` reports what the host has. `Allowed_Nodes` reports what this
process may allocate on. They differ when a control group restricts the
process, and **the difference is not visible from the host description
alone**: a container is shown the whole machine's node list while
`cpuset.mems` limits what it may use. `Allowed_Nodes` is the set to act on.

```ada
if NUMA.Support.Restricted then
   --  Fewer nodes are usable than the host has online.
   null;
end if;
```

## Node numbers are the host's own

Node and processor numbers match sysfs paths, `/proc/self/status`, and
`numactl` output, so a number reported here is the number to look up
elsewhere. They are **sparse**: a host with three nodes may number them 0, 2
and 5. Iterate a reported set rather than a numeric range.

## Nodes without processors, and packages without one node

Two structures that older descriptions of NUMA do not cover, and that this
crate reports directly:

- A node may carry memory and have **no processor attached** — a memory
  expander, or a high-bandwidth tier. `Has_Processors` reports false and
  `Processors_Of` returns an empty set. Such a node is a legal target for
  memory but is never local to any thread.
- One processor package may be divided into **several memory nodes**. The
  host then declares a small but non-local distance, such as 11, between two
  nodes of one package. A value above 10 therefore does not mean a different
  package. Compare `Package_Of` when package identity is what matters.

## Placing memory

Reading a description always succeeds. Acting on one often does not, so the
two are separate packages and support is reported before anything is tried:

```ada
case NUMA.Placement.Support is
   when NUMA.Placement.Supported        => null;  --  go ahead
   when NUMA.Placement.Unsupported_Host => null;  --  no such facility here
   when NUMA.Placement.Denied           => null;  --  facility exists, we may not
end case;
```

`Denied` is worth keeping distinct from `Unsupported_Host`. A container
sandbox commonly refuses these calls while the machine underneath has memory
nodes and other processes are using them. Reporting that as "this host has no
NUMA" would be wrong, and it is the failure most easily mistaken for one.

Placement governs where pages come from. It acts on whole pages, so a range
must begin on a `Page_Size` boundary:

```ada
NUMA.Placement.Apply_To
  (Base   => Region_Base,
   Length => Region_Length,
   Policy => NUMA.Placement.Interleaved,
   Nodes  => NUMA.Allowed_Nodes,
   Result => Outcome);
```

`Interleaved` spreads pages over the set in rotation, trading a nearby node's
latency for the combined transfer rate of several — the right choice for
memory every node reads. `Bound` draws only from the set and fails rather
than spilling, which can mean running out of memory while other nodes still
have some. `Preferred` spills instead of failing, but the host's interface
takes a single node there, so only the lowest-numbered node in the set is
preferred; use `Bound` or `Interleaved` to name several.

`Local` and `Unrestricted` take no nodes. Passing a set alongside them is
harmless — it is dropped before the host sees it, because the host rejects a
policy of either kind that arrives carrying one.

Every operation reports an outcome and none of them raise:

```ada
type Placement_Outcome is
  (Applied, Not_Supported, Not_Permitted, Unusable_Nodes,
   Unaligned, Insufficient_Memory, Failed);
```

`Apply_To_Thread` places what the calling thread allocates from then on,
whatever the source. `Node_Of_Address` reports which node holds a page —
but asking about an untouched page causes it to be acquired, because the
host answers by placing it.

## Naming Ada processors

Ada numbers processors from one; hosts number them from zero. GNAT bridges
the two by adding one, without checking that the host's numbering is
consecutive. A host with an offline processor breaks that assumption, and the
arithmetic then names a processor the caller did not intend.

`To_CPU` performs the same mapping and declines when discovery saw numbering
it cannot carry:

```ada
CPU : constant System.Multiprocessors.CPU_Range := NUMA.To_CPU (Processor);
--  Not_A_Specific_CPU when the host's processor numbers have a gap.
```

## Boundaries

- **Memory, not threads.** Placement governs where pages come from. It does
  not move a running thread; a thread is placed with the `CPU` aspect or a
  dispatching domain, using the processors reported for a node.
- **Later allocations.** `Apply_To` governs the pages a range acquires from
  then on. Pages it already holds stay where they are unless `Move` is
  requested, and moving pages shared with another process needs privileges
  this process may not have.
- **Read once.** Discovery runs while the package elaborates and is kept for
  the life of the process. Nodes added or removed afterwards are not seen.
- **Linux and macOS.** Linux is read from `/sys/devices/system/node` and
  `/proc/self/status`, and placed through the kernel's memory-policy calls.
  Those calls have no C library wrapper, and their numbers differ per
  architecture — the x86-64 table and the table newer architectures share
  disagree on the order of the policy calls — so an architecture whose
  numbers this crate does not record reports `Unsupported_Host` rather than
  calling by a number borrowed from elsewhere. x86-64, AArch64 and RISC-V 64
  are recorded.
- **macOS reports one node and places nothing.** It describes no
  memory-node structure and offers no way to draw memory from a chosen part
  of the machine. The performance and efficiency processor clusters it does
  describe are not memory nodes — they share one memory domain — and are not
  reported here.
- **Limits.** Nodes above 63 and processors above 4095 are not represented.
  A host that exceeds either reports `Support.Complete` as false, so a
  partial answer can be told apart from a whole one.
- **Distances are ordinal.** They order node pairs. They are declared by
  firmware, are not latencies, and are frequently declared poorly.

## Build and test

```sh
alr build
```

```sh
./scripts/test.sh
```

The suite has two parts. One checks the description reported for the host
running the tests, against invariants every host must satisfy. The other
reads recorded host descriptions from `tests/fixtures/` — two packages of
one node each, two packages each divided into two nodes, a node with no
processor, sparse node numbering, a control-group restriction, a gap in
processor numbering, and several descriptions this crate must refuse or
report as incomplete.

The recorded descriptions matter because the interesting cases cannot be
reached otherwise: a development machine has one node, and a container on
one is single-node too. Reading them keeps node numbering, distance-row
alignment, and restriction handling under test on every host rather than
only on hardware that happens to have them.
