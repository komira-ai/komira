// What a build script writes to OUT_DIR and the crate includes.
include!(concat!(env!("OUT_DIR"), "/generated.rs"));

pub fn describe() -> String {
    format!("{} {}", GREETING, LUCKY)
}
