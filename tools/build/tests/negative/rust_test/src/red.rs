//! One passing and one failing #[test]. The harness must report both: a
//! failing test that aborted the process (a broken unwinder in the link)
//! would not reach `1 passed; 1 failed`.

pub fn add(a: u32, b: u32) -> u32 {
    a + b
}

#[cfg(test)]
mod tests {
    use super::add;

    #[test]
    fn passes() {
        assert_eq!(add(2, 2), 4);
    }

    #[test]
    fn fails() {
        assert_eq!(add(2, 2), 5, "planted failure");
    }
}
