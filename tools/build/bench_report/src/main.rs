//! bench_report: checks bench reports against their schema and merges them
//! into the parallelism table.
//!
//!     bench_report --out <table.md> --report <report.json> [--report <report.json>]...
//!
//! Each `--report` is the `[report]` of a report test (a `py_test` with a
//! `run_id`): one JSON object of the schema in `report.rs`. The table
//! (`table.rs`) is written to `--out` only if every report passes the
//! check. Exit status 2 is a usage error, 1 a report that is refused, with
//! `bench_report: <file>: <where>: <why>` on standard error.

mod json;
mod report;
mod table;

use std::process::ExitCode;

const USAGE: &str = "usage: bench_report --out <table.md> --report <report.json> [--report <report.json>]...";

/// The output path and the table, or an exit status and a message.
fn cli(args: &[String], read: &dyn Fn(&str) -> std::io::Result<String>) -> Result<(String, String), (u8, String)> {
    let usage = |why: &str| Err((2, format!("bench_report: {}\n{}", why, USAGE)));
    let mut out = None;
    let mut paths = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let Some(v) = args.get(i + 1) else {
            return usage(&format!("{} needs a value", args[i]));
        };
        match args[i].as_str() {
            "--out" if out.is_none() => out = Some(v.clone()),
            "--out" => return usage("--out is given twice"),
            "--report" => paths.push(v.clone()),
            other => return usage(&format!("unknown argument {}", other)),
        }
        i += 2;
    }
    let Some(out) = out else {
        return usage("--out is required");
    };
    if paths.is_empty() {
        return usage("at least one --report is required");
    }
    let mut reports = Vec::new();
    for p in &paths {
        let fail = |why: String| (1, format!("bench_report: {}: {}", p, why));
        let text = read(p).map_err(|e| fail(format!("cannot read: {}", e)))?;
        let doc = json::parse(&text).map_err(|e| fail(format!("not JSON: {}", e)))?;
        reports.push(report::check(&doc).map_err(fail)?);
    }
    let md = table::render(&reports).map_err(|e| (1, format!("bench_report: {}", e)))?;
    Ok((out, md))
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match cli(&args, &|p| std::fs::read_to_string(p)) {
        Ok((out, md)) => match std::fs::write(&out, md) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("bench_report: cannot write {}: {}", out, e);
                ExitCode::from(1)
            }
        },
        Err((status, msg)) => {
            eprintln!("{}", msg);
            ExitCode::from(status)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::report::tests::GOOD;

    fn files(path: &str) -> std::io::Result<String> {
        match path {
            "good.json" => Ok(GOOD.to_string()),
            "other.json" => Ok(GOOD.replacen("x:x_bench", "y:y_bench", 1).replacen("\"variant\": \"v\"", "\"variant\": \"w\"", 1)),
            "broken.json" => Ok("{\"run_id\": ".to_string()),
            "bad_schema.json" => Ok(GOOD.replacen("\"cpus\": 8", "\"cpus\": 0", 1)),
            _ => Err(std::io::Error::new(std::io::ErrorKind::NotFound, "no such file")),
        }
    }

    fn run(args: &[&str]) -> Result<(String, String), (u8, String)> {
        let args: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        cli(&args, &files)
    }

    fn usage(why: &str) -> Result<(String, String), (u8, String)> {
        Err((2, format!("bench_report: {}\n{}", why, USAGE)))
    }

    #[test]
    fn usage_errors() {
        assert_eq!(run(&[]), usage("--out is required"));
        assert_eq!(run(&["--out", "t.md"]), usage("at least one --report is required"));
        assert_eq!(run(&["--report", "good.json"]), usage("--out is required"));
        assert_eq!(run(&["--out"]), usage("--out needs a value"));
        assert_eq!(run(&["--out", "a", "--out", "b", "--report", "good.json"]), usage("--out is given twice"));
        assert_eq!(run(&["--out", "a", "good.json", "x"]), usage("unknown argument good.json"));
    }

    #[test]
    fn refused_reports_name_the_file() {
        assert_eq!(
            run(&["--out", "t.md", "--report", "good.json", "--report", "missing.json"]),
            Err((1, "bench_report: missing.json: cannot read: no such file".to_string()))
        );
        assert_eq!(
            run(&["--out", "t.md", "--report", "broken.json"]),
            Err((1, "bench_report: broken.json: not JSON: byte 11: unexpected end of input".to_string()))
        );
        assert_eq!(
            run(&["--out", "t.md", "--report", "bad_schema.json"]),
            Err((1, "bench_report: bad_schema.json: host.cpus: 0 is below 1".to_string()))
        );
        assert_eq!(
            run(&["--out", "t.md", "--report", "good.json", "--report", "good.json"]),
            Err((1, "bench_report: v per_batch N=1 is in komira//src/tests/e2e/x:x_bench and in komira//src/tests/e2e/x:x_bench".to_string()))
        );
    }

    #[test]
    fn merges_reports_in_order() {
        let (out, md) = run(&["--out", "t.md", "--report", "good.json", "--report", "other.json"]).unwrap();
        assert_eq!(out, "t.md");
        let v = md.find("| v | per_batch | 1 | 1000000 |").expect(&md);
        let w = md.find("| w | per_batch | 1 | 1000000 |").expect(&md);
        assert!(v < w);
        assert!(md.contains("- `komira//src/tests/e2e/y:y_bench[report]` run_id=r1: "), "{md}");
    }
}
