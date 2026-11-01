// The Cargo variables a crate reads at compile time, set by `env`.
fn main() {
    println!("{} {}", env!("CARGO_PKG_NAME"), env!("CARGO_PKG_VERSION"));
}
