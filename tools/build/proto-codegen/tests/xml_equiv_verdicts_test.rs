//! The rest-xml verdicts file `xml-equiv-verdicts` writes over the pinned
//! botocore corpus, checked for shape: the non-empty, non-skipped bodies per
//! direction, and exactly one verdict for each unordered pair of them.
//!
//! The file is compiled in (include_str!): `rest_xml_verdicts.tsv` is the
//! output name the `xml_equiv_verdicts` rule (conformance.bzl) chooses.

use std::collections::BTreeSet;

const VERDICTS: &str = include_str!("../rest_xml_verdicts.tsv");

/// botocore 1.43.70's rest-xml corpus: the non-empty request bodies
/// (`serialized.body`) and response bodies (`response.body`) of the cases
/// its ignore list does not skip.
const INPUT_BODIES: usize = 43;
const OUTPUT_BODIES: usize = 57;

struct Verdicts {
    bodies: Vec<(String, String)>,
    pairs: Vec<(String, String, String)>,
}

fn verdicts() -> Verdicts {
    let mut v = Verdicts { bodies: Vec::new(), pairs: Vec::new() };
    for (n, line) in VERDICTS.lines().enumerate() {
        let f: Vec<&str> = line.split('\t').collect();
        match f.as_slice() {
            ["body", key, kind] => v.bodies.push((key.to_string(), kind.to_string())),
            ["pair", a, b, verdict] => v.pairs.push((a.to_string(), b.to_string(), verdict.to_string())),
            _ => panic!("line {}: not a body or pair record: {line:?}", n + 1),
        }
    }
    v
}

#[test]
fn the_body_counts_match_the_corpus() {
    let v = verdicts();
    let count = |dir: &str| v.bodies.iter().filter(|(k, _)| k.starts_with(dir)).count();
    assert_eq!(count("input/"), INPUT_BODIES);
    assert_eq!(count("output/"), OUTPUT_BODIES);
    assert_eq!(v.bodies.len(), INPUT_BODIES + OUTPUT_BODIES, "a body key in no direction");
    for (k, kind) in &v.bodies {
        assert!(kind == "parses" || kind == "raw", "{k}: {kind}");
        assert!(k.starts_with("input/rest-xml.json#") || k.starts_with("output/rest-xml.json#"), "{k}");
    }
    let unique: BTreeSet<&String> = v.bodies.iter().map(|(k, _)| k).collect();
    assert_eq!(unique.len(), v.bodies.len(), "a body is listed twice");
}

#[test]
fn every_unordered_pair_has_one_verdict() {
    let v = verdicts();
    let n = v.bodies.len();
    assert_eq!(v.pairs.len(), n * (n - 1) / 2);
    let order: Vec<&String> = v.bodies.iter().map(|(k, _)| k).collect();
    let mut seen = BTreeSet::new();
    for (a, b, verdict) in &v.pairs {
        assert!(verdict == "equal" || verdict == "differ", "{a} {b}: {verdict}");
        let ia = order.iter().position(|k| *k == a).unwrap_or_else(|| panic!("no body {a}"));
        let ib = order.iter().position(|k| *k == b).unwrap_or_else(|| panic!("no body {b}"));
        assert!(ia < ib, "{a} {b}: not in body order");
        assert!(seen.insert((ia, ib)), "{a} {b}: given twice");
    }
}
