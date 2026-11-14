//! Forwards to the library (`komira_ns_rename::run`).

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = komira_ns_rename::run(&args, &mut std::io::stdout(), &mut std::io::stderr());
    std::process::exit(code);
}
