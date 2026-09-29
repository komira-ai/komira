//! `aws-model-check`: validates one botocore `service-2.json` before it is
//! used as generator input.

use std::collections::BTreeSet;
use std::io::Write;
use std::process::ExitCode;

use komira_proto_codegen::json::{parse, Json};

const KNOWN_PROTOCOLS: &[&str] = &[
    "json",
    "rest-json",
    "rest-xml",
    "query",
    "ec2",
    "smithy-rpc-v2-cbor",
];

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 7 {
        eprintln!(
            "usage: {} <service> <api-version> <protocol> <model.json> \
             <out-model.json> <out-facts.tsv>",
            args.first().map(String::as_str).unwrap_or("aws-model-check")
        );
        return ExitCode::FAILURE;
    }
    match run(&args[1], &args[2], &args[3], &args[4], &args[5], &args[6]) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("aws-model-check: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(
    service: &str,
    api_version: &str,
    declared_protocol: &str,
    model_path: &str,
    out_model: &str,
    out_facts: &str,
) -> Result<(), String> {
    // (1) Present and non-empty. `read` on an absent path is an Err, which is
    // the "input is absent" case the rule must fail loudly on.
    let raw = std::fs::read(model_path)
        .map_err(|e| format!("cannot read {model_path}: {e}"))?;
    if raw.is_empty() {
        return Err(format!("{model_path}: ZERO-BYTE model"));
    }
    let text = String::from_utf8(raw.clone())
        .map_err(|e| format!("{model_path}: not UTF-8: {e}"))?;

    // (2) Parses.
    let doc = parse(&text).map_err(|e| format!("{model_path}: not valid JSON: {e}"))?;
    let root = doc
        .as_object()
        .ok_or_else(|| format!("{model_path}: top level is not a JSON object"))?;

    // (3)(4)(5) metadata.
    let metadata = root
        .get("metadata")
        .and_then(Json::as_object)
        .ok_or_else(|| format!("{model_path}: no `metadata` object"))?;

    let protocol = metadata
        .get("protocol")
        .and_then(Json::as_str)
        .ok_or_else(|| {
            format!(
                "{model_path}: no `metadata.protocol`. That string is the \
                 generator's dispatch key — a model without it cannot be lowered"
            )
        })?;
    if !KNOWN_PROTOCOLS.contains(&protocol) {
        return Err(format!(
            "{model_path}: unknown `metadata.protocol` {protocol:?} (known: {}). \
             A new protocol needs a serializer, not a default",
            KNOWN_PROTOCOLS.join(", ")
        ));
    }
    // The DECLARED protocol must BE the model's protocol. Without this the
    // `protocol` attribute is decoration: it would pass the analysis-time
    // known-list check and then disagree with the model forever, and the
    // generator dispatches on it.
    if declared_protocol != protocol {
        return Err(format!(
            "{model_path}: declared protocol {declared_protocol:?} but \
             `metadata.protocol` is {protocol:?}. That string is the generator's \
             dispatch key — a BUILD file and its model may not disagree about it"
        ));
    }

    let declared_api = metadata.get("apiVersion").and_then(Json::as_str);
    if let Some(v) = declared_api {
        if v != api_version {
            return Err(format!(
                "{model_path}: filed under api-version {api_version:?} but \
                 `metadata.apiVersion` is {v:?}"
            ));
        }
    } else {
        return Err(format!("{model_path}: no `metadata.apiVersion`"));
    }

    let service_id = metadata
        .get("serviceId")
        .and_then(Json::as_str)
        .unwrap_or("");
    let endpoint_prefix = metadata
        .get("endpointPrefix")
        .and_then(Json::as_str)
        .unwrap_or("");
    let signing_name = metadata
        .get("signingName")
        .and_then(Json::as_str)
        .unwrap_or(endpoint_prefix);

    // (6)(7) operations + shapes, both non-empty.
    let operations = root
        .get("operations")
        .and_then(Json::as_object)
        .ok_or_else(|| format!("{model_path}: no `operations` object"))?;
    if operations.is_empty() {
        return Err(format!("{model_path}: `operations` is EMPTY"));
    }
    let shapes = root
        .get("shapes")
        .and_then(Json::as_object)
        .ok_or_else(|| format!("{model_path}: no `shapes` object"))?;
    if shapes.is_empty() {
        return Err(format!("{model_path}: `shapes` is EMPTY"));
    }

    // (8) every operation-level shape reference resolves.
    let known: BTreeSet<&str> = shapes.keys().map(String::as_str).collect();
    let mut dangling: Vec<String> = Vec::new();
    for (op_name, op) in operations {
        let Some(op_obj) = op.as_object() else {
            return Err(format!("{model_path}: operation {op_name:?} is not an object"));
        };
        for field in ["input", "output"] {
            if let Some(r) = op_obj.get(field).and_then(Json::as_object) {
                if let Some(s) = r.get("shape").and_then(Json::as_str) {
                    if !known.contains(s) {
                        dangling.push(format!("{op_name}.{field} -> {s}"));
                    }
                }
            }
        }
        if let Some(errs) = op_obj.get("errors").and_then(Json::as_array) {
            for e in errs {
                if let Some(s) = e.get("shape").and_then(Json::as_str) {
                    if !known.contains(s) {
                        dangling.push(format!("{op_name}.errors -> {s}"));
                    }
                }
            }
        }
    }
    if !dangling.is_empty() {
        let shown: Vec<String> = dangling.iter().take(10).cloned().collect();
        return Err(format!(
            "{model_path}: {} operation shape reference(s) name a shape that is \
             not in `shapes`: {}{}",
            dangling.len(),
            shown.join(", "),
            if dangling.len() > shown.len() { ", ..." } else { "" }
        ));
    }

    write_bytes(out_model, &raw)?;
    let facts = format!(
        "service\t{service}\n\
         api_version\t{api_version}\n\
         protocol\t{protocol}\n\
         service_id\t{service_id}\n\
         endpoint_prefix\t{endpoint_prefix}\n\
         signing_name\t{signing_name}\n\
         operations\t{}\n\
         shapes\t{}\n\
         bytes\t{}\n",
        operations.len(),
        shapes.len(),
        raw.len()
    );
    write_bytes(out_facts, facts.as_bytes())?;
    Ok(())
}

fn write_bytes(path: &str, bytes: &[u8]) -> Result<(), String> {
    if let Some(parent) = std::path::Path::new(path).parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
    }
    let mut f = std::fs::File::create(path)
        .map_err(|e| format!("cannot create {path}: {e}"))?;
    f.write_all(bytes)
        .map_err(|e| format!("cannot write {path}: {e}"))
}
