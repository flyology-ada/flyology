# The host CPU lock convention

`host-cpu-lock/1`

An advisory, cross-tool way for processes that need exclusive CPU capacity on a
machine to avoid running at the same time.

This document specifies the convention so that tools other than
`flyology_bench` can implement it. It is a proposal, not an established
standard: no widely used benchmark runner implements anything like it today.

## What the convention is for

Two kinds of tool want the same thing from opposite directions. A benchmark,
a profiler, or a latency measurement needs the machine quiet. A load
generator, a soak test, or a stress run makes the machine loud. Both should
take the same claim, which is why the convention is named for the resource
rather than for benchmarking.

Two measurement runs that share a machine produce two wrong answers. Worse,
two runs that each pause when they detect interference will oscillate against
each other indefinitely, because each is the other's interference. A shared
claim removes that failure mode at the source.

## What it does not provide

A claim is not proof of exclusivity, and an implementation must not present it
as one.

- It coordinates only with processes that reach the same file. A compile, a
  browser, or a container build is unaffected.
- It says nothing about contention for shared cache or memory bandwidth.
- A privately mounted claim path silently reduces the claim's scope to one
  mount namespace. See [Path isolation](#path-isolation).

## Paths

```
/tmp/host-cpu.lock          the machine's whole CPU capacity
/tmp/host-cpu.<N>.lock      logical CPU N, zero-based
```

An implementation resolves the machine path in this order, taking the first
that is set and non-empty:

1. Its own tool-specific override, if it defines one.
2. The environment variable `HOST_CPU_LOCK_PATH`.
3. `/tmp/host-cpu.lock`.

The per-CPU path is derived from the machine path by removing a trailing
`.lock`, appending `.` and the decimal CPU number, and restoring the suffix.
A machine path without a `.lock` suffix simply gains `.` and the number.

Future resource classes extend the same shape: `host-<resource>[.<index>].lock`.

### Why a single default and no fallback chain

A convention only works when every tool computes the same path. A chain such
as "`/run/lock` when writable, otherwise `/tmp`" reintroduces exactly the
failure it was meant to prevent: `/run/lock` is mode `1777` on Debian and
root-owned `0755` on Red Hat derivatives, so a root process and an
unprivileged process on one machine would probe differently, land on different
files, and each conclude it holds the machine.

`/tmp` is mode `1777` on both Linux and macOS, which lets any user create the
file, and it is local, which matters because `flock` over NFS is unreliable.
The path must be on a local filesystem.

### Do not use `$TMPDIR`

The usual portable answer for temporary files is wrong here. The convention
needs a *shared* location; `$TMPDIR` is deliberately private. On macOS it
points into a per-user directory under `/var/folders`, so honoring it would
give every user a private claim and silently serialize nothing.

### Where `/tmp` is unusable

`/tmp` is not universal, and an implementation must document what it does in
each case rather than crashing or pretending it holds a claim:

- **Absent.** Container images built `FROM scratch` have no `/tmp`.
- **Read-only.** A read-only root filesystem leaves `/tmp` present but
  unwritable unless a writable volume is mounted over it.
- **Not at the FHS location.** Android and Termux place it under a prefix.

In all three the claim cannot be taken. The path override exists for these
hosts.

## Protocol

Conflict detection is `flock` and nothing else. Liveness is the lock itself:
a holder that dies releases its claim with no cleanup path, no stale entries,
and no pid-reuse hazard. `fcntl` locks must not be used, because closing any
descriptor to the file drops every lock the process holds on it.

**Claiming the whole machine** — take `LOCK_EX` on the machine file.

**Claiming individual CPUs** — take `LOCK_SH` on the machine file, then
`LOCK_EX` on the file for each claimed CPU.

The shared/exclusive split is what makes disjoint claims coexist: two
core-scoped runs on non-overlapping CPUs both hold the machine file shared and
proceed, while a machine-wide run excludes both. No registry and no arbiter is
involved.

### Rules

- **Acquire per-CPU claims in ascending CPU order.** A total order is what
  stops two callers with overlapping sets from deadlocking on each other's
  partial claims.
- **Release everything on failure.** A caller that cannot complete its claim
  must drop the parts it took before reporting a conflict.
- **Never unlink a claim file.** Unlink-then-recreate races let two processes
  hold locks on different inodes while both believe they hold the same claim.
  The files are a few bytes and are meant to persist.
- **Wait idle.** A caller blocked on a claim must not spin, or it becomes the
  competing load it is waiting out.
- **Claim the whole watched set.** A core-scoped claim must cover every CPU
  whose behavior affects the measurement, which includes SMT siblings.
  Claiming CPU 3 without its sibling CPU 11 permits concurrency that degrades
  both runs while appearing to have worked.

### File creation

Create with `O_RDWR | O_CREAT`, mode `0666`, and set the mode again after
creation. A restrictive umask in whichever process created the file first
would otherwise lock every other user out of the convention, and being unable
to open the file is indistinguishable from finding it free.

`O_NOFOLLOW` is recommended. `/tmp` is world-writable, so a local user can
create the file first or hold the claim indefinitely; this is not a meaningful
escalation, because that user could equally just consume the CPU.

## File content

Content is diagnostic. It is written after the claim is taken and is **never**
consulted to decide whether claims conflict.

```
convention=host-cpu-lock/1
spec=https://github.com/flyology-ada/flyology/blob/main/docs/host-cpu-lock.md
tool=flyology_bench
pid=48213
started=2026-08-19T14:03:11Z
claim=all
cwd=/home/me/src/flyology
```

### Grammar

One `key=value` pair per line, split on the first `=`. Keys match
`[a-z][a-z0-9_]*`. Values are UTF-8 with `CR`, `LF`, and `%` percent-encoded
as `%0D`, `%0A`, and `%25`; no other escaping applies, so a value may contain
spaces. Unknown keys are ignored, which is how later revisions stay readable
by earlier parsers.

One pair per line rather than space-separated pairs is deliberate: `cwd` can
contain spaces, and a grammar with no quoting rules is one that every
implementer gets right. A conforming file can be produced by `printf` and read
by `awk -F=`.

### Keys

| Key | Meaning |
| --- | --- |
| `convention` | Convention identifier, `host-cpu-lock/1`. |
| `spec` | URL of this document, so the file is self-describing. |
| `tool` | Program holding the claim. |
| `pid` | Holder's process identifier. |
| `started` | Acquisition time, ISO 8601 UTC. |
| `claim` | `all`, or a comma-separated list of logical CPUs. |
| `cwd` | Holder's working directory when it acquired. |

`cwd` is what distinguishes one checkout or CI workspace from another when
several run on the same host; `tool` and `pid` alone do not.

### Reading

Readers open the file **without locking**. Taking a shared lock to read would
block behind the holder, which is the one process the reader is trying to
name.

A reader must therefore tolerate content that is empty, stale, or partial:

- Content is written after the lock is taken, so there is a window in which
  the file is empty.
- A holder that died mid-write leaves a truncated line.
- `cwd` is a snapshot; the holder may have changed directory since.

Because the content is untrusted, a reader should extract only the keys it
knows rather than echoing the file, so that pointing the path at an unrelated
file discloses nothing.

## Path isolation

A claim can be taken successfully and still cover only part of the machine.

`systemd PrivateTmp=` bind-mounts a per-service directory over `/tmp` in a new
mount namespace, at a host path of the form
`/tmp/systemd-private-<hex>-<service>-<jumble>/tmp`. Two services on one
machine each see a `/tmp` that looks entirely normal, share every CPU, and
cannot see each other's claim files. Many distribution unit files enable it by
default.

This fails silently, which makes it more dangerous than an absent `/tmp`: the
tool creates the file, acquires the claim, observes no contention, and reports
a clean exclusive run.

An implementation on Linux should detect this by reading
`/proc/self/mountinfo`, finding the mount whose mount point is the longest
prefix of the claim path, and checking its root field. A root other than `/`
means the path is a bind mount of a subtree, which is what `PrivateTmp=`
produces. When detected, the claim must be reported as namespace-scoped rather
than machine-wide.

Separate containers are **not** detectable this way. They share the host's
CPUs but each has its own `/tmp`, and from inside there is no reliable signal.
Operators must point `HOST_CPU_LOCK_PATH` at a shared bind-mounted directory.

Note the asymmetry: an implementation can prove a path is private, but never
that it is machine-wide. "Not detected" is not evidence of sharing. A caller
that cannot accept an unserialized run should be able to require a
machine-wide claim and fail when one is not available, because a silently
unserialized measurement is worse than a failed one.

## Reference implementation

`Flyology_Bench.Host_Lock` implements this convention, and
`Flyology_Bench.Configuration.Host_Lock` applies it around a benchmark run.
See `flyology_bench/README.md`.
