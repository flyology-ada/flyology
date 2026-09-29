# Task exit-result architecture

`Flyology.Task_Results` records termination in storage owned by each created
Ada task. It does not catch, recover, resume, restart, or supervise a
terminated task.

## Observation point

GNARL's `Task_Wrapper` already surrounds the compiler-generated task body. The
body reports whether it returned normally, escaped with an unhandled exception,
or completed abnormally. Its generated cleanup finalizes task-local controlled
objects, and GNARL's completion path joins the task's dependent-task master
before returning to the wrapper.

Flyology publishes at that outer boundary, before GNARL invokes a specific or
fallback `Ada.Task_Termination` handler. Publication renders bounded exception
text, fills the fixed result, release-stores the terminal phase, and opens a
persistent completion gate. It holds no ATCB, scheduler, or RTS lock and invokes
no application callback. GNARL then continues through its ordinary termination
and reap paths; the old task is never resumed.

## Task-owned storage and lifetime

Changing the ATCB layout would be an ABI change for stock GNARL units that the
prepared runtime does not rebuild. Flyology instead reserves one of GNARL's
fixed task-attribute slots and stores a typed sidecar pointer in it. The sidecar
contains one fixed result, one atomic lifecycle phase, and one protected
completion gate. It is allocated during `Create_Task`, before any RTS or ATCB
lock is taken, and attached by a scalar store after ATCB initialization. No
allocation occurs during task exit, observation, or waiting.

GNARL normally finalizes task attributes while holding an RTS or ATCB lock, so
the Flyology slot is deliberately registered as non-finalizing. The two common
ATCB reap paths detach its pointer under their existing lock, release the lock,
and only then release the task object's ownership reference. The last
task-object or monitor reference deallocates the sidecar and finalizes its
completion gate. This keeps allocation, deallocation, protected signaling,
exception rendering, and potential finalization outside runtime locks.

The storage remains present for a declared task until its object leaves scope,
and for an allocator-created task until its access object is deallocated or
GNARL performs deferred deallocation after termination. A retained monitor can
extend only the sidecar lifetime beyond that point. The direct `Task_Id`
operations require the task object to remain alive throughout the call; using a
stale `Task_Id` remains invalid under `Ada.Task_Identification`. A copied
`Task_Result` is an ordinary application value and remains valid after the task
object and sidecar are reclaimed.

The cost is one bounded allocation per created task and one permanently
reserved GNARL task-attribute index, leaving 31 of the usual 32 indices for
`Ada.Task_Attributes` instantiations. Failure to allocate the sidecar makes task
creation fail with `Storage_Error` before the task becomes visible.

The reference count starts with one task-object owner and is changed with
acquire/release compare-and-exchange operations. Retain rejects zero and the
maximum count; release rejects underflow and deallocates only on the transition
to zero. The scalar retain/release transition predicates are isolated in the
SPARK policy unit. The task object must still be alive during monitor
attachment, so its owner reference prevents attachment from racing the final
release.

## Identity and activation

No post-allocation registration or secondary identity is used. The sidecar is
attached before the ATCB enters the activation chain, so a task may complete
before its allocator's continuation without losing its result. The caller uses
only the task object's normal `Task_Id`.

If activation fails, Ada propagates `Tasking_Error`. An allocator whose task
cannot activate returns no task object and therefore no valid `Task_Id`; there
is intentionally no detached lookup for that failure. Failure before GNARL
creates and links a task object similarly creates no observable result.

Publication happens only in `Task_Wrapper`, so a task that was created but never
activated never publishes. Its sidecar stays non-terminal and its completion
gate stays closed for as long as the task object exists, even though Ada already
reports the task as terminated. `Observe` therefore returns `Not_Terminal` for
such a task, and an indefinite `Wait` on it would not return; a bounded timeout
is the supported way to wait on a task that may have failed activation. When the
runtime later reclaims the unactivated task, finalizing its gate under a queued
waiter raises `Program_Error` in that waiter per RM 9.4. The exported wait
converts that into its ABI failure code, so `Wait` raises its own documented
`Program_Error` instead of letting a runtime exception cross the boundary.

## Observation and waiting

`Observe` acquire-loads the sidecar phase. It returns `Not_Terminal` until a
publisher has completed the release-store, then copies the entire fixed result
to the caller. No reference or address into the sidecar is exposed, so object
reclamation cannot change an already returned result.

`Wait` first checks the same atomic phase. An indefinite or positive timed wait
then calls the sidecar's persistent protected entry. Publication cannot be lost
between the check and entry call: once a task publishes, the entry barrier stays
open for current and later waiters. After wake or timeout, the public body calls
`Observe` again so a publication that wins the timeout boundary is returned.
Zero timeout is an immediate check; any negative timeout waits indefinitely.

This is one implementation for both lanes, not a `pthread_join` wrapper. GNARL
owns native thread joining and ATCB reclamation. Its ordinary protected-entry
and delay machinery blocks a native caller on the native tasking path and
suspends only a lightweight caller's fiber. `Wait` is abortable and must not be
called from a protected action.

## Exact-task monitors

`Flyology.Task_Results.Monitor` is a limited controlled handle to one exact
sidecar. `Attach` must run while the target task object and its `Task_Id` are
valid. A successful attachment retains the sidecar without allocating or
registering a callback; the task object may then be reclaimed independently.
`Observe (Monitor)` and `Wait (Monitor)` use the retained storage directly, so
they remain valid after task-object reclamation. `Detach` is idempotent and
controlled finalization invokes it automatically.

The monitor is passive. It does not keep the task alive, alter Ada master
joining, request cancellation or abort, restart a task, or follow application
state later occupied by another task. Detaching or finalizing a monitor
concurrently with one of its waits is erroneous; structured ownership must keep
the limited monitor alive for every borrower. Multiple monitors may retain the
same sidecar independently.

The facility deliberately has no global callback registry or unbounded
wait-any set. Current consumers need one exact task result or a controller's
bounded generation registration. A future fan-in facility should begin with a
concrete ownership and capacity requirement rather than adding hidden
publication fan-out to every task.

## Exception retention

An unhandled exception result contains up to 96 characters of fully qualified
exception name and 128 characters of message, with independent truncation
flags. Rendering occurs before publication and outside runtime locks. The
exception occurrence, traceback, and any runtime-owned address are not retained.
Normal and abnormal results leave both text fields empty.

## RTS hook

`Ada.Task_Termination` supplies the needed causes and safe wrapper boundary but
cannot attach storage before activation. A specific handler installed after
`new Task_Type` returns races a fast task, handlers are replaceable, and taking
them over would couple observation to application termination policy.

The exact-version common task-stages patch therefore performs three narrow
operations: allocate and attach the sidecar during task creation, publish at
the existing wrapper boundary, and detach the sidecar in the two common ATCB
reap paths. The task-attribute slot avoids an ATCB layout change. The patch adds
no restart policy, supervisor topology, public address, global result registry,
or platform-specific native/lightweight tasking path.

The environment task does not execute `Task_Wrapper`; its termination ends the
process and has no in-process observation window.
