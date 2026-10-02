//! A #[test] that never returns.

#[cfg(test)]
mod tests {
    #[test]
    fn hangs() {
        loop {
            std::thread::sleep(std::time::Duration::from_secs(60));
        }
    }
}
