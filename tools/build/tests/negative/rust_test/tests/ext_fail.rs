//! One passing and one failing external test: the run reports both.

#[test]
fn passes() {
    assert_eq!(ext::add(1, 1), 2);
}

#[test]
fn fails() {
    assert_eq!(ext::add(2, 2), 5, "planted failure");
}
