//! botocore's protocol conformance corpus, scored against the actuals the
//! generated Mojo driver printed, and checked against the ledger.
//!
//! Everything is compiled in: the corpus files and the ignore list from the
//! pinned botocore archive, the driver's stdout (built by running it), and
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
    (Direction::Input, "json.json", corpus!("input/json.json")),
    (Direction::Input, "json_1_0.json", corpus!("input/json_1_0.json")),
    (
        Direction::Input,
        "json_1_0-query-compatible.json",
        corpus!("input/json_1_0-query-compatible.json"),
    ),
    (Direction::Input, "rest-json.json", corpus!("input/rest-json.json")),
    (Direction::Input, "rest-xml.json", corpus!("input/rest-xml.json")),
    (Direction::Output, "json.json", corpus!("output/json.json")),
    (Direction::Output, "json_1_0.json", corpus!("output/json_1_0.json")),
    (
        Direction::Output,
        "json_1_0-query-compatible.json",
        corpus!("output/json_1_0-query-compatible.json"),
    ),
    (Direction::Output, "rest-json.json", corpus!("output/rest-json.json")),
    (Direction::Output, "rest-xml.json", corpus!("output/rest-xml.json")),
];

const IGNORE_LIST: &str = corpus!("protocol-tests-ignore-list.json");
// The `[run_check]` sub-target of the driver writes `<name>.stdout`
// (tools/build/mojo/defs.bzl); renaming it breaks this path.
const ACTUALS: &str = include_str!("../aws_conformance_driver.stdout");
const LEDGER: &str = include_str!("../aws_conformance_ledger.txt");

fn corpus() -> Corpus {
    let mut c = Corpus::default();
    for (direction, name, text) in FILES {
        c.extend(load_file(*direction, name, text).unwrap_or_else(|e| panic!("{e}")));
    }
    c
}

fn report() -> Report {
    let actuals = ActualsFile::parse(ACTUALS).unwrap_or_else(|e| panic!("actuals: {e}"));
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
    let actuals = ActualsFile::parse(ACTUALS).unwrap();
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
