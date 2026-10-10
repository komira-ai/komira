//! `aws-conformance-gen`: generates the Mojo driver that runs botocore's
//! protocol conformance corpus against the generated serializer.
//!
//! usage: aws-conformance-gen --corpus <dir> --protocol <p> [--protocol <p>...]
//!            --ignore-list <file> --out <file.mojo>
//!
//! `<dir>` holds botocore's `input/` and `output/` case files. Every suite
//! whose `metadata.protocol` is one of the `--protocol` values is
//! reassembled into a service model, lowered by the real front-end and
//! emitted by the real emitter; the driver's `main` prints one actuals
//! record per case (the format `aws_conformance::ActualsFile::parse`
//! reads). A case botocore's ignore list skips is not driven. A case the
//! generator cannot build (its suite does not lower or emit, or the driver
//! cannot construct its input) becomes a `refused` record carrying the error text,
//! so the harness can tell a named refusal from a defect.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::path::{Path, PathBuf};

use komira_proto_codegen::aws_conformance::{Direction as CorpusDirection, IgnoreList};
use komira_proto_codegen::aws_in::{lower_aws_service, AwsLowering};
use komira_proto_codegen::emit_aws::{emit_aws_client, pure_preamble, AwsEmitOptions, AwsProtocol};
use komira_proto_codegen::ir::{IrField, IrMessage, IrType, Label, ScalarKind};
use komira_proto_codegen::json::{parse, Json, JsonObject};
use komira_proto_codegen::overrides::AwsOverrides;

/// The endpoint a case without `clientEndpoint` is sent to.
const DEFAULT_ENDPOINT: &str = "https://protocoltests.us-east-1.amazonaws.com";
/// The signing region, and the fixed credentials and time the driver signs
/// with. Signing headers are not compared (botocore compares the expected
/// headers as a subset); they are here so each request goes through the
/// production signing path, which is what sets Content-Length.
const SIGNING_REGION: &str = "us-east-1";
const SIGNING_TIME_UNIX: i64 = 1_700_000_000;

struct Args {
    corpus: PathBuf,
    protocols: BTreeSet<String>,
    ignore_list: PathBuf,
    out: PathBuf,
}

fn parse_args(argv: &[String]) -> Result<Args, String> {
    let mut corpus = None;
    let mut protocols = BTreeSet::new();
    let mut ignore_list = None;
    let mut out = None;
    let mut it = argv.iter();
    while let Some(flag) = it.next() {
        let mut value = || {
            it.next()
                .cloned()
                .ok_or_else(|| format!("{flag} needs a value"))
        };
        match flag.as_str() {
            "--corpus" => corpus = Some(PathBuf::from(value()?)),
            "--protocol" => {
                let p = value()?;
                if p.is_empty() || !protocols.insert(p.clone()) {
                    return Err(format!("--protocol `{p}` is empty or given twice"));
                }
            }
            "--ignore-list" => ignore_list = Some(PathBuf::from(value()?)),
            "--out" => out = Some(PathBuf::from(value()?)),
            other => return Err(format!("unknown argument `{other}`")),
        }
    }
    if protocols.is_empty() {
        return Err("at least one --protocol is required".into());
    }
    for p in &protocols {
        driver_protocol(p)?;
    }
    Ok(Args {
        corpus: corpus.ok_or("--corpus is required")?,
        protocols,
        ignore_list: ignore_list.ok_or("--ignore-list is required")?,
        out: out.ok_or("--out is required")?,
    })
}

/// The protocol `--protocol <p>` drives, refused unless the driver can run it.
///
/// ⚠ THE DRIVER RECORDS EVERY ACTUAL AS A `JsonValue` (komira_json), whatever
/// the suites are, so it needs the JSON runtime in its preamble: the JSON-body
/// protocols import it, and the MODEL-convention rows import it for restXml.
/// An error case reads the code and message as its protocol's client does:
/// awsJson from the body (`aws_error_code_from_body` /
/// `aws_error_message_from_body`), restJson1 with `aws_rest_json_error`,
/// restXml with `aws_rest_xml_error`, awsQuery and ec2Query with
/// `aws_query_error`.
fn driver_protocol(p: &str) -> Result<AwsProtocol, String> {
    match AwsProtocol::from_botocore(p) {
        Some(
            proto @ (AwsProtocol::Json
            | AwsProtocol::RestJson
            | AwsProtocol::RestXml
            | AwsProtocol::Query
            | AwsProtocol::Ec2),
        ) => Ok(proto),
        Some(_) => Err(format!(
            "--protocol `{p}`: the conformance driver reads errors as awsJson, \
             restJson1, restXml, awsQuery and ec2Query clients do, so it drives \
             `json`, `rest-json`, `rest-xml`, `query` and `ec2` only"
        )),
        None => Err(format!("--protocol `{p}` is not a botocore protocol name")),
    }
}

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let status = cli(&argv, &mut std::io::stderr());
    if status != 0 {
        std::process::exit(status);
    }
}

/// The program over `argv` (the arguments after the program name), its
/// diagnostics written to `err`. Returns the exit status: 2 for an argument
/// refused before anything is read (the reason, then the usage line), 1 for
/// a failed run, 0 otherwise.
fn cli(argv: &[String], err: &mut dyn std::io::Write) -> i32 {
    let args = match parse_args(argv) {
        Ok(a) => a,
        Err(e) => {
            let _ = writeln!(err, "aws-conformance-gen: {e}");
            let _ = writeln!(
                err,
                "usage: aws-conformance-gen --corpus <dir> --protocol <p> [--protocol <p>...] \
                 --ignore-list <file> --out <file.mojo>"
            );
            return 2;
        }
    };
    if let Err(e) = run(&args) {
        let _ = writeln!(err, "aws-conformance-gen: {e}");
        return 1;
    }
    0
}

// The command line's refusals, run through `cli` (rust_test
// :aws_conformance_gen_cli, welded into the binary).
#[cfg(test)]
#[path = "main_aws_conformance_gen_test.rs"]
mod cli_test;

struct Suite {
    module: String,
    prefix: String,
    lowering: AwsLowering,
    /// case key -> the case body
    cases: Vec<(String, Json)>,
    direction: Direction,
    client_endpoint: Option<String>,
    signing_name: String,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Direction {
    Input,
    Output,
}

impl Direction {
    fn dir(self) -> &'static str {
        match self {
            Direction::Input => "input",
            Direction::Output => "output",
        }
    }

    fn corpus(self) -> CorpusDirection {
        match self {
            Direction::Input => CorpusDirection::Input,
            Direction::Output => CorpusDirection::Output,
        }
    }
}

fn read(path: &Path) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|e| format!("read {}: {e}", path.display()))
}

fn run(args: &Args) -> Result<(), String> {
    if let Some(d) = args.out.parent() {
        std::fs::create_dir_all(d).map_err(|e| format!("mkdir {}: {e}", d.display()))?;
    }
    let ignore = IgnoreList::parse(&read(&args.ignore_list)?)?;

    let mut suites: Vec<Suite> = Vec::new();
    // case key -> why the generator could not build it.
    let mut refused: Vec<(String, String)> = Vec::new();
    let mut n_cases = 0usize;
    let mut n_skipped = 0usize;
    let mut suite_seq = 0usize;
    let mut seen_protocols: BTreeSet<String> = BTreeSet::new();

    for direction in [Direction::Input, Direction::Output] {
        let dir = args.corpus.join(direction.dir());
        let mut files: Vec<_> = std::fs::read_dir(&dir)
            .map_err(|e| format!("readdir {}: {e}", dir.display()))?
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().map(|x| x == "json").unwrap_or(false))
            .collect();
        files.sort();
        for path in files {
            let doc = parse(&read(&path)?).map_err(|e| format!("{}: {e}", path.display()))?;
            let arr = doc
                .as_array()
                .ok_or_else(|| format!("{}: not a JSON array", path.display()))?;
            let basename = path
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_string();
            for (si, suite) in arr.iter().enumerate() {
                let obj = suite
                    .as_object()
                    .ok_or_else(|| format!("{basename}[{si}]: not an object"))?;
                let meta = obj
                    .get("metadata")
                    .and_then(Json::as_object)
                    .ok_or_else(|| format!("{basename}[{si}]: no metadata"))?;
                let protocol = meta.get("protocol").and_then(Json::as_str).unwrap_or("");
                if !args.protocols.contains(protocol) {
                    continue;
                }
                seen_protocols.insert(protocol.to_string());
                let description = obj.get("description").and_then(Json::as_str).unwrap_or("");
                let all_cases = obj
                    .get("cases")
                    .and_then(Json::as_array)
                    .ok_or_else(|| format!("{basename}[{si}]: no cases"))?;
                n_cases += all_cases.len();
                let mut cases: Vec<Json> = Vec::new();
                for c in all_cases {
                    let id = case_id(c).ok_or_else(|| format!("{basename}[{si}]: a case has no id"))?;
                    if ignore.skips(direction.corpus(), &basename, description, id) {
                        n_skipped += 1;
                    } else {
                        cases.push(c.clone());
                    }
                }
                if cases.is_empty() {
                    continue;
                }

                let module = format!(
                    "{}_{}_{}",
                    direction.dir(),
                    basename.trim_end_matches(".json").replace(['-', '.'], "_"),
                    si
                );
                let prefix = format!(
                    "S{}{suite_seq}",
                    if direction == Direction::Input { "i" } else { "o" }
                );
                suite_seq += 1;
                match build_suite(obj, meta, &cases, &module, &prefix, &basename, direction) {
                    Ok(s) => suites.push(s),
                    Err(e) => {
                        for c in &cases {
                            let id = case_id(c).unwrap_or("<no id>");
                            refused.push((format!("{}/{basename}#{id}", direction.dir()), e.clone()));
                        }
                    }
                }
            }
        }
    }
    let missing: Vec<&String> = args.protocols.difference(&seen_protocols).collect();
    if !missing.is_empty() {
        return Err(format!("the corpus holds no suite for --protocol {missing:?}"));
    }

    // A suite the emitter refuses is refused case by case, as one the
    // front-end refuses is.
    let mut bodies = String::new();
    let mut emitted: Vec<Suite> = Vec::new();
    for s in suites {
        let r = emit_aws_client(
            &s.lowering,
            &AwsOverrides::empty(),
            &s.module,
            AwsEmitOptions {
                emit_model_json: true,
                pure_only: true,
                omit_preamble: true,
                s3: false,
                route53: false,
            },
        );
        match r {
            Ok((_, src)) => {
                bodies.push_str(&src);
                emitted.push(s);
            }
            Err(e) => {
                for (key, _) in &s.cases {
                    refused.push((key.clone(), e.clone()));
                }
            }
        }
    }
    let suites = emitted;
    let (driver_main, undriveable) = emit_driver(&suites, &refused, &args.protocols)?;
    let mut all_refused = refused.clone();
    all_refused.extend(undriveable.iter().cloned());
    let mut whole = driver_header(&suites, &all_refused, n_cases, n_skipped, &args.protocols);
    // One preamble for every driven protocol: each import row that applies
    // to any of them, once.
    let protocols: Vec<AwsProtocol> = args
        .protocols
        .iter()
        .map(|p| driver_protocol(p))
        .collect::<Result<_, _>>()?;
    whole.push_str(&pure_preamble(&protocols, true));
    whole.push_str(&bodies);
    whole.push_str(&driver_main);
    std::fs::write(&args.out, &whole)
        .map_err(|e| format!("write {}: {e}", args.out.display()))?;

    eprintln!(
        "aws-conformance-gen: {} suites, {} cases in scope, {} skipped upstream, {} refused",
        suites.len(),
        n_cases,
        n_skipped,
        all_refused.len()
    );
    for (k, e) in &all_refused {
        eprintln!("  REFUSED {k}: {}", first_line(e));
    }
    Ok(())
}

fn case_id(c: &Json) -> Option<&str> {
    c.as_object().and_then(|o| o.get("id")).and_then(Json::as_str)
}

fn first_line(s: &str) -> &str {
    s.split('\n').next().unwrap_or(s)
}

/// MIRRORS botocore's tests/unit/test_protocols.py (`test_output_compliance`):
/// for a `query` suite whose output shape has members, the harness sets the
/// output's `resultWrapper` to `<operation>Result`, which the case files do
/// not state and every real awsQuery model does. The response bodies hold
/// that element.
fn wrap_query_result(given: &mut Json, shapes: Option<&Json>) {
    let Json::Object(g) = given else { return };
    let Some(name) = g.get("name").and_then(Json::as_str).map(str::to_string) else {
        return;
    };
    let Some(Json::Object(output)) = g.get("output").cloned() else {
        return;
    };
    let has_members = output
        .get("shape")
        .and_then(Json::as_str)
        .and_then(|s| shapes.and_then(|sh| sh.as_object()).and_then(|sh| sh.get(s)))
        .and_then(|s| s.as_object())
        .and_then(|s| s.get("members"))
        .and_then(Json::as_object)
        .is_some_and(|m| m.iter_declared().next().is_some());
    if !has_members {
        return;
    }
    let mut output = output;
    output.insert("resultWrapper".into(), Json::Str(format!("{name}Result")));
    g.insert("output".into(), Json::Object(output));
}

/// Reassemble a conformance suite into a botocore service model and lower it.
fn build_suite(
    obj: &JsonObject,
    meta: &JsonObject,
    cases: &[Json],
    module: &str,
    prefix: &str,
    basename: &str,
    direction: Direction,
) -> Result<Suite, String> {
    // operations: one entry per distinct `given.name`.
    let mut operations = JsonObject::new();
    let mut op_names: Vec<String> = Vec::new();
    let mut keyed: Vec<(String, Json)> = Vec::new();
    let protocol = meta.get("protocol").and_then(Json::as_str).unwrap_or("");
    for c in cases {
        let co = c
            .as_object()
            .ok_or_else(|| "case is not an object".to_string())?;
        let id = co
            .get("id")
            .and_then(Json::as_str)
            .ok_or_else(|| "case has no id".to_string())?;
        let mut given = co
            .get("given")
            .cloned()
            .ok_or_else(|| format!("case {id} has no `given`"))?;
        if protocol == "query" && direction == Direction::Output {
            wrap_query_result(&mut given, obj.get("shapes"));
        }
        let name = given
            .as_object()
            .and_then(|g| g.get("name"))
            .and_then(Json::as_str)
            .ok_or_else(|| format!("case {id} has no `given.name`"))?
            .to_string();
        if !op_names.contains(&name) {
            op_names.push(name.clone());
            operations.insert(name, given);
        }
        keyed.push((
            format!("{}/{basename}#{id}", direction.dir()),
            c.clone(),
        ));
    }

    // metadata: the suite's own, plus the fields a service model must carry.
    let mut m = JsonObject::new();
    for (k, v) in meta {
        m.insert(k.clone(), v.clone());
    }
    m.insert("serviceId".into(), Json::Str(prefix.to_string()));
    m.insert("endpointPrefix".into(), Json::Str("protocoltests".into()));
    m.insert(
        "serviceFullName".into(),
        Json::Str(format!("Protocol test suite {module}")),
    );
    // The conformance corpus states only the protocol-relevant metadata; a real
    // service model also carries these, and `lower_aws_service` requires them
    // because a client that does not know how to SIGN is not a client. They are
    // synthesised rather than made optional in the front-end: relaxing the
    // front-end to please a test corpus would let a real model omit them.
    if !m.contains_key("signatureVersion") {
        m.insert("signatureVersion".into(), Json::Str("v4".into()));
    }
    if !m.contains_key("apiVersion") {
        m.insert("apiVersion".into(), Json::Str("2018-01-01".into()));
    }
    if !m.contains_key("uid") {
        m.insert("uid".into(), Json::Str(format!("{module}-2018-01-01")));
    }
    let signing_name = m
        .get("signingName")
        .and_then(Json::as_str)
        .unwrap_or("protocoltests")
        .to_string();

    let mut model = JsonObject::new();
    model.insert("version".into(), Json::Str("2.0".into()));
    model.insert("metadata".into(), Json::Object(m));
    model.insert("operations".into(), Json::Object(operations));
    model.insert(
        "shapes".into(),
        obj.get("shapes").cloned().unwrap_or(Json::Object(JsonObject::new())),
    );

    let lowering = lower_aws_service(
        &Json::Object(model),
        "protocoltests",
        &op_names,
        &format!("{basename} suite {module}"),
        "aws.protocoltests",
    )?;

    Ok(Suite {
        module: module.to_string(),
        prefix: prefix.to_string(),
        lowering,
        cases: keyed,
        direction,
        client_endpoint: obj
            .get("clientEndpoint")
            .and_then(Json::as_str)
            .map(str::to_string),
        signing_name,
    })
}

// ---------------------------------------------------------------------------
// The driver
// ---------------------------------------------------------------------------

fn driver_header(
    suites: &[Suite],
    refused: &[(String, String)],
    n_cases: usize,
    n_skipped: usize,
    protocols: &BTreeSet<String>,
) -> String {
    let mut o = Out::new();
    o.line("# ==========================================================================");
    o.line("# GENERATED by //tools/build/proto-codegen:aws-conformance-gen. DO NOT EDIT.");
    o.line("#");
    o.line("# Runs botocore's protocol conformance corpus against the GENERATED");
    o.line("# serializers and parsers, and prints the actuals file on stdout, in the");
    o.line("# format `aws_conformance::ActualsFile::parse` reads. Each request is");
    o.line("# signed by komira_aws_core's build_sigv4_signed_request (static");
    o.line("# credentials, fixed clock), the path a client sends through.");
    o.line("#");
    o.line("# A case the generated code raises on has a `raised` record holding the");
    o.line("# error, which the harness scores red. A case the generator could not");
    o.line("# build has a `refused` record holding the error. The first output");
    o.line("# case's parser is also handed a body that is not well-formed UTF-8,");
    o.line("# and the driver stops when it does not refuse it.");
    o.line("#");
    let p: Vec<&str> = protocols.iter().map(String::as_str).collect();
    o.line(&format!("#   protocols       : {}", p.join(", ")));
    o.line(&format!("#   suites lowered  : {}", suites.len()));
    o.line(&format!("#   cases in scope  : {n_cases}"));
    o.line(&format!("#   skipped upstream: {n_skipped}"));
    o.line(&format!("#   refused         : {}", refused.len()));
    for (k, e) in refused {
        o.line(&format!("#     {k}: {}", first_line(e)));
    }
    o.line("# ==========================================================================");
    o.line("");
    o.line("from komira_aws_core import (");
    o.line("    AwsCredential,");
    o.line("    AwsEndpoint,");
    o.line("    AwsResponse,");
    o.line("    FixedClock,");
    o.line("    Header,");
    o.line("    build_sigv4_signed_request,");
    if protocols.contains("rest-json") {
        o.line("    aws_rest_json_error,");
    }
    if protocols.contains("rest-xml") {
        o.line("    aws_rest_xml_error,");
    }
    if protocols.contains("query") || protocols.contains("ec2") {
        o.line("    aws_query_error,");
    }
    o.line(")");
    o.line("");
    o.buf
}

fn emit_driver(
    suites: &[Suite],
    refused: &[(String, String)],
    protocols: &BTreeSet<String>,
) -> Result<(String, Vec<(String, String)>), String> {
    let mut o = Out::new();
    o.line("def main() raises:");
    o.indent += 1;
    o.line("var actuals = JsonValue.empty_object()");
    o.line("var inp = JsonValue.empty_object()");
    o.line("var outp = JsonValue.empty_object()");
    o.line("var refused = JsonValue.empty_object()");
    o.line("var raised = JsonValue.empty_object()");
    o.line("var protocols = JsonValue.empty_array()");
    for p in protocols {
        o.line(&format!("protocols.push(JsonValue.from_string(String(\"{}\")))", esc(p)));
    }
    o.line(&format!(
        "var _cred = AwsCredential(String(\"AKIDCONFORMANCE\"), String(\"{}\"), String(\"\"))",
        "conformance-secret-key"
    ));
    o.line(&format!("var _clock = FixedClock({SIGNING_TIME_UNIX})"));

    let mut undriveable: Vec<(String, String)> = Vec::new();
    let mut ctr = 0usize;
    // The parser of the first output case driven: the ill-formed UTF-8
    // probe below runs it.
    let mut probe: Option<String> = None;
    for s in suites {
        for (key, case) in &s.cases {
            let co = case.as_object().unwrap();
            let id = co.get("id").and_then(Json::as_str).unwrap_or("");
            let mut sub = Out::new();
            sub.indent = o.indent;
            let r = match s.direction {
                Direction::Input => emit_input_case(&mut sub, s, key, id, co, &mut ctr),
                Direction::Output => emit_output_case(&mut sub, s, key, id, co, &mut ctr),
            };
            match r {
                Ok(()) => {
                    o.line("");
                    o.line(&format!("# --- {key} ---"));
                    o.buf.push_str(&sub.buf);
                    if probe.is_none() && s.direction == Direction::Output {
                        probe = Some(output_parser(s, co)?);
                    }
                }
                Err(e) => undriveable.push((key.clone(), e)),
            }
        }
    }

    if let Some(parser) = probe {
        emit_utf8_probe(&mut o, &parser);
    }

    o.line("");
    let mut all: BTreeMap<&String, &String> = BTreeMap::new();
    for (k, e) in refused.iter().chain(undriveable.iter()) {
        all.insert(k, e);
    }
    for (k, e) in all {
        o.line(&format!(
            "refused.set_member(String(\"{}\"), JsonValue.from_string(String(\"{}\")))",
            esc(k),
            esc(e)
        ));
    }
    o.line("");
    o.line("actuals.set_member(String(\"protocols\"), protocols^)");
    o.line("actuals.set_member(String(\"input\"), inp^)");
    o.line("actuals.set_member(String(\"output\"), outp^)");
    o.line("actuals.set_member(String(\"refused\"), refused^)");
    o.line("actuals.set_member(String(\"raised\"), raised^)");
    o.line("print(actuals.serialize())");
    o.indent -= 1;
    Ok((o.buf, undriveable))
}

/// The generated parser an output case calls.
fn output_parser(s: &Suite, case: &JsonObject) -> Result<String, String> {
    let op_name = case
        .get("given")
        .and_then(Json::as_object)
        .and_then(|g| g.get("name"))
        .and_then(Json::as_str)
        .ok_or("no given.name")?;
    let facts = s.lowering.facts.operation(op_name)?;
    Ok(format!(
        "{}_parse_{}_response",
        s.prefix.to_lowercase(),
        facts.ir_method_name
    ))
}

/// A generated parser handed a 200 response whose body is JSON holding a
/// string that is not well-formed UTF-8 (`{"a":"\xFF"}`) must refuse it.
/// The corpus holds only text bodies, so no case asks this; a parser that
/// accepts the bytes stops the driver, and with it the conformance test.
fn emit_utf8_probe(o: &mut Out, parser: &str) {
    o.line("");
    o.line("# --- probe: a body that is not well-formed UTF-8 is refused ---");
    o.line("var _utf8_refused = False");
    o.line("try:");
    o.indent += 1;
    o.line("var _bad: List[UInt8] = [");
    o.indent += 1;
    o.line("UInt8(0x7B), UInt8(0x22), UInt8(0x61), UInt8(0x22), UInt8(0x3A),");
    o.line("UInt8(0x22), UInt8(0xFF), UInt8(0x22), UInt8(0x7D),");
    o.indent -= 1;
    o.line("]");
    o.line(&format!("_ = {parser}(AwsResponse(200, _bad^))"));
    o.indent -= 1;
    o.line("except e:");
    o.indent += 1;
    o.line("_utf8_refused = String(e).find(\"UTF-8\") >= 0");
    o.indent -= 1;
    o.line("if not _utf8_refused:");
    o.indent += 1;
    o.line(&format!(
        "raise Error(\"{parser} did not refuse a body that is not well-formed UTF-8\")"
    ));
    o.indent -= 1;
}

fn emit_input_case(
    o: &mut Out,
    s: &Suite,
    key: &str,
    id: &str,
    case: &JsonObject,
    ctr: &mut usize,
) -> Result<(), String> {
    let op_name = case
        .get("given")
        .and_then(Json::as_object)
        .and_then(|g| g.get("name"))
        .and_then(Json::as_str)
        .ok_or("no given.name")?;
    let facts = s.lowering.facts.operation(op_name)?;
    let method = facts.ir_method_name.clone();
    let input_fq = {
        let svc = &s.lowering.model.files[0].services[0];
        svc.methods
            .iter()
            .find(|m| m.name == method)
            .map(|m| m.input.fq_name.clone())
            .ok_or_else(|| format!("no IR method {method}"))?
    };
    let params = case
        .get("params")
        .cloned()
        .unwrap_or(Json::Object(JsonObject::new()));
    let endpoint = s
        .client_endpoint
        .clone()
        .unwrap_or_else(|| DEFAULT_ENDPOINT.to_string());

    let var = format!("_c_{}", sanitize(id));
    o.line("try:");
    o.indent += 1;
    let expr = emit_construct(o, s, &input_fq, &params, ctr)?;
    o.line(&format!("var {var} = {expr}"));
    let fp = s.prefix.to_lowercase();
    o.line(&format!("var _req = {fp}_build_{method}_request({var})"));
    // MIRRORS the generated `send` (emit_aws/mod.rs), which this driver cannot
    // call without a connector: the unsigned request's headers go to the
    // signer as `extra`, except a header named Content-Type in any case
    // (header names are case-insensitive), which is its own argument, and
    // the endpoint carries `_req.host_prefix` ahead of its host
    // (`AwsEndpoint.with_host_prefix`), as `send` passes it.
    o.line("var _ct = String(\"\")");
    o.line("var _extra = List[Header]()");
    o.line("for _i in range(len(_req.header_names)):");
    o.indent += 1;
    o.line("if _req.header_names[_i].lower() == String(\"content-type\"):");
    o.line("    _ct = _req.header_values[_i].copy()");
    o.line("else:");
    o.line("    _extra.append(Header(_req.header_names[_i].copy(), _req.header_values[_i].copy()))");
    o.indent -= 1;
    o.line(&format!(
        "var _ep = AwsEndpoint.parse(String(\"{}\"), String(\"clientEndpoint\")).with_host_prefix(_req.host_prefix)",
        esc(&endpoint)
    ));
    o.line("var _sr = build_sigv4_signed_request(");
    o.indent += 1;
    o.line("_req.method,");
    o.line("_cred,");
    o.line(&format!("String(\"{SIGNING_REGION}\"),"));
    o.line(&format!("String(\"{}\"),", esc(&s.signing_name)));
    o.line("_ep,");
    o.line("_req.uri,");
    o.line("_ct,");
    o.line("Span(_req.body),");
    o.line("_extra,");
    o.line("_clock,");
    o.indent -= 1;
    o.line(")");
    o.line("var _rec = JsonValue.empty_object()");
    o.line("_rec.set_member(String(\"host\"), JsonValue.from_string(_sr.header(String(\"Host\"))))");
    o.line("_rec.set_member(String(\"method\"), JsonValue.from_string(_sr.method.copy()))");
    o.line("_rec.set_member(String(\"uri\"), JsonValue.from_string(_sr.target.copy()))");
    o.line("_rec.set_member(String(\"body\"), JsonValue.from_string(_sr.body_text()))");
    o.line("var _hdr = JsonValue.empty_object()");
    o.line("for _i in range(len(_sr.headers)):");
    o.indent += 1;
    o.line("_hdr.set_member(");
    o.indent += 1;
    o.line("_sr.headers[_i].name.copy(),");
    o.line("JsonValue.from_string(_sr.headers[_i].value.copy()),");
    o.indent -= 1;
    o.line(")");
    o.indent -= 1;
    o.line("_rec.set_member(String(\"headers\"), _hdr^)");
    o.line(&format!("inp.set_member(String(\"{}\"), _rec^)", esc(key)));
    o.indent -= 1;
    o.line("except e:");
    o.indent += 1;
    o.line(&format!(
        "raised.set_member(String(\"{}\"), JsonValue.from_string(String(e)))",
        esc(key)
    ));
    o.indent -= 1;
    Ok(())
}

fn emit_output_case(
    o: &mut Out,
    s: &Suite,
    key: &str,
    _id: &str,
    case: &JsonObject,
    _ctr: &mut usize,
) -> Result<(), String> {
    let op_name = case
        .get("given")
        .and_then(Json::as_object)
        .and_then(|g| g.get("name"))
        .and_then(Json::as_str)
        .ok_or("no given.name")?;
    let facts = s.lowering.facts.operation(op_name)?;
    let method = facts.ir_method_name.clone();
    let resp = case.get("response").and_then(Json::as_object);
    let body = resp
        .and_then(|r| r.get("body"))
        .and_then(Json::as_str)
        .unwrap_or("")
        .to_string();
    let status = resp
        .and_then(|r| r.get("status_code"))
        .and_then(|v| match v {
            Json::Number(n) => Some(*n as i64),
            _ => None,
        })
        .unwrap_or(200);
    let headers: Vec<(String, String)> = resp
        .and_then(|r| r.get("headers"))
        .and_then(Json::as_object)
        .map(|h| {
            h.iter_declared()
                .filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_string())))
                .collect()
        })
        .unwrap_or_default();

    o.line("try:");
    o.indent += 1;
    let fp = s.prefix.to_lowercase();
    // The whole response is bound, status and headers included: the
    // AwsResponse a generated parser reads.
    o.line(&format!("var _resp = AwsResponse.of_text({status}, String(\"{}\"))", esc(&body)));
    for (k, v) in &headers {
        o.line(&format!("_resp.add_header(String(\"{}\"), String(\"{}\"))", esc(k), esc(v)));
    }
    o.line("var _rec = JsonValue.empty_object()");
    // MIRRORS the generated client's error builder (`_<module>_error` in
    // emit_aws/mod.rs, the code and message expressions of the protocol's
    // binding): awsJson reads the body only, restJson1 the X-Amzn-Errortype
    // header and then the body, restXml the <Error> element, awsQuery and
    // ec2Query <ErrorResponse><Error> or <Response><Errors><Error>. The
    // builder is not called, so a defect in it would not show here.
    o.line("if aws_is_error_status(_resp.status):");
    o.indent += 1;
    if s.lowering.service.protocol == "rest-xml" {
        o.line("var _ei = aws_rest_xml_error(_resp)");
        o.line("_rec.set_member(String(\"errorCode\"), JsonValue.from_string(_ei.code))");
        o.line("_rec.set_member(String(\"errorMessage\"), JsonValue.from_string(_ei.message))");
    } else if s.lowering.service.protocol == "query" || s.lowering.service.protocol == "ec2" {
        o.line("var _ei = aws_query_error(_resp)");
        o.line("_rec.set_member(String(\"errorCode\"), JsonValue.from_string(_ei.code))");
        o.line("_rec.set_member(String(\"errorMessage\"), JsonValue.from_string(_ei.message))");
    } else if s.lowering.service.protocol == "rest-json" {
        o.line("var _ei = aws_rest_json_error(_resp)");
        o.line("_rec.set_member(String(\"errorCode\"), JsonValue.from_string(_ei.code))");
        o.line("_rec.set_member(String(\"errorMessage\"), JsonValue.from_string(_ei.message))");
    } else {
        o.line("_rec.set_member(String(\"errorCode\"), JsonValue.from_string(aws_error_code_from_body(_resp.body)))");
        o.line("_rec.set_member(String(\"errorMessage\"), JsonValue.from_string(aws_error_message_from_body(_resp.body)))");
    }
    o.indent -= 1;
    o.line("else:");
    o.indent += 1;
    o.line(&format!("var _out = {fp}_parse_{method}_response(_resp)"));
    o.line("_rec.set_member(String(\"result\"), _out.to_model_json())");
    o.indent -= 1;
    o.line(&format!("outp.set_member(String(\"{}\"), _rec^)", esc(key)));
    o.indent -= 1;
    o.line("except e:");
    o.indent += 1;
    o.line(&format!(
        "raised.set_member(String(\"{}\"), JsonValue.from_string(String(e)))",
        esc(key)
    ));
    o.indent -= 1;
    Ok(())
}

/// Emit the statements that build a value of message `fq` from `params`, and
/// return the EXPRESSION naming it.
fn emit_construct(
    o: &mut Out,
    s: &Suite,
    fq: &str,
    params: &Json,
    ctr: &mut usize,
) -> Result<String, String> {
    let msg: IrMessage = s.lowering.model.files[0]
        .messages
        .iter()
        .find(|m| m.fq_name == fq)
        .cloned()
        .ok_or_else(|| format!("no message {fq}"))?;
    let ty = format!("{}{}", s.prefix, msg.mojo_name);
    let obj = params.as_object().cloned().unwrap_or_else(JsonObject::new);

    // A case's `params` name members by their MEMBER name, not their wire
    // name (`locationName`): member name -> field.
    let mut by_name: BTreeMap<String, IrField> = BTreeMap::new();
    for f in &msg.fields {
        let n = s
            .lowering
            .facts
            .member(&msg.fq_name, &f.name)
            .map(|m| m.member_name.clone())
            .unwrap_or_else(|_| f.json_name.clone());
        by_name.insert(n, f.clone());
    }

    // Required members are constructor arguments.
    let mut args: Vec<String> = Vec::new();
    for f in &msg.fields {
        let mf = s.lowering.facts.member(&msg.fq_name, &f.name)?;
        if !mf.required {
            continue;
        }
        let v = obj.get(&mf.member_name);
        args.push(match v {
            Some(j) => emit_value(o, s, &msg, f, j, ctr)?,
            None => default_expr(s, &msg, f)?,
        });
    }
    *ctr += 1;
    let name = format!("_t{}", *ctr);
    o.line(&format!("var {name} = {ty}({})", args.join(", ")));

    for (member, f) in &by_name {
        let mf = s.lowering.facts.member(&msg.fq_name, &f.name)?;
        if mf.required {
            continue;
        }
        // An explicit `null` is an unset member, as botocore serializes it.
        let Some(j) = obj.get(member).filter(|j| !matches!(j, Json::Null)) else {
            continue;
        };
        let v = emit_value(o, s, &msg, f, j, ctr)?;
        o.line(&format!("{name}.set_{}({v})", f.name));
    }
    Ok(format!("{name}^"))
}

/// Emit whatever statements a value needs and return its expression.
fn emit_value(
    o: &mut Out,
    s: &Suite,
    msg: &IrMessage,
    f: &IrField,
    j: &Json,
    ctr: &mut usize,
) -> Result<String, String> {
    match (&f.label, &f.ty) {
        (Label::Repeated, ty) => {
            let elem_ty = elem_type(s, msg, f, ty)?;
            let arr = j.as_array().ok_or("expected an array")?;
            *ctr += 1;
            let name = format!("_t{}", *ctr);
            o.line(&format!("var {name} = List[{elem_ty}]()"));
            for e in arr {
                let v = emit_scalar(o, s, msg, f, ty, e, ctr)?;
                o.line(&format!("{name}.append({v})"));
            }
            Ok(format!("{name}^"))
        }
        (_, IrType::Map(_, vt)) => {
            let elem_ty = elem_type(s, msg, f, vt)?;
            let mo = j.as_object().ok_or("expected an object")?;
            *ctr += 1;
            let name = format!("_t{}", *ctr);
            o.line(&format!("var {name} = Dict[String, {elem_ty}]()"));
            for (k, v) in mo {
                let e = emit_scalar(o, s, msg, f, vt, v, ctr)?;
                o.line(&format!("{name}[String(\"{}\")] = {e}", esc(k)));
            }
            Ok(format!("{name}^"))
        }
        (_, ty) => emit_scalar(o, s, msg, f, ty, j, ctr),
    }
}

fn emit_scalar(
    o: &mut Out,
    s: &Suite,
    msg: &IrMessage,
    f: &IrField,
    ty: &IrType,
    j: &Json,
    ctr: &mut usize,
) -> Result<String, String> {
    let ts = s
        .lowering
        .facts
        .member(&msg.fq_name, &f.name)
        .ok()
        .and_then(|m| m.timestamp_format);
    Ok(match ty {
        IrType::Message(t) => {
            let e = emit_construct(o, s, &t.fq_name, j, ctr)?;
            e
        }
        IrType::Enum(_) => format!(
            "String(\"{}\")",
            esc(j.as_str().ok_or("enum value is not a string")?)
        ),
        IrType::List(e) => {
            let elem_ty = elem_type(s, msg, f, e)?;
            let arr = j.as_array().ok_or("expected an array")?;
            *ctr += 1;
            let name = format!("_t{}", *ctr);
            o.line(&format!("var {name} = List[{elem_ty}]()"));
            for x in arr {
                let v = emit_scalar(o, s, msg, f, e, x, ctr)?;
                o.line(&format!("{name}.append({v})"));
            }
            format!("{name}^")
        }
        IrType::Map(_, vt) => {
            let elem_ty = elem_type(s, msg, f, vt)?;
            let mo = j.as_object().ok_or("expected an object")?;
            *ctr += 1;
            let name = format!("_t{}", *ctr);
            o.line(&format!("var {name} = Dict[String, {elem_ty}]()"));
            for (k, val) in mo {
                let v = emit_scalar(o, s, msg, f, vt, val, ctr)?;
                o.line(&format!("{name}[String(\"{}\")] = {v}", esc(k)));
            }
            format!("{name}^")
        }
        IrType::Scalar(ScalarKind::String) if ts.is_some() => {
            format!("Float64({})", num_text(j)?)
        }
        IrType::Scalar(ScalarKind::String) => format!(
            "String(\"{}\")",
            esc(j.as_str().ok_or("string value is not a string")?)
        ),
        IrType::Scalar(ScalarKind::Bytes) => {
            // A conformance case states a blob as its DECODED text.
            let text = j.as_str().ok_or("blob value is not a string")?;
            *ctr += 1;
            let name = format!("_t{}", *ctr);
            o.line(&format!("var {name} = List[UInt8]()"));
            for b in text.as_bytes() {
                o.line(&format!("{name}.append(UInt8({b}))"));
            }
            format!("{name}^")
        }
        IrType::Scalar(ScalarKind::Bool) => match j {
            Json::Bool(true) => "True".into(),
            Json::Bool(false) => "False".into(),
            _ => return Err("bool value is not a bool".into()),
        },
        IrType::Scalar(ScalarKind::Double) => format!("Float64({})", num_text(j)?),
        IrType::Scalar(ScalarKind::Float) => format!("Float32({})", num_text(j)?),
        IrType::Scalar(k) => format!("{}({})", k.mojo_type(), int_text(j)?),
    })
}

fn num_text(j: &Json) -> Result<String, String> {
    match j {
        Json::Number(n) => Ok(format!("{n:?}")),
        // AWS spells the three non-finite floats as STRINGS, in both the wire
        // body and a case's `params` — `{"floatValue": "NaN"}`. Mojo has no
        // literal for them, so they are built by division.
        Json::Str(s) if s == "NaN" => Ok("Float64(0.0) / Float64(0.0)".into()),
        Json::Str(s) if s == "Infinity" => Ok("Float64(1.0) / Float64(0.0)".into()),
        Json::Str(s) if s == "-Infinity" => Ok("Float64(-1.0) / Float64(0.0)".into()),
        _ => Err("expected a number".into()),
    }
}

fn int_text(j: &Json) -> Result<String, String> {
    match j {
        Json::Number(n) => Ok(format!("{}", *n as i64)),
        _ => Err("expected a number".into()),
    }
}

fn elem_type(s: &Suite, msg: &IrMessage, f: &IrField, ty: &IrType) -> Result<String, String> {
    let ts = s
        .lowering
        .facts
        .member(&msg.fq_name, &f.name)
        .ok()
        .and_then(|m| m.timestamp_format);
    Ok(match ty {
        IrType::Message(t) => {
            let m = s.lowering.model.files[0]
                .messages
                .iter()
                .find(|m| m.fq_name == t.fq_name)
                .ok_or_else(|| format!("no message {}", t.fq_name))?;
            format!("{}{}", s.prefix, m.mojo_name)
        }
        IrType::Enum(_) => "String".into(),
        IrType::Map(_, v) => format!("Dict[String, {}]", elem_type(s, msg, f, v)?),
        IrType::List(e) => format!("List[{}]", elem_type(s, msg, f, e)?),
        IrType::Scalar(ScalarKind::String) if ts.is_some() => "Float64".into(),
        IrType::Scalar(k) => k.mojo_type().into(),
    })
}

fn default_expr(s: &Suite, msg: &IrMessage, f: &IrField) -> Result<String, String> {
    let ts = s
        .lowering
        .facts
        .member(&msg.fq_name, &f.name)
        .ok()
        .and_then(|m| m.timestamp_format);
    Ok(match (&f.label, &f.ty) {
        (Label::Repeated, ty) => format!("List[{}]()", elem_type(s, msg, f, ty)?),
        (_, IrType::Map(_, v)) => format!("Dict[String, {}]()", elem_type(s, msg, f, v)?),
        (_, IrType::List(e)) => format!("List[{}]()", elem_type(s, msg, f, e)?),
        (_, IrType::Message(t)) => {
            let m = s.lowering.model.files[0]
                .messages
                .iter()
                .find(|m| m.fq_name == t.fq_name)
                .ok_or_else(|| format!("no message {}", t.fq_name))?;
            format!("{}{}()", s.prefix, m.mojo_name)
        }
        (_, IrType::Enum(_)) => "String(\"\")".into(),
        (_, IrType::Scalar(ScalarKind::String)) if ts.is_some() => "Float64(0.0)".into(),
        (_, IrType::Scalar(ScalarKind::String)) => "String(\"\")".into(),
        (_, IrType::Scalar(ScalarKind::Bytes)) => "List[UInt8]()".into(),
        (_, IrType::Scalar(ScalarKind::Bool)) => "False".into(),
        (_, IrType::Scalar(ScalarKind::Double)) => "Float64(0.0)".into(),
        (_, IrType::Scalar(ScalarKind::Float)) => "Float32(0.0)".into(),
        (_, IrType::Scalar(k)) => format!("{}(0)", k.mojo_type()),
    })
}

fn sanitize(s: &str) -> String {
    s.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect()
}

fn esc(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            _ => out.push(c),
        }
    }
    out
}

struct Out {
    buf: String,
    indent: usize,
}

impl Out {
    fn new() -> Self {
        Out {
            buf: String::new(),
            indent: 0,
        }
    }
    fn line(&mut self, s: &str) {
        if !s.is_empty() {
            for _ in 0..self.indent {
                self.buf.push_str("    ");
            }
            self.buf.push_str(s);
        }
        self.buf.push('\n');
    }
}
