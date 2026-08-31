use flyology_rust_ingress_spike::{AdmissionGate, RegistrationReservation};
use std::ffi::{c_int, c_void};
use std::sync::{Arc, mpsc};
use std::thread::JoinHandle;

const STD_THREADS: usize = 6;
const TOKIO_BLOCKING_JOBS: usize = 6;
const CALLS_PER_WORKER: usize = 24;

unsafe extern "C" {
    fn adainit();
    fn adafinal();
    fn flyology_rust_ingress_run(
        registered_id: *mut c_void,
        caller_id: c_int,
        iteration: c_int,
    ) -> c_int;
    fn flyology_rust_ingress_completed() -> c_int;
    fn flyology_rust_ingress_maximum_concurrent() -> c_int;
    fn flyology_rust_ingress_failures() -> c_int;
    fn flyology_rust_ingress_activation_incomplete() -> c_int;
    fn __gnat_register_thread() -> *mut c_void;
    fn __gnat_unregister_thread();
}

struct RegisteredThread {
    task: *mut c_void,
    _reservation: RegistrationReservation,
}

impl RegisteredThread {
    fn register(gate: &Arc<AdmissionGate>) -> Result<Self, String> {
        let reservation = gate
            .reserve_registration()
            .ok_or_else(|| "registration rejected during shutdown".to_owned())?;
        let task = unsafe { __gnat_register_thread() };
        if task.is_null() {
            return Err("GNAT rejected explicit foreign-thread registration".to_owned());
        }
        Ok(Self {
            task,
            _reservation: reservation,
        })
    }
}

impl Drop for RegisteredThread {
    fn drop(&mut self) {
        // Registration remains reserved until unregister has completed.
        unsafe { __gnat_unregister_thread() };
    }
}

fn worker(
    gate: Arc<AdmissionGate>,
    caller_id: usize,
    ready: mpsc::Sender<()>,
) -> Result<usize, String> {
    let registration = RegisteredThread::register(&gate)?;
    let mut completed = 0;

    let first_admission = gate
        .enter()
        .ok_or_else(|| "first call was not admitted".to_owned())?;
    ready
        .send(())
        .map_err(|_| "ready receiver disappeared".to_owned())?;
    let first_status =
        unsafe { flyology_rust_ingress_run(registration.task, caller_id as c_int, 0) };
    drop(first_admission);
    if first_status != 0 {
        return Err(format!(
            "Ada call 0 for caller {caller_id} returned {first_status}"
        ));
    }
    completed += 1;

    for iteration in 1..CALLS_PER_WORKER {
        let Some(admission) = gate.enter() else {
            break;
        };
        let status = unsafe {
            flyology_rust_ingress_run(registration.task, caller_id as c_int, iteration as c_int)
        };
        drop(admission);
        if status != 0 {
            return Err(format!(
                "Ada call {iteration} for caller {caller_id} returned {status}"
            ));
        }
        completed += 1;
    }

    Ok(completed)
}

fn join_std_workers(workers: Vec<JoinHandle<Result<usize, String>>>) -> Result<usize, String> {
    workers.into_iter().try_fold(0, |total, worker| {
        let completed = worker
            .join()
            .map_err(|_| "Rust std worker panicked".to_owned())??;
        Ok(total + completed)
    })
}

fn run() -> Result<(), String> {
    // Binder lifecycle calls have no status and are intentionally outside any
    // claim of Rust-side exception containment. The companion subprocess
    // probes characterize that limitation.
    unsafe { adainit() };
    let gate = AdmissionGate::new();
    let (ready_tx, ready_rx) = mpsc::channel();

    let mut std_workers = Vec::new();
    for caller_id in 0..STD_THREADS {
        let gate = Arc::clone(&gate);
        let ready = ready_tx.clone();
        std_workers.push(std::thread::spawn(move || worker(gate, caller_id, ready)));
    }

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .max_blocking_threads(TOKIO_BLOCKING_JOBS)
        .build()
        .map_err(|error| format!("cannot build Tokio runtime: {error}"))?;
    let mut tokio_workers = Vec::new();
    for offset in 0..TOKIO_BLOCKING_JOBS {
        let gate = Arc::clone(&gate);
        let ready = ready_tx.clone();
        tokio_workers
            .push(runtime.spawn_blocking(move || worker(gate, STD_THREADS + offset, ready)));
    }
    drop(ready_tx);

    for _worker in 0..(STD_THREADS + TOKIO_BLOCKING_JOBS) {
        ready_rx
            .recv()
            .map_err(|_| "worker exited before the close race".to_owned())?;
    }

    // Closing flips admission before it waits. Every worker holds one active
    // admission at this point, so this exercises drain rather than an idle close.
    gate.close_and_wait()?;

    let std_result = join_std_workers(std_workers);
    let tokio_result = tokio_workers.into_iter().try_fold(0, |total, worker| {
        let completed = runtime
            .block_on(worker)
            .map_err(|error| format!("Tokio blocking job failed: {error}"))??;
        Ok::<usize, String>(total + completed)
    });

    if let Err(error) = &std_result {
        eprintln!("DETAIL std worker: {error}");
    }
    if let Err(error) = &tokio_result {
        eprintln!("DETAIL Tokio blocking worker: {error}");
    }

    let completed = unsafe { flyology_rust_ingress_completed() };
    let maximum = unsafe { flyology_rust_ingress_maximum_concurrent() };
    let failures = unsafe { flyology_rust_ingress_failures() };
    let activation_incomplete = unsafe { flyology_rust_ingress_activation_incomplete() };
    if completed < (STD_THREADS + TOKIO_BLOCKING_JOBS) as c_int {
        return Err(format!(
            "only {completed} initially admitted calls completed"
        ));
    }
    if maximum < 2 {
        return Err(format!(
            "Ada entries did not overlap; maximum was {maximum}"
        ));
    }
    if failures != 0 {
        return Err(format!("Ada recorded {failures} failed calls"));
    }
    if activation_incomplete == 0 {
        return Err("the activation-only negative was not observed".to_owned());
    }

    // No registered foreign thread or active call remains, and the closed gate
    // rejects both kinds of new admission before finalization begins.
    unsafe { adafinal() };
    gate.mark_finalized()?;

    let std_completed = std_result?;
    let tokio_completed = tokio_result?;

    println!(
        "PASS ingress completed={completed} max_concurrent={maximum} \
         activation_incomplete={activation_incomplete} \
         std_calls={std_completed} tokio_blocking_calls={tokio_completed}"
    );
    println!("PASS lifecycle-gate adafinal-after-drain");
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("FAIL {error}");
        std::process::exit(1);
    }
}
