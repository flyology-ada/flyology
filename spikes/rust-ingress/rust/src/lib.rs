use std::sync::{Arc, Condvar, Mutex};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Phase {
    Running,
    Closing,
    Finalized,
}

#[derive(Debug)]
struct State {
    phase: Phase,
    active_calls: usize,
    registration_reservations: usize,
}

#[derive(Debug)]
pub struct AdmissionGate {
    state: Mutex<State>,
    drained: Condvar,
}

impl AdmissionGate {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(State {
                phase: Phase::Running,
                active_calls: 0,
                registration_reservations: 0,
            }),
            drained: Condvar::new(),
        })
    }

    pub fn reserve_registration(self: &Arc<Self>) -> Option<RegistrationReservation> {
        let mut state = self.state.lock().expect("admission gate poisoned");
        if state.phase != Phase::Running {
            return None;
        }
        state.registration_reservations += 1;
        Some(RegistrationReservation {
            gate: Arc::clone(self),
        })
    }

    pub fn enter(self: &Arc<Self>) -> Option<CallAdmission> {
        let mut state = self.state.lock().expect("admission gate poisoned");
        if state.phase != Phase::Running {
            return None;
        }
        state.active_calls += 1;
        Some(CallAdmission {
            gate: Arc::clone(self),
        })
    }

    pub fn close_and_wait(&self) -> Result<(), &'static str> {
        let mut state = self.state.lock().expect("admission gate poisoned");
        if state.phase != Phase::Running {
            return Err("lifecycle is not running");
        }
        state.phase = Phase::Closing;
        while state.active_calls != 0 || state.registration_reservations != 0 {
            state = self
                .drained
                .wait(state)
                .expect("admission gate poisoned while closing");
        }
        Ok(())
    }

    pub fn mark_finalized(&self) -> Result<(), &'static str> {
        let mut state = self.state.lock().expect("admission gate poisoned");
        if state.phase != Phase::Closing
            || state.active_calls != 0
            || state.registration_reservations != 0
        {
            return Err("lifecycle is not quiescent and closing");
        }
        state.phase = Phase::Finalized;
        Ok(())
    }

    fn release_call(&self) {
        let mut state = self.state.lock().expect("admission gate poisoned");
        assert!(state.active_calls > 0);
        state.active_calls -= 1;
        if state.active_calls == 0 && state.registration_reservations == 0 {
            self.drained.notify_all();
        }
    }

    fn release_registration(&self) {
        let mut state = self.state.lock().expect("admission gate poisoned");
        assert!(state.registration_reservations > 0);
        state.registration_reservations -= 1;
        if state.active_calls == 0 && state.registration_reservations == 0 {
            self.drained.notify_all();
        }
    }
}

pub struct CallAdmission {
    gate: Arc<AdmissionGate>,
}

impl Drop for CallAdmission {
    fn drop(&mut self) {
        self.gate.release_call();
    }
}

pub struct RegistrationReservation {
    gate: Arc<AdmissionGate>,
}

impl Drop for RegistrationReservation {
    fn drop(&mut self) {
        self.gate.release_registration();
    }
}

#[cfg(test)]
mod tests {
    use super::AdmissionGate;
    use std::sync::{Arc, Barrier};

    #[test]
    fn closing_rejects_new_calls_and_drains_existing_calls_and_registrations() {
        for _round in 0..250 {
            let gate = AdmissionGate::new();
            let ready = Arc::new(Barrier::new(5));
            let release = Arc::new(Barrier::new(5));
            let mut workers = Vec::new();

            for _worker in 0..4 {
                let gate = Arc::clone(&gate);
                let ready = Arc::clone(&ready);
                let release = Arc::clone(&release);
                workers.push(std::thread::spawn(move || {
                    let _registration = gate.reserve_registration().expect("registration admitted");
                    let _call = gate.enter().expect("call admitted");
                    ready.wait();
                    release.wait();
                }));
            }

            ready.wait();
            let closing_gate = Arc::clone(&gate);
            let closer = std::thread::spawn(move || closing_gate.close_and_wait());

            while gate.enter().is_some() {
                std::thread::yield_now();
            }
            assert!(gate.reserve_registration().is_none());
            release.wait();
            for worker in workers {
                worker.join().expect("worker did not panic");
            }
            closer.join().expect("closer did not panic").unwrap();
            gate.mark_finalized().unwrap();
            assert!(gate.enter().is_none());
        }
    }
}
