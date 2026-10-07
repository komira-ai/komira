//! aws-conformance-gen's command line, run through `cli` as `main` runs it:
//! each refusal of `--protocol` is exit status 2 with exactly the reason and
//! the usage line on stderr, before the corpus, the ignore list or the
//! output is touched. The output's directory, under /dev/null, cannot be
//! made, so a run that gets past the flags fails at its first step.

use super::cli;

const USAGE: &str = "usage: aws-conformance-gen --corpus <dir> --protocol <p> \
                     [--protocol <p>...] --ignore-list <file> --out <file.mojo>\n";

/// `cli` over the flags with each `--protocol` value: (status, stderr).
fn run_with(protocols: &[&str]) -> (i32, String) {
    let mut argv: Vec<String> = vec!["--corpus".into(), "/nonexistent/corpus".into()];
    for p in protocols {
        argv.push("--protocol".into());
        argv.push((*p).into());
    }
    argv.extend([
        "--ignore-list".into(),
        "/nonexistent/ignore.json".into(),
        "--out".into(),
        "/dev/null/x/driver.mojo".into(),
    ]);
    let mut err = Vec::new();
    let status = cli(&argv, &mut err);
    (status, String::from_utf8(err).expect("stderr is UTF-8"))
}

const DRIVEN_ONLY: &str = "the conformance driver reads errors as awsJson, restJson1, \
                           restXml, awsQuery and ec2Query clients do, so it drives `json`, \
                           `rest-json`, `rest-xml`, `query` and `ec2` only";

#[test]
fn a_botocore_protocol_the_driver_does_not_run_is_refused() {
    let (status, err) = run_with(&["smithy-rpc-v2-cbor"]);
    assert_eq!(status, 2);
    assert_eq!(
        err,
        format!("aws-conformance-gen: --protocol `smithy-rpc-v2-cbor`: {DRIVEN_ONLY}\n{USAGE}")
    );
}

#[test]
fn the_refusal_holds_beside_a_driven_protocol() {
    let (status, err) = run_with(&["json", "smithy-rpc-v2-cbor"]);
    assert_eq!(status, 2);
    assert_eq!(
        err,
        format!("aws-conformance-gen: --protocol `smithy-rpc-v2-cbor`: {DRIVEN_ONLY}\n{USAGE}")
    );
}

#[test]
fn a_name_botocore_does_not_define_is_refused() {
    let (status, err) = run_with(&["soap"]);
    assert_eq!(status, 2);
    assert_eq!(
        err,
        format!("aws-conformance-gen: --protocol `soap` is not a botocore protocol name\n{USAGE}")
    );
}

#[test]
fn a_protocol_given_twice_is_refused() {
    let (status, err) = run_with(&["json", "json"]);
    assert_eq!(status, 2);
    assert_eq!(
        err,
        format!("aws-conformance-gen: --protocol `json` is empty or given twice\n{USAGE}")
    );
}

#[test]
fn no_protocol_is_refused() {
    let (status, err) = run_with(&[]);
    assert_eq!(status, 2);
    assert_eq!(err, format!("aws-conformance-gen: at least one --protocol is required\n{USAGE}"));
}

#[test]
fn every_driven_protocol_passes_the_flags() {
    // Past the flags, the run's first step (making the output's directory)
    // fails: status 1 and that step's error, not the usage error, so none of
    // the five is refused by `--protocol`.
    let (status, err) = run_with(&["ec2", "json", "query", "rest-json", "rest-xml"]);
    assert_eq!(status, 1, "stderr: {err}");
    assert!(err.starts_with("aws-conformance-gen: mkdir /dev/null/x: "), "stderr: {err}");
    assert!(!err.contains("usage:"), "stderr: {err}");
}
