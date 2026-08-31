use std::ffi::{c_int, c_void};
use std::os::unix::net::UnixStream as StdUnixStream;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::slice;
use std::sync::atomic::{AtomicU8, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::runtime::{Builder, Runtime};
use tokio::sync::oneshot;

const SLOT_COUNT: usize = 8;
const MAX_PAYLOAD: usize = 256;

const OK: c_int = 0;
const INVALID_ARGUMENT: c_int = 1;
const INVALID_HANDLE: c_int = 2;
const NO_CAPACITY: c_int = 3;
const JOB_STILL_PENDING: c_int = 4;
const ENGINE_BUSY: c_int = 5;
const BUFFER_TOO_SMALL: c_int = 6;
const RUST_PANIC: c_int = 9;

const JOB_PENDING: u8 = 0;
const JOB_SUCCEEDED: u8 = 1;
const JOB_CANCELLED: u8 = 2;
const JOB_SIGNAL_FAILED: u8 = 3;
const JOB_IO_FAILED: u8 = 4;
const JOB_PUBLISHING: u8 = 5;

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct JobHandle {
    generation: u64,
    slot: u32,
    reserved: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct Progress {
    request_writes: u32,
    request_reads: u32,
    response_writes: u32,
    response_reads: u32,
}

#[derive(Default)]
struct AtomicProgress {
    request_writes: AtomicU32,
    request_reads: AtomicU32,
    response_writes: AtomicU32,
    response_reads: AtomicU32,
}

impl AtomicProgress {
    fn snapshot(&self) -> Progress {
        Progress {
            request_writes: self.request_writes.load(Ordering::Acquire),
            request_reads: self.request_reads.load(Ordering::Acquire),
            response_writes: self.response_writes.load(Ordering::Acquire),
            response_reads: self.response_reads.load(Ordering::Acquire),
        }
    }
}

struct Job {
    state: AtomicU8,
    output: Mutex<Option<Vec<u8>>>,
    progress: AtomicProgress,
    cancel: Mutex<Option<oneshot::Sender<()>>>,
    signal_fd: c_int,
}

impl Job {
    fn new(signal_fd: c_int, cancel: oneshot::Sender<()>) -> Self {
        Self {
            state: AtomicU8::new(JOB_PENDING),
            output: Mutex::new(None),
            progress: AtomicProgress::default(),
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
    active_descriptors: Arc<AtomicU32>,
}

impl Engine {
    fn new() -> Result<Self, ()> {
        let runtime = Builder::new_multi_thread()
            .worker_threads(1)
            .thread_name("flyology-rust-io-spike")
            .enable_all()
            .build()
            .map_err(|_| ())?;
        Ok(Self {
            runtime: Mutex::new(Some(runtime)),
            slots: Mutex::new(std::array::from_fn(|_| Slot {
                generation: 0,
                job: None,
            })),
            next_generation: AtomicU64::new(1),
            active_descriptors: Arc::new(AtomicU32::new(0)),
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

struct DescriptorLease(Arc<AtomicU32>);

impl DescriptorLease {
    fn new(count: Arc<AtomicU32>) -> Self {
        count.fetch_add(2, Ordering::AcqRel);
        Self(count)
    }
}

impl Drop for DescriptorLease {
    fn drop(&mut self) {
        self.0.fetch_sub(2, Ordering::AcqRel);
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
        // SAFETY: the byte remains live for the call and Ada retains the
        // borrowed signal descriptor until terminal publication completes.
        let written = unsafe { write(fd, ptr::from_ref(&byte).cast(), 1) };
        if written == 1 {
            return true;
        }
        match std::io::Error::last_os_error().kind() {
            std::io::ErrorKind::Interrupted => continue,
            std::io::ErrorKind::WouldBlock => return true,
            _ => return false,
        }
    }
}

async fn step_pause(delay_ms: u64) {
    if delay_ms == 0 {
        tokio::task::yield_now().await;
    } else {
        tokio::time::sleep(Duration::from_millis(delay_ms)).await;
    }
}

async fn run_duplex(
    mut left: UnixStream,
    mut right: UnixStream,
    input: Vec<u8>,
    chunk_size: usize,
    delay_ms: u64,
    progress: &AtomicProgress,
) -> std::io::Result<Vec<u8>> {
    let mut offset = 0;
    while offset < input.len() {
        let end = (offset + chunk_size).min(input.len());
        let count = left.write(&input[offset..end]).await?;
        if count == 0 {
            return Err(std::io::ErrorKind::WriteZero.into());
        }
        offset += count;
        progress.request_writes.fetch_add(1, Ordering::Release);
        step_pause(delay_ms).await;
    }

    let mut received = vec![0_u8; input.len()];
    offset = 0;
    while offset < received.len() {
        let end = (offset + chunk_size).min(received.len());
        let count = right.read(&mut received[offset..end]).await?;
        if count == 0 {
            return Err(std::io::ErrorKind::UnexpectedEof.into());
        }
        offset += count;
        progress.request_reads.fetch_add(1, Ordering::Release);
        step_pause(delay_ms).await;
    }

    let response: Vec<u8> = received.iter().rev().map(|byte| byte ^ 0xA5).collect();
    offset = 0;
    while offset < response.len() {
        let end = (offset + chunk_size).min(response.len());
        let count = right.write(&response[offset..end]).await?;
        if count == 0 {
            return Err(std::io::ErrorKind::WriteZero.into());
        }
        offset += count;
        progress.response_writes.fetch_add(1, Ordering::Release);
        step_pause(delay_ms).await;
    }

    let mut returned = vec![0_u8; response.len()];
    offset = 0;
    while offset < returned.len() {
        let end = (offset + chunk_size).min(returned.len());
        let count = left.read(&mut returned[offset..end]).await?;
        if count == 0 {
            return Err(std::io::ErrorKind::UnexpectedEof.into());
        }
        offset += count;
        progress.response_reads.fetch_add(1, Ordering::Release);
        step_pause(delay_ms).await;
    }
    Ok(returned)
}

fn ffi_guard(action: impl FnOnce() -> c_int) -> c_int {
    catch_unwind(AssertUnwindSafe(action)).unwrap_or(RUST_PANIC)
}

unsafe fn with_engine<'a>(engine: *mut Engine) -> Result<&'a Engine, c_int> {
    // SAFETY: the ABI contract keeps the allocation live and excludes destroy.
    unsafe { engine.as_ref() }.ok_or(INVALID_ARGUMENT)
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `result` must point to writable storage for one engine pointer.
pub unsafe extern "C" fn flyology_rust_io_engine_create(result: *mut *mut Engine) -> c_int {
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
/// `engine` must be the live allocation returned by `flyology_rust_io_engine_create`, and the
/// caller must exclude all concurrent engine calls.
pub unsafe extern "C" fn flyology_rust_io_engine_destroy(engine: *mut Engine) -> c_int {
    ffi_guard(|| {
        let engine_ref = match unsafe { with_engine(engine) } {
            Ok(engine) => engine,
            Err(status) => return status,
        };
        let busy = match engine_ref.slots.lock() {
            Ok(slots) => slots.iter().any(|slot| slot.job.is_some()),
            Err(_) => return RUST_PANIC,
        } || engine_ref.active_descriptors.load(Ordering::Acquire) != 0;
        if busy {
            return ENGINE_BUSY;
        }
        let runtime = match engine_ref.runtime.lock() {
            Ok(mut runtime) => runtime.take(),
            Err(_) => return RUST_PANIC,
        };
        if let Some(runtime) = runtime {
            runtime.shutdown_timeout(Duration::from_secs(1));
        }
        // SAFETY: the ABI contract excludes every concurrent engine call.
        unsafe { drop(Box::from_raw(engine)) };
        OK
    })
}

unsafe fn write_count(engine: *mut Engine, count: *mut u32, descriptors: bool) -> c_int {
    ffi_guard(|| {
        if count.is_null() {
            return INVALID_ARGUMENT;
        }
        let engine = match unsafe { with_engine(engine) } {
            Ok(engine) => engine,
            Err(status) => return status,
        };
        let value = if descriptors {
            engine.active_descriptors.load(Ordering::Acquire)
        } else {
            match engine.slots.lock() {
                Ok(slots) => slots.iter().filter(|slot| slot.job.is_some()).count() as u32,
                Err(_) => return RUST_PANIC,
            }
        };
        // SAFETY: count was checked.
        unsafe { count.write(value) };
        OK
    })
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `engine` must remain live for the call and `count` must point to writable storage.
pub unsafe extern "C" fn flyology_rust_io_engine_active_jobs(
    engine: *mut Engine,
    count: *mut u32,
) -> c_int {
    unsafe { write_count(engine, count, false) }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `engine` must remain live for the call and `count` must point to writable storage.
pub unsafe extern "C" fn flyology_rust_io_engine_active_descriptors(
    engine: *mut Engine,
    count: *mut u32,
) -> c_int {
    unsafe { write_count(engine, count, true) }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `engine` must remain live, `input` must identify `length` readable bytes for this call,
/// `result` must be writable, and `signal_fd` must remain valid until terminal publication.
pub unsafe extern "C" fn flyology_rust_io_start(
    engine: *mut Engine,
    input: *const u8,
    length: u32,
    chunk_size: u32,
    delay_ms: u64,
    signal_fd: c_int,
    result: *mut JobHandle,
) -> c_int {
    ffi_guard(|| {
        if input.is_null()
            || result.is_null()
            || length == 0
            || length as usize > MAX_PAYLOAD
            || chunk_size == 0
            || signal_fd < 0
        {
            return INVALID_ARGUMENT;
        }
        let engine = match unsafe { with_engine(engine) } {
            Ok(engine) => engine,
            Err(status) => return status,
        };
        // The only Ada data borrow ends here, before this ABI call returns.
        // SAFETY: the caller promises length readable bytes for this call.
        let owned_input = unsafe { slice::from_raw_parts(input, length as usize) }.to_vec();
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
            |current| (current != 0 && current != u64::MAX).then_some(current + 1),
        ) {
            Ok(generation) => generation,
            Err(_) => return NO_CAPACITY,
        };
        let (cancel_tx, cancel_rx) = oneshot::channel();
        let job = Arc::new(Job::new(signal_fd, cancel_tx));
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

        let pair = (|| -> std::io::Result<(UnixStream, UnixStream)> {
            let (left, right) = StdUnixStream::pair()?;
            left.set_nonblocking(true)?;
            right.set_nonblocking(true)?;
            let _guard = runtime_handle.enter();
            Ok((UnixStream::from_std(left)?, UnixStream::from_std(right)?))
        })();
        let (left, right) = match pair {
            Ok(pair) => pair,
            Err(_) => {
                if let Ok(mut slots) = engine.slots.lock() {
                    slots[slot_index].job = None;
                }
                return RUST_PANIC;
            }
        };
        let descriptor_lease = DescriptorLease::new(Arc::clone(&engine.active_descriptors));
        let handle = JobHandle {
            generation,
            slot: slot_index as u32 + 1,
            reserved: 0,
        };
        // SAFETY: result was checked and JobHandle has a C representation.
        unsafe { result.write(handle) };

        runtime_handle.spawn(async move {
            let outcome = tokio::select! {
                _ = cancel_rx => Err(JOB_CANCELLED),
                result = run_duplex(
                    left,
                    right,
                    owned_input,
                    chunk_size as usize,
                    delay_ms,
                    &job.progress,
                ) => match result {
                    Ok(output) => {
                        match job.output.lock() {
                            Ok(mut retained) => *retained = Some(output),
                            Err(_) => return job.terminalize(JOB_IO_FAILED),
                        }
                        Ok(())
                    }
                    Err(_) => Err(JOB_IO_FAILED),
                },
            };
            // Descriptors and their Tokio registrations are gone before the
            // descriptor lease is dropped and terminal state becomes visible.
            drop(descriptor_lease);
            job.terminalize(match outcome {
                Ok(()) => JOB_SUCCEEDED,
                Err(state) => state,
            });
        });
        OK
    })
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `engine` and `handle` must identify a live job; both output pointers must be writable.
pub unsafe extern "C" fn flyology_rust_io_poll(
    engine: *mut Engine,
    handle: JobHandle,
    state: *mut c_int,
    progress: *mut Progress,
) -> c_int {
    ffi_guard(|| {
        if state.is_null() || progress.is_null() {
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
            progress.write(job.progress.snapshot());
        }
        OK
    })
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `engine` and `handle` must identify a successful live job, `output` must identify `capacity`
/// writable bytes, and `length` must be writable.
pub unsafe extern "C" fn flyology_rust_io_copy_result(
    engine: *mut Engine,
    handle: JobHandle,
    output: *mut u8,
    capacity: u32,
    length: *mut u32,
) -> c_int {
    ffi_guard(|| {
        if output.is_null() || length.is_null() {
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
        if job.state.load(Ordering::Acquire) != JOB_SUCCEEDED {
            return JOB_STILL_PENDING;
        }
        let retained = match job.output.lock() {
            Ok(retained) => retained,
            Err(_) => return RUST_PANIC,
        };
        let Some(retained) = retained.as_ref() else {
            return RUST_PANIC;
        };
        if retained.len() > capacity as usize {
            return BUFFER_TOO_SMALL;
        }
        // SAFETY: output has capacity bytes by contract and length was checked.
        unsafe {
            ptr::copy_nonoverlapping(retained.as_ptr(), output, retained.len());
            length.write(retained.len() as u32);
        }
        OK
    })
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `engine` and `handle` must identify a live job for the duration of the call.
pub unsafe extern "C" fn flyology_rust_io_cancel(engine: *mut Engine, handle: JobHandle) -> c_int {
    ffi_guard(|| {
        let engine = match unsafe { with_engine(engine) } {
            Ok(engine) => engine,
            Err(status) => return status,
        };
        let job = match engine.lookup(handle) {
            Ok(job) => job,
            Err(status) => return status,
        };
        if job.state.load(Ordering::Acquire) == JOB_PENDING {
            let sender = match job.cancel.lock() {
                Ok(mut sender) => sender.take(),
                Err(_) => return RUST_PANIC,
            };
            if let Some(sender) = sender {
                let _ = sender.send(());
            }
        }
        OK
    })
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `engine` and `handle` must identify a terminal live job, with release externally serialized.
pub unsafe extern "C" fn flyology_rust_io_release(engine: *mut Engine, handle: JobHandle) -> c_int {
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

    #[tokio::test]
    async fn duplex_uses_both_directions_in_multiple_steps() {
        let (left, right) = UnixStream::pair().expect("pair");
        let progress = AtomicProgress::default();
        let input: Vec<u8> = (0_u8..31).collect();
        let output = run_duplex(left, right, input.clone(), 3, 0, &progress)
            .await
            .expect("duplex");
        let expected: Vec<u8> = input.iter().rev().map(|byte| byte ^ 0xA5).collect();
        assert_eq!(output, expected);
        let stats = progress.snapshot();
        assert!(stats.request_writes > 1);
        assert!(stats.request_reads > 1);
        assert!(stats.response_writes > 1);
        assert!(stats.response_reads > 1);
    }
}
