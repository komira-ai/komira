extern "C" {
    fn komira_rust_native_add(a: i32, b: i32) -> i32;
}

#[test]
fn adds_in_c() {
    assert_eq!(unsafe { komira_rust_native_add(2, 3) }, 5);
}
