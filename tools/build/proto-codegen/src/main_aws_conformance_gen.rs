//! `aws-conformance-gen`: generates the Mojo driver that runs botocore's
//! protocol conformance corpus against the generated serializer.

use std::collections::BTreeMap;
use std::path::Path;

use komira_proto_codegen::aws_in::{lower_aws_service, AwsLowering};
use komira_proto_codegen::emit_aws::{emit_aws_client, pure_preamble, AwsEmitOptions};
use komira_proto_codegen::ir::{IrField, IrMessage, IrType, Label, ScalarKind};
use komira_proto_codegen::json::{parse, Json, JsonObject};
use komira_proto_codegen::overrides::AwsOverrides;

const PROTOCOL: &str = "json";

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: aws-conformance-gen <corpus-dir> <out-file.mojo>");
        std::process::exit(2);
    }
    if let Err(e) = run(Path::new(&args[1]), Path::new(&args[2])) {
        eprintln!("aws-conformance-gen: {e}");
        std::process::exit(1);
    }
}

struct Suite {
    module: String,
    prefix: String,
    lowering: AwsLowering,
    /// case key -> the case body
    cases: Vec<(String, Json)>,
    direction: Direction,
    client_endpoint: Option<String>,
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
}

fn run(corpus: &Path, out: &Path) -> Result<(), String> {
    if let Some(d) = out.parent() {
        std::fs::create_dir_all(d).map_err(|e| format!("mkdir {}: {e}", d.display()))?;
    }

    let mut suites: Vec<Suite> = Vec::new();
    let mut skipped: Vec<(String, String)> = Vec::new();
    let mut n_cases_total = 0usize;
    let mut suite_seq = 0usize;

    for direction in [Direction::Input, Direction::Output] {
        let dir = corpus.join(direction.dir());
        let mut files: Vec<_> = std::fs::read_dir(&dir)
            .map_err(|e| format!("readdir {}: {e}", dir.display()))?
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().map(|x| x == "json").unwrap_or(false))
            .collect();
        files.sort();
        for path in files {
            let text = std::fs::read_to_string(&path)
                .map_err(|e| format!("read {}: {e}", path.display()))?;
            let doc = parse(&text).map_err(|e| format!("{}: {e}", path.display()))?;
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
                if meta.get("protocol").and_then(Json::as_str) != Some(PROTOCOL) {
                    continue;
                }
                let cases = obj
                    .get("cases")
                    .and_then(Json::as_array)
                    .ok_or_else(|| format!("{basename}[{si}]: no cases"))?;
                n_cases_total += cases.len();

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
                match build_suite(obj, meta, cases, &module, &prefix, &basename, direction) {
                    Ok(s) => suites.push(s),
                    Err(e) => {
                        // A suite the front-end cannot lower yields NO actuals
                        // for its cases, which the harness scores `unsupported`
                        // — never a pass and never a silent zero.
                        for c in cases {
                            let id = c
                                .as_object()
                                .and_then(|o| o.get("id"))
                                .and_then(Json::as_str)
                                .unwrap_or("<no id>");
                            skipped.push((
                                format!("{}/{basename}#{id}", direction.dir()),
                                e.clone(),
                            ));
                        }
                    }
                }
            }
        }
    }

    let mut bodies = String::new();
    for s in &suites {
        let (_, src) = emit_aws_client(
            &s.lowering,
            &AwsOverrides::empty(),
            &s.module,
            AwsEmitOptions {
                emit_model_json: true,
                pure_only: true,
                omit_preamble: true,
            },
        )?;
        bodies.push_str(&src);
    }
    let (driver_main, undriveable) = emit_driver(&suites, &skipped, n_cases_total)?;
    let mut whole = driver_header(&suites, &skipped, &undriveable, n_cases_total);
    whole.push_str(&pure_preamble(true));
    whole.push_str(&bodies);
    whole.push_str(&driver_main);
    std::fs::write(out, &whole)
        .map_err(|e| format!("write {}: {e}", out.display()))?;

    eprintln!(
        "aws-conformance-gen: {} suites, {} cases in scope, {} unlowerable",
        suites.len(),
        n_cases_total,
        skipped.len()
    );
    for (k, e) in &skipped {
        eprintln!("  UNLOWERABLE {k}: {}", first_line(e));
    }
    for (k, e) in &undriveable {
        eprintln!("  UNDRIVEABLE {k}: {}", first_line(e));
    }
    Ok(())
}

fn first_line(s: &str) -> &str {
    s.split('\n').next().unwrap_or(s)
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
    for c in cases {
        let co = c
            .as_object()
            .ok_or_else(|| "case is not an object".to_string())?;
        let id = co
            .get("id")
            .and_then(Json::as_str)
            .ok_or_else(|| "case has no id".to_string())?;
        let given = co
            .get("given")
            .cloned()
            .ok_or_else(|| format!("case {id} has no `given`"))?;
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
    })
}

fn init_module(modules: &[String]) -> String {
    let mut s = String::new();
    s.push_str("\"\"\"GENERATED by //tools/build/proto-codegen:aws-conformance-gen — DO NOT EDIT.\n\n");
    s.push_str("The botocore protocol conformance corpus, reassembled into one generated\n");
    s.push_str("Mojo module per suite by the REAL front-end and the REAL emitter, plus a\n");
    s.push_str("driver that prints the actuals file the Stage-0b harness compares.\n\"\"\"\n");
    for m in modules {
        s.push_str(&format!("from . import {m}\n"));
    }
    s.push_str("from . import conformance_driver\n");
    s
}

// ---------------------------------------------------------------------------
// The driver
// ---------------------------------------------------------------------------

fn driver_header(
    suites: &[Suite],
    skipped: &[(String, String)],
    undriveable: &[(String, String)],
    n_cases_total: usize,
) -> String {
    let mut o = Out::new();
    o.line("# ==========================================================================");
    o.line("# GENERATED by //tools/build/proto-codegen:aws-conformance-gen — DO NOT EDIT.");
    o.line("#");
    o.line("# Runs botocore's own protocol conformance corpus against the GENERATED");
    o.line("# awsJson serializer and prints the actuals file on stdout, in the format");
    o.line("# `aws_conformance::ActualsFile::parse` reads.");
    o.line("#");
    o.line("# ⚠ A CASE THIS DRIVER CANNOT ANSWER IS ABSENT FROM THE OUTPUT, AND ABSENT");
    o.line("# IS `unsupported` — never a pass. A `try/except` that swallowed an error");
    o.line("# and wrote a plausible record would convert 'we cannot do this' into 'we");
    o.line("# do this correctly', which is the failure mode the whole harness exists");
    o.line("# to refuse.");
    o.line("#");
    o.line(&format!("#   suites lowered : {}", suites.len()));
    o.line(&format!("#   cases in scope : {n_cases_total}"));
    o.line(&format!("#   unlowerable    : {}", skipped.len()));
    for (k, e) in skipped {
        o.line(&format!("#     {k}: {}", first_line(e)));
    }
    o.line(&format!("#   undriveable    : {}", undriveable.len()));
    for (k, e) in undriveable {
        o.line(&format!("#     {k}: {}", first_line(e)));
    }
    o.line("# ==========================================================================");
    o.line("");
    o.line("from std.sys import stderr");
    o.line("");
    o.buf
}

fn emit_driver(
    suites: &[Suite],
    skipped: &[(String, String)],
    n_cases_total: usize,
) -> Result<(String, Vec<(String, String)>), String> {
    let mut o = Out::new();
    o.line("def _note_unsupported(key: String, e: Error):");
    o.indent += 1;
    o.line("\"\"\"A case the generated code RAISED on. It is reported on STDERR and");
    o.line("    contributes NO record, so the harness scores it `unsupported`.");
    o.blank_comment();
    o.line("    ⛔ STDERR, NOT STDOUT. Stdout carries the actuals JSON and nothing");
    o.line("    else; one stray line there makes the whole file unparseable and");
    o.line("    turns 168 answers into a parse error.\"\"\"");
    o.line("print(String(\"UNSUPPORTED \") + key + String(\": \") + String(e), file=stderr)");
    o.indent -= 1;
    o.line("");
    o.line("");
    o.line("def main() raises:");
    o.indent += 1;
    o.line("var actuals = JsonValue.empty_object()");
    o.line("var inp = JsonValue.empty_object()");
    o.line("var outp = JsonValue.empty_object()");

    let mut undriveable: Vec<(String, String)> = Vec::new();
    let mut ctr = 0usize;
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
                }
                Err(e) => undriveable.push((key.clone(), e)),
            }
        }
    }

    o.line("");
    for (k, e) in &undriveable {
        o.line(&format!("# UNDRIVEABLE {k}: {}", first_line(e)));
    }
    o.line("");
    o.line("actuals.set_member(String(\"input\"), inp^)");
    o.line("actuals.set_member(String(\"output\"), outp^)");
    o.line("print(actuals.serialize())");
    o.indent -= 1;
    Ok((o.buf, undriveable))
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

    // `client_endpoint` is the case's own endpoint, default `https://<host>`.
    let endpoint = s
        .client_endpoint
        .clone()
        .unwrap_or_else(|| "https://protocoltests.us-east-1.amazonaws.com".to_string());
    let without_scheme = endpoint
        .split_once("://")
        .map(|(_, r)| r)
        .unwrap_or(&endpoint)
        .trim_end_matches('/')
        .to_string();
    let (endpoint_authority, endpoint_path) = match without_scheme.find('/') {
        Some(i) => (without_scheme.clone(), without_scheme[i..].to_string()),
        None => (without_scheme.clone(), String::new()),
    };

    let var = format!("_c_{}", sanitize(id));
    o.line("try:");
    o.indent += 1;
    let expr = emit_construct(o, s, &input_fq, &params, ctr)?;
    o.line(&format!("var {var} = {expr}"));
    let fp = s.prefix.to_lowercase();
    o.line(&format!("var _req = {fp}_build_{method}_request({var})"));
    o.line("var _rec = JsonValue.empty_object()");
    // ENDPOINT COMPOSITION happens HERE, not in the serializer. `AwsRequest`
    // carries a host PREFIX and a path; the endpoint (`client_endpoint`, or in
    // production a region + partition resolution) supplies the rest. botocore's
    // own comparison folds the endpoint's PATH into both fields — expected host
    // `example.com/custom` and uri `/custom/` for endpoint
    // `https://example.com/custom` — which is why this is two concatenations
    // and not one.
    o.line(&format!(
        "_rec.set_member(String(\"host\"), JsonValue.from_string(\n    \
         _req.host_prefix + String(\"{}\")))",
        esc(&endpoint_authority)
    ));
    o.line("_rec.set_member(String(\"method\"), JsonValue.from_string(_req.method.copy()))");
    o.line(&format!(
        "_rec.set_member(String(\"uri\"), JsonValue.from_string(\n    \
         String(\"{}\") + _req.uri))",
        esc(&endpoint_path)
    ));
    o.line("_rec.set_member(String(\"body\"), JsonValue.from_string(_req.body.copy()))");
    o.line("var _hdr = JsonValue.empty_object()");
    o.line("for _i in range(len(_req.header_names)):");
    o.indent += 1;
    o.line("_hdr.set_member(");
    o.indent += 1;
    o.line("_req.header_names[_i].copy(),");
    o.line("JsonValue.from_string(_req.header_values[_i].copy()),");
    o.indent -= 1;
    o.line(")");
    o.indent -= 1;
    o.line("_rec.set_member(String(\"headers\"), _hdr^)");
    o.line(&format!(
        "inp.set_member(String(\"{}\"), _rec^)",
        esc(key)
    ));
    o.indent -= 1;
    o.line("except e:");
    o.indent += 1;
    o.line(&format!(
        "_note_unsupported(String(\"{}\"), e)",
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
    let hdr = |name: &str| -> String {
        resp.and_then(|r| r.get("headers"))
            .and_then(Json::as_object)
            .and_then(|h| {
                h.iter()
                    .find(|(k, _)| k.eq_ignore_ascii_case(name))
                    .and_then(|(_, v)| v.as_str())
            })
            .unwrap_or("")
            .to_string()
    };
    let err_hdr = hdr("x-amzn-errortype");
    let query_err_hdr = hdr("x-amzn-query-error");

    o.line("try:");
    o.indent += 1;
    let fp = s.prefix.to_lowercase();
    o.line("var _rec = JsonValue.empty_object()");
    // The STATUS is the case's; the CLASSIFICATION is the shipped predicate.
    o.line(&format!("if aws_is_error_status({status}):"));
    o.indent += 1;
    o.line(&format!(
        "_rec.set_member(String(\"errorCode\"), JsonValue.from_string(\n             aws_error_code(String(\"{}\"), String(\"{}\"), String(\"{}\"))))",
        esc(&err_hdr),
        esc(&body),
        esc(&query_err_hdr)
    ));
    o.line(&format!(
        "_rec.set_member(String(\"errorMessage\"), JsonValue.from_string(\n             aws_error_message_from_body(String(\"{}\"))))",
        esc(&body)
    ));
    o.indent -= 1;
    o.line("else:");
    o.indent += 1;
    o.line(&format!(
        "var _out = {fp}_parse_{method}_response(String(\"{}\"))",
        esc(&body)
    ));
    o.line("_rec.set_member(String(\"result\"), _out.to_model_json())");
    o.indent -= 1;
    o.line(&format!(
        "outp.set_member(String(\"{}\"), _rec^)",
        esc(key)
    ));
    o.indent -= 1;
    o.line("except e:");
    o.indent += 1;
    o.line(&format!("_note_unsupported(String(\"{}\"), e)", esc(key)));
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

    // wire name -> field
    let mut by_wire: BTreeMap<String, IrField> = BTreeMap::new();
    for f in &msg.fields {
        let w = s
            .lowering
            .facts
            .member(&msg.fq_name, &f.name)
            .map(|m| m.wire_name.clone())
            .unwrap_or_else(|_| f.json_name.clone());
        by_wire.insert(w, f.clone());
    }

    // Required members are constructor arguments.
    let mut args: Vec<String> = Vec::new();
    for f in &msg.fields {
        let mf = s.lowering.facts.member(&msg.fq_name, &f.name)?;
        if !mf.required {
            continue;
        }
        let v = obj.get(&mf.wire_name);
        args.push(match v {
            Some(j) => emit_value(o, s, &msg, f, j, ctr)?,
            None => default_expr(s, &msg, f)?,
        });
    }
    *ctr += 1;
    let name = format!("_t{}", *ctr);
    o.line(&format!("var {name} = {ty}({})", args.join(", ")));

    for (wire, f) in &by_wire {
        let mf = s.lowering.facts.member(&msg.fq_name, &f.name)?;
        if mf.required {
            continue;
        }
        let Some(j) = obj.get(wire) else { continue };
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
    fn blank_comment(&mut self) {
        self.buf.push('\n');
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
