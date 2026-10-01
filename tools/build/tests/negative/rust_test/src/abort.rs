//! One passing #[test] and one that aborts the process. A held test must
//! fail with libtest's own verdict; an abort leaves no summary, so holding
//! it measures nothing.

#[cfg(test)]
mod tests {
    #[test]
    fn passes() {}

    #[test]
    fn aborts() {
        std::process::abort();
    }
}
