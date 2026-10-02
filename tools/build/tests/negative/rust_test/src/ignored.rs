//! One passing #[test] and one #[ignore]d one, which libtest does not run.

#[cfg(test)]
mod tests {
    #[test]
    fn passes() {}

    #[test]
    #[ignore]
    fn muted() {
        panic!("never runs");
    }
}
