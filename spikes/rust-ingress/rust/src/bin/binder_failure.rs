use std::ffi::c_int;

unsafe extern "C" {
    fn adainit();
    fn adafinal();
    fn flyology_lifecycle_failure_touch() -> c_int;
}

fn main() {
    unsafe { adainit() };
    println!("BINDER_INIT_RETURNED");
    let status = unsafe { flyology_lifecycle_failure_touch() };
    if status != 0 {
        std::process::exit(2);
    }
    unsafe { adafinal() };
    println!("BINDER_FINAL_RETURNED");
}
