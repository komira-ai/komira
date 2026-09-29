//! `komira_proto_codegen`: the library behind the `protoc-gen-mojo` family of
//! protoc plugins. A request is DECODED (`plugin`), LOWERED to the
//! protocol-neutral IR (`lower`, `ir`) and EMITTED as Mojo (`emit` and its
//! siblings).

pub mod aws_conformance;
pub mod aws_in;
pub mod db_options;
pub mod emit;
pub mod emit_aws;
pub mod emit_dbstorable;
pub mod emit_index;
pub mod emit_rest;
pub mod http_options;
pub mod ir;
pub mod json;
pub mod lower;
pub mod mojo_names;
pub mod openapi_emit;
pub mod openapi_in;
pub mod overrides;
pub mod path_template;
pub mod plugin;
pub mod retry_policy;
pub mod routing_options;
pub mod xml_equiv;

pub const FEATURE_PROTO3_OPTIONAL: u64 = 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum ProtocolMode {
    /// Classic gRPC over HTTP/2 (`default_protocol=grpc`). The default.
    #[default]
    Grpc,
    /// Connect-RPC (`default_protocol=connect`).
    Connect,
    /// REST / JSON over HTTP (`default_protocol=rest`).
    Rest,
}

impl ProtocolMode {
    /// Parse a `default_protocol` value into a `ProtocolMode`. Returns
    /// `Err` with the offending value for an unknown protocol so a typo in
    /// `buf.gen.yaml` / the `mojo_proto_library` rule is a loud failure
    /// rather than a silent fall-through.
    pub fn parse(s: &str) -> Result<Self, String> {
        match s {
            "grpc" => Ok(ProtocolMode::Grpc),
            "connect" => Ok(ProtocolMode::Connect),
            "rest" => Ok(ProtocolMode::Rest),
            other => Err(format!(
                "unknown default_protocol `{other}` — expected one of: grpc, connect, rest"
            )),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PluginParameters {
    pub default_wire: String,
    pub default_protocol: String,
    pub package_prefix: String,
}

impl Default for PluginParameters {
    fn default() -> Self {
        Self {
            default_wire: "proto".to_string(),
            default_protocol: "connect".to_string(),
            package_prefix: "komira_rpc_storage".to_string(),
        }
    }
}

impl PluginParameters {
    pub fn parse(param: &str) -> Self {
        let mut p = Self::default();
        for pair in param.split(',') {
            let pair = pair.trim();
            if pair.is_empty() {
                continue;
            }
            if let Some((k, v)) = pair.split_once('=') {
                match k.trim() {
                    "default_wire" => p.default_wire = v.trim().to_string(),
                    "default_protocol" => p.default_protocol = v.trim().to_string(),
                    "package_prefix" => p.package_prefix = v.trim().to_string(),
                    _ => {}
                }
            }
        }
        p
    }
}

/// Run the full DECODE -> LOWER -> EMIT pipeline on a decoded request.
///
/// Returns the generated files as `(mojo_path, source)` pairs, or an error
/// string (which the caller surfaces in `CodeGeneratorResponse.error`).
pub fn generate(
    request: &plugin::CodeGeneratorRequest,
) -> Result<Vec<(String, String)>, String> {
    let params = PluginParameters::parse(request.parameter.as_deref().unwrap_or(""));
    let mode = ProtocolMode::parse(&params.default_protocol)?;
    let model = lower::lower(
        &request.proto_file,
        &request.file_to_generate,
        &params.package_prefix,
    )?;
    Ok(emit::emit_model_with_protocol(&model, mode))
}

/// Run the gRPC/connect DECODE -> LOWER -> EMIT pipeline, ALSO recovering the
/// `(google.api.routing)` annotation from the raw request bytes so the
/// generated gRPC client methods emit the `x-goog-request-params` routing
/// header. `prost-types` strips the custom `routing` extension on decode, so
/// (like the `http` / db options) it must be re-decoded from the wire bytes
/// (`routing_options.rs`). This is the entry point the plugin uses for
/// grpc/connect targets — it is byte-identical to [`generate`] for any
/// `.proto` carrying NO routing annotation.
pub fn generate_with_routing(
    request: &plugin::CodeGeneratorRequest,
    request_bytes: &[u8],
) -> Result<Vec<(String, String)>, String> {
    let params = PluginParameters::parse(request.parameter.as_deref().unwrap_or(""));
    let mode = ProtocolMode::parse(&params.default_protocol)?;
    let routing_rules =
        routing_options::RoutingRuleTable::from_request_bytes(request_bytes)?;
    let http_rules = http_options::HttpRuleTable::from_request_bytes(request_bytes)?;
    let model = lower::lower_with_http_and_routing_rules(
        &request.proto_file,
        &request.file_to_generate,
        &params.package_prefix,
        http_rules,
        routing_rules,
    )?;
    Ok(emit::emit_model_with_protocol(&model, mode))
}

pub fn generate_db(
    request: &plugin::CodeGeneratorRequest,
    descriptor_set_bytes: &[u8],
) -> Result<Vec<(String, String)>, String> {
    let params = PluginParameters::parse(request.parameter.as_deref().unwrap_or(""));
    let model = lower::lower(
        &request.proto_file,
        &request.file_to_generate,
        &params.package_prefix,
    )?;
    let opts = db_options::DbOptionTable::from_descriptor_set_bytes(descriptor_set_bytes)?;
    Ok(emit_dbstorable::emit_db_model(&model, &opts))
}

pub fn generate_index(
    request: &plugin::CodeGeneratorRequest,
    descriptor_set_bytes: &[u8],
) -> Result<Vec<(String, String)>, String> {
    let params = PluginParameters::parse(request.parameter.as_deref().unwrap_or(""));
    let model = lower::lower(
        &request.proto_file,
        &request.file_to_generate,
        &params.package_prefix,
    )?;
    let opts = db_options::DbOptionTable::from_descriptor_set_bytes(descriptor_set_bytes)?;
    emit_index::emit_index_model(&model, &opts)
}

pub fn generate_rest(
    request: &plugin::CodeGeneratorRequest,
    descriptor_set_bytes: &[u8],
) -> Result<Vec<(String, String)>, String> {
    let params = PluginParameters::parse(request.parameter.as_deref().unwrap_or(""));
    let mode = ProtocolMode::parse(&params.default_protocol)?;
    if mode != ProtocolMode::Rest {
        return Err(format!(
            "generate_rest called with default_protocol=`{}` (expected `rest`)",
            params.default_protocol
        ));
    }
    let http_rules =
        http_options::HttpRuleTable::from_descriptor_set_bytes(descriptor_set_bytes)?;
    let model = lower::lower_with_http_rules(
        &request.proto_file,
        &request.file_to_generate,
        &params.package_prefix,
        http_rules,
    )?;
    // Pre-validate every annotated service so a missing annotation / bad
    // template is a clean Result error rather than the emitter's panic
    // backstop. `emit_rest::emit_rest_service` returns the same error the
    // emitter would, so this is the single source of the loud failure.
    for file in &model.files {
        for svc in &file.services {
            emit_rest::emit_rest_service(file, svc)?;
        }
    }
    Ok(emit::emit_model_with_protocol(&model, mode))
}

pub fn generate_from_openapi(
    doc_text: &str,
    doc_path: &str,
    package_prefix: &str,
) -> Result<(Vec<(String, String)>, Vec<String>), String> {
    let doc = json::parse(doc_text)
        .map_err(|e| format!("OpenAPI document is not valid JSON: {e}"))?;
    let lowering = openapi_in::lower_openapi(&doc, doc_path, package_prefix)?;
    Ok((emit::emit_model(&lowering.model), lowering.notes))
}

pub fn respond_with_bytes(
    request: &plugin::CodeGeneratorRequest,
    request_bytes: &[u8],
) -> plugin::CodeGeneratorResponse {
    // Route a `rest` target through the REST pipeline (which recovers the
    // http annotations + validates loudly); everything else through the
    // default gRPC/connect path.
    let params = PluginParameters::parse(request.parameter.as_deref().unwrap_or(""));
    let result = match ProtocolMode::parse(&params.default_protocol) {
        Ok(ProtocolMode::Rest) => http_options::HttpRuleTable::from_request_bytes(request_bytes)
            .and_then(|rules| {
                let model = lower::lower_with_http_rules(
                    &request.proto_file,
                    &request.file_to_generate,
                    &params.package_prefix,
                    rules,
                )?;
                for file in &model.files {
                    for svc in &file.services {
                        emit_rest::emit_rest_service(file, svc)?;
                    }
                }
                Ok(emit::emit_model_with_protocol(&model, ProtocolMode::Rest))
            }),
        // grpc/connect: recover the `(google.api.routing)` annotation from the
        // raw bytes so the generated client emits the `x-goog-request-params`
        // routing header (prost strips the extension on the typed decode).
        Ok(_) => generate_with_routing(request, request_bytes),
        Err(e) => Err(e),
    };
    build_response(result)
}

/// Build the full `CodeGeneratorResponse` for a request through the default
/// (grpc/connect) path. Kept for callers that do not have the raw bytes; a
/// `rest` target reached here emits with no http annotations and will fail
/// loudly at emit (the missing-annotation rule) — use [`respond_with_bytes`]
/// for REST.
pub fn respond(
    request: &plugin::CodeGeneratorRequest,
) -> plugin::CodeGeneratorResponse {
    build_response(generate(request))
}

/// Wrap a `generate*` result into a `CodeGeneratorResponse`.
fn build_response(
    result: Result<Vec<(String, String)>, String>,
) -> plugin::CodeGeneratorResponse {
    match result {
        Ok(files) => plugin::CodeGeneratorResponse {
            error: None,
            supported_features: Some(FEATURE_PROTO3_OPTIONAL),
            file: files
                .into_iter()
                .map(|(name, content)| plugin::code_generator_response::File {
                    name: Some(name),
                    content: Some(content),
                })
                .collect(),
        },
        Err(e) => plugin::CodeGeneratorResponse::with_error(format!(
            "protoc-gen-mojo: {e}"
        )),
    }
}
