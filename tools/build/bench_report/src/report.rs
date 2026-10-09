//! The bench report schema, `komira-bench-report-1`: what a report test
//! writes, checked key by key. A key the schema does not name is an error,
//! so a misspelt field is refused rather than dropped.
//!
//! ```text
//! run_id, target   strings, written by the py_test runner
//! schema           "komira-bench-report-1"
//! host             cpus (affinity size, >= 1), cpu_model, cpu_max (cgroup cpu.max),
//!                  loadavg [3 numbers], nr_throttled_delta, throttled_usec_delta
//! build            opt_levels {component: "0".."3"} (at least one), coverage (bool),
//!                  versions {name: version}
//! rows             at least one row:
//!   variant, function   names: a-z 0-9 _ '
//!   threads             >= 1
//!   rows, batches, calls  >= 1, and calls == batches (a runtime call per batch, never per row)
//!   wall_ns             >= 1; cpu_user_ns, cpu_sys_ns, invol_ctx_switches >= 0
//!   memory              {pss | uss | rss_delta_per_thread | node_external | v8_heap
//!                        | memory_report: bytes}, at least one; memory_report is what a
//!                        runtime's `memory_report` entry returned (bytes outside Arrow buffers)
//!   latency_ns          warmup_discarded >= 0, samples >= 30, min <= median <= p90 <= max
//! ```
//!
//! Counts are JSON numbers that must be whole and at most 2^53.

use crate::json::Json;

pub const SCHEMA: &str = "komira-bench-report-1";

pub const MEMORY_KINDS: [&str; 6] = ["pss", "uss", "rss_delta_per_thread", "node_external", "v8_heap", "memory_report"];

#[derive(Clone, Debug, PartialEq)]
pub struct Host {
    pub cpus: u64,
    pub cpu_model: String,
    pub cpu_max: String,
    pub loadavg: [f64; 3],
    pub nr_throttled_delta: u64,
    pub throttled_usec_delta: u64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Build {
    pub opt_levels: Vec<(String, String)>,
    pub coverage: bool,
    pub versions: Vec<(String, String)>,
}

// Every field is checked; the table shows only some of them.
#[allow(dead_code)]
#[derive(Clone, Debug, PartialEq)]
pub struct Latency {
    pub warmup_discarded: u64,
    pub samples: u64,
    pub min: u64,
    pub median: u64,
    pub p90: u64,
    pub max: u64,
}

// Every field is checked; the table shows only some of them.
#[allow(dead_code)]
#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    pub variant: String,
    pub function: String,
    pub threads: u64,
    pub rows: u64,
    pub batches: u64,
    pub calls: u64,
    pub wall_ns: u64,
    pub cpu_user_ns: u64,
    pub cpu_sys_ns: u64,
    pub invol_ctx_switches: u64,
    pub memory: Vec<(String, u64)>,
    pub latency: Latency,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Report {
    pub run_id: String,
    pub target: String,
    pub host: Host,
    pub build: Build,
    pub rows: Vec<Row>,
}

/// One object, read key by key: every key must be taken, and none twice.
struct Obj<'a> {
    path: String,
    fields: &'a [(String, Json)],
    taken: Vec<&'a str>,
}

fn obj<'a>(path: &str, v: &'a Json) -> Result<Obj<'a>, String> {
    match v {
        Json::Object(fields) => Ok(Obj { path: path.to_string(), fields, taken: Vec::new() }),
        other => Err(format!("{}: is {}, not an object", if path.is_empty() { "report" } else { path }, other.kind())),
    }
}

fn join(path: &str, key: &str) -> String {
    if path.is_empty() {
        key.to_string()
    } else {
        format!("{}.{}", path, key)
    }
}

impl<'a> Obj<'a> {
    fn get(&mut self, key: &'a str) -> Result<(&'a Json, String), String> {
        self.taken.push(key);
        let p = join(&self.path, key);
        match self.fields.iter().find(|(k, _)| k == key) {
            Some((_, v)) => Ok((v, p)),
            None => Err(format!("{}: missing", p)),
        }
    }

    fn str(&mut self, key: &'a str) -> Result<String, String> {
        let (v, p) = self.get(key)?;
        string(&p, v)
    }

    fn count(&mut self, key: &'a str, min: u64) -> Result<u64, String> {
        let (v, p) = self.get(key)?;
        count(&p, v, min)
    }

    /// Fails on the first key that was not taken.
    fn done(self) -> Result<(), String> {
        for (k, _) in self.fields {
            if !self.taken.contains(&k.as_str()) {
                return Err(format!("{}: not a key of the schema", join(&self.path, k)));
            }
        }
        Ok(())
    }
}

fn string(path: &str, v: &Json) -> Result<String, String> {
    match v {
        Json::Str(s) if !s.is_empty() => Ok(s.clone()),
        Json::Str(_) => Err(format!("{}: is empty", path)),
        other => Err(format!("{}: is {}, not a string", path, other.kind())),
    }
}

fn number(path: &str, v: &Json) -> Result<f64, String> {
    match v {
        Json::Number(n) => Ok(*n),
        other => Err(format!("{}: is {}, not a number", path, other.kind())),
    }
}

const MAX_COUNT: f64 = 9007199254740992.0; // 2^53

fn count(path: &str, v: &Json, min: u64) -> Result<u64, String> {
    let n = number(path, v)?;
    if n.fract() != 0.0 || n < 0.0 || n > MAX_COUNT {
        return Err(format!("{}: {} is not a whole number from 0 to 2^53", path, n));
    }
    let n = n as u64;
    if n < min {
        return Err(format!("{}: {} is below {}", path, n, min));
    }
    Ok(n)
}

fn name(path: &str, v: &Json) -> Result<String, String> {
    let s = string(path, v)?;
    if !s.bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_' || c == b'\'') {
        return Err(format!("{}: '{}' is not a name (a-z 0-9 _ ')", path, s));
    }
    Ok(s)
}

/// A non-empty object of string values, in the order written.
fn string_map(path: &str, v: &Json, allow_empty: bool) -> Result<Vec<(String, String)>, String> {
    let o = obj(path, v)?;
    if o.fields.is_empty() && !allow_empty {
        return Err(format!("{}: is empty", path));
    }
    o.fields.iter().map(|(k, v)| Ok((k.clone(), string(&join(path, k), v)?))).collect()
}

fn host(path: &str, v: &Json) -> Result<Host, String> {
    let mut o = obj(path, v)?;
    let cpus = o.count("cpus", 1)?;
    let cpu_model = o.str("cpu_model")?;
    let cpu_max = o.str("cpu_max")?;
    let (lv, lp) = o.get("loadavg")?;
    let loadavg = match lv {
        Json::Array(a) if a.len() == 3 => {
            let mut out = [0.0; 3];
            for (i, x) in a.iter().enumerate() {
                let p = format!("{}[{}]", lp, i);
                out[i] = number(&p, x)?;
                if out[i] < 0.0 {
                    return Err(format!("{}: {} is negative", p, out[i]));
                }
            }
            out
        }
        _ => return Err(format!("{}: is not an array of three numbers", lp)),
    };
    let nr_throttled_delta = o.count("nr_throttled_delta", 0)?;
    let throttled_usec_delta = o.count("throttled_usec_delta", 0)?;
    o.done()?;
    Ok(Host { cpus, cpu_model, cpu_max, loadavg, nr_throttled_delta, throttled_usec_delta })
}

fn build(path: &str, v: &Json) -> Result<Build, String> {
    let mut o = obj(path, v)?;
    let (ov, op) = o.get("opt_levels")?;
    let opt_levels = string_map(&op, ov, false)?;
    for (k, level) in &opt_levels {
        if !["0", "1", "2", "3"].contains(&level.as_str()) {
            return Err(format!("{}: '{}' is not one of 0, 1, 2, 3", join(&op, k), level));
        }
    }
    let (cv, cp) = o.get("coverage")?;
    let coverage = match cv {
        Json::Bool(b) => *b,
        other => return Err(format!("{}: is {}, not a boolean", cp, other.kind())),
    };
    let (vv, vp) = o.get("versions")?;
    let versions = string_map(&vp, vv, true)?;
    o.done()?;
    Ok(Build { opt_levels, coverage, versions })
}

fn latency(path: &str, v: &Json) -> Result<Latency, String> {
    let mut o = obj(path, v)?;
    let l = Latency {
        warmup_discarded: o.count("warmup_discarded", 0)?,
        samples: o.count("samples", 30)?,
        min: o.count("min", 0)?,
        median: o.count("median", 0)?,
        p90: o.count("p90", 0)?,
        max: o.count("max", 0)?,
    };
    o.done()?;
    if !(l.min <= l.median && l.median <= l.p90 && l.p90 <= l.max) {
        return Err(format!("{}: min {} <= median {} <= p90 {} <= max {} does not hold", path, l.min, l.median, l.p90, l.max));
    }
    Ok(l)
}

fn row(path: &str, v: &Json) -> Result<Row, String> {
    let mut o = obj(path, v)?;
    let (vv, vp) = o.get("variant")?;
    let variant = name(&vp, vv)?;
    let (fv, fp) = o.get("function")?;
    let function = name(&fp, fv)?;
    let threads = o.count("threads", 1)?;
    let rows = o.count("rows", 1)?;
    let batches = o.count("batches", 1)?;
    let calls = o.count("calls", 1)?;
    let wall_ns = o.count("wall_ns", 1)?;
    let cpu_user_ns = o.count("cpu_user_ns", 0)?;
    let cpu_sys_ns = o.count("cpu_sys_ns", 0)?;
    let invol_ctx_switches = o.count("invol_ctx_switches", 0)?;
    let (mv, mp) = o.get("memory")?;
    let m = obj(&mp, mv)?;
    if m.fields.is_empty() {
        return Err(format!("{}: is empty", mp));
    }
    let mut memory = Vec::new();
    for (k, b) in m.fields {
        let p = join(&mp, k);
        if !MEMORY_KINDS.contains(&k.as_str()) {
            return Err(format!("{}: not a memory kind ({})", p, MEMORY_KINDS.join(", ")));
        }
        memory.push((k.clone(), count(&p, b, 0)?));
    }
    let (lv, lp) = o.get("latency_ns")?;
    let latency = latency(&lp, lv)?;
    o.done()?;
    if calls != batches {
        return Err(format!("{}: {} runtime calls for {} batches; a runtime is called once per batch", path, calls, batches));
    }
    Ok(Row {
        variant,
        function,
        threads,
        rows,
        batches,
        calls,
        wall_ns,
        cpu_user_ns,
        cpu_sys_ns,
        invol_ctx_switches,
        memory,
        latency,
    })
}

/// Checks one parsed report against the schema.
pub fn check(v: &Json) -> Result<Report, String> {
    let mut o = obj("", v)?;
    let run_id = o.str("run_id")?;
    let target = o.str("target")?;
    let (sv, sp) = o.get("schema")?;
    if *sv != Json::Str(SCHEMA.to_string()) {
        return Err(format!("{}: is not \"{}\"", sp, SCHEMA));
    }
    let (hv, hp) = o.get("host")?;
    let host = host(&hp, hv)?;
    let (bv, bp) = o.get("build")?;
    let build = build(&bp, bv)?;
    let (rv, rp) = o.get("rows")?;
    let rows = match rv {
        Json::Array(a) if !a.is_empty() => a.iter().enumerate().map(|(i, r)| row(&format!("{}[{}]", rp, i), r)).collect::<Result<Vec<_>, _>>()?,
        Json::Array(_) => return Err(format!("{}: is empty", rp)),
        other => return Err(format!("{}: is {}, not an array", rp, other.kind())),
    };
    o.done()?;
    Ok(Report { run_id, target, host, build, rows })
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::json::parse;

    /// A report that passes the check; tests edit one value of it.
    pub const GOOD: &str = r#"{
  "run_id": "r1",
  "target": "komira//src/tests/e2e/x:x_bench",
  "schema": "komira-bench-report-1",
  "host": {"cpus": 8, "cpu_model": "Test CPU", "cpu_max": "max 100000", "loadavg": [0.5, 1, 1.5],
           "nr_throttled_delta": 0, "throttled_usec_delta": 0},
  "build": {"opt_levels": {"engine": "3", "driver": "1"}, "coverage": false, "versions": {"python": "3.13.9"}},
  "rows": [
    {"variant": "v", "function": "per_batch", "threads": 1, "rows": 1000000, "batches": 100, "calls": 100,
     "wall_ns": 1000000000, "cpu_user_ns": 900000000, "cpu_sys_ns": 100000000, "invol_ctx_switches": 3,
     "memory": {"rss_delta_per_thread": 1048576},
     "latency_ns": {"warmup_discarded": 4, "samples": 30, "min": 10, "median": 20, "p90": 30, "max": 40}}
  ]
}"#;

    fn checked(doc: &str) -> Result<Report, String> {
        check(&parse(doc).expect("test documents parse"))
    }

    /// GOOD with `from` replaced by `to` (exactly once).
    fn with(from: &str, to: &str) -> String {
        assert_eq!(GOOD.matches(from).count(), 1, "{from}");
        GOOD.replacen(from, to, 1)
    }

    #[test]
    fn good_report() {
        let r = checked(GOOD).unwrap();
        assert_eq!(r.run_id, "r1");
        assert_eq!(r.target, "komira//src/tests/e2e/x:x_bench");
        assert_eq!(
            r.host,
            Host {
                cpus: 8,
                cpu_model: "Test CPU".into(),
                cpu_max: "max 100000".into(),
                loadavg: [0.5, 1.0, 1.5],
                nr_throttled_delta: 0,
                throttled_usec_delta: 0,
            }
        );
        assert_eq!(r.build.opt_levels, vec![("engine".to_string(), "3".to_string()), ("driver".into(), "1".into())]);
        assert!(!r.build.coverage);
        assert_eq!(r.build.versions, vec![("python".to_string(), "3.13.9".to_string())]);
        let row = &r.rows[0];
        assert_eq!((row.variant.as_str(), row.function.as_str(), row.threads), ("v", "per_batch", 1));
        assert_eq!((row.rows, row.batches, row.calls, row.wall_ns), (1000000, 100, 100, 1000000000));
        assert_eq!((row.cpu_user_ns, row.cpu_sys_ns, row.invol_ctx_switches), (900000000, 100000000, 3));
        assert_eq!(row.memory, vec![("rss_delta_per_thread".to_string(), 1048576)]);
        assert_eq!(row.latency, Latency { warmup_discarded: 4, samples: 30, min: 10, median: 20, p90: 30, max: 40 });
        // Empty versions are allowed, and every memory kind is accepted.
        let r = checked(&with("{\"python\": \"3.13.9\"}", "{}")).unwrap();
        assert!(r.build.versions.is_empty());
        let all = "{\"pss\": 1, \"uss\": 2, \"rss_delta_per_thread\": 3, \"node_external\": 4, \"v8_heap\": 5, \"memory_report\": 6}";
        let r = checked(&with("{\"rss_delta_per_thread\": 1048576}", all)).unwrap();
        assert_eq!(r.rows[0].memory.len(), 6);
        assert!(checked(&with("\"coverage\": false", "\"coverage\": true")).unwrap().build.coverage);
    }

    #[test]
    fn refusals() {
        for (from, to, why) in [
            ("\"run_id\": \"r1\"", "\"run_id\": \"\"", "run_id: is empty"),
            ("\"run_id\": \"r1\",\n", "", "run_id: missing"),
            ("\"target\": \"komira//src/tests/e2e/x:x_bench\"", "\"target\": 3", "target: is a number, not a string"),
            ("\"komira-bench-report-1\"", "\"komira-bench-report-2\"", "schema: is not \"komira-bench-report-1\""),
            ("\"schema\"", "\"extra\": 1, \"schema\"", "extra: not a key of the schema"),
            ("\"cpus\": 8", "\"cpus\": 0", "host.cpus: 0 is below 1"),
            ("\"cpus\": 8", "\"cpus\": 8.5", "host.cpus: 8.5 is not a whole number from 0 to 2^53"),
            ("\"cpus\": 8", "\"cpus\": -1", "host.cpus: -1 is not a whole number from 0 to 2^53"),
            ("\"cpus\": 8", "\"cpus\": 1e16", "host.cpus: 10000000000000000 is not a whole number from 0 to 2^53"),
            ("\"cpus\": 8", "\"cpus\": \"8\"", "host.cpus: is a string, not a number"),
            ("[0.5, 1, 1.5]", "[0.5, 1]", "host.loadavg: is not an array of three numbers"),
            ("[0.5, 1, 1.5]", "[0.5, -1, 1.5]", "host.loadavg[1]: -1 is negative"),
            ("[0.5, 1, 1.5]", "[0.5, 1, null]", "host.loadavg[2]: is null, not a number"),
            ("\"nr_throttled_delta\": 0,", "\"nr_throttled_delta\": 0, \"pid\": 1,", "host.pid: not a key of the schema"),
            ("\"cpu_max\": \"max 100000\", ", "", "host.cpu_max: missing"),
            ("\"host\": {", "\"host\": [], \"x\": {", "host: is an array, not an object"),
            ("\"engine\": \"3\"", "\"engine\": \"fast\"", "build.opt_levels.engine: 'fast' is not one of 0, 1, 2, 3"),
            ("{\"engine\": \"3\", \"driver\": \"1\"}", "{}", "build.opt_levels: is empty"),
            ("\"coverage\": false", "\"coverage\": \"no\"", "build.coverage: is a string, not a boolean"),
            ("\"python\": \"3.13.9\"", "\"python\": 3", "build.versions.python: is a number, not a string"),
            ("\"variant\": \"v\"", "\"variant\": \"V-1\"", "rows[0].variant: 'V-1' is not a name (a-z 0-9 _ ')"),
            ("\"function\": \"per_batch\"", "\"function\": \"\"", "rows[0].function: is empty"),
            ("\"threads\": 1", "\"threads\": 0", "rows[0].threads: 0 is below 1"),
            ("\"calls\": 100", "\"calls\": 1000000", "rows[0]: 1000000 runtime calls for 100 batches; a runtime is called once per batch"),
            ("\"calls\": 100", "\"calls\": 99", "rows[0]: 99 runtime calls for 100 batches; a runtime is called once per batch"),
            ("\"wall_ns\": 1000000000", "\"wall_ns\": 0", "rows[0].wall_ns: 0 is below 1"),
            ("{\"rss_delta_per_thread\": 1048576}", "{}", "rows[0].memory: is empty"),
            ("{\"rss_delta_per_thread\": 1048576}", "{\"rss\": 1}", "rows[0].memory.rss: not a memory kind (pss, uss, rss_delta_per_thread, node_external, v8_heap, memory_report)"),
            ("{\"rss_delta_per_thread\": 1048576}", "{\"pss\": -1}", "rows[0].memory.pss: -1 is not a whole number from 0 to 2^53"),
            ("{\"rss_delta_per_thread\": 1048576}", "7", "rows[0].memory: is a number, not an object"),
            ("\"samples\": 30", "\"samples\": 29", "rows[0].latency_ns.samples: 29 is below 30"),
            ("\"median\": 20", "\"median\": 9", "rows[0].latency_ns: min 10 <= median 9 <= p90 30 <= max 40 does not hold"),
            ("\"p90\": 30", "\"p90\": 19", "rows[0].latency_ns: min 10 <= median 20 <= p90 19 <= max 40 does not hold"),
            ("\"max\": 40", "\"max\": 29", "rows[0].latency_ns: min 10 <= median 20 <= p90 30 <= max 29 does not hold"),
            ("\"max\": 40", "\"max\": 40, \"mean\": 25", "rows[0].latency_ns.mean: not a key of the schema"),
            ("\"invol_ctx_switches\": 3,", "\"invol_ctx_switches\": 3, \"ok\": true,", "rows[0].ok: not a key of the schema"),
        ] {
            assert_eq!(checked(&with(from, to)), Err(why.to_string()), "{from} -> {to}");
        }
        assert_eq!(checked("[]"), Err("report: is an array, not an object".to_string()));
        let rows_at = GOOD.find("\"rows\": [").unwrap();
        let no_rows = format!("{}\"rows\": []\n}}", &GOOD[..rows_at]);
        assert_eq!(checked(&no_rows), Err("rows: is empty".to_string()));
        let obj_rows = format!("{}\"rows\": {{}}\n}}", &GOOD[..rows_at]);
        assert_eq!(checked(&obj_rows), Err("rows: is an object, not an array".to_string()));
        let bad_row = format!("{}\"rows\": [[]]\n}}", &GOOD[..rows_at]);
        assert_eq!(checked(&bad_row), Err("rows[0]: is an array, not an object".to_string()));
    }
}
