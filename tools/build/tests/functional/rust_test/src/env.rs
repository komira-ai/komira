//! The harness's environment is exactly the three variables the runner sets,
//! so nothing in the action's environment (RUST_TEST_*, RUST_MIN_STACK, ...)
//! reaches a test.

#[cfg(test)]
mod tests {
    #[test]
    fn env_is_scrubbed() {
        let mut names: Vec<String> = std::env::vars_os()
            .map(|(k, _)| k.to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert_eq!(names, ["HOME", "PATH", "TMPDIR"]);
    }
}
