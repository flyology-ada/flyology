use std::cell::Cell;
use std::ffi::{c_int, c_void};
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::task::{Context, Poll, Waker};
use std::time::{Duration, Instant};

const MAX_INTERESTS: usize = 6;
const NO_DEADLINE: u64 = u64::MAX;

const PENDING: c_int = 0;
const READY: c_int = 1;
const FAILED: c_int = 2;
const INVALID: c_int = -1;

const READ_ONE: c_int = 0;
const DELAY_ONLY: c_int = 1;
const READY_BEFORE_ARM: c_int = 2;
const READ_EITHER: c_int = 3;
const NEVER_READ: c_int = 4;
const WRITE_READY: c_int = 5;

static POLL_ACTIVE: AtomicBool = AtomicBool::new(false);
static POLL_COUNT: AtomicUsize = AtomicUsize::new(0);
static CONCURRENT_POLLS: AtomicUsize = AtomicUsize::new(0);
static DROP_COUNT: AtomicUsize = AtomicUsize::new(0);

unsafe extern "C" {
    fn read(fd: c_int, buffer: *mut c_void, length: usize) -> isize;
}

#[repr(C)]
pub struct InterestPlan {
    count: u64,
    descriptors: [i64; MAX_INTERESTS],
    for_write: [u64; MAX_INTERESTS],
    deadline_micros: u64,
}

impl InterestPlan {
    fn reset(&mut self) {
        self.count = 0;
        self.descriptors.fill(-1);
        self.for_write.fill(0);
        self.deadline_micros = NO_DEADLINE;
    }

    fn add(&mut self, fd: c_int, for_write: bool) -> bool {
        let count = self.count as usize;
        if fd < 0 || count >= MAX_INTERESTS {
            return false;
        }
        if (0..count).any(|index| {
            self.descriptors[index] == i64::from(fd)
                && self.for_write[index] == u64::from(for_write)
        }) {
            return true;
        }
        self.descriptors[count] = i64::from(fd);
        self.for_write[count] = u64::from(for_write);
        self.count += 1;
        true
    }

    fn add_deadline(&mut self, deadline: Instant) {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let micros = remaining.as_micros().clamp(1, u128::from(u64::MAX - 1)) as u64;
        self.deadline_micros = self.deadline_micros.min(micros);
    }
}

thread_local! {
    static ACTIVE_PLAN: Cell<*mut InterestPlan> = const { Cell::new(std::ptr::null_mut()) };
    static PLAN_FAILED: Cell<bool> = const { Cell::new(false) };
}

struct PlanScope {
    previous: *mut InterestPlan,
    previous_failed: bool,
}

impl PlanScope {
    fn enter(plan: &mut InterestPlan) -> Self {
        let previous = ACTIVE_PLAN.replace(plan);
        let previous_failed = PLAN_FAILED.replace(false);
        Self {
            previous,
            previous_failed,
        }
    }

    fn failed() -> bool {
        PLAN_FAILED.get()
    }
}

impl Drop for PlanScope {
    fn drop(&mut self) {
        ACTIVE_PLAN.set(self.previous);
        PLAN_FAILED.set(self.previous_failed);
    }
}

fn request_descriptor(fd: c_int, for_write: bool) {
    ACTIVE_PLAN.with(|active| {
        let plan = active.get();
        if plan.is_null() {
            PLAN_FAILED.set(true);
        } else {
            // SAFETY: `PlanScope` installs the unique plan borrowed by the
            // current serialized poll and restores the previous pointer before
            // that borrow ends.
            let accepted = unsafe { &mut *plan }.add(fd, for_write);
            if !accepted {
                PLAN_FAILED.set(true);
            }
        }
    });
}

fn request_deadline(deadline: Instant) {
    ACTIVE_PLAN.with(|active| {
        let plan = active.get();
        if plan.is_null() {
            PLAN_FAILED.set(true);
        } else {
            // SAFETY: see `request_descriptor`; one poll owns this plan.
            unsafe { &mut *plan }.add_deadline(deadline);
        }
    });
}

enum ReadAttempt {
    Byte,
    Pending,
    Failed,
}

fn try_read(fd: c_int) -> ReadAttempt {
    let mut byte = 0_u8;
    loop {
        // SAFETY: `byte` is writable one-byte storage and the caller guarantees
        // that the borrowed descriptor remains live and nonblocking.
        let result = unsafe { read(fd, (&mut byte as *mut u8).cast::<c_void>(), 1) };
        if result == 1 {
            return ReadAttempt::Byte;
        }
        if result == 0 {
            return ReadAttempt::Failed;
        }
        let error = std::io::Error::last_os_error();
        match error.kind() {
            std::io::ErrorKind::Interrupted => {}
            std::io::ErrorKind::WouldBlock => return ReadAttempt::Pending,
            _ => return ReadAttempt::Failed,
        }
    }
}

type FutureOutput = Result<i64, ()>;
type OpaqueFuture = Pin<Box<dyn Future<Output = FutureOutput> + Send + 'static>>;

struct ReadFuture {
    fd: c_int,
    value: i64,
}

impl Future for ReadFuture {
    type Output = FutureOutput;

    fn poll(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Self::Output> {
        match try_read(self.fd) {
            ReadAttempt::Byte => Poll::Ready(Ok(self.value)),
            ReadAttempt::Pending => {
                request_descriptor(self.fd, false);
                Poll::Pending
            }
            ReadAttempt::Failed => Poll::Ready(Err(())),
        }
    }
}

struct DelayFuture {
    deadline: Instant,
    value: i64,
}

impl Future for DelayFuture {
    type Output = FutureOutput;

    fn poll(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Self::Output> {
        if Instant::now() >= self.deadline {
            Poll::Ready(Ok(self.value))
        } else {
            request_deadline(self.deadline);
            Poll::Pending
        }
    }
}

struct ReadyBeforeArmFuture {
    fd: c_int,
    value: i64,
    armed_once: bool,
}

impl Future for ReadyBeforeArmFuture {
    type Output = FutureOutput;

    fn poll(mut self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Self::Output> {
        if !self.armed_once {
            self.armed_once = true;
            request_descriptor(self.fd, false);
            return Poll::Pending;
        }
        match try_read(self.fd) {
            ReadAttempt::Byte => Poll::Ready(Ok(self.value)),
            ReadAttempt::Pending => {
                request_descriptor(self.fd, false);
                Poll::Pending
            }
            ReadAttempt::Failed => Poll::Ready(Err(())),
        }
    }
}

struct ReadEitherFuture {
    first: c_int,
    second: c_int,
    deadline: Instant,
    value: i64,
}

impl Future for ReadEitherFuture {
    type Output = FutureOutput;

    fn poll(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Self::Output> {
        match try_read(self.first) {
            ReadAttempt::Byte => return Poll::Ready(Ok(self.value + 1)),
            ReadAttempt::Failed => return Poll::Ready(Err(())),
            ReadAttempt::Pending => {}
        }
        match try_read(self.second) {
            ReadAttempt::Byte => return Poll::Ready(Ok(self.value + 2)),
            ReadAttempt::Failed => return Poll::Ready(Err(())),
            ReadAttempt::Pending => {}
        }
        if Instant::now() >= self.deadline {
            return Poll::Ready(Err(()));
        }
        request_descriptor(self.first, false);
        request_descriptor(self.second, false);
        request_deadline(self.deadline);
        Poll::Pending
    }
}

struct NeverReadFuture {
    fd: c_int,
}

impl Future for NeverReadFuture {
    type Output = FutureOutput;

    fn poll(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Self::Output> {
        request_descriptor(self.fd, false);
        Poll::Pending
    }
}

struct WriteReadyFuture {
    fd: c_int,
    value: i64,
    armed_once: bool,
}

impl Future for WriteReadyFuture {
    type Output = FutureOutput;

    fn poll(mut self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Self::Output> {
        if self.armed_once {
            Poll::Ready(Ok(self.value))
        } else {
            self.armed_once = true;
            request_descriptor(self.fd, true);
            Poll::Pending
        }
    }
}

struct Job {
    future: OpaqueFuture,
}

struct PollGuard;

impl PollGuard {
    fn enter() -> Self {
        POLL_COUNT.fetch_add(1, Ordering::Relaxed);
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
pub extern "C" fn flyology_rust_interest_create(
    kind: c_int,
    first_fd: c_int,
    second_fd: c_int,
    delay_millis: u64,
    value: i64,
) -> *mut c_void {
    let delay = Duration::from_millis(delay_millis);
    let deadline = Instant::now().checked_add(delay);
    let future: OpaqueFuture = match kind {
        READ_ONE if first_fd >= 0 => Box::pin(ReadFuture {
            fd: first_fd,
            value,
        }),
        DELAY_ONLY => {
            let Some(deadline) = deadline else {
                return std::ptr::null_mut();
            };
            Box::pin(DelayFuture { deadline, value })
        }
        READY_BEFORE_ARM if first_fd >= 0 => Box::pin(ReadyBeforeArmFuture {
            fd: first_fd,
            value,
            armed_once: false,
        }),
        READ_EITHER if first_fd >= 0 && second_fd >= 0 => {
            let Some(deadline) = deadline else {
                return std::ptr::null_mut();
            };
            Box::pin(ReadEitherFuture {
                first: first_fd,
                second: second_fd,
                deadline,
                value,
            })
        }
        NEVER_READ if first_fd >= 0 => Box::pin(NeverReadFuture { fd: first_fd }),
        WRITE_READY if first_fd >= 0 => Box::pin(WriteReadyFuture {
            fd: first_fd,
            value,
            armed_once: false,
        }),
        _ => return std::ptr::null_mut(),
    };
    Box::into_raw(Box::new(Job { future })).cast::<c_void>()
}

#[unsafe(no_mangle)]
/// Poll one future and return the complete next Flyology interest plan.
///
/// # Safety
///
/// `job` must be a live pointer returned by `flyology_rust_interest_create`.
/// `result` and `plan` must point to writable values. Calls using one job must
/// be serialized on its owner task, and every descriptor borrowed by the
/// future must remain open until destroy returns.
pub unsafe extern "C" fn flyology_rust_interest_poll(
    job: *mut c_void,
    result: *mut i64,
    plan: *mut InterestPlan,
) -> c_int {
    let Some(job) = (unsafe { job.cast::<Job>().as_mut() }) else {
        return INVALID;
    };
    let Some(result) = (unsafe { result.as_mut() }) else {
        return INVALID;
    };
    let Some(plan) = (unsafe { plan.as_mut() }) else {
        return INVALID;
    };
    plan.reset();
    let scope = PlanScope::enter(plan);
    let guard = PollGuard::enter();
    let waker = Waker::noop();
    let mut context = Context::from_waker(waker);
    let polled = job.future.as_mut().poll(&mut context);
    drop(guard);
    let failed = PlanScope::failed();
    drop(scope);
    if failed {
        return FAILED;
    }
    match polled {
        Poll::Ready(Ok(value)) => {
            *result = value;
            READY
        }
        Poll::Ready(Err(())) => FAILED,
        Poll::Pending if plan.count > 0 || plan.deadline_micros != NO_DEADLINE => PENDING,
        Poll::Pending => FAILED,
    }
}

#[unsafe(no_mangle)]
/// Destroy a future after completion or after Flyology has disarmed it.
///
/// # Safety
///
/// `job` must be null or a live pointer returned by create. A non-null pointer
/// may be passed exactly once, with no concurrent poll.
pub unsafe extern "C" fn flyology_rust_interest_destroy(job: *mut c_void) {
    if !job.is_null() {
        // SAFETY: the Ada owner calls destroy exactly once after disarming.
        drop(unsafe { Box::from_raw(job.cast::<Job>()) });
        DROP_COUNT.fetch_add(1, Ordering::Relaxed);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn flyology_rust_interest_reset_observations() {
    POLL_COUNT.store(0, Ordering::Relaxed);
    CONCURRENT_POLLS.store(0, Ordering::Relaxed);
    DROP_COUNT.store(0, Ordering::Relaxed);
}

#[unsafe(no_mangle)]
pub extern "C" fn flyology_rust_interest_poll_count() -> u64 {
    POLL_COUNT.load(Ordering::Relaxed) as u64
}

#[unsafe(no_mangle)]
pub extern "C" fn flyology_rust_interest_concurrent_polls() -> u64 {
    CONCURRENT_POLLS.load(Ordering::Relaxed) as u64
}

#[unsafe(no_mangle)]
pub extern "C" fn flyology_rust_interest_drop_count() -> u64 {
    DROP_COUNT.load(Ordering::Relaxed) as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{align_of, size_of};

    #[test]
    fn interest_plan_has_stable_integer_only_layout() {
        assert_eq!(size_of::<InterestPlan>(), 112);
        assert_eq!(align_of::<InterestPlan>(), 8);
    }

    #[test]
    fn bridge_aware_future_records_bounded_plan() {
        let mut plan = InterestPlan {
            count: 99,
            descriptors: [99; MAX_INTERESTS],
            for_write: [99; MAX_INTERESTS],
            deadline_micros: 0,
        };
        let scope = PlanScope::enter(&mut plan);
        plan.reset();
        request_descriptor(7, false);
        request_descriptor(7, false);
        request_descriptor(8, true);
        request_deadline(Instant::now() + Duration::from_millis(10));
        assert!(!PlanScope::failed());
        drop(scope);
        assert_eq!(plan.count, 2);
        assert_eq!(plan.descriptors[0], 7);
        assert_eq!(plan.descriptors[1], 8);
        assert_eq!(plan.for_write[1], 1);
        assert_ne!(plan.deadline_micros, NO_DEADLINE);
    }
}
