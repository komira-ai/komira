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

/// The `--mojo_opt` options of a protoc-gen-mojo invocation.
///
/// protoc hands the plugin one string; the Mojo proto rules build it by
/// joining `key=value` tokens with `,`. Every token must be `key=value` with
/// a known key: [`PluginParameters::parse`] refuses anything else, so a typo
/// in a rule is a loud failure rather than an option silently ignored.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PluginParameters {
    pub default_wire: String,
    pub default_protocol: String,
    pub package_prefix: String,
    /// What to emit; see [`lower::Scope`].
    pub scope: lower::Scope,
    /// `layout_probe=true`: also write [`emit::LAYOUT_PROBE_FILE`], one
    /// `size_of` per emitted struct.
    pub layout_probe: bool,
}

impl Default for PluginParameters {
    fn default() -> Self {
        Self {
            default_wire: "proto".to_string(),
            default_protocol: "connect".to_string(),
            package_prefix: "komira_rpc_storage".to_string(),
            scope: lower::Scope::default(),
            layout_probe: false,
        }
    }
}

/// The separator of the items of a list-valued option (`roots=`,
/// `methods=`). Not `,`: that separates the options themselves.
pub const LIST_SEPARATOR: char = '+';

impl PluginParameters {
    /// Parse the comma-joined `key=value` option string.
    ///
    /// Refused: a token without `=` (including an empty one, so `a=1,,b=2`
    /// is an error), an unknown key, a key given twice, an empty value, an
    /// empty item of a list, and a boolean other than `true` / `false`.
    pub fn parse(param: &str) -> Result<Self, String> {
        let mut p = Self::default();
        if param.trim().is_empty() {
            return Ok(p);
        }
        let mut seen: Vec<&str> = Vec::new();
        for token in param.split(',') {
            let token = token.trim();
            let (k, v) = token.split_once('=').ok_or_else(|| {
                format!("option `{token}` is not `key=value` (options: {param:?})")
            })?;
            let (k, v) = (k.trim(), v.trim());
            if seen.contains(&k) {
                return Err(format!("option `{k}` is given twice (options: {param:?})"));
            }
            seen.push(k);
            if v.is_empty() {
                return Err(format!("option `{k}` has an empty value"));
            }
            match k {
                "default_wire" => p.default_wire = v.to_string(),
                "default_protocol" => p.default_protocol = v.to_string(),
                "package_prefix" => p.package_prefix = v.to_string(),
                "roots" => p.scope.roots = parse_list(k, v)?,
                "methods" => p.scope.methods = parse_list(k, v)?,
                "messages_only" => p.scope.messages_only = parse_bool(k, v)?,
                "layout_probe" => p.layout_probe = parse_bool(k, v)?,
                other => {
                    return Err(format!(
                        "unknown option `{other}` — expected one of: default_wire, \
                         default_protocol, package_prefix, roots, methods, \
                         messages_only, layout_probe"
                    ))
                }
            }
        }
        Ok(p)
    }

    /// Refuse the options only protoc-gen-mojo implements, for the plugins
    /// (db, index, OpenAPI) that would otherwise ignore them.
    pub fn require_only_package_prefix(&self, plugin: &str) -> Result<(), String> {
        if !self.scope.is_everything() || self.layout_probe {
            return Err(format!(
                "{plugin} does not implement roots, methods, messages_only or layout_probe"
            ));
        }
        Ok(())
    }
}

fn parse_list(key: &str, value: &str) -> Result<Vec<String>, String> {
    let items: Vec<String> = value
        .split(LIST_SEPARATOR)
        .map(|s| s.trim().to_string())
        .collect();
    if items.iter().any(String::is_empty) {
        return Err(format!(
            "option `{key}={value}` has an empty item (items are separated by `{LIST_SEPARATOR}`)"
        ));
    }
    Ok(items)
}

fn parse_bool(key: &str, value: &str) -> Result<bool, String> {
    match value {
        "true" => Ok(true),
        "false" => Ok(false),
        other => Err(format!("option `{key}` must be `true` or `false`, not `{other}`")),
    }
}

/// Lower the request with its options and both annotation overlays, then
/// emit: the Mojo modules, plus the layout probe when asked for. The one
/// path of `rest`, `grpc` and `connect` targets.
fn generate_scoped(
    request: &plugin::CodeGeneratorRequest,
    params: &PluginParameters,
    http_rules: http_options::HttpRuleTable,
    routing_rules: routing_options::RoutingRuleTable,
    mode: ProtocolMode,
) -> Result<Vec<(String, String)>, String> {
    let model = lower::lower_scoped(
        &request.proto_file,
        &request.file_to_generate,
        &params.package_prefix,
        http_rules,
        routing_rules,
        &params.scope,
    )?;
    if mode == ProtocolMode::Rest {
        // Pre-validate every annotated service so a missing annotation / bad
        // template is a clean Result error rather than the emitter's panic
        // backstop.
        for file in &model.files {
            for svc in &file.services {
                emit_rest::emit_rest_service(file, svc)?;
            }
        }
    }
    let mut files = emit::emit_model_with_protocol(&model, mode);
    if params.layout_probe {
        files.push(emit::emit_layout_probe(&model));
    }
    Ok(files)
}

/// Run the full DECODE -> LOWER -> EMIT pipeline on a decoded request, with
/// no annotation overlays.
///
/// Returns the generated files as `(mojo_path, source)` pairs, or an error
/// string (which the caller surfaces in `CodeGeneratorResponse.error`).
pub fn generate(
    request: &plugin::CodeGeneratorRequest,
) -> Result<Vec<(String, String)>, String> {
    let params = PluginParameters::parse(request.parameter.as_deref().unwrap_or(""))?;
    let mode = ProtocolMode::parse(&params.default_protocol)?;
    generate_scoped(
        request,
        &params,
        http_options::HttpRuleTable::default(),
        routing_options::RoutingRuleTable::default(),
        mode,
    )
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
    let params = PluginParameters::parse(request.parameter.as_deref().unwrap_or(""))?;
    let mode = ProtocolMode::parse(&params.default_protocol)?;
    let routing_rules =
        routing_options::RoutingRuleTable::from_request_bytes(request_bytes)?;
    let http_rules = http_options::HttpRuleTable::from_request_bytes(request_bytes)?;
    generate_scoped(request, &params, http_rules, routing_rules, mode)
}

pub fn generate_db(
    request: &plugin::CodeGeneratorRequest,
    descriptor_set_bytes: &[u8],
) -> Result<Vec<(String, String)>, String> {
    let params = PluginParameters::parse(request.parameter.as_deref().unwrap_or(""))?;
    params.require_only_package_prefix("protoc-gen-mojo-db")?;
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
    let params = PluginParameters::parse(request.parameter.as_deref().unwrap_or(""))?;
    params.require_only_package_prefix("protoc-gen-mojo-index")?;
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
    let params = PluginParameters::parse(request.parameter.as_deref().unwrap_or(""))?;
    let mode = ProtocolMode::parse(&params.default_protocol)?;
    if mode != ProtocolMode::Rest {
        return Err(format!(
            "generate_rest called with default_protocol=`{}` (expected `rest`)",
            params.default_protocol
        ));
    }
    let http_rules =
        http_options::HttpRuleTable::from_descriptor_set_bytes(descriptor_set_bytes)?;
    generate_scoped(
        request,
        &params,
        http_rules,
        routing_options::RoutingRuleTable::default(),
        mode,
    )
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
    // default gRPC/connect path, which also recovers the
    // `(google.api.routing)` annotation (prost strips the extension on the
    // typed decode).
    let result = PluginParameters::parse(request.parameter.as_deref().unwrap_or(""))
        .and_then(|params| {
            match ProtocolMode::parse(&params.default_protocol)? {
                ProtocolMode::Rest => {
                    let rules = http_options::HttpRuleTable::from_request_bytes(request_bytes)?;
                    generate_scoped(
                        request,
                        &params,
                        rules,
                        routing_options::RoutingRuleTable::default(),
                        ProtocolMode::Rest,
                    )
                }
                _ => generate_with_routing(request, request_bytes),
            }
        });
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
