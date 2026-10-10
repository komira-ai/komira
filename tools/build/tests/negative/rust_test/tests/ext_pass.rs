//! An external test that passes, using a module under tests/ that is not a
//! test crate of its own.

mod common;

#[test]
fn adds() {
    assert_eq!(ext::add(2, 2), common::FOUR);
}
