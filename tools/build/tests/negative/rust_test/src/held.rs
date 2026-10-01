//! Two passing #[test]s and one failing one, for the holds.

#[cfg(test)]
mod tests {
    #[test]
    fn passes() {}

    #[test]
    fn also_passes() {}

    #[test]
    fn fails() {
        assert_eq!(2 + 2, 5, "planted failure");
    }
}
