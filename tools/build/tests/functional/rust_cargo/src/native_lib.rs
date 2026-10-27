// A `-sys`-style library: it declares the C function, and the archive comes
// with it (`native_deps` on the library).
extern "C" {
    fn komira_rust_native_add(a: i32, b: i32) -> i32;
}

pub fn add(a: i32, b: i32) -> i32 {
    unsafe { komira_rust_native_add(a, b) }
}
