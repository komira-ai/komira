//! A library whose tests are external (`tests/*.rs`), compiled against it as
//! another crate, so they see only its public API; `both` also welds this
//! file's inline test.

pub fn add(a: u32, b: u32) -> u32 {
    a + b
}

#[cfg(test)]
mod tests {
    use super::add;

    #[test]
    fn adds() {
        assert_eq!(add(2, 3), 5);
    }
}
