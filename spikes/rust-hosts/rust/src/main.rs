use std::ffi::{c_int, c_void};

unsafe extern "C" {
    fn adainit();
    fn adafinal();
    fn flyology_rust_host_run() -> c_int;
    fn __gnat_register_thread() -> *mut c_void;
    fn __gnat_unregister_thread();
}

fn run_ada(label: &str) -> Result<(), String> {
    let status = unsafe { flyology_rust_host_run() };
    if status == 0 {
        println!("PASS {label}");
        Ok(())
    } else {
        Err(format!("Ada probe failed on {label} with status {status}"))
    }
}

fn main() {
    unsafe { adainit() };

    let result = (|| {
        run_ada("rust-main-thread")?;

        std::thread::spawn(|| {
            let task = unsafe { __gnat_register_thread() };
            if task.is_null() {
                return Err("GNAT rejected Rust std-thread registration".to_owned());
            }

            let result = run_ada("registered-rust-std-thread");
            unsafe { __gnat_unregister_thread() };
            result
        })
        .join()
        .map_err(|_| "Rust std thread panicked".to_owned())??;

        Ok::<(), String>(())
    })();

    unsafe { adafinal() };

    match result {
        Ok(()) => println!("PASS adafinal"),
        Err(error) => {
            eprintln!("FAIL {error}");
            std::process::exit(1);
        }
    }
}
