use std::cell::Cell;
use std::ffi::c_void;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;

const OK: u32 = 0;
const INVALID_ARGUMENT: u32 = 1;
const PANICKED: u32 = 2;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct AbiRecord {
    pub tag: u32,
    pub flags: u32,
    pub value: u64,
}

#[repr(C)]
pub struct AbiLayout {
    pub record_size: usize,
    pub record_alignment: usize,
    pub tag_offset: usize,
    pub flags_offset: usize,
    pub value_offset: usize,
}

struct Blob {
    bytes: Vec<u8>,
}

thread_local! {
    static TLS_COUNTER: Cell<u32> = const { Cell::new(0) };
}

fn guarded(action: impl FnOnce() -> u32) -> u32 {
    catch_unwind(AssertUnwindSafe(action)).unwrap_or(PANICKED)
}

fn bump_tls() -> u32 {
    TLS_COUNTER.with(|counter| {
        let next = counter.get() + 1;
        counter.set(next);
        next
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn flyology_rust_abi_version() -> u32 {
    1
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn flyology_rust_abi_layout(output: *mut AbiLayout) -> u32 {
    guarded(|| {
        if output.is_null() {
            return INVALID_ARGUMENT;
        }
        // SAFETY: The caller supplies writable storage for one C-layout value.
        unsafe {
            output.write(AbiLayout {
                record_size: size_of::<AbiRecord>(),
                record_alignment: align_of::<AbiRecord>(),
                tag_offset: std::mem::offset_of!(AbiRecord, tag),
                flags_offset: std::mem::offset_of!(AbiRecord, flags),
                value_offset: std::mem::offset_of!(AbiRecord, value),
            });
        }
        OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn flyology_rust_abi_round_trip(
    input: *const AbiRecord,
    output: *mut AbiRecord,
) -> u32 {
    guarded(|| {
        if input.is_null() || output.is_null() {
            return INVALID_ARGUMENT;
        }
        // SAFETY: The checked pointers name one readable and one writable
        // C-layout record for the duration of this call.
        let input = unsafe { input.read() };
        unsafe {
            output.write(AbiRecord {
                tag: input.tag.wrapping_add(1),
                flags: input.flags ^ 0xa5a5_a5a5,
                value: input.value.wrapping_add(0x0102_0304_0506_0708),
            });
        }
        OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn flyology_rust_abi_sum_bytes(
    bytes: *const u8,
    length: usize,
    output: *mut u64,
) -> u32 {
    guarded(|| {
        if output.is_null() || (bytes.is_null() && length != 0) {
            return INVALID_ARGUMENT;
        }
        let sum = if length == 0 {
            0
        } else {
            // SAFETY: A nonzero length requires a checked non-null pointer;
            // the caller retains this immutable span for the call.
            unsafe { std::slice::from_raw_parts(bytes, length) }
                .iter()
                .map(|byte| u64::from(*byte))
                .sum()
        };
        unsafe { output.write(sum) };
        OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn flyology_rust_abi_blob_new(
    length: usize,
    output: *mut *mut c_void,
) -> u32 {
    guarded(|| {
        if output.is_null() {
            return INVALID_ARGUMENT;
        }
        let bytes = (0..length).map(|index| (index & 0xff) as u8).collect();
        let blob = Box::new(Blob { bytes });
        unsafe { output.write(Box::into_raw(blob).cast()) };
        OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn flyology_rust_abi_blob_copy(
    handle: *const c_void,
    output: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> u32 {
    guarded(|| {
        if handle.is_null() || written.is_null() || (output.is_null() && capacity != 0) {
            return INVALID_ARGUMENT;
        }
        let blob = unsafe { &*handle.cast::<Blob>() };
        if capacity < blob.bytes.len() {
            return INVALID_ARGUMENT;
        }
        if !blob.bytes.is_empty() {
            unsafe { ptr::copy_nonoverlapping(blob.bytes.as_ptr(), output, blob.bytes.len()) };
        }
        unsafe { written.write(blob.bytes.len()) };
        OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn flyology_rust_abi_blob_drop(handle: *mut c_void) -> u32 {
    guarded(|| {
        if handle.is_null() {
            return INVALID_ARGUMENT;
        }
        // SAFETY: The handle came from blob_new and is consumed exactly once.
        drop(unsafe { Box::from_raw(handle.cast::<Blob>()) });
        OK
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn flyology_rust_abi_panic_probe() -> u32 {
    guarded(|| panic!("intentional Rust ABI spike panic"))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn flyology_rust_abi_tls_probe(
    main_first: *mut u32,
    main_second: *mut u32,
    child_first: *mut u32,
    child_second: *mut u32,
) -> u32 {
    guarded(|| {
        if main_first.is_null()
            || main_second.is_null()
            || child_first.is_null()
            || child_second.is_null()
        {
            return INVALID_ARGUMENT;
        }
        let first = bump_tls();
        let second = bump_tls();
        let child = std::thread::spawn(|| (bump_tls(), bump_tls()));
        let Ok((child_one, child_two)) = child.join() else {
            return PANICKED;
        };
        unsafe {
            main_first.write(first);
            main_second.write(second);
            child_first.write(child_one);
            child_second.write(child_two);
        }
        OK
    })
}
