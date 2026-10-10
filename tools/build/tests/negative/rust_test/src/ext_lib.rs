//! A library with no inline tests: its tests are external (`tests/*.rs`),
//! compiled against the library as another crate, so they see only its
//! public API.

pub fn add(a: u32, b: u32) -> u32 {
    a + b
}
