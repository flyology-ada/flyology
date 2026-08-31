use std::ffi::{c_int, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::sync::atomic::{AtomicI64, AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::runtime::{Builder, Runtime};
use tokio::sync::oneshot;

const SLOT_COUNT: usize = 8;

const OK: c_int = 0;
const INVALID_ARGUMENT: c_int = 1;
const INVALID_HANDLE: c_int = 2;
const NO_CAPACITY: c_int = 3;
const JOB_STILL_PENDING: c_int = 4;
const ENGINE_BUSY: c_int = 5;
const RUST_PANIC: c_int = 9;

const JOB_PENDING: u8 = 0;
const JOB_SUCCEEDED: u8 = 1;
const JOB_CANCELLED: u8 = 2;
const JOB_PANICKED: u8 = 3;
const JOB_SIGNAL_FAILED: u8 = 4;
const JOB_PUBLISHING: u8 = 5;

const MODE_IMMEDIATE: c_int = 0;
const MODE_DELAYED: c_int = 1;
const MODE_PANIC: c_int = 2;

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct JobHandle {
    generation: u64,
    slot: u32,
    reserved: u32,
}

struct Job {
    state: AtomicU8,
    value: AtomicI64,
    cancel: Mutex<Option<oneshot::Sender<()>>>,
    signal_fd: c_int,
}

impl Job {
    fn new(value: i64, signal_fd: c_int, cancel: oneshot::Sender<()>) -> Self {
        Self {
            state: AtomicU8::new(JOB_PENDING),
            value: AtomicI64::new(value),
            cancel: Mutex::new(Some(cancel)),
            signal_fd,
        }
    }

    fn terminalize(&self, state: u8) {
        if self
            .state
            .compare_exchange(
                JOB_PENDING,
                JOB_PUBLISHING,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok()
        {
            let published = if signal_borrowed(self.signal_fd) {
                state
            } else {
                JOB_SIGNAL_FAILED
            };
            // Poll does not expose terminal state until the borrowed write has
            // returned, so Ada cannot release or reuse the descriptor while a
            // Rust producer can still touch it.
            self.state.store(published, Ordering::Release);
        }
    }
}

struct Slot {
    generation: u64,
    job: Option<Arc<Job>>,
}

pub struct Engine {
    runtime: Mutex<Option<Runtime>>,
    slots: Mutex<[Slot; SLOT_COUNT]>,
    next_generation: AtomicU64,
}

impl Engine {
    fn new() -> Result<Self, ()> {
        let runtime = Builder::new_multi_thread()
            .worker_threads(1)
            .thread_name("flyology-rust-spike")
            .enable_time()
            .build()
            .map_err(|_| ())?;
        Ok(Self {
            runtime: Mutex::new(Some(runtime)),
            slots: Mutex::new(std::array::from_fn(|_| Slot {
                generation: 0,
                job: None,
            })),
            next_generation: AtomicU64::new(1),
        })
    }

    fn lookup(&self, handle: JobHandle) -> Result<Arc<Job>, c_int> {
        if handle.reserved != 0 || handle.slot == 0 || handle.slot as usize > SLOT_COUNT {
            return Err(INVALID_HANDLE);
        }
        let slots = self.slots.lock().map_err(|_| RUST_PANIC)?;
        let slot = &slots[handle.slot as usize - 1];
        if slot.generation != handle.generation {
            return Err(INVALID_HANDLE);
        }
        slot.job.clone().ok_or(INVALID_HANDLE)
    }
}

unsafe extern "C" {
    fn write(fd: c_int, buffer: *const c_void, length: usize) -> isize;
}

fn signal_borrowed(fd: c_int) -> bool {
    if fd < 0 {
        return false;
    }
    let byte: u8 = 1;
    loop {
        // SAFETY: byte is live for the one-byte write and the descriptor is a
        // borrowed Flyology wake descriptor retained by the Ada operation.
        let written = unsafe { write(fd, ptr::from_ref(&byte).cast(), 1) };
        if written == 1 {
            return true;
        }
        let error = std::io::Error::last_os_error();
        match error.kind() {
            std::io::ErrorKind::Interrupted => continue,
            // A full nonblocking pipe is already a retained notification.
            std::io::ErrorKind::WouldBlock => return true,
            _ => return false,
        }
    }
}

fn ffi_guard(action: impl FnOnce() -> c_int) -> c_int {
    catch_unwind(AssertUnwindSafe(action)).unwrap_or(RUST_PANIC)
}

unsafe fn with_engine<'a>(engine: *mut Engine) -> Result<&'a Engine, c_int> {
    // SAFETY: the ABI contract keeps the engine alive and excludes destroy
    // while any other engine call is active.
    unsafe { engine.as_ref() }.ok_or(INVALID_ARGUMENT)
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `result` must be null or point to writable storage for one engine pointer.
pub unsafe extern "C" fn flyology_rust_engine_create(result: *mut *mut Engine) -> c_int {
    ffi_guard(|| {
        if result.is_null() {
            return INVALID_ARGUMENT;
        }
        let engine = match Engine::new() {
            Ok(engine) => engine,
            Err(()) => return RUST_PANIC,
        };
        // SAFETY: result was checked and the allocation becomes Ada-owned.
        unsafe { result.write(Box::into_raw(Box::new(engine))) };
        OK
    })
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `engine` must be null or the live allocation returned by `flyology_rust_engine_create`.
/// The caller must exclude every concurrent engine call.
pub unsafe extern "C" fn flyology_rust_engine_destroy(engine: *mut Engine) -> c_int {
    ffi_guard(|| {
        if engine.is_null() {
            return INVALID_ARGUMENT;
        }
        let reference = match unsafe { with_engine(engine) } {
            Ok(reference) => reference,
            Err(status) => return status,
        };
        let busy = match reference.slots.lock() {
            Ok(slots) => slots.iter().any(|slot| slot.job.is_some()),
            Err(_) => return RUST_PANIC,
        };
        if busy {
            return ENGINE_BUSY;
        }
        let runtime = match reference.runtime.lock() {
            Ok(mut runtime) => runtime.take(),
            Err(_) => return RUST_PANIC,
        };
        if let Some(runtime) = runtime {
            runtime.shutdown_timeout(Duration::from_secs(1));
        }
        // SAFETY: shutdown completed, the ABI contract excludes every
        // concurrent call, and destroy now takes sole ownership.
        unsafe { drop(Box::from_raw(engine)) };
        OK
    })
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `engine` must remain live for the call and `count` must point to writable storage.
pub unsafe extern "C" fn flyology_rust_engine_active_jobs(
    engine: *mut Engine,
    count: *mut u32,
) -> c_int {
    ffi_guard(|| {
        if count.is_null() {
            return INVALID_ARGUMENT;
        }
        let engine = match unsafe { with_engine(engine) } {
            Ok(engine) => engine,
            Err(status) => return status,
        };
        let active = match engine.slots.lock() {
            Ok(slots) => slots.iter().filter(|slot| slot.job.is_some()).count(),
            Err(_) => return RUST_PANIC,
        };
        // SAFETY: count was checked and SLOT_COUNT fits in u32.
        unsafe { count.write(active as u32) };
        OK
    })
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `engine` must remain live for the call, `result` must be writable, and `signal_fd`
/// must remain a valid borrowed Flyology wake descriptor until the job terminalizes.
pub unsafe extern "C" fn flyology_rust_job_start(
    engine: *mut Engine,
    mode: c_int,
    delay_ms: u64,
    value: i64,
    signal_fd: c_int,
    result: *mut JobHandle,
) -> c_int {
    ffi_guard(|| {
        if result.is_null()
            || signal_fd < 0
            || !matches!(mode, MODE_IMMEDIATE | MODE_DELAYED | MODE_PANIC)
        {
            return INVALID_ARGUMENT;
        }
        let engine = match unsafe { with_engine(engine) } {
            Ok(engine) => engine,
            Err(status) => return status,
        };
        let runtime_handle = {
            let runtime = match engine.runtime.lock() {
                Ok(runtime) => runtime,
                Err(_) => return RUST_PANIC,
            };
            let Some(runtime) = runtime.as_ref() else {
                return ENGINE_BUSY;
            };
            runtime.handle().clone()
        };
        let generation = match engine.next_generation.fetch_update(
            Ordering::Relaxed,
            Ordering::Relaxed,
            |current| {
                if current == 0 || current == u64::MAX {
                    None
                } else {
                    Some(current + 1)
                }
            },
        ) {
            Ok(generation) => generation,
            Err(_) => return NO_CAPACITY,
        };
        let (cancel_tx, cancel_rx) = oneshot::channel();
        let job = Arc::new(Job::new(value, signal_fd, cancel_tx));
        let slot_index = {
            let mut slots = match engine.slots.lock() {
                Ok(slots) => slots,
                Err(_) => return RUST_PANIC,
            };
            let Some(index) = slots.iter().position(|slot| slot.job.is_none()) else {
                return NO_CAPACITY;
            };
            slots[index].generation = generation;
            slots[index].job = Some(Arc::clone(&job));
            index
        };
        let handle = JobHandle {
            generation,
            slot: slot_index as u32 + 1,
            reserved: 0,
        };
        // SAFETY: result was checked and JobHandle has a C representation.
        unsafe { result.write(handle) };

        if mode == MODE_IMMEDIATE {
            job.terminalize(JOB_SUCCEEDED);
            return OK;
        }

        runtime_handle.spawn(async move {
            let worker_job = Arc::clone(&job);
            let worker = tokio::spawn(async move {
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_millis(delay_ms)) => {
                        if mode == MODE_PANIC {
                            panic!("intentional Flyology Rust spike panic");
                        }
                        JOB_SUCCEEDED
                    }
                    _ = cancel_rx => JOB_CANCELLED,
                }
            });
            let terminal = match worker.await {
                Ok(state) => state,
                Err(error) if error.is_panic() => JOB_PANICKED,
                Err(_) => JOB_CANCELLED,
            };
            worker_job.terminalize(terminal);
        });
        OK
    })
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `engine` and `handle` must identify a live job; `state` and `value` must be writable.
pub unsafe extern "C" fn flyology_rust_job_poll(
    engine: *mut Engine,
    handle: JobHandle,
    state: *mut c_int,
    value: *mut i64,
) -> c_int {
    ffi_guard(|| {
        if state.is_null() || value.is_null() {
            return INVALID_ARGUMENT;
        }
        let engine = match unsafe { with_engine(engine) } {
            Ok(engine) => engine,
            Err(status) => return status,
        };
        let job = match engine.lookup(handle) {
            Ok(job) => job,
            Err(status) => return status,
        };
        let mut observed = job.state.load(Ordering::Acquire);
        while observed == JOB_PUBLISHING {
            std::hint::spin_loop();
            observed = job.state.load(Ordering::Acquire);
        }
        // SAFETY: both output pointers were checked.
        unsafe {
            state.write(c_int::from(observed));
            value.write(job.value.load(Ordering::Relaxed));
        }
        OK
    })
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `engine` and `handle` must identify a live job for the duration of the call.
pub unsafe extern "C" fn flyology_rust_job_cancel(engine: *mut Engine, handle: JobHandle) -> c_int {
    ffi_guard(|| {
        let engine = match unsafe { with_engine(engine) } {
            Ok(engine) => engine,
            Err(status) => return status,
        };
        let job = match engine.lookup(handle) {
            Ok(job) => job,
            Err(status) => return status,
        };
        if job.state.load(Ordering::Acquire) != JOB_PENDING {
            return OK;
        }
        let sender = match job.cancel.lock() {
            Ok(mut sender) => sender.take(),
            Err(_) => return RUST_PANIC,
        };
        if let Some(sender) = sender {
            let _ = sender.send(());
        }
        OK
    })
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `engine` and `handle` must identify a terminal live job, with release externally serialized.
pub unsafe extern "C" fn flyology_rust_job_release(
    engine: *mut Engine,
    handle: JobHandle,
) -> c_int {
    ffi_guard(|| {
        let engine = match unsafe { with_engine(engine) } {
            Ok(engine) => engine,
            Err(status) => return status,
        };
        if handle.reserved != 0 || handle.slot == 0 || handle.slot as usize > SLOT_COUNT {
            return INVALID_HANDLE;
        }
        let mut slots = match engine.slots.lock() {
            Ok(slots) => slots,
            Err(_) => return RUST_PANIC,
        };
        let slot = &mut slots[handle.slot as usize - 1];
        if slot.generation != handle.generation {
            return INVALID_HANDLE;
        }
        let Some(job) = slot.job.as_ref() else {
            return INVALID_HANDLE;
        };
        if matches!(
            job.state.load(Ordering::Acquire),
            JOB_PENDING | JOB_PUBLISHING
        ) {
            return JOB_STILL_PENDING;
        }
        slot.job = None;
        OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::AsRawFd;
    use std::os::unix::net::UnixStream;

    fn create_engine() -> *mut Engine {
        let mut engine = ptr::null_mut();
        assert_eq!(
            // SAFETY: engine points to writable storage for the returned pointer.
            unsafe { flyology_rust_engine_create(ptr::from_mut(&mut engine)) },
            OK
        );
        assert!(!engine.is_null());
        engine
    }

    fn start_immediate(engine: *mut Engine, signal_fd: c_int, value: i64) -> JobHandle {
        let mut handle = JobHandle::default();
        assert_eq!(
            // SAFETY: engine is live, handle is writable, and the caller retains signal_fd.
            unsafe {
                flyology_rust_job_start(
                    engine,
                    MODE_IMMEDIATE,
                    0,
                    value,
                    signal_fd,
                    ptr::from_mut(&mut handle),
                )
            },
            OK
        );
        handle
    }

    #[test]
    fn rejects_null_engine_output() {
        assert_eq!(
            // SAFETY: null is an explicitly accepted validation case.
            unsafe { flyology_rust_engine_create(ptr::null_mut()) },
            INVALID_ARGUMENT
        );
    }

    #[test]
    fn catches_ffi_panics() {
        assert_eq!(ffi_guard(|| panic!("contained")), RUST_PANIC);
    }

    #[test]
    fn generation_reuse_rejects_stale_handle() {
        let engine = create_engine();
        let (signal_reader, signal_writer) = UnixStream::pair().expect("signal pair");
        let first = start_immediate(engine, signal_writer.as_raw_fd(), 11);
        assert_eq!(
            // SAFETY: engine and first identify a terminal live job.
            unsafe { flyology_rust_job_release(engine, first) },
            OK
        );

        let second = start_immediate(engine, signal_writer.as_raw_fd(), 22);
        assert_eq!(first.slot, second.slot);
        assert_ne!(first.generation, second.generation);
        let mut state = -1;
        let mut value = -1;
        assert_eq!(
            // SAFETY: outputs are writable; stale handles are an explicit validation case.
            unsafe {
                flyology_rust_job_poll(
                    engine,
                    first,
                    ptr::from_mut(&mut state),
                    ptr::from_mut(&mut value),
                )
            },
            INVALID_HANDLE
        );
        assert_eq!(
            // SAFETY: engine and second identify a terminal live job.
            unsafe { flyology_rust_job_release(engine, second) },
            OK
        );
        assert_eq!(
            // SAFETY: all jobs are released and the engine is exclusively owned here.
            unsafe { flyology_rust_engine_destroy(engine) },
            OK
        );
        drop((signal_reader, signal_writer));
    }

    #[test]
    fn ninth_job_is_rejected_until_a_slot_is_released() {
        let engine = create_engine();
        let (signal_reader, signal_writer) = UnixStream::pair().expect("signal pair");
        let handles: [JobHandle; SLOT_COUNT] = std::array::from_fn(|index| {
            start_immediate(engine, signal_writer.as_raw_fd(), index as i64)
        });
        let mut ninth = JobHandle::default();
        assert_eq!(
            // SAFETY: all arguments are live and writable; capacity exhaustion is expected.
            unsafe {
                flyology_rust_job_start(
                    engine,
                    MODE_IMMEDIATE,
                    0,
                    9,
                    signal_writer.as_raw_fd(),
                    ptr::from_mut(&mut ninth),
                )
            },
            NO_CAPACITY
        );
        for handle in handles {
            assert_eq!(
                // SAFETY: each handle identifies a terminal live job and is released once.
                unsafe { flyology_rust_job_release(engine, handle) },
                OK
            );
        }
        let reused = start_immediate(engine, signal_writer.as_raw_fd(), 10);
        assert_eq!(
            // SAFETY: reused identifies a terminal live job.
            unsafe { flyology_rust_job_release(engine, reused) },
            OK
        );
        assert_eq!(
            // SAFETY: all jobs are released and the engine is exclusively owned here.
            unsafe { flyology_rust_engine_destroy(engine) },
            OK
        );
        drop((signal_reader, signal_writer));
    }
}
