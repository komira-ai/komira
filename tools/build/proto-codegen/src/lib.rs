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
pub mod service_config;
pub mod service_options;
pub mod xml_equiv;
pub mod yaml_subset;

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
    /// `gcp=true`: a Google Cloud client. Its gRPC service clients take a
    /// `komira_gcp_core` token source, set its token as each call's
    /// `authorization` metadata, speak classic gRPC only, and raise a non-OK
    /// status through `komira_gcp_core` (`emit::Emitter::with_options`).
    /// Refused with `default_protocol=connect`; REST clients are Google Cloud
    /// clients either way.
    pub gcp: bool,
    /// `module_names=<path>:<stem>+...`: the module each named generated
    /// `.proto` is written as, in place of its basename's stem
    /// ([`lower::ModuleNames`]).
    pub module_names: lower::ModuleNames,
    /// `service_config=<path>`: a service configuration YAML whose
    /// `http.rules` and `name` are overlaid on the lowered model
    /// ([`service_config::ServiceConfig::apply`]). `default_protocol=rest`
    /// only.
    pub service_config: Option<String>,
}

impl Default for PluginParameters {
    fn default() -> Self {
        Self {
            default_wire: "proto".to_string(),
            default_protocol: "connect".to_string(),
            package_prefix: "komira_rpc_storage".to_string(),
            scope: lower::Scope::default(),
            layout_probe: false,
            gcp: false,
            module_names: lower::ModuleNames::new(),
            service_config: None,
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
                "omit_fields" => p.scope.omit_fields = parse_list(k, v)?,
                "layout_probe" => p.layout_probe = parse_bool(k, v)?,
                "gcp" => p.gcp = parse_bool(k, v)?,
                "module_names" => p.module_names = parse_module_names(k, v)?,
                "service_config" => p.service_config = Some(v.to_string()),
                other => {
                    return Err(format!(
                        "unknown option `{other}` — expected one of: default_wire, \
                         default_protocol, package_prefix, roots, methods, \
                         messages_only, omit_fields, layout_probe, gcp, module_names, \
                         service_config"
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
                "{plugin} does not implement roots, methods, omit_fields, messages_only or layout_probe"
            ));
        }
        if self.gcp {
            return Err(format!("{plugin} does not implement gcp"));
        }
        if !self.module_names.is_empty() {
            return Err(format!("{plugin} does not implement module_names"));
        }
        if self.service_config.is_some() {
            return Err(format!("{plugin} does not implement service_config"));
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

/// Parse `module_names`: `+`-separated `<proto path>:<module stem>` items,
/// each path named once. The stems are checked against the generated files
/// in [`check_module_names`].
fn parse_module_names(key: &str, value: &str) -> Result<lower::ModuleNames, String> {
    let mut names = lower::ModuleNames::new();
    for item in parse_list(key, value)? {
        let (path, stem) = item.split_once(':').ok_or_else(|| {
            format!("option `{key}` item `{item}` is not `<proto path>:<module stem>`")
        })?;
        if path.is_empty() || stem.is_empty() {
            return Err(format!("option `{key}` item `{item}` has an empty path or stem"));
        }
        if names.insert(path.to_string(), stem.to_string()).is_some() {
            return Err(format!("option `{key}` names `{path}` twice"));
        }
    }
    Ok(names)
}

/// Hold the generated files' modules to what a Mojo package can import: each
/// a Mojo identifier and not a keyword, none the package's own `__init__` or the layout
/// probe, no two the same (the package is flat), and every `module_names`
/// entry a file that is generated (a misspelt path renames nothing).
fn check_module_names(
    file_to_generate: &[String],
    names: &lower::ModuleNames,
) -> Result<(), String> {
    for path in names.keys() {
        if !file_to_generate.contains(path) {
            return Err(format!(
                "option `module_names` names `{path}`, which is not a file to generate"
            ));
        }
    }
    let mut seen: std::collections::BTreeMap<String, &str> = std::collections::BTreeMap::new();
    for path in file_to_generate {
        let stem = lower::module_stem(path, names);
        let ident = stem
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
            && stem.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
        if !ident {
            return Err(format!(
                "`{path}` would be generated as module `{stem}`, which is not a Mojo \
                 module name: name one in `module_names`"
            ));
        }
        if mojo_names::KEYWORDS.contains(&stem.as_str()) {
            return Err(format!(
                "`{path}` would be generated as module `{stem}`, a Mojo keyword, \
                 which no import can name: name one in `module_names`"
            ));
        }
        if stem == "__init__" || format!("{stem}.mojo") == emit::LAYOUT_PROBE_FILE {
            return Err(format!(
                "`{path}` would be generated as module `{stem}`, a name the generated \
                 package keeps for itself"
            ));
        }
        if let Some(other) = seen.insert(stem.clone(), path) {
            return Err(format!(
                "`{other}` and `{path}` would both be generated as module `{stem}` (the \
                 generated package is flat): name one in `module_names`"
            ));
        }
    }
    Ok(())
}

fn parse_bool(key: &str, value: &str) -> Result<bool, String> {
    match value {
        "true" => Ok(true),
        "false" => Ok(false),
        other => Err(format!("option `{key}` must be `true` or `false`, not `{other}`")),
    }
}

/// Lower the request with its options, both annotation overlays and the
/// recovered `(google.api.default_host)` of each service, then emit: the Mojo
/// modules, plus the layout probe when asked for. The one path of `rest`,
/// `grpc` and `connect` targets.
fn generate_scoped(
    request: &plugin::CodeGeneratorRequest,
    params: &PluginParameters,
    http_rules: http_options::HttpRuleTable,
    routing_rules: routing_options::RoutingRuleTable,
    default_hosts: service_options::DefaultHostTable,
    mode: ProtocolMode,
) -> Result<Vec<(String, String)>, String> {
    if params.gcp && mode == ProtocolMode::Connect {
        return Err(
            "option `gcp=true` emits a Google Cloud client, which speaks classic gRPC \
             (`default_protocol=grpc`) or REST (`default_protocol=rest`), never Connect"
                .to_string(),
        );
    }
    check_module_names(&request.file_to_generate, &params.module_names)?;
    let config_overlay = match &params.service_config {
        Some(_) if mode != ProtocolMode::Rest => {
            return Err(
                "option `service_config` binds REST methods: it is read with \
                 `default_protocol=rest` only"
                    .to_string(),
            )
        }
        Some(path) => {
            let text = std::fs::read_to_string(path)
                .map_err(|e| format!("option `service_config`: cannot read `{path}`: {e}"))?;
            Some(service_config::ServiceConfig::parse(&text, path)?)
        }
        None => None,
    };
    let mut model = lower::lower_scoped(
        &request.proto_file,
        &request.file_to_generate,
        &params.package_prefix,
        http_rules,
        routing_rules,
        &params.scope,
        &params.module_names,
    )?;
    for file in &mut model.files {
        for svc in &mut file.services {
            svc.default_host = default_hosts
                .host_for(&file.proto_package, &svc.name)
                .map(str::to_string);
        }
    }
    // After the scope: a rule binds only what is generated.
    if let Some(config) = &config_overlay {
        config.apply(&mut model)?;
    }
    if mode == ProtocolMode::Rest {
        // Pre-validate every kept service so a streaming method, a missing
        // annotation, a bad template or an unusable default host is a clean
        // Result error rather than the emitter's panic backstop.
        for file in &model.files {
            for svc in &file.services {
                emit_rest::emit_rest_service_in(file, &model.files, svc)?;
            }
        }
    }
    let mut files = emit::emit_model_with_names(&model, mode, params.gcp, &params.module_names);
    if params.layout_probe {
        files.push(emit::emit_layout_probe_with_names(&model, &params.module_names));
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
        service_options::DefaultHostTable::default(),
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
    let default_hosts = service_options::DefaultHostTable::from_request_bytes(request_bytes)?;
    generate_scoped(request, &params, http_rules, routing_rules, default_hosts, mode)
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
    let default_hosts =
        service_options::DefaultHostTable::from_descriptor_set_bytes(descriptor_set_bytes)?;
    generate_scoped(
        request,
        &params,
        http_rules,
        routing_options::RoutingRuleTable::default(),
        default_hosts,
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
                    let hosts =
                        service_options::DefaultHostTable::from_request_bytes(request_bytes)?;
                    generate_scoped(
                        request,
                        &params,
                        rules,
                        routing_options::RoutingRuleTable::default(),
                        hosts,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn module_names_parse_into_path_to_stem() {
        let p = PluginParameters::parse(
            "package_prefix=x,module_names=a/k8s.min.proto:k8s_min+b/status.proto:run_status",
        )
        .unwrap();
        assert_eq!(p.module_names.get("a/k8s.min.proto").map(String::as_str), Some("k8s_min"));
        assert_eq!(p.module_names.get("b/status.proto").map(String::as_str), Some("run_status"));
        assert_eq!(lower::module_stem("b/status.proto", &p.module_names), "run_status");
        assert_eq!(lower::module_stem("c/status.proto", &p.module_names), "status");
    }

    #[test]
    fn service_config_is_a_path_only_protoc_gen_mojo_reads() {
        let p = PluginParameters::parse("package_prefix=x,service_config=a/run_v2.yaml").unwrap();
        assert_eq!(p.service_config.as_deref(), Some("a/run_v2.yaml"));
        assert_eq!(
            p.require_only_package_prefix("protoc-gen-mojo-db").unwrap_err(),
            "protoc-gen-mojo-db does not implement service_config"
        );
        assert_eq!(PluginParameters::parse("package_prefix=x").unwrap().service_config, None);
    }

    #[test]
    fn service_config_is_refused_outside_rest_and_unreadable() {
        let request = |opt: &str| plugin::CodeGeneratorRequest {
            file_to_generate: vec![],
            parameter: Some(opt.to_string()),
            proto_file: vec![],
            compiler_version: None,
        };
        let err = generate(&request("default_protocol=grpc,service_config=a.yaml")).unwrap_err();
        assert_eq!(
            err,
            "option `service_config` binds REST methods: it is read with \
             `default_protocol=rest` only"
        );
        let err = generate(&request("default_protocol=rest,service_config=no/such.yaml"))
            .unwrap_err();
        assert!(
            err.starts_with("option `service_config`: cannot read `no/such.yaml`: "),
            "{err}"
        );
    }

    #[test]
    fn module_names_refuse_malformed_items() {
        for (opt, want) in [
            ("module_names=a.proto", "is not `<proto path>:<module stem>`"),
            ("module_names=a.proto:", "has an empty path or stem"),
            ("module_names=:x", "has an empty path or stem"),
            ("module_names=a.proto:x+a.proto:y", "names `a.proto` twice"),
        ] {
            let err = PluginParameters::parse(opt).unwrap_err();
            assert!(err.contains(want), "{opt}: {err}");
        }
    }

    #[test]
    fn generated_modules_must_be_distinct_mojo_names() {
        let files: Vec<String> = ["g/rpc/status.proto", "g/run/status.proto", "g/run/k8s.min.proto"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let mut names = lower::ModuleNames::new();
        // Unnamed, k8s.min is not a module name.
        names.insert("g/run/status.proto".into(), "run_status".into());
        let err = check_module_names(&files, &names).unwrap_err();
        assert!(err.contains("module `k8s.min`, which is not a Mojo module name"), "{err}");
        // Named, the two status files still collide until one is renamed.
        let mut clash = lower::ModuleNames::new();
        clash.insert("g/run/k8s.min.proto".into(), "k8s_min".into());
        let err = check_module_names(&files, &clash).unwrap_err();
        assert!(
            err.contains("`g/rpc/status.proto` and `g/run/status.proto` would both be generated as module `status`"),
            "{err}"
        );
        names.insert("g/run/k8s.min.proto".into(), "k8s_min".into());
        check_module_names(&files, &names).unwrap();
        // A rename onto a name the package keeps, or of a file not generated.
        let mut bad = names.clone();
        bad.insert("g/rpc/status.proto".into(), "_layout_probe".into());
        assert!(check_module_names(&files, &bad).unwrap_err().contains("keeps for itself"));
        // A keyword is an identifier no import can name, renamed or not.
        let mut kw = names.clone();
        kw.insert("g/rpc/status.proto".into(), "import".into());
        assert!(check_module_names(&files, &kw).unwrap_err().contains("module `import`, a Mojo keyword"));
        let kw_file: Vec<String> = vec!["g/struct.proto".into()];
        assert!(check_module_names(&kw_file, &lower::ModuleNames::new())
            .unwrap_err()
            .contains("module `struct`, a Mojo keyword"));
        let mut stray = names.clone();
        stray.insert("g/other.proto".into(), "other".into());
        assert!(check_module_names(&files, &stray)
            .unwrap_err()
            .contains("names `g/other.proto`, which is not a file to generate"));
    }
}
