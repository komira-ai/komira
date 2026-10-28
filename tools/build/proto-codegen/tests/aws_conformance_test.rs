//! botocore's protocol conformance corpus, scored against the actuals the
//! generated Mojo drivers printed, and checked against the ledger.
//!
//! There is one driver per protocol, so the drivers compile in parallel; each
//! prints the actuals of its own protocol. The test reads the five actuals
//! files, merges them, and scores the union against the corpus: the ledger,
//! one row per (protocol, direction), is checked over the union.
//!
//! Everything is compiled in: the corpus files and the ignore list from the
//! pinned botocore archive, the drivers' stdout (built by running them), and
//! `aws_conformance_ledger.txt`. A change to any of them rebuilds this test.

use std::collections::BTreeSet;

use komira_proto_codegen::aws_conformance::{
    check_ledger, load_file, run, ActualsFile, Corpus, Direction, IgnoreList, Outcome, Report,
};

/// Where the archive's `tests/unit/protocols` is staged, relative to this
/// file: `files/` is the tree archive_files declares
/// (tools/build/mojo/archive.bzl), so renaming it breaks these paths.
macro_rules! corpus {
    ($rel:literal) => {
        include_str!(concat!("../files/tests/unit/protocols/", $rel))
    };
}

/// Every case file the archive target extracts, by direction and basename.
const FILES: &[(Direction, &str, &str)] = &[
    (Direction::Input, "ec2.json", corpus!("input/ec2.json")),
    (Direction::Input, "json.json", corpus!("input/json.json")),
    (Direction::Input, "json_1_0.json", corpus!("input/json_1_0.json")),
    (
        Direction::Input,
        "json_1_0-query-compatible.json",
        corpus!("input/json_1_0-query-compatible.json"),
    ),
    (Direction::Input, "query.json", corpus!("input/query.json")),
    (Direction::Input, "rest-json.json", corpus!("input/rest-json.json")),
    (Direction::Input, "rest-xml.json", corpus!("input/rest-xml.json")),
    (Direction::Output, "ec2.json", corpus!("output/ec2.json")),
    (Direction::Output, "json.json", corpus!("output/json.json")),
    (Direction::Output, "json_1_0.json", corpus!("output/json_1_0.json")),
    (
        Direction::Output,
        "json_1_0-query-compatible.json",
        corpus!("output/json_1_0-query-compatible.json"),
    ),
    (Direction::Output, "query.json", corpus!("output/query.json")),
    (Direction::Output, "rest-json.json", corpus!("output/rest-json.json")),
    (Direction::Output, "rest-xml.json", corpus!("output/rest-xml.json")),
];

const IGNORE_LIST: &str = corpus!("protocol-tests-ignore-list.json");
// The `[run_check]` sub-target of a driver writes `<name>.stdout`
// (tools/build/mojo/defs.bzl); renaming a driver breaks its path. The first
// element is the `metadata.protocol` the driver is generated for.
const DRIVERS: &[(&str, &str)] = &[
    ("ec2", include_str!("../aws_conformance_driver_ec2.stdout")),
    ("json", include_str!("../aws_conformance_driver_json.stdout")),
    ("query", include_str!("../aws_conformance_driver_query.stdout")),
    ("rest-json", include_str!("../aws_conformance_driver_rest_json.stdout")),
    ("rest-xml", include_str!("../aws_conformance_driver_rest_xml.stdout")),
];
const LEDGER: &str = include_str!("../aws_conformance_ledger.txt");

fn corpus() -> Corpus {
    let mut c = Corpus::default();
    for (direction, name, text) in FILES {
        c.extend(load_file(*direction, name, text).unwrap_or_else(|e| panic!("{e}")));
    }
    c
}

/// Every driver's actuals, parsed, with the protocol it was built for.
fn parts() -> Vec<(&'static str, ActualsFile)> {
    DRIVERS
        .iter()
        .map(|(name, text)| {
            let a = ActualsFile::parse(text).unwrap_or_else(|e| panic!("{name} actuals: {e}"));
            (*name, a)
        })
        .collect()
}

/// Union of per-driver actuals. A case key or a protocol held by two parts is
/// an error: the drivers must partition the work, so a union that hides a
/// duplicate could hide a case answered by the wrong driver.
fn merge(parts: &[(&str, ActualsFile)]) -> Result<ActualsFile, String> {
    let mut out = ActualsFile::default();
    for (name, a) in parts {
        for p in &a.protocols {
            if !out.protocols.insert(p.clone()) {
                return Err(format!("{name}: protocol `{p}` is driven by two drivers"));
            }
        }
        for (k, v) in &a.input {
            if out.input.insert(k.clone(), v.clone()).is_some() {
                return Err(format!("{name}: input case `{k}` is answered twice"));
            }
        }
        for (k, v) in &a.output {
            if out.output.insert(k.clone(), v.clone()).is_some() {
                return Err(format!("{name}: output case `{k}` is answered twice"));
            }
        }
        for (k, v) in &a.refused {
            if out.refused.insert(k.clone(), v.clone()).is_some() {
                return Err(format!("{name}: case `{k}` is refused twice"));
            }
        }
        for (k, v) in &a.raised {
            if out.raised.insert(k.clone(), v.clone()).is_some() {
                return Err(format!("{name}: case `{k}` raised twice"));
            }
        }
    }
    Ok(out)
}

fn union() -> ActualsFile {
    merge(&parts()).unwrap_or_else(|e| panic!("{e}"))
}

fn report() -> Report {
    let actuals = union();
    let ignore = IgnoreList::parse(IGNORE_LIST).unwrap_or_else(|e| panic!("{e}"));
    assert!(
        !actuals.protocols.is_empty(),
        "the actuals name no protocol: the driver drove nothing"
    );
    run(&corpus(), &actuals.protocols, &ignore, &actuals)
}

#[test]
fn case_keys_are_unique() {
    let keys = corpus().keys();
    let unique: BTreeSet<&String> = keys.iter().collect();
    assert_eq!(unique.len(), keys.len(), "two corpus cases share a key");
}

#[test]
fn every_actual_names_a_corpus_case() {
    let actuals = union();
    let keys: BTreeSet<String> = corpus().keys().into_iter().collect();
    let stray: Vec<&String> = actuals
        .input
        .keys()
        .chain(actuals.output.keys())
        .chain(actuals.refused.keys())
        .chain(actuals.raised.keys())
        .filter(|k| !keys.contains(*k))
        .collect();
    assert!(stray.is_empty(), "actuals for no corpus case: {stray:?}");
}

#[test]
fn the_ledger_holds() {
    let r = report();
    let violations = check_ledger(&r, LEDGER);
    if !violations.is_empty() {
        let mut msg = String::from("the conformance ledger does not hold:\n");
        for v in &violations {
            msg.push_str(&format!("  {v:?}\n"));
        }
        msg.push_str("\nthe rows this run produced:\n");
        msg.push_str(&r.to_ledger());
        panic!("{msg}");
    }
}

#[test]
fn no_case_is_red() {
    let r = report();
    let red: Vec<String> = r
        .outcomes
        .iter()
        .filter_map(|(k, o)| match o {
            Outcome::Failed(why) => Some(format!("{k}: {why}")),
            _ => None,
        })
        .collect();
    assert!(red.is_empty(), "{} red case(s):\n{}", red.len(), red.join("\n"));
}

#[test]
fn each_driver_drives_exactly_its_protocol() {
    for (name, a) in parts() {
        let want: BTreeSet<String> = [name.to_string()].into();
        assert_eq!(a.protocols, want, "the {name} driver was generated for another protocol set");
    }
}

/// The drivers are a partition of the corpus: every case botocore does not
/// skip is answered by exactly one driver, the one of its own protocol. A
/// case that no driver holds, or one a driver of another protocol holds, is
/// named here rather than only as a changed count in the ledger.
#[test]
fn every_corpus_case_is_answered_by_exactly_its_protocol_driver() {
    let ignore = IgnoreList::parse(IGNORE_LIST).unwrap();
    let parts = parts();
    let held_by = |key: &str| -> Vec<&str> {
        parts
            .iter()
            .filter(|(_, a)| {
                a.input.contains_key(key)
                    || a.output.contains_key(key)
                    || a.refused.contains_key(key)
                    || a.raised.contains_key(key)
            })
            .map(|(n, _)| *n)
            .collect()
    };
    let c = corpus();
    let cases = c
        .input
        .iter()
        .map(|x| (Direction::Input, &x.key, &x.protocol, &x.file, &x.suite, &x.id))
        .chain(
            c.output
                .iter()
                .map(|x| (Direction::Output, &x.key, &x.protocol, &x.file, &x.suite, &x.id)),
        );
    let mut bad = Vec::new();
    let mut driven = 0usize;
    for (dir, key, protocol, file, suite, id) in cases {
        if !DRIVERS.iter().any(|(n, _)| n == protocol) {
            continue;
        }
        driven += 1;
        let holders = held_by(key);
        let expect: Vec<&str> =
            if ignore.skips(dir, file, suite, id) { vec![] } else { vec![protocol.as_str()] };
        if holders != expect {
            bad.push(format!("{key}: held by {holders:?}, expected {expect:?}"));
        }
    }
    assert!(driven > 0, "no corpus case belongs to a driven protocol");
    assert!(bad.is_empty(), "{} case(s) misplaced:\n{}", bad.len(), bad.join("\n"));
}

/// The ledger's rows name exactly the protocols the drivers cover, and the
/// cases scored are the cases the ledger counts: adding or dropping a driver
/// is not silent.
#[test]
fn the_drivers_cover_the_ledger_totals() {
    let rows = || LEDGER.lines().filter(|l| !l.trim().is_empty() && !l.starts_with('#'));
    let ledger_protocols: BTreeSet<String> =
        rows().filter_map(|l| l.split_whitespace().next().map(str::to_string)).collect();
    let drivers: BTreeSet<String> = DRIVERS.iter().map(|(n, _)| n.to_string()).collect();
    assert_eq!(ledger_protocols, drivers, "the ledger and the drivers cover different protocols");
    let ledger_total: usize =
        rows().map(|l| l.split_whitespace().nth(2).unwrap().parse::<usize>().unwrap()).sum();
    assert_eq!(report().outcomes.len(), ledger_total, "cases scored differ from the ledger's total");
}

fn part(json: &str) -> ActualsFile {
    ActualsFile::parse(json).unwrap()
}

#[test]
fn merge_unions_disjoint_parts() {
    let a = part(r#"{"protocols":["a"],"refused":{"k1":"REFUSED x: y"}}"#);
    let b = part(r#"{"protocols":["b"],"raised":{"k2":"boom"},"input":{"k3":{"method":"GET"}}}"#);
    let m = merge(&[("a", a), ("b", b)]).unwrap();
    assert_eq!(m.protocols.len(), 2);
    assert!(m.refused.contains_key("k1") && m.raised.contains_key("k2") && m.input.contains_key("k3"));
}

#[test]
fn merge_refuses_a_case_two_parts_answer() {
    let a = part(r#"{"protocols":["a"],"input":{"k":{"method":"GET"}}}"#);
    let b = part(r#"{"protocols":["b"],"input":{"k":{"method":"GET"}}}"#);
    let e = merge(&[("a", a), ("b", b)]).unwrap_err();
    assert!(e.contains("`k` is answered twice"), "{e}");
}

#[test]
fn merge_refuses_a_protocol_two_parts_drive() {
    let a = part(r#"{"protocols":["a"]}"#);
    let b = part(r#"{"protocols":["a"]}"#);
    let e = merge(&[("a", a), ("b", b)]).unwrap_err();
    assert!(e.contains("driven by two drivers"), "{e}");
}
