// Two crates both named `shared`, as two versions of one registry crate are:
// the first is reached as `shared`, the second under an alias.
fn main() {
    println!("{} {}", shared::id(), shared_two::id());
}
