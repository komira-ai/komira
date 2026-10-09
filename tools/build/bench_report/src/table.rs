//! The parallelism table: one line per variant, function and thread count,
//! from checked reports.
//!
//! For each variant and function, the lines are N = 1, 4 and 16 and every
//! other N a report holds, ascending. A line's numbers come from its row:
//! rows/s = rows / wall time, per thread = rows/s / N, efficiency =
//! rows/s(N) / (N x rows/s(1)), from the same variant and function at N = 1.
//! A row with more threads than its host's CPUs, and a missing line whose N
//! is above the CPUs of the variant's first report, read
//! `not measured: <cpus> cpus`; any other missing line reads `missing`.
//! Flags: `noisy` when user + system CPU time is below 0.8 x wall x N, and
//! `throttled` when the cgroup throttled the run (nr_throttled went up).
//! The same variant, function and N in two rows is an error.

use crate::report::{Report, Row};

pub const STANDARD_THREADS: [u64; 3] = [1, 4, 16];

fn rows_per_s(r: &Row) -> f64 {
    r.rows as f64 * 1e9 / r.wall_ns as f64
}

fn noisy(r: &Row) -> bool {
    ((r.cpu_user_ns + r.cpu_sys_ns) as f64) < 0.8 * r.wall_ns as f64 * r.threads as f64
}

fn mib(bytes: u64) -> String {
    format!("{:.1} MiB", bytes as f64 / 1048576.0)
}

struct Group<'a> {
    variant: &'a str,
    function: &'a str,
    rows: Vec<(&'a Row, &'a Report)>,
}

fn groups(reports: &[Report]) -> Result<Vec<Group<'_>>, String> {
    let mut out: Vec<Group<'_>> = Vec::new();
    for rep in reports {
        for row in &rep.rows {
            let i = match out.iter().position(|g| g.variant == row.variant && g.function == row.function) {
                Some(i) => i,
                None => {
                    out.push(Group { variant: &row.variant, function: &row.function, rows: Vec::new() });
                    out.len() - 1
                }
            };
            if let Some((_, other)) = out[i].rows.iter().find(|(r, _)| r.threads == row.threads) {
                return Err(format!(
                    "{} {} N={} is in {} and in {}",
                    row.variant, row.function, row.threads, other.target, rep.target
                ));
            }
            out[i].rows.push((row, rep));
        }
    }
    Ok(out)
}

fn line(cells: &[String]) -> String {
    format!("| {} |\n", cells.join(" | "))
}

/// Renders the table and the facts of each report, in Markdown.
pub fn render(reports: &[Report]) -> Result<String, String> {
    let mut out = String::from("# Parallelism table\n\n");
    let mut ids: Vec<&str> = reports.iter().map(|r| r.run_id.as_str()).collect();
    ids.sort();
    ids.dedup();
    if ids.len() > 1 {
        out.push_str(&format!("The reports are of {} runs: {}.\n\n", ids.len(), ids.join(", ")));
    }
    out.push_str(&line(&[
        "variant", "function", "N", "rows/s", "rows/s per thread", "efficiency", "memory", "latency ns (median / p90)", "flags", "run_id",
    ].map(String::from)));
    out.push_str(&line(&["---"; 10].map(String::from)));
    for g in groups(reports)? {
        let base = g.rows.iter().find(|(r, _)| r.threads == 1).map(|(r, _)| rows_per_s(r));
        let first = g.rows[0].1;
        let mut ns: Vec<u64> = g.rows.iter().map(|(r, _)| r.threads).chain(STANDARD_THREADS).collect();
        ns.sort();
        ns.dedup();
        for n in ns {
            let head = [g.variant.to_string(), g.function.to_string(), n.to_string()];
            let Some((row, rep)) = g.rows.iter().find(|(r, _)| r.threads == n) else {
                let why = if n > first.host.cpus { format!("not measured: {} cpus", first.host.cpus) } else { "missing".to_string() };
                let mut cells = head.to_vec();
                cells.push(why);
                cells.extend(["-"; 5].map(String::from));
                cells.push(first.run_id.clone());
                out.push_str(&line(&cells));
                continue;
            };
            let mut cells = head.to_vec();
            if n > rep.host.cpus {
                cells.push(format!("not measured: {} cpus", rep.host.cpus));
                cells.extend(["-"; 5].map(String::from));
            } else {
                let rps = rows_per_s(row);
                cells.push(format!("{:.0}", rps));
                cells.push(format!("{:.0}", rps / n as f64));
                cells.push(match base {
                    Some(b) => format!("{:.2}", rps / (n as f64 * b)),
                    None => "-".to_string(),
                });
                cells.push(row.memory.iter().map(|(k, b)| format!("{} {}", k, mib(*b))).collect::<Vec<_>>().join(", "));
                cells.push(format!("{} / {}", row.latency.median, row.latency.p90));
                let mut flags = Vec::new();
                if noisy(row) {
                    flags.push("noisy");
                }
                if rep.host.nr_throttled_delta > 0 {
                    flags.push("throttled");
                }
                cells.push(if flags.is_empty() { "-".to_string() } else { flags.join(", ") });
            }
            cells.push(rep.run_id.clone());
            out.push_str(&line(&cells));
        }
    }
    out.push_str("\n## Reports\n\n");
    for r in reports {
        let h = &r.host;
        let b = &r.build;
        let opt: Vec<String> = b.opt_levels.iter().map(|(k, v)| format!("{}=O{}", k, v)).collect();
        let ver: Vec<String> = b.versions.iter().map(|(k, v)| format!("{} {}", k, v)).collect();
        out.push_str(&format!(
            "- `{}[report]` run_id={}: {} cpus ({}), cpu.max {}, nr_throttled +{}, throttled_usec +{}, loadavg {} {} {}; opt levels {}; coverage {}; versions {}; warmup discarded {}\n",
            r.target,
            r.run_id,
            h.cpus,
            h.cpu_model,
            h.cpu_max,
            h.nr_throttled_delta,
            h.throttled_usec_delta,
            h.loadavg[0],
            h.loadavg[1],
            h.loadavg[2],
            opt.join(" "),
            if b.coverage { "yes" } else { "no" },
            if ver.is_empty() { "-".to_string() } else { ver.join(", ") },
            r.rows.iter().map(|x| x.latency.warmup_discarded.to_string()).collect::<Vec<_>>().join("/"),
        ));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::parse;
    use crate::report::{check, tests::GOOD};

    fn report(edits: &[(&str, &str)]) -> Report {
        let mut doc = GOOD.to_string();
        for (from, to) in edits {
            assert_eq!(doc.matches(from).count(), 1, "{from}");
            doc = doc.replacen(from, to, 1);
        }
        check(&parse(&doc).unwrap()).unwrap()
    }

    /// GOOD's row at N threads, with `wall_ns` and CPU time scaled so the
    /// rows/s and efficiency are as the test wants.
    fn row_at(n: u64, wall_ns: u64, cpu_user_ns: u64) -> Row {
        let mut r = report(&[]).rows[0].clone();
        r.threads = n;
        r.wall_ns = wall_ns;
        r.cpu_user_ns = cpu_user_ns;
        r.cpu_sys_ns = 0;
        r
    }

    #[test]
    fn numbers_flags_and_missing_lines() {
        // 1M rows: N=1 in 1 s (1M rows/s), N=4 in 0.5 s (2M rows/s, efficiency 0.5).
        // The N=4 row used 1.5 s of CPU, under 0.8 x 0.5 x 4 = 1.6 s: noisy.
        let mut r = report(&[]);
        r.rows = vec![row_at(1, 1_000_000_000, 1_000_000_000), row_at(4, 500_000_000, 1_500_000_000)];
        let got = render(&[r]).unwrap();
        let want = "# Parallelism table\n\n\
| variant | function | N | rows/s | rows/s per thread | efficiency | memory | latency ns (median / p90) | flags | run_id |\n\
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n\
| v | per_batch | 1 | 1000000 | 1000000 | 1.00 | rss_delta_per_thread 1.0 MiB | 20 / 30 | - | r1 |\n\
| v | per_batch | 4 | 2000000 | 500000 | 0.50 | rss_delta_per_thread 1.0 MiB | 20 / 30 | noisy | r1 |\n\
| v | per_batch | 16 | not measured: 8 cpus | - | - | - | - | - | r1 |\n\
\n## Reports\n\n\
- `komira//src/tests/e2e/x:x_bench[report]` run_id=r1: 8 cpus (Test CPU), cpu.max max 100000, nr_throttled +0, throttled_usec +0, loadavg 0.5 1 1.5; opt levels engine=O3 driver=O1; coverage no; versions python 3.13.9; warmup discarded 4/4\n";
        assert_eq!(got, want);
    }

    #[test]
    fn noisy_boundary() {
        // Exactly 0.8 x wall x N is not noisy; one nanosecond less is.
        assert!(!noisy(&row_at(4, 1_000_000_000, 3_200_000_000)));
        assert!(noisy(&row_at(4, 1_000_000_000, 3_199_999_999)));
        let mut r = row_at(1, 1_000_000_000, 700_000_000);
        r.cpu_sys_ns = 100_000_000;
        assert!(!noisy(&r));
    }

    #[test]
    fn over_cpus_missing_and_no_base() {
        // A 16-thread row on 8 CPUs is not measured whatever its numbers;
        // N=4 is missing (4 <= 8 CPUs); with no N=1 row, efficiency is "-".
        let mut r = report(&[("\"nr_throttled_delta\": 0", "\"nr_throttled_delta\": 2")]);
        r.rows = vec![row_at(2, 1_000_000_000, 2_000_000_000), row_at(16, 1_000_000_000, 16_000_000_000)];
        let got = render(&[r]).unwrap();
        assert!(got.contains("| v | per_batch | 1 | missing | - | - | - | - | - | r1 |\n"), "{got}");
        assert!(got.contains("| v | per_batch | 2 | 1000000 | 500000 | - | rss_delta_per_thread 1.0 MiB | 20 / 30 | throttled | r1 |\n"), "{got}");
        assert!(got.contains("| v | per_batch | 4 | missing |"), "{got}");
        assert!(got.contains("| v | per_batch | 16 | not measured: 8 cpus | - | - | - | - | - | r1 |\n"), "{got}");
        let lines: Vec<&str> = got.lines().filter(|l| l.starts_with("| v ")).collect();
        let ns: Vec<&str> = lines.iter().map(|l| l.split(" | ").nth(2).unwrap()).collect();
        assert_eq!(ns, ["1", "2", "4", "16"]);
    }

    #[test]
    fn several_reports_groups_and_duplicates() {
        let a = report(&[]);
        let mut b = report(&[("\"run_id\": \"r1\"", "\"run_id\": \"r0\""), ("x:x_bench", "y:y_bench"), ("\"coverage\": false", "\"coverage\": true"), ("{\"python\": \"3.13.9\"}", "{}")]);
        b.rows[0].variant = "w".to_string();
        b.rows[0].memory = vec![("pss".to_string(), 3 * 1048576 / 2), ("uss".to_string(), 0)];
        let got = render(&[a.clone(), b.clone()]).unwrap();
        assert!(got.starts_with("# Parallelism table\n\nThe reports are of 2 runs: r0, r1.\n\n"), "{got}");
        // Groups keep the order of the reports.
        let v = got.find("| v | per_batch | 1 |").unwrap();
        let w = got.find("| w | per_batch | 1 | 1000000 | 1000000 | 1.00 | pss 1.5 MiB, uss 0.0 MiB |").unwrap();
        assert!(v < w, "{got}");
        assert!(got.contains("- `komira//src/tests/e2e/y:y_bench[report]` run_id=r0: "), "{got}");
        assert!(got.contains("; coverage yes; versions -; "), "{got}");
        // One run id: no runs line.
        assert!(!render(&[a.clone()]).unwrap().contains("runs:"));
        // The same variant, function and N twice.
        assert_eq!(
            render(&[a.clone(), a]),
            Err("v per_batch N=1 is in komira//src/tests/e2e/x:x_bench and in komira//src/tests/e2e/x:x_bench".to_string())
        );
    }
}
