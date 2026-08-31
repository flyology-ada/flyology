use std::panic::{AssertUnwindSafe, catch_unwind};

const PANICKED: u32 = 2;

#[unsafe(no_mangle)]
pub extern "C" fn flyology_rust_unwind_probe() -> u32 {
    catch_unwind(AssertUnwindSafe(|| {
        panic!("intentional Rust unwind spike panic");
    }))
    .map_or(PANICKED, |()| 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panic_is_translated_inside_rust() {
        assert_eq!(flyology_rust_unwind_probe(), PANICKED);
    }
}
