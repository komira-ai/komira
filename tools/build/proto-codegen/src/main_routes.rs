//! `protoc-gen-mojo-routes`: a protoc plugin that writes `<stem>_routes.mojo`
//! (per service: a handler trait, a komira_http_server route table built from
//! the RPCs' `(google.api.http)` rules, and a dispatcher) for each input
//! `.proto` that declares a service. Its one option, `package_prefix`, is
//! the Mojo package the message modules were generated in.

use std::io::{Read, Write};

use prost_types::{DescriptorProto, FileDescriptorProto};

use komira_proto_codegen::http_options::HttpRuleTable;
use komira_proto_codegen::lower;
use komira_proto_codegen::plugin::{
    code_generator_response, CodeGeneratorRequest, CodeGeneratorResponse,
};
use komira_proto_codegen::{PluginParameters, FEATURE_PROTO3_OPTIONAL};

mod routes;

fn main() -> std::io::Result<()> {
    let mut buf = Vec::new();
    std::io::stdin().read_to_end(&mut buf)?;
    let response = match CodeGeneratorRequest::from_stdin_bytes(&buf) {
        Ok(request) => match respond(&request, &buf) {
            Ok(files) => CodeGeneratorResponse {
                error: None,
                supported_features: Some(FEATURE_PROTO3_OPTIONAL),
                file: files
                    .into_iter()
                    .map(|(name, content)| code_generator_response::File {
                        name: Some(name),
                        content: Some(content),
                    })
                    .collect(),
            },
            Err(e) => CodeGeneratorResponse::with_error(format!("protoc-gen-mojo-routes: {e}")),
        },
        Err(e) => CodeGeneratorResponse::with_error(format!(
            "protoc-gen-mojo-routes: failed to decode CodeGeneratorRequest: {e}"
        )),
    };
    std::io::stdout().write_all(&response.to_stdout_bytes())?;
    Ok(())
}

/// DECODE the options and the `(google.api.http)` rules (from the raw bytes:
/// prost's typed decode drops the extension), LOWER, EMIT.
fn respond(request: &CodeGeneratorRequest, request_bytes: &[u8]) -> Result<Vec<(String, String)>, String> {
    let params = PluginParameters::parse(request.parameter.as_deref().unwrap_or(""))?;
    params.require_only_package_prefix("protoc-gen-mojo-routes")?;
    let rules = HttpRuleTable::from_request_bytes(request_bytes)?;
    let model = lower::lower_with_http_rules(
        &request.proto_file,
        &files_to_lower(request),
        &params.package_prefix,
        rules,
    )?;
    routes::emit_routes(&model, &request.file_to_generate)
}

/// The files to generate, then each other file declaring an RPC's request
/// message: the emitter binds path and query parameters to that message's
/// fields, so it needs them lowered too. A well-known type
/// (`google.protobuf.*`) is not lowered: it has no fields to bind.
fn files_to_lower(request: &CodeGeneratorRequest) -> Vec<String> {
    let mut out = request.file_to_generate.clone();
    let generated = request
        .proto_file
        .iter()
        .filter(|f| request.file_to_generate.contains(&f.name().to_string()));
    for f in generated {
        for m in f.service.iter().flat_map(|s| s.method.iter()) {
            let declaring = request.proto_file.iter().find(|d| {
                d.package() != "google.protobuf" && declares(d, m.input_type())
            });
            if let Some(d) = declaring {
                if !out.iter().any(|n| n == d.name()) {
                    out.push(d.name().to_string());
                }
            }
        }
    }
    out
}

/// True when `file` declares the message `fq_name` (`.pkg.Outer.Inner`).
fn declares(file: &FileDescriptorProto, fq_name: &str) -> bool {
    fn walk(prefix: &str, msgs: &[DescriptorProto], fq_name: &str) -> bool {
        msgs.iter().any(|m| {
            let name = format!("{prefix}.{}", m.name());
            name == fq_name || walk(&name, &m.nested_type, fq_name)
        })
    }
    let prefix = if file.package().is_empty() {
        String::new()
    } else {
        format!(".{}", file.package())
    };
    walk(&prefix, &file.message_type, fq_name)
}
