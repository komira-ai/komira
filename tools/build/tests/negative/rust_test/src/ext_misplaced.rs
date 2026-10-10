//! An external test placed outside tests/ (ext_outside): test_srcs refuses it.
//! Were it accepted, `src/` would be cut as if it were `tests/`, and this file
//! would build and pass as a test crate named `xt_misplaced`.

#[test]
fn adds() {
    assert_eq!(ext::add(1, 1), 2);
}
