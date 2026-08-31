use std::ffi::{c_int, c_void};
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::task::{Context, Poll, Wake, Waker};
use std::thread;
use std::time::Duration;

const PENDING: c_int = 0;
const READY: c_int = 1;
const PANICKED: c_int = 2;
const INVALID: c_int = -1;

const F_GETFD: c_int = 1;
const F_SETFD: c_int = 2;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const FD_CLOEXEC: c_int = 1;

#[cfg(target_os = "macos")]
const O_NONBLOCK: c_int = 0x0004;
#[cfg(target_os = "linux")]
const O_NONBLOCK: c_int = 0x0800;

static LATE_WAKES: AtomicUsize = AtomicUsize::new(0);
static SIGNAL_FAILURES: AtomicUsize = AtomicUsize::new(0);
static POLL_ACTIVE: AtomicBool = AtomicBool::new(false);
static CONCURRENT_POLLS: AtomicUsize = AtomicUsize::new(0);

unsafe extern "C" {
    fn pipe(ends: *mut c_int) -> c_int;
    fn fcntl(fd: c_int, command: c_int, ...) -> c_int;
    fn read(fd: c_int, buffer: *mut c_void, length: usize) -> isize;
    fn write(fd: c_int, buffer: *const c_void, length: usize) -> isize;
    fn close(fd: c_int) -> c_int;
}

fn lock(inner: &Mutex<WakeInner>) -> MutexGuard<'_, WakeInner> {
    inner
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

struct WakeInner {
    read_fd: c_int,
    write_fd: c_int,
    active: bool,
    notified: bool,
}

struct WakeState {
    inner: Mutex<WakeInner>,
}

impl WakeState {
    fn create() -> Option<Arc<Self>> {
        let mut ends = [-1; 2];
        // SAFETY: `ends` is writable storage for exactly two C integers.
        if unsafe { pipe(ends.as_mut_ptr()) } != 0 {
            return None;
        }
        if !configure(ends[0]) || !configure(ends[1]) {
            // SAFETY: both descriptors were returned by the successful pipe call.
            unsafe {
                close(ends[0]);
                close(ends[1]);
            }
            return None;
        }
        Some(Arc::new(Self {
            inner: Mutex::new(WakeInner {
                read_fd: ends[0],
                write_fd: ends[1],
                active: true,
                notified: false,
            }),
        }))
    }

    fn read_fd(&self) -> c_int {
        lock(&self.inner).read_fd
    }

    fn prepare_poll(&self) {
        let mut inner = lock(&self.inner);
        if inner.notified {
            let mut byte = 0_u8;
            // SAFETY: the mutex excludes writers, the notification flag records one
            // coalesced byte, and `byte` is writable one-byte storage.
            let result = unsafe { read(inner.read_fd, (&mut byte as *mut u8).cast::<c_void>(), 1) };
            if result != 1 {
                SIGNAL_FAILURES.fetch_add(1, Ordering::Relaxed);
            }
            inner.notified = false;
        }
    }

    fn deactivate(&self) {
        let mut inner = lock(&self.inner);
        if !inner.active {
            return;
        }
        inner.active = false;
        // SAFETY: the mutex excludes every wake write while both descriptors
        // are closed and invalidated. Later cloned wakers observe inactive.
        unsafe {
            close(inner.read_fd);
            close(inner.write_fd);
        }
        inner.read_fd = -1;
        inner.write_fd = -1;
    }
}

impl Drop for WakeState {
    fn drop(&mut self) {
        let inner = lock(&self.inner);
        // SAFETY: a still-active state exclusively owns both descriptors.
        unsafe {
            if inner.read_fd >= 0 {
                close(inner.read_fd);
            }
            if inner.write_fd >= 0 {
                close(inner.write_fd);
            }
        }
    }
}

impl Wake for WakeState {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }

    fn wake_by_ref(self: &Arc<Self>) {
        let mut inner = lock(&self.inner);
        if !inner.active {
            LATE_WAKES.fetch_add(1, Ordering::Relaxed);
            return;
        }
        if inner.notified {
            return;
        }
        let byte = 1_u8;
        // SAFETY: the mutex keeps the descriptor live for the complete write and
        // `byte` is readable one-byte storage.
        let result = unsafe { write(inner.write_fd, (&byte as *const u8).cast::<c_void>(), 1) };
        if result == 1 {
            inner.notified = true;
        } else {
            SIGNAL_FAILURES.fetch_add(1, Ordering::Relaxed);
        }
    }
}

fn configure(fd: c_int) -> bool {
    // SAFETY: fcntl accepts this descriptor and command pair without a third arg.
    let status = unsafe { fcntl(fd, F_GETFL) };
    if status < 0 {
        return false;
    }
    // SAFETY: F_SETFL consumes one C integer argument.
    if unsafe { fcntl(fd, F_SETFL, status | O_NONBLOCK) } < 0 {
        return false;
    }
    // SAFETY: fcntl accepts this descriptor and command pair without a third arg.
    let descriptor = unsafe { fcntl(fd, F_GETFD) };
    if descriptor < 0 {
        return false;
    }
    // SAFETY: F_SETFD consumes one C integer argument.
    unsafe { fcntl(fd, F_SETFD, descriptor | FD_CLOEXEC) >= 0 }
}

type FutureOutput = Result<i64, ()>;
type OpaqueFuture = Pin<Box<dyn Future<Output = FutureOutput> + Send + 'static>>;

struct DelayedFuture {
    delay: Duration,
    value: i64,
    spawned: bool,
    ready: Arc<AtomicBool>,
}

impl Future for DelayedFuture {
    type Output = FutureOutput;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        if self.ready.load(Ordering::Acquire) {
            return Poll::Ready(Ok(self.value));
        }
        if !self.spawned {
            self.spawned = true;
            let delay = self.delay;
            let ready = Arc::clone(&self.ready);
            let waker = cx.waker().clone();
            thread::spawn(move || {
                thread::sleep(delay);
                ready.store(true, Ordering::Release);
                waker.wake();
            });
        }
        Poll::Pending
    }
}

struct SelfWakeFuture {
    value: i64,
    pending_once: bool,
}

impl Future for SelfWakeFuture {
    type Output = FutureOutput;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        if self.pending_once {
            Poll::Ready(Ok(self.value))
        } else {
            self.pending_once = true;
            cx.waker().wake_by_ref();
            Poll::Pending
        }
    }
}

struct PanicFuture;

impl Future for PanicFuture {
    type Output = FutureOutput;

    fn poll(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Self::Output> {
        panic!("intentional direct-future spike panic")
    }
}

struct Job {
    future: Option<OpaqueFuture>,
    wake: Arc<WakeState>,
}

impl Job {
    fn deactivate(&mut self) {
        self.wake.deactivate();
        self.future = None;
    }
}

struct PollGuard;

impl PollGuard {
    fn enter() -> Self {
        if POLL_ACTIVE.swap(true, Ordering::AcqRel) {
            CONCURRENT_POLLS.fetch_add(1, Ordering::Relaxed);
        }
        Self
    }
}

impl Drop for PollGuard {
    fn drop(&mut self) {
        POLL_ACTIVE.store(false, Ordering::Release);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn flyology_rust_future_create(
    kind: c_int,
    delay_millis: u64,
    value: i64,
) -> *mut c_void {
    let created = std::panic::catch_unwind(|| {
        let wake = WakeState::create()?;
        let future: OpaqueFuture = match kind {
            0 => Box::pin(SelfWakeFuture {
                value,
                pending_once: false,
            }),
            1 => Box::pin(DelayedFuture {
                delay: Duration::from_millis(delay_millis),
                value,
                spawned: false,
                ready: Arc::new(AtomicBool::new(false)),
            }),
            2 => Box::pin(PanicFuture),
            _ => return None,
        };
        Some(
            Box::into_raw(Box::new(Job {
                future: Some(future),
                wake,
            }))
            .cast::<c_void>(),
        )
    });
    created.ok().flatten().unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
/// Return the readable wake descriptor owned by a live opaque job.
///
/// # Safety
///
/// `job` must be null or a pointer returned by `flyology_rust_future_create`
/// that has not been destroyed. The owner must serialize this call with poll,
/// cancel, and destroy.
pub unsafe extern "C" fn flyology_rust_future_read_fd(job: *mut c_void) -> c_int {
    // SAFETY: the Ada owner passes the live opaque pointer returned by create.
    unsafe { job.cast::<Job>().as_ref() }
        .map(|job| job.wake.read_fd())
        .unwrap_or(-1)
}

#[unsafe(no_mangle)]
/// Poll one live opaque job exactly once.
///
/// # Safety
///
/// `job` must be a live pointer returned by `flyology_rust_future_create`, and
/// `result` must point to writable `i64` storage. The owner must serialize all
/// calls that use the job.
pub unsafe extern "C" fn flyology_rust_future_poll(job: *mut c_void, result: *mut i64) -> c_int {
    // SAFETY: the Ada operation serializes every access to its live opaque job.
    let Some(job) = (unsafe { job.cast::<Job>().as_mut() }) else {
        return INVALID;
    };
    let Some(future) = job.future.as_mut() else {
        return INVALID;
    };
    job.wake.prepare_poll();
    let waker: Waker = Waker::from(Arc::clone(&job.wake));
    let mut context = Context::from_waker(&waker);
    let guard = PollGuard::enter();
    let polled = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        future.as_mut().poll(&mut context)
    }));
    drop(guard);
    match polled {
        Ok(Poll::Pending) => PENDING,
        Ok(Poll::Ready(Ok(value))) => {
            if result.is_null() {
                return INVALID;
            }
            // SAFETY: Ada supplies writable storage for one i64 result.
            unsafe { result.write(value) };
            job.deactivate();
            READY
        }
        Ok(Poll::Ready(Err(()))) | Err(_) => {
            job.deactivate();
            PANICKED
        }
    }
}

#[unsafe(no_mangle)]
/// Deactivate the waker and drop the future retained by one live job.
///
/// # Safety
///
/// `job` must be a live pointer returned by `flyology_rust_future_create`. The
/// owner must serialize this call with every other operation on the job.
pub unsafe extern "C" fn flyology_rust_future_cancel(job: *mut c_void) -> c_int {
    // SAFETY: the Ada operation serializes every access to its live opaque job.
    let Some(job) = (unsafe { job.cast::<Job>().as_mut() }) else {
        return INVALID;
    };
    job.deactivate();
    0
}

#[unsafe(no_mangle)]
/// Destroy an opaque job after it has been deactivated or completed.
///
/// # Safety
///
/// `job` must be null or a pointer returned by `flyology_rust_future_create`.
/// A non-null pointer may be passed to this function exactly once.
pub unsafe extern "C" fn flyology_rust_future_destroy(job: *mut c_void) {
    if !job.is_null() {
        // SAFETY: Ada calls destroy exactly once for the pointer returned by create.
        drop(unsafe { Box::from_raw(job.cast::<Job>()) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn flyology_rust_future_reset_observations() {
    LATE_WAKES.store(0, Ordering::Relaxed);
    SIGNAL_FAILURES.store(0, Ordering::Relaxed);
    CONCURRENT_POLLS.store(0, Ordering::Relaxed);
}

#[unsafe(no_mangle)]
pub extern "C" fn flyology_rust_future_late_wakes() -> u64 {
    LATE_WAKES.load(Ordering::Relaxed) as u64
}

#[unsafe(no_mangle)]
pub extern "C" fn flyology_rust_future_signal_failures() -> u64 {
    SIGNAL_FAILURES.load(Ordering::Relaxed) as u64
}

#[unsafe(no_mangle)]
pub extern "C" fn flyology_rust_future_concurrent_polls() -> u64 {
    CONCURRENT_POLLS.load(Ordering::Relaxed) as u64
}
