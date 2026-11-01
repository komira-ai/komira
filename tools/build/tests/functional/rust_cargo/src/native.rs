extern "C" {
    fn komira_rust_native_add(a: i32, b: i32) -> i32;
}

fn main() {
    println!("{}", unsafe { komira_rust_native_add(40, 2) });
}
