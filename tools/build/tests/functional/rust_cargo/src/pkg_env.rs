// Every variable cargo_pkg_env sets.
fn main() {
    println!(
        "{}|{}|{}|{}|{}|{}|{}",
        env!("CARGO_PKG_NAME"),
        env!("CARGO_PKG_VERSION"),
        env!("CARGO_PKG_VERSION_MAJOR"),
        env!("CARGO_PKG_VERSION_MINOR"),
        env!("CARGO_PKG_VERSION_PATCH"),
        env!("CARGO_PKG_VERSION_PRE"),
        env!("CARGO_CRATE_NAME"),
    );
}
