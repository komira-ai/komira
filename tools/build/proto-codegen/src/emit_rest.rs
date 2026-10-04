//! The REST client emitter: for `ProtocolMode::Rest`, one client method per
//! unary method carrying a `(google.api.http)` annotation, on a client that
//! starts at the service's `(google.api.default_host)` (or, with none, refuses
//! to send until its caller names a host).

use std::fmt::Write as _;

use crate::ir::*;
use crate::mojo_names::rpc_method_name;
use crate::path_template::{
    percent_encode_simple, BodyDesignator, FieldPartition, PathSegment, PathTemplate, VarPattern,
};

const REST_PORT: &str = "0";

/// The result of emitting one REST service.
#[derive(Clone, Debug)]
pub struct RestServiceEmit {
    /// The generated client-struct source (already indented; appended raw to
    /// the file buffer by the caller).
    pub source: String,
}

/// The hand-written GCP core the generated REST clients import from (its
/// package root, never a submodule, so the core may lay its files out freely).
pub const GCP_CORE: &str = "komira_gcp_core";

/// The token-source trait of [`GCP_CORE`]. Its contract:
/// `trait GcpTokenSource(Movable): def access_token(mut self) raises -> String`,
/// the bare token (no `Bearer ` prefix). Acquiring, caching and refreshing the
/// token (metadata server, service-account JWT, workload-identity exchange) is
/// the core's; the generated client only asks for one per request.
pub const GCP_TOKEN_SOURCE: &str = "GcpTokenSource";

/// The error mapper of [`GCP_CORE`]. Its contract:
/// `def gcp_status_error(verb: String, rpc: String, http_status: Int, body: List[UInt8]) -> Error`
/// reads the `google.rpc.Status` envelope (`{"error": {"code", "status", ...}}`)
/// leniently and returns an `Error` naming the verb, the RPC, the HTTP status,
/// the `error.status` code (when it is an `[A-Z_]+` token) and the body's byte
/// count. It never copies any other body byte into the message: `error.message`
/// and `error.details` can carry resource names and request data.
pub const GCP_STATUS_ERROR: &str = "gcp_status_error";

/// The import block a REST-target file needs (replaces the gRPC import set in
/// `emit.rs::emit_header` when `ProtocolMode::Rest`). One source line per
/// emitted entry, no trailing blank — the header owns surrounding blanks.
///
/// The `komira_gcp_core` line is the core's contract: [`GCP_TOKEN_SOURCE`] and
/// [`GCP_STATUS_ERROR`], re-exported from its package root.
pub fn rest_imports() -> &'static [&'static str] {
    &[
        "from komira_gcp_core import GcpTokenSource, gcp_status_error",
        "from komira_proto_codec.codec import encode_json, decode_json_lenient",
        "from komira_http_client.client import (",
        "    HttpClient,",
        "    build_get_request,",
        "    build_request_with_body,",
        ")",
        "from komira_http_client.body import BytesBody, EmptyBody",
        "from komira_http_client.header_map import HeaderMap",
        "from komira_http_client.url import Url",
        "from komira_http_core.codec.types import HttpMethod",
        "from komira_http_core.transport.io_stream import Connector",
        "from komira_async.reactor.reactor import Reactor",
        "from komira_async.runtime.runtime_trait import Runtime",
    ]
}

/// Emit the REST client struct for `svc`, looking up request messages in
/// `file`. Returns the generated source, or a hard error naming the service
/// and method for: a streaming method (it has no REST form, and a kept
/// method that silently generated nothing would be a client missing a
/// method its target listed), an un-annotated method (the missing-annotation
/// rule), or a `(google.api.default_host)` that is not a plain host name.
pub fn emit_rest_service(
    file: &IrFile,
    svc: &IrService,
) -> Result<RestServiceEmit, String> {
    let mut w = Writer::new();

    // Refusals first, before any text: a service is emitted whole or not at
    // all.
    for m in &svc.methods {
        if m.client_streaming || m.server_streaming {
            let shape = match (m.client_streaming, m.server_streaming) {
                (true, true) => "bidirectional-streaming",
                (true, false) => "client-streaming",
                _ => "server-streaming",
            };
            return Err(format!(
                "service `{}` method `{}` is {shape}, and a `rest` target generates \
                 unary methods only (a streaming method has no REST/JSON form): \
                 drop it from `methods`, or generate it with `default_protocol=grpc`",
                svc.name, m.name
            ));
        }
    }
    let fq_service = fq_service_name(file, svc);
    let default_host = rest_default_host(&fq_service, svc)?;

    let struct_name = format!("{}Client", svc.name);
    w.blank();
    w.line(&format!("# REST/JSON client for `{fq_service}`."));
    w.line(&format!(
        "struct {struct_name}[C: Connector, T: {GCP_TOKEN_SOURCE}](Movable, Deinitable):"
    ));
    w.indent();
    w.line(&format!(
        "\"\"\"The generated REST/JSON client for `{}`, parametric over the HTTP",
        svc.name
    ));
    w.line("    connector `C` and the access-token source `T`.");
    w.blank();
    w.line("    Every request carries `Authorization: Bearer <token>` from `T` (a");
    w.line(&format!(
        "    `{GCP_CORE}.{GCP_TOKEN_SOURCE}`): the client reads no environment"
    ));
    w.line("    and holds no credential of its own.");
    w.blank();
    // ONE role for the connector: the `HttpClient` owns it and every method
    // dials through `send_buffered`, which scheme-checks, sets the per-request
    // dial host (SNI), applies the request budget and consults the client's
    // pool. A per-method `connector` argument would be a second connector of
    // the same type that the owned one never sees; `call_pooled` would pool
    // only when handed that same type, and its keepalive cache is plaintext
    // h1 only, so over https it would dial fresh exactly like `call`.
    w.line("    The connector has one role: the `HttpClient[C]` passed to `__init__`");
    w.line("    owns it, and every method sends through that client's");
    w.line("    `send_buffered`, which checks the URL scheme against the connector,");
    w.line("    sets the dial host (SNI) per request and goes through the client's");
    w.line("    connection pool.");
    w.line("    No method takes a connector of its own.");
    w.blank();
    w.line("    The caller owns the time budget: build the `HttpClient[C]` with the");
    w.line("    `HttpClientConfig` that fits the process. A process serving requests");
    w.line("    under a platform deadline (Cloud Run, Lambda) builds it from");
    w.line("    `HttpClientConfig.for_serving_ceiling(ceiling)`, not");
    w.line("    `HttpClient.with_defaults`, whose 600s budget can outlive the");
    w.line("    container. This client applies no ceiling of its own.\"\"\"");
    w.blank();
    w.line("var _client: HttpClient[Self.C]");
    w.line("\"\"\"The HTTP transport.\"\"\"");
    w.blank();
    w.line("var _token_source: Self.T");
    w.line("\"\"\"Where each request's bearer token comes from.\"\"\"");
    w.blank();
    w.line("var _default_headers: HeaderMap");
    w.line("\"\"\"Headers merged into every request. Empty unless given.\"\"\"");
    w.blank();
    // The REST base host. It starts at the service's own
    // `(google.api.default_host)`; with none declared it starts empty, and
    // every method refuses to send (`_rest_require_host`) until the caller
    // names one. Never a placeholder: whatever host the URL names receives
    // the bearer token. The URL host feeds BOTH the dial-target DNS
    // resolution and the injected `Host:` header (SNI on the TLS connector is
    // not the dial target).
    let initial_host = default_host.as_deref().unwrap_or("");
    w.line("var _rest_host: String");
    w.line("\"\"\"The host the request URLs target: it drives BOTH the dial DNS");
    match &default_host {
        Some(h) => {
            w.line("    target and the `Host:` header. Starts at the service's");
            w.line(&format!(
                "    `google.api.default_host`, `{h}`; `set_rest_host` replaces it.\"\"\""
            ));
        }
        None => {
            w.line("    target and the `Host:` header. Starts empty: the service declares");
            w.line("    no `google.api.default_host`, so every method refuses to send until");
            w.line("    `set_rest_host` names a host.\"\"\"");
        }
    }
    w.blank();
    w.line("def __init__(out self, var client: HttpClient[Self.C], var token_source: Self.T):");
    w.indent();
    w.line("\"\"\"Construct with no default headers.\"\"\"");
    w.line("self._client = client^");
    w.line("self._token_source = token_source^");
    w.line("self._default_headers = HeaderMap()");
    w.line(&format!("self._rest_host = String(\"{initial_host}\")"));
    w.dedent();
    w.blank();
    w.line("def __init__(");
    w.line("    out self,");
    w.line("    var client: HttpClient[Self.C],");
    w.line("    var token_source: Self.T,");
    w.line("    var default_headers: HeaderMap,");
    w.line("):");
    w.indent();
    w.line("\"\"\"Construct with default headers merged into every request.\"\"\"");
    w.line("self._client = client^");
    w.line("self._token_source = token_source^");
    w.line("self._default_headers = default_headers^");
    w.line(&format!("self._rest_host = String(\"{initial_host}\")"));
    w.dedent();
    w.blank();
    w.line("def set_rest_host(mut self, var host: String):");
    w.indent();
    w.line("\"\"\"Point the request URLs at `host` (a regional or private endpoint,");
    w.line("    or a test server). The URL host feeds BOTH the dial-target DNS");
    w.line("    resolution and the injected `Host:` header. An empty host makes");
    w.line("    every method refuse to send.\"\"\"");
    w.line("self._rest_host = host^");
    w.dedent();
    w.blank();
    // The no-host refusal, called first in every method: before the token
    // source is asked and before anything is dialled.
    w.line("def _rest_require_host(self, method: String) raises:");
    w.indent();
    w.line("\"\"\"Raise, naming the method, when no host is set.\"\"\"");
    w.line("if self._rest_host.byte_length() == 0:");
    w.indent();
    let why = match &default_host {
        Some(h) => format!(
            "the host was set empty (the service's google.api.default_host is {h}); \
             call set_rest_host(host) with a host before sending"
        ),
        None => format!(
            "{fq_service} declares no google.api.default_host; \
             call set_rest_host(host) before sending"
        ),
    };
    w.line(&format!(
        "raise Error(String(\"{struct_name}.\") + method + String(\": no REST host: {why}\"))"
    ));
    w.dedent();
    w.dedent();
    w.blank();
    // The default-header merge helper — appends each default header into the
    // per-request `HeaderMap`. Header names are HTTP-case-insensitive (HTTP/2
    // mandates lowercase), so the lowercased egress from `entry_at` is correct
    // on the wire.
    w.line("def _rest_apply_default_headers(self, mut headers: HeaderMap) raises:");
    w.indent();
    w.line("\"\"\"Merge the per-client default headers into `headers`.\"\"\"");
    w.line("var _rest_i = 0");
    w.line("while _rest_i < self._default_headers.len():");
    w.indent();
    w.line("var _rest_e = self._default_headers.entry_at(_rest_i)");
    w.line("headers.append(_rest_e.name, _rest_e.value)");
    w.line("_rest_i += 1");
    w.dedent();
    w.dedent();
    w.blank();

    for m in &svc.methods {
        let Some(rule) = &m.http_rule else {
            // The missing-annotation LOUD rule — an un-annotated method in a
            // rest target is a hard error, not a silent no-op.
            return Err(format!(
                "service `{}` method `{}` has no `(google.api.http)` annotation \
                 but the target is `rest` — every method in a rest target must be \
                 annotated (a missing annotation must not silently emit nothing)",
                svc.name, m.name
            ));
        };
        emit_rest_method(&mut w, file, m, rule)?;
    }

    w.dedent();
    Ok(RestServiceEmit {
        source: w.into_source(),
    })
}

/// The full proto name of `svc`: `pkg.Service`, or the bare service name for
/// a file that declares no package.
fn fq_service_name(file: &IrFile, svc: &IrService) -> String {
    if file.proto_package.is_empty() {
        svc.name.clone()
    } else {
        format!("{}.{}", file.proto_package, svc.name)
    }
}

/// The host a generated client of `svc` starts at: its
/// `(google.api.default_host)`, or `None` when it declares none. googleapis
/// writes the option as a bare host (`logging.googleapis.com`), and some
/// services as `host:443`; the port is dropped, as the client always speaks
/// HTTPS on the default port. Anything else (another port, a scheme, a path,
/// an empty value, a character outside a DNS name) is refused by name rather
/// than written into the client.
fn rest_default_host(fq_service: &str, svc: &IrService) -> Result<Option<String>, String> {
    let Some(declared) = &svc.default_host else {
        return Ok(None);
    };
    let host = declared.strip_suffix(":443").unwrap_or(declared);
    let dns_name = !host.is_empty()
        && host.len() <= 253
        && host.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        });
    if !dns_name {
        return Err(format!(
            "service `{fq_service}` declares `(google.api.default_host)` = {declared:?}, \
             which is not a host name (optionally `:443`): a REST client sends to it over \
             HTTPS on the default port"
        ));
    }
    Ok(Some(host.to_string()))
}

/// Emit one annotated unary REST method.
fn emit_rest_method(
    w: &mut Writer,
    file: &IrFile,
    m: &IrMethod,
    rule: &IrHttpRule,
) -> Result<(), String> {
    let method_name = rpc_method_name(&m.name);
    let req_ty = &m.input.mojo_name;
    let resp_ty = &m.output.mojo_name;

    let req_msg = file
        .messages
        .iter()
        .find(|msg| msg.fq_name == m.input.fq_name)
        .ok_or_else(|| {
            format!(
                "REST method `{}`: request type `{}` not found in this file \
                 (cross-file request types are unsupported in Phase 1)",
                m.name, m.input.fq_name
            )
        })?;

    let template = PathTemplate::parse(&rule.path_template)
        .map_err(|e| format!("REST method `{}`: {e}", m.name))?;

    let leaf_fields: Vec<String> =
        req_msg.fields.iter().map(|f| f.name.clone()).collect();
    let part = partition_or_err(m, &leaf_fields, &template, &rule.body)?;

    let mut bool_fields: std::collections::BTreeSet<String> =
        std::collections::BTreeSet::new();
    for f in part.path_fields.iter().chain(part.query_fields.iter()) {
        let fld = req_msg
            .fields
            .iter()
            .find(|x| &x.name == f)
            .expect("partition field came from the message");
        // A repeated scalar is a repeated query key (`?k=a&k=b`); a path
        // variable is one value, so a repeated one has no expansion.
        if matches!(fld.label, Label::Repeated) && part.path_fields.contains(f) {
            return Err(format!(
                "REST method `{}`: path variable `{}` is a `repeated` field; a \
                 path variable takes one value",
                m.name, f
            ));
        }
        if !is_scalar(&fld.ty) {
            return Err(format!(
                "REST method `{}`: field `{}` is used in the path/query but is \
                 not a scalar (only a scalar renders into a URL)",
                m.name, f
            ));
        }
        if matches!(&fld.ty, IrType::Scalar(ScalarKind::Bytes)) {
            return Err(format!(
                "REST method `{}`: field `{}` is `bytes`, which has no URL \
                 rendering here (proto3 JSON writes it as base64)",
                m.name, f
            ));
        }
        if matches!(&fld.ty, IrType::Scalar(ScalarKind::Bool)) {
            bool_fields.insert(f.clone());
        }
    }

    let verb = rule.verb.as_str();
    let has_body = !matches!(part.body, BodyDesignator::None);

    w.line(&format!(
        "def {method_name}[RT: Runtime](mut self, req: {req_ty}, \
         mut reactor: Reactor[RT.Sink]) raises -> {resp_ty}:"
    ));
    w.indent();
    w.line(&format!(
        "\"\"\"{} `{}` — REST/JSON.\"\"\"",
        verb.to_uppercase(),
        rule.path_template
    ));
    // No host, no request: refused before the token source is asked and
    // before anything is dialled.
    w.line(&format!("self._rest_require_host(String(\"{method_name}\"))"));

    // -- path substitution ---------------------------------------------------
    emit_path_build(w, &template, &bool_fields);

    // -- query params --------------------------------------------------------
    emit_query_build(w, &part, &bool_fields, req_msg);

    w.line(&format!(
        "var url = Url.https(self._rest_host.copy(), UInt16({REST_PORT}), path^)"
    ));
    if !part.query_fields.is_empty() {
        w.line("url.query = query^");
    }

    w.line("var headers = HeaderMap()");
    w.line("self._rest_apply_default_headers(headers)");
    w.line(
        "headers.append(String(\"Authorization\"), String(\"Bearer \") + self._token_source.access_token())",
    );
    if has_body {
        w.line(
            "headers.append(String(\"Content-Type\"), String(\"application/json\"))",
        );
    }

    // -- body serialization --------------------------------------------------
    if has_body {
        emit_body_build(w, &part, req_msg)?;
    }

    // -- request construction (verb is a property of the request) ------------
    // The request-body conformer type the constructor yields drives the
    // `send_buffered[RT, B]` binding below: GET builds a `ClientRequest[EmptyBody]`
    // (`build_get_request`), every other verb a `ClientRequest[BytesBody]`.
    // The `send_buffered`'s `B` parameter MUST match the constructed request's body
    // type — pinning `BytesBody` for a GET would be a hard type mismatch
    // against `ClientRequest[EmptyBody]`.
    let body_ty: &str;
    match verb {
        "get" => {
            // GET — no body. `build_get_request` yields ClientRequest[EmptyBody].
            w.line("var req_http = build_get_request(url^, headers^)");
            body_ty = "EmptyBody";
        }
        "delete" => {
            if has_body {
                w.line("var req_http = build_request_with_body[BytesBody](");
                w.line("    HttpMethod.delete(), url^, headers^, body^,");
                w.line(")");
            } else {
                w.line("var empty_body = BytesBody.from_bytes(List[UInt8]())");
                w.line("var req_http = build_request_with_body[BytesBody](");
                w.line("    HttpMethod.delete(), url^, headers^, empty_body^,");
                w.line(")");
            }
            body_ty = "BytesBody";
        }
        "post" | "put" | "patch" => {
            if has_body {
                w.line("var req_http = build_request_with_body[BytesBody](");
                w.line(&format!(
                    "    HttpMethod.{verb}(), url^, headers^, body^,"
                ));
                w.line(")");
            } else {
                w.line("var empty_body = BytesBody.from_bytes(List[UInt8]())");
                w.line("var req_http = build_request_with_body[BytesBody](");
                w.line(&format!(
                    "    HttpMethod.{verb}(), url^, headers^, empty_body^,"
                ));
                w.line(")");
            }
            body_ty = "BytesBody";
        }
        other => {
            return Err(format!(
                "REST method `{}`: unsupported verb `{other}`",
                m.name
            ));
        }
    }

    // -- dispatch ------------------------------------------------------------
    // Through the client-owned connector (the struct docstring states why
    // there is no per-method one).
    w.line(&format!(
        "var resp = self._client.send_buffered[RT, {body_ty}](req_http^, reactor)"
    ));

    // -- status check --------------------------------------------------------
    // Anything but 2xx is an error: a 3xx or 1xx body decoded leniently
    // would read as an empty success. The body goes to the core's
    // `google.rpc.Status` mapper, which reports its code and byte count and
    // never echoes it (`GCP_STATUS_ERROR`).
    w.line("var status_int = Int(resp.status)");
    w.line("var resp_bytes = resp.body.take_bytes()");
    w.line("if status_int < 200 or status_int >= 300:");
    w.indent();
    w.line(&format!(
        "raise {GCP_STATUS_ERROR}(String(\"{}\"), String(\"{}\"), status_int, resp_bytes)",
        verb.to_uppercase(),
        m.name
    ));
    w.dedent();

    // -- response decode -----------------------------------------------------
    // Lenient: a field the server added after these protos were pinned is
    // skipped, not an error (the proto3 JSON forward-compatibility rule).
    w.line(
        "var resp_text = String(unsafe_from_utf8=Span(resp_bytes))",
    );
    w.line("if resp_text.byte_length() == 0:");
    w.indent();
    w.line("resp_text = String(\"{}\")");
    w.dedent();
    // Through the codec, never `{resp_ty}.decode(JsonDecoder)`: a response
    // that IS a well-known type (`Struct`, `Timestamp`, `Value`, ...) is that
    // type's canonical JSON value, which only the codec's comptime branch
    // reads. For any other message `decode_json_lenient` is the same
    // `JsonDecoder.from_text_lenient` read.
    w.line(&format!("return decode_json_lenient[{resp_ty}](resp_text)"));
    w.dedent();
    w.blank();
    Ok(())
}

/// Emit the path-string build: `var path = String("") + "/" + seg + ...`, each
/// variable filled from its request field, then the `:verb` suffix.
fn emit_path_build(
    w: &mut Writer,
    template: &PathTemplate,
    bool_fields: &std::collections::BTreeSet<String>,
) {
    // Build the path incrementally so a variable's runtime value is encoded.
    w.line("var path = String(\"\")");
    for seg in &template.segments {
        match seg {
            PathSegment::Literal(lit) => {
                w.line(&format!(
                    "path += String(\"/{}\")",
                    percent_encode_simple(lit)
                ));
            }
            PathSegment::Var(var) => {
                let value = field_to_str_expr(&var.field, bool_fields);
                w.line("path += String(\"/\")");
                match &var.pattern {
                    // `{field}` / `{field=*}`: one segment, `/` included in
                    // the encoding; an empty, `.` or `..` value is refused at
                    // run time, as in `_rest_path_var`. The field name is an
                    // identifier (the parser refuses anything else), so it is
                    // safe inside a Mojo literal.
                    VarPattern::Segment => {
                        w.line(&format!(
                            "path += _rest_path_segment({value}, String(\"{}\"))",
                            var.field
                        ));
                    }
                    // `{field=pattern}`: checked against the pattern at run
                    // time, each segment encoded, the `/` between them kept.
                    // The pattern is unreserved-only (the parser refuses
                    // anything else), so it is safe inside a Mojo literal.
                    VarPattern::Segments(pattern) => {
                        w.line(&format!(
                            "path += _rest_path_var({value}, String(\"{pattern}\"), String(\"{}\"))",
                            var.field
                        ));
                    }
                }
            }
        }
    }
    if template.segments.is_empty() {
        w.line("path += String(\"/\")");
    }
    // The custom verb (`:list`), an unreserved literal (the parser refuses
    // anything else).
    if let Some(verb) = &template.verb {
        w.line(&format!("path += String(\":{verb}\")"));
    }
}

/// The Mojo expression that stringifies `req.{field}` for URL path/query use.
/// A proto `bool` field MUST render as proto3-JSON lowercase `true`/`false`
/// (`_rest_bool_str`); Mojo's generic `String(Bool)` yields `True`/`False`,
/// which is wrong on the wire. Every other scalar uses the generic
/// `_rest_to_str`.
fn field_to_str_expr(
    field: &str,
    bool_fields: &std::collections::BTreeSet<String>,
) -> String {
    if bool_fields.contains(field) {
        format!("_rest_bool_str(req.{field})")
    } else {
        format!("_rest_to_str(req.{field})")
    }
}

fn emit_query_build(
    w: &mut Writer,
    part: &FieldPartition,
    bool_fields: &std::collections::BTreeSet<String>,
    req_msg: &IrMessage,
) {
    if part.query_fields.is_empty() {
        return;
    }
    w.line("var query = String(\"\")");
    for f in part.query_fields.iter() {
        // The query KEY is the field's proto3-JSON `json_name` (lowerCamel),
        // NOT the snake_case proto field name: `google.api.http` maps a query
        // parameter to the field's JSON name, so the emitted key matches the
        // live wire (`includeArchived`, `archivedOnly`, `orgId`, ...). The
        // VALUE is still read from the Mojo struct field (`req.<field>`) — the
        // struct field keeps the snake_case proto name. (When json_name equals
        // the field name — the common single-word case — this is a no-op.)
        let fld = req_msg.fields.iter().find(|x| &x.name == f);
        let key = fld.map(|x| x.json_name.as_str()).unwrap_or(f.as_str());
        let label = fld.map(|x| x.label).unwrap_or(Label::Single);
        let stringify = |expr: &str| {
            if bool_fields.contains(f) {
                format!("_rest_bool_str({expr})")
            } else {
                format!("_rest_to_str({expr})")
            }
        };
        // An `Optional[T]` field reads through `.value()` INSIDE its presence
        // check; a repeated one appends its key once per element, in order
        // (`?resourceNames=a&resourceNames=b`); a plain field reads directly.
        let (guard, value_expr) = match label {
            Label::Optional => (Some(format!("if req.{f}:")), stringify(&format!("req.{f}.value()"))),
            Label::Repeated => (Some(format!("for _rest_v in req.{f}:")), stringify("_rest_v")),
            // An implicit-presence scalar at its default is omitted, as the
            // proto3 JSON mapping omits it: no `pageToken=` on a first page.
            // An enum renders whatever its value is.
            Label::Single => {
                let guard = match fld.map(|x| &x.ty) {
                    Some(IrType::Scalar(ScalarKind::String)) => Some(format!("if req.{f}.byte_length() > 0:")),
                    Some(IrType::Scalar(ScalarKind::Bool)) => Some(format!("if req.{f}:")),
                    Some(IrType::Scalar(_)) => Some(format!("if req.{f} != 0:")),
                    _ => None,
                };
                (guard, field_to_str_expr(f, bool_fields))
            }
        };
        if let Some(g) = &guard {
            w.line(g);
            w.indent();
        }
        w.line("if query.byte_length() > 0:");
        w.indent();
        w.line("query += String(\"&\")");
        w.dedent();
        w.line(&format!(
            "query += String(\"{}=\") + _rest_pct_encode({})",
            percent_encode_simple(key),
            value_expr
        ));
        if guard.is_some() {
            w.dedent();
        }
    }
}

/// Emit the JSON-body build. For `body: "*"` the whole `req` serializes; for a
/// named field the single field's message serializes. Both go through
/// `komira_proto_codec.codec.encode_json`, so a well-known type writes its
/// canonical JSON value.
fn emit_body_build(
    w: &mut Writer,
    part: &FieldPartition,
    req_msg: &IrMessage,
) -> Result<(), String> {
    // Through the codec's `encode_json`, never `<msg>.encode(JsonEncoder)`:
    // a body field that IS a well-known type writes its canonical JSON
    // value, which only the codec's comptime branch does. For any other
    // message it is the same encode + `finish()`.
    match &part.body {
        BodyDesignator::Whole => {
            w.line("var body_text = encode_json(req)");
        }
        BodyDesignator::Field(name) => {
            let fld = req_msg
                .fields
                .iter()
                .find(|f| &f.name == name)
                .ok_or_else(|| {
                    format!(
                        "REST body field `{name}` does not match any request field"
                    )
                })?;
            let stored_optional = matches!(fld.ty, IrType::Message(_))
                && fld.label != Label::Repeated;
            if stored_optional {
                // Presence-guard: only serialize the body when the field is
                // set; an unset body message emits an empty `{}`.
                w.line("var body_text = String(\"{}\")");
                w.line(&format!("if req.{name}:"));
                w.indent();
                w.line(&format!("body_text = encode_json(req.{name}.value())"));
                w.dedent();
            } else {
                w.line(&format!("var body_text = encode_json(req.{name})"));
            }
        }
        BodyDesignator::None => unreachable!("emit_body_build only on a body verb"),
    }
    w.line("var body = BytesBody.from_str(body_text)");
    Ok(())
}

/// The percent-encode, path-variable and stringify helpers the generated
/// path/query code calls. Emitted ONCE per REST file (free functions, module
/// level), so the generated code needs no URL library.
pub fn rest_helper_functions() -> &'static str {
    r#"# ---- REST URL helpers (one copy per REST file) ----
def _rest_pct_append(mut out: String, b: UInt8):
    """Append byte `b` to `out`, percent-encoded unless it is in the RFC 3986
    unreserved set `[A-Za-z0-9-._~]`."""
    var unreserved = (
        (b >= 0x30 and b <= 0x39)  # 0-9
        or (b >= 0x41 and b <= 0x5A)  # A-Z
        or (b >= 0x61 and b <= 0x7A)  # a-z
        or b == 0x2D  # -
        or b == 0x2E  # .
        or b == 0x5F  # _
        or b == 0x7E  # ~
    )
    if unreserved:
        out += chr(Int(b))
    else:
        out += String("%")
        out += _rest_hex_upper(b >> 4)
        out += _rest_hex_upper(b & 0x0F)


def _rest_pct_encode(s: String) -> String:
    """Percent-encode every byte of `s` outside the unreserved set, `/`
    included: the expansion of a one-segment path variable and of a query
    value."""
    var out = String("")
    var bs = s.as_bytes()
    var i = 0
    while i < len(bs):
        _rest_pct_append(out, bs[i])
        i += 1
    return out^


def _rest_path_segment(value: String, field: String) raises -> String:
    """Expand a one-segment `{field}` or `{field=*}` path variable: every byte
    outside the unreserved set is percent-encoded, `/` included. An empty,
    `.` or `..` value is refused: an RFC 3986 normalizer (a proxy, a URL
    parser, the front end) would drop or collapse it, and the request would
    name a different resource. An error names the field, never the value."""
    var vb = value.as_bytes()
    var n = len(vb)
    if (
        n == 0
        or (n == 1 and vb[0] == 0x2E)
        or (n == 2 and vb[0] == 0x2E and vb[1] == 0x2E)
    ):
        raise Error(
            String("path variable `") + field
            + String("` is empty, `.` or `..`")
        )
    return _rest_pct_encode(value)


def _rest_path_var(value: String, pattern: String, field: String) raises -> String:
    """Expand a `{field=pattern}` path variable as `google/api/http.proto`
    states it: `value` must match `pattern` segment by segment (`*` is one
    segment, a trailing `**` the rest of the value, zero or more segments,
    anything else a literal), and each segment is percent-encoded with the
    `/` between them kept. An empty, `.` or `..` segment is refused: it would
    change which resource the path names. So is an empty expansion, which a
    lone `**` would otherwise produce from an empty value. An error names the
    field and the pattern, never the value."""
    var vb = value.as_bytes()
    var pb = pattern.as_bytes()
    var out = String("")
    var vi = 0  # start of the next value segment
    var vleft = len(vb) > 0  # a value segment starts at vi
    var pi = 0
    while pi < len(pb):
        var pe = pi
        while pe < len(pb) and pb[pe] != 0x2F:
            pe += 1
        var plen = pe - pi
        var dstar = plen == 2 and pb[pi] == 0x2A and pb[pi + 1] == 0x2A
        var star = plen == 1 and pb[pi] == 0x2A
        var took = 0
        while vleft and (dstar or took == 0):
            var ve = vi
            while ve < len(vb) and vb[ve] != 0x2F:
                ve += 1
            var n = ve - vi
            if (
                n == 0
                or (n == 1 and vb[vi] == 0x2E)
                or (n == 2 and vb[vi] == 0x2E and vb[vi + 1] == 0x2E)
            ):
                raise Error(
                    String("path variable `") + field
                    + String("` has an empty, `.` or `..` segment")
                )
            if not star and not dstar:
                var same = n == plen
                var k = 0
                while same and k < n:
                    same = vb[vi + k] == pb[pi + k]
                    k += 1
                if not same:
                    raise Error(
                        String("path variable `") + field
                        + String("` does not match `") + pattern + String("`")
                    )
            if out.byte_length() > 0:
                out += String("/")
            var j = vi
            while j < ve:
                _rest_pct_append(out, vb[j])
                j += 1
            took += 1
            if ve < len(vb):
                vi = ve + 1
            else:
                vleft = False
        if took == 0 and not dstar:
            raise Error(
                String("path variable `") + field
                + String("` does not match `") + pattern + String("`")
            )
        pi = pe + 1
    if vleft:
        raise Error(
            String("path variable `") + field
            + String("` does not match `") + pattern + String("`")
        )
    # A lone `**` takes zero segments of an empty value; the path would then
    # end in the `/` before the variable and name a different resource.
    if out.byte_length() == 0:
        raise Error(
            String("path variable `") + field
            + String("` has an empty, `.` or `..` segment")
        )
    return out^


def _rest_hex_upper(nibble: UInt8) -> String:
    """One uppercase hex digit for a 4-bit nibble."""
    if nibble < 10:
        return chr(Int(0x30 + nibble))
    return chr(Int(0x41 + (nibble - 10)))


def _rest_to_str[T: Writable](v: T) -> String:
    """Stringify a scalar path/query field value. `T: Writable` (NOT
    `Stringable`, which is not available unqualified in a generated module
    in Mojo 1.0.0b1) — `String(v)` is the canonical conversion and every
    scalar (String / Int* / Float* / Bool) conforms to `Writable`."""
    return String(v)


def _rest_bool_str(b: Bool) -> String:
    """Stringify a proto `bool` for the URL as proto3-JSON lowercase
    `true`/`false`. Mojo's `String(Bool)` yields `True`/`False`, which is
    wrong on the wire — proto3 JSON mandates lowercase."""
    if b:
        return String("true")
    return String("false")


# ---- end of REST URL helpers ----
"#
}

/// Partition the request fields, mapping the error to a per-method message.
fn partition_or_err(
    m: &IrMethod,
    leaf_fields: &[String],
    template: &PathTemplate,
    body: &str,
) -> Result<FieldPartition, String> {
    crate::path_template::partition_fields(leaf_fields, template, body)
        .map_err(|e| format!("REST method `{}`: {e}", m.name))
}

fn is_scalar(ty: &IrType) -> bool {
    matches!(ty, IrType::Scalar(_) | IrType::Enum(_))
}

/// A small indentation-aware line writer, local to this module so REST emit
/// is self-contained (the `Emitter` in `emit.rs` appends the resulting source
/// block raw). 4-space units, matching the emitter's convention.
struct Writer {
    buf: String,
    indent: usize,
}

impl Writer {
    fn new() -> Self {
        Writer {
            buf: String::new(),
            indent: 0,
        }
    }
    fn line(&mut self, text: &str) {
        if text.is_empty() {
            self.buf.push('\n');
            return;
        }
        for _ in 0..self.indent {
            self.buf.push_str("    ");
        }
        let _ = writeln!(self.buf, "{text}");
    }
    fn blank(&mut self) {
        self.buf.push('\n');
    }
    fn indent(&mut self) {
        self.indent += 1;
    }
    fn dedent(&mut self) {
        self.indent = self.indent.saturating_sub(1);
    }
    fn into_source(self) -> String {
        self.buf
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scalar_field(name: &str, kind: ScalarKind) -> IrField {
        IrField {
            name: name.to_string(),
            ty: IrType::Scalar(kind),
            label: Label::Single,
            proto_field_number: 1,
            json_name: name.to_string(),
            oneof_index: None,
        }
    }

    fn msg_field(name: &str, fq: &str, mojo: &str) -> IrField {
        IrField {
            name: name.to_string(),
            ty: IrType::Message(TypeRef {
                fq_name: fq.to_string(),
                mojo_name: mojo.to_string(),
            }),
            label: Label::Optional,
            proto_field_number: 1,
            json_name: name.to_string(),
            oneof_index: None,
        }
    }

    fn file_with(messages: Vec<IrMessage>, svc: IrService) -> IrFile {
        IrFile {
            proto_path: "tiny_rest.proto".to_string(),
            proto_package: "tiny.rest.v1".to_string(),
            mojo_package: "komira_rpc_storage".to_string(),
            messages,
            enums: vec![],
            services: vec![svc],
            imports: vec![],
        }
    }

    #[test]
    fn unannotated_method_is_a_loud_error() {
        let req = IrMessage {
            name: "Req".into(),
            mojo_name: "Req".into(),
            fq_name: ".tiny.rest.v1.Req".into(),
            is_map_entry: false,
            fields: vec![],
            oneofs: vec![],
        };
        let svc = IrService {
            name: "Svc".into(),
            default_host: None,
            methods: vec![IrMethod {
                name: "DoThing".into(),
                input: TypeRef {
                    fq_name: ".tiny.rest.v1.Req".into(),
                    mojo_name: "Req".into(),
                },
                output: TypeRef {
                    fq_name: ".tiny.rest.v1.Req".into(),
                    mojo_name: "Req".into(),
                },
                client_streaming: false,
                server_streaming: false,
                idempotent: false,
                http_rule: None,
                routing_rule: None,
            }],
        };
        let file = file_with(vec![req], svc.clone());
        let err = emit_rest_service(&file, &svc).unwrap_err();
        assert!(err.contains("no `(google.api.http)` annotation"), "{err}");
    }

    #[test]
    fn get_method_substitutes_path_var_and_query() {
        let req = IrMessage {
            name: "GetReq".into(),
            mojo_name: "GetReq".into(),
            fq_name: ".tiny.rest.v1.GetReq".into(),
            is_map_entry: false,
            fields: vec![
                scalar_field("shelf", ScalarKind::String),
                scalar_field("page_size", ScalarKind::Int32),
            ],
            oneofs: vec![],
        };
        let svc = IrService {
            name: "Library".into(),
            default_host: None,
            methods: vec![IrMethod {
                name: "GetShelf".into(),
                input: TypeRef {
                    fq_name: ".tiny.rest.v1.GetReq".into(),
                    mojo_name: "GetReq".into(),
                },
                output: TypeRef {
                    fq_name: ".tiny.rest.v1.GetReq".into(),
                    mojo_name: "GetReq".into(),
                },
                client_streaming: false,
                server_streaming: false,
                idempotent: true,
                http_rule: Some(IrHttpRule {
                    verb: "get".into(),
                    path_template: "/v1/shelves/{shelf}".into(),
                    body: "".into(),
                }),
                routing_rule: None,
            }],
        };
        let file = file_with(vec![req], svc.clone());
        let emit = emit_rest_service(&file, &svc).unwrap();
        // The path var is substituted via the runtime helper, the query field
        // is appended, and the GET request constructor is used.
        assert!(emit.source.contains(
            "path += _rest_path_segment(_rest_to_str(req.shelf), String(\"shelf\"))"
        ));
        assert!(emit.source.contains("page_size="));
        assert!(emit.source.contains("build_get_request(url^, headers^)"));
        assert!(emit.source.contains("return decode_json_lenient[GetReq](resp_text)"));
        assert!(!emit.source.contains("JsonDecoder"));
    }

    #[test]
    fn the_rest_client_conforms_to_deinitable_not_the_b2_name() {
        let req = IrMessage {
            name: "Req".into(),
            mojo_name: "Req".into(),
            fq_name: ".tiny.rest.v1.Req".into(),
            is_map_entry: false,
            fields: vec![],
            oneofs: vec![],
        };
        let svc = IrService {
            name: "Svc".into(),
            default_host: None,
            methods: vec![IrMethod {
                name: "GetThing".into(),
                input: TypeRef {
                    fq_name: ".tiny.rest.v1.Req".into(),
                    mojo_name: "Req".into(),
                },
                output: TypeRef {
                    fq_name: ".tiny.rest.v1.Req".into(),
                    mojo_name: "Req".into(),
                },
                client_streaming: false,
                server_streaming: false,
                idempotent: false,
                http_rule: Some(IrHttpRule {
                    verb: "get".into(),
                    path_template: "/v1/thing".into(),
                    body: "".into(),
                }),
                routing_rule: None,
            }],
        };
        let file = file_with(vec![req], svc.clone());
        let emit = emit_rest_service(&file, &svc).unwrap();
        assert!(
            emit.source
                .contains("struct SvcClient[C: Connector, T: GcpTokenSource](Movable, Deinitable):"),
            "the generated REST client must conform to 1.0.0's `Deinitable`; got:\n{}",
            emit.source
        );
        assert!(
            !emit.source.contains("ImplicitlyDestructible"),
            "the b2 trait name must not survive into generated 1.0.0 code; got:\n{}",
            emit.source
        );
    }

    fn streaming_svc(client: bool, server: bool, annotated: bool) -> (IrFile, IrService) {
        let req = IrMessage {
            name: "Req".into(),
            mojo_name: "Req".into(),
            fq_name: ".tiny.rest.v1.Req".into(),
            is_map_entry: false,
            fields: vec![],
            oneofs: vec![],
        };
        let ty = TypeRef { fq_name: ".tiny.rest.v1.Req".into(), mojo_name: "Req".into() };
        let svc = IrService {
            name: "Svc".into(),
            default_host: None,
            methods: vec![IrMethod {
                name: "Stream".into(),
                input: ty.clone(),
                output: ty,
                client_streaming: client,
                server_streaming: server,
                idempotent: false,
                http_rule: annotated.then(|| IrHttpRule {
                    verb: "get".into(),
                    path_template: "/v1/stream".into(),
                    body: "".into(),
                }),
                routing_rule: None,
            }],
        };
        (file_with(vec![req], svc.clone()), svc)
    }

    #[test]
    fn streaming_method_is_refused_by_name() {
        for (client, server, shape) in [
            (false, true, "server-streaming"),
            (true, false, "client-streaming"),
            (true, true, "bidirectional-streaming"),
        ] {
            let (file, svc) = streaming_svc(client, server, true);
            let err = emit_rest_service(&file, &svc).unwrap_err();
            assert!(
                err.contains(&format!("service `Svc` method `Stream` is {shape}")),
                "{err}"
            );
            assert!(err.contains("drop it from `methods`"), "{err}");
        }
    }

    #[test]
    fn unannotated_streaming_method_is_refused_as_streaming() {
        // The shape is the reason it has no REST form; an annotation would
        // not give it one.
        let (file, svc) = streaming_svc(false, true, false);
        let err = emit_rest_service(&file, &svc).unwrap_err();
        assert!(err.contains("method `Stream` is server-streaming"), "{err}");
    }

    fn with_host(host: Option<&str>) -> Result<RestServiceEmit, String> {
        with_host_in("tiny.rest.v1", host)
    }

    fn with_host_in(package: &str, host: Option<&str>) -> Result<RestServiceEmit, String> {
        let req = IrMessage {
            name: "Req".into(),
            mojo_name: "Req".into(),
            fq_name: ".tiny.rest.v1.Req".into(),
            is_map_entry: false,
            fields: vec![],
            oneofs: vec![],
        };
        let ty = TypeRef { fq_name: ".tiny.rest.v1.Req".into(), mojo_name: "Req".into() };
        let svc = IrService {
            name: "Logging".into(),
            default_host: host.map(str::to_string),
            methods: vec![IrMethod {
                name: "M".into(),
                input: ty.clone(),
                output: ty,
                client_streaming: false,
                server_streaming: false,
                idempotent: false,
                http_rule: Some(IrHttpRule {
                    verb: "post".into(),
                    path_template: "/v2/entries:list".into(),
                    body: "*".into(),
                }),
                routing_rule: None,
            }],
        };
        let mut file = file_with(vec![req], svc.clone());
        file.proto_package = package.to_string();
        emit_rest_service(&file, &svc)
    }

    #[test]
    fn the_client_starts_at_the_declared_default_host() {
        let e = with_host(Some("logging.googleapis.com")).unwrap();
        assert_eq!(
            e.source.matches("self._rest_host = String(\"logging.googleapis.com\")").count(),
            2,
            "both constructors start at the default host"
        );
        assert!(!e.source.contains("localhost"));
        assert!(e.source.contains("self._rest_require_host(String(\"m\"))"));
    }

    #[test]
    fn a_port_443_default_host_drops_the_port() {
        let e = with_host(Some("logging.googleapis.com:443")).unwrap();
        assert!(e.source.contains("self._rest_host = String(\"logging.googleapis.com\")"));
        assert!(!e.source.contains(":443"));
    }

    #[test]
    fn no_default_host_starts_empty_and_every_method_refuses_first() {
        let e = with_host(None).unwrap();
        assert_eq!(e.source.matches("self._rest_host = String(\"\")").count(), 2);
        assert!(!e.source.contains("localhost"));
        assert!(e.source.contains(
            "no REST host: tiny.rest.v1.Logging declares no google.api.default_host; \
             call set_rest_host(host) before sending"
        ));
        // The guard is the method's first statement: before the token
        // source is asked, before the URL is built.
        let body = &e.source[e.source.find("def m[RT: Runtime]").unwrap()..];
        let guard = body.find("self._rest_require_host(String(\"m\"))").unwrap();
        assert!(guard < body.find("access_token()").unwrap());
        assert!(guard < body.find("var url = ").unwrap());
        assert!(guard < body.find("send_buffered").unwrap());
    }

    #[test]
    fn a_default_host_that_is_not_a_host_name_is_refused() {
        for bad in [
            "",
            "https://logging.googleapis.com",
            "logging.googleapis.com:8443",
            "logging.googleapis.com/v2",
            "-bad.example.com",
            "a..b",
            "bad host",
            "x\"y",
        ] {
            let err = with_host(Some(bad)).unwrap_err();
            assert!(
                err.contains("service `tiny.rest.v1.Logging` declares `(google.api.default_host)`"),
                "{bad}: {err}"
            );
        }
        // A file with no package names the bare service, not `.Logging`.
        let err = with_host_in("", Some("https://logging.googleapis.com")).unwrap_err();
        assert!(
            err.contains("service `Logging` declares `(google.api.default_host)`"),
            "{err}"
        );
    }

    #[test]
    fn post_with_whole_body_serializes_request() {
        let book = IrMessage {
            name: "Book".into(),
            mojo_name: "Book".into(),
            fq_name: ".tiny.rest.v1.Book".into(),
            is_map_entry: false,
            fields: vec![scalar_field("title", ScalarKind::String)],
            oneofs: vec![],
        };
        let req = IrMessage {
            name: "CreateBookReq".into(),
            mojo_name: "CreateBookReq".into(),
            fq_name: ".tiny.rest.v1.CreateBookReq".into(),
            is_map_entry: false,
            fields: vec![
                scalar_field("shelf", ScalarKind::String),
                msg_field("book", ".tiny.rest.v1.Book", "Book"),
            ],
            oneofs: vec![],
        };
        let svc = IrService {
            name: "Library".into(),
            default_host: None,
            methods: vec![IrMethod {
                name: "CreateBook".into(),
                input: TypeRef {
                    fq_name: ".tiny.rest.v1.CreateBookReq".into(),
                    mojo_name: "CreateBookReq".into(),
                },
                output: TypeRef {
                    fq_name: ".tiny.rest.v1.Book".into(),
                    mojo_name: "Book".into(),
                },
                client_streaming: false,
                server_streaming: false,
                idempotent: false,
                http_rule: Some(IrHttpRule {
                    verb: "post".into(),
                    path_template: "/v1/shelves/{shelf}/books".into(),
                    body: "book".into(),
                }),
                routing_rule: None,
            }],
        };
        let file = file_with(vec![book, req], svc.clone());
        let emit = emit_rest_service(&file, &svc).unwrap();
        // The named body field is a singular MESSAGE (stored `Optional[Book]`),
        // so it serializes via `encode_json(req.book.value())` guarded by a
        // presence check — NOT `encode_json(req.book)` (Optional is not
        // Serializable). The post constructor + Content-Type are emitted.
        assert!(emit.source.contains("if req.book:"));
        assert!(emit.source.contains("body_text = encode_json(req.book.value())"));
        assert!(emit.source.contains("BytesBody.from_str(body_text)"));
        assert!(emit.source.contains("HttpMethod.post()"));
        assert!(emit.source.contains("Content-Type"));
        // POST routes through `send_buffered[RT, BytesBody]` (the body verb).
        assert!(emit
            .source
            .contains("self._client.send_buffered[RT, BytesBody](req_http^, reactor)"));
    }

    #[test]
    fn delete_with_body_serializes_request_and_does_not_drop_it() {
        let req = IrMessage {
            name: "RevokeReq".into(),
            mojo_name: "RevokeReq".into(),
            fq_name: ".tiny.rest.v1.RevokeReq".into(),
            is_map_entry: false,
            fields: vec![
                scalar_field("shelf", ScalarKind::String),
                scalar_field("user_id", ScalarKind::String),
            ],
            oneofs: vec![],
        };
        let out = IrMessage {
            name: "RevokeResp".into(),
            mojo_name: "RevokeResp".into(),
            fq_name: ".tiny.rest.v1.RevokeResp".into(),
            is_map_entry: false,
            fields: vec![scalar_field("revoked", ScalarKind::Bool)],
            oneofs: vec![],
        };
        let svc = IrService {
            name: "Library".into(),
            default_host: None,
            methods: vec![IrMethod {
                name: "Revoke".into(),
                input: TypeRef {
                    fq_name: ".tiny.rest.v1.RevokeReq".into(),
                    mojo_name: "RevokeReq".into(),
                },
                output: TypeRef {
                    fq_name: ".tiny.rest.v1.RevokeResp".into(),
                    mojo_name: "RevokeResp".into(),
                },
                client_streaming: false,
                server_streaming: false,
                idempotent: false,
                http_rule: Some(IrHttpRule {
                    verb: "delete".into(),
                    path_template: "/v1/shelves/{shelf}/access".into(),
                    body: "*".into(),
                }),
                routing_rule: None,
            }],
        };
        let file = file_with(vec![req, out], svc.clone());
        let emit = emit_rest_service(&file, &svc).unwrap();
        assert!(emit.source.contains("var body_text = encode_json(req)"));
        assert!(emit.source.contains("BytesBody.from_str(body_text)"));
        assert!(emit.source.contains("HttpMethod.delete()"));
        assert!(emit.source.contains("Content-Type"));
        assert!(emit
            .source
            .contains("HttpMethod.delete(), url^, headers^, body^,"));
        assert!(!emit
            .source
            .contains("HttpMethod.delete(), url^, headers^, empty_body^,"));
    }

    #[test]
    fn get_method_uses_empty_body_and_lowercase_bool() {
        // A GET with a Bool query field: the request is a
        // `ClientRequest[EmptyBody]` so the dispatch MUST bind `EmptyBody`
        // (pinning `BytesBody` is a hard type mismatch), and a proto `bool`
        // query field stringifies as proto3-JSON lowercase `true`/`false`
        // via `_rest_bool_str`, never Mojo's `String(Bool)` (`True`/`False`).
        let req = IrMessage {
            name: "GetReq".into(),
            mojo_name: "GetReq".into(),
            fq_name: ".tiny.rest.v1.GetReq".into(),
            is_map_entry: false,
            fields: vec![
                scalar_field("shelf", ScalarKind::String),
                scalar_field("include_reviews", ScalarKind::Bool),
            ],
            oneofs: vec![],
        };
        let svc = IrService {
            name: "Library".into(),
            default_host: None,
            methods: vec![IrMethod {
                name: "GetBook".into(),
                input: TypeRef {
                    fq_name: ".tiny.rest.v1.GetReq".into(),
                    mojo_name: "GetReq".into(),
                },
                output: TypeRef {
                    fq_name: ".tiny.rest.v1.GetReq".into(),
                    mojo_name: "GetReq".into(),
                },
                client_streaming: false,
                server_streaming: false,
                idempotent: true,
                http_rule: Some(IrHttpRule {
                    verb: "get".into(),
                    path_template: "/v1/shelves/{shelf}".into(),
                    body: "".into(),
                }),
                routing_rule: None,
            }],
        };
        let file = file_with(vec![req], svc.clone());
        let emit = emit_rest_service(&file, &svc).unwrap();
        // GET binds EmptyBody (its request is ClientRequest[EmptyBody]).
        assert!(emit
            .source
            .contains("self._client.send_buffered[RT, EmptyBody](req_http^, reactor)"));
        // The connector has ONE role (the HttpClient owns it): no method takes
        // one, nothing reaches the unpooled `call`, and the docstring states
        // the caller's serving-ceiling obligation.
        assert!(!emit.source.contains("mut connector"));
        assert!(!emit.source.contains("self._client.call["));
        assert!(emit.source.contains("HttpClientConfig.for_serving_ceiling(ceiling)"));
        assert!(emit
            .source
            .contains("_rest_bool_str(req.include_reviews)"));
        // A non-Bool scalar still uses the generic stringifier.
        assert!(emit.source.contains("_rest_to_str(req.shelf)"));
    }

    #[test]
    fn client_carries_per_client_default_headers() {
        let req = IrMessage {
            name: "GetReq".into(),
            mojo_name: "GetReq".into(),
            fq_name: ".tiny.rest.v1.GetReq".into(),
            is_map_entry: false,
            fields: vec![scalar_field("shelf", ScalarKind::String)],
            oneofs: vec![],
        };
        let svc = IrService {
            name: "Library".into(),
            default_host: None,
            methods: vec![IrMethod {
                name: "GetShelf".into(),
                input: TypeRef {
                    fq_name: ".tiny.rest.v1.GetReq".into(),
                    mojo_name: "GetReq".into(),
                },
                output: TypeRef {
                    fq_name: ".tiny.rest.v1.GetReq".into(),
                    mojo_name: "GetReq".into(),
                },
                client_streaming: false,
                server_streaming: false,
                idempotent: true,
                http_rule: Some(IrHttpRule {
                    verb: "get".into(),
                    path_template: "/v1/shelves/{shelf}".into(),
                    body: "".into(),
                }),
                routing_rule: None,
            }],
        };
        let file = file_with(vec![req], svc.clone());
        let emit = emit_rest_service(&file, &svc).unwrap();
        // The field + both constructors + the merge helper.
        assert!(emit.source.contains("var _default_headers: HeaderMap"));
        assert!(emit
            .source
            .contains("def __init__(out self, var client: HttpClient[Self.C], var token_source: Self.T):"));
        assert!(emit.source.contains("    var default_headers: HeaderMap,\n"));
        assert!(emit.source.contains(
            "def _rest_apply_default_headers(self, mut headers: HeaderMap) raises:"
        ));
        // Every method merges the defaults into its per-request HeaderMap.
        assert!(emit
            .source
            .contains("self._rest_apply_default_headers(headers)"));
    }

    #[test]
    fn query_key_uses_json_name_not_field_name() {
        let req = IrMessage {
            name: "ListReq".into(),
            mojo_name: "ListReq".into(),
            fq_name: ".tiny.rest.v1.ListReq".into(),
            is_map_entry: false,
            fields: vec![
                scalar_field("shelf", ScalarKind::String),
                // json_name deliberately DIFFERS from the field name.
                IrField {
                    name: "include_archived".into(),
                    ty: IrType::Scalar(ScalarKind::Bool),
                    label: Label::Single,
                    proto_field_number: 2,
                    json_name: "includeArchived".into(),
                    oneof_index: None,
                },
            ],
            oneofs: vec![],
        };
        let svc = IrService {
            name: "Library".into(),
            default_host: None,
            methods: vec![IrMethod {
                name: "ListShelf".into(),
                input: TypeRef {
                    fq_name: ".tiny.rest.v1.ListReq".into(),
                    mojo_name: "ListReq".into(),
                },
                output: TypeRef {
                    fq_name: ".tiny.rest.v1.ListReq".into(),
                    mojo_name: "ListReq".into(),
                },
                client_streaming: false,
                server_streaming: false,
                idempotent: true,
                http_rule: Some(IrHttpRule {
                    verb: "get".into(),
                    path_template: "/v1/shelves/{shelf}".into(),
                    body: "".into(),
                }),
                routing_rule: None,
            }],
        };
        let file = file_with(vec![req], svc.clone());
        let emit = emit_rest_service(&file, &svc).unwrap();
        // The camelCase json_name is the query KEY.
        assert!(
            emit.source.contains("includeArchived="),
            "query key must be the json_name"
        );
        // The snake_case field name is NEVER a query key (`include_archived=`
        // would only appear if the emitter used the field name).
        assert!(
            !emit.source.contains("include_archived="),
            "query key must NOT be the snake field name"
        );
        // The VALUE is still read from the snake_case Mojo struct field.
        assert!(emit
            .source
            .contains("_rest_bool_str(req.include_archived)"));
    }

    #[test]
    fn optional_query_field_is_presence_checked() {
        let req = IrMessage {
            name: "InsertReq".into(),
            mojo_name: "InsertReq".into(),
            fq_name: ".tiny.rest.v1.InsertReq".into(),
            is_map_entry: false,
            fields: vec![
                scalar_field("shelf", ScalarKind::String),
                IrField {
                    name: "request_id".into(),
                    ty: IrType::Scalar(ScalarKind::String),
                    label: Label::Optional, // proto3 explicit presence
                    proto_field_number: 2,
                    json_name: "requestId".into(),
                    oneof_index: None,
                },
            ],
            oneofs: vec![],
        };
        let svc = IrService {
            name: "Library".into(),
            default_host: None,
            methods: vec![IrMethod {
                name: "InsertShelf".into(),
                input: TypeRef {
                    fq_name: ".tiny.rest.v1.InsertReq".into(),
                    mojo_name: "InsertReq".into(),
                },
                output: TypeRef {
                    fq_name: ".tiny.rest.v1.InsertReq".into(),
                    mojo_name: "InsertReq".into(),
                },
                client_streaming: false,
                server_streaming: false,
                idempotent: true,
                http_rule: Some(IrHttpRule {
                    verb: "get".into(),
                    path_template: "/v1/shelves/{shelf}".into(),
                    body: "".into(),
                }),
                routing_rule: None,
            }],
        };
        let file = file_with(vec![req], svc.clone());
        let emit = emit_rest_service(&file, &svc).unwrap();
        assert!(
            emit.source.contains("if req.request_id:"),
            "an optional query field must be presence-checked"
        );
        // ...and reads the value THROUGH the Optional.
        assert!(
            emit.source
                .contains("_rest_to_str(req.request_id.value())"),
            "an optional query field reads through .value()"
        );
        // The separator is dynamic (joins on the accumulated query), never a
        // static leading `&` that would dangle when the first field is unset.
        assert!(
            emit.source.contains("if query.byte_length() > 0:"),
            "the query separator must be dynamic"
        );
    }

    #[test]
    fn empty_response_body_decodes_as_object() {
        let req = IrMessage {
            name: "DeleteReq".into(),
            mojo_name: "DeleteReq".into(),
            fq_name: ".tiny.rest.v1.DeleteReq".into(),
            is_map_entry: false,
            fields: vec![scalar_field("shelf", ScalarKind::String)],
            oneofs: vec![],
        };
        let svc = IrService {
            name: "Library".into(),
            default_host: None,
            methods: vec![IrMethod {
                name: "DeleteShelf".into(),
                input: TypeRef {
                    fq_name: ".tiny.rest.v1.DeleteReq".into(),
                    mojo_name: "DeleteReq".into(),
                },
                output: TypeRef {
                    fq_name: ".tiny.rest.v1.DeleteReq".into(),
                    mojo_name: "DeleteReq".into(),
                },
                client_streaming: false,
                server_streaming: false,
                idempotent: false,
                http_rule: Some(IrHttpRule {
                    verb: "delete".into(),
                    path_template: "/v1/shelves/{shelf}".into(),
                    body: "".into(),
                }),
                routing_rule: None,
            }],
        };
        let file = file_with(vec![req], svc.clone());
        let emit = emit_rest_service(&file, &svc).unwrap();
        assert!(emit.source.contains("if resp_text.byte_length() == 0:"));
        assert!(emit.source.contains("resp_text = String(\"{}\")"));
    }

    /// One service `Logging` with one unary method `M` over request `Req`.
    fn one_method(fields: Vec<IrField>, verb: &str, path: &str, body: &str) -> Result<RestServiceEmit, String> {
        let req = IrMessage {
            name: "Req".into(),
            mojo_name: "Req".into(),
            fq_name: ".tiny.rest.v1.Req".into(),
            is_map_entry: false,
            fields,
            oneofs: vec![],
        };
        let ty = TypeRef { fq_name: ".tiny.rest.v1.Req".into(), mojo_name: "Req".into() };
        let svc = IrService {
            name: "Logging".into(),
            default_host: None,
            methods: vec![IrMethod {
                name: "M".into(),
                input: ty.clone(),
                output: ty,
                client_streaming: false,
                server_streaming: false,
                idempotent: false,
                http_rule: Some(IrHttpRule {
                    verb: verb.into(),
                    path_template: path.into(),
                    body: body.into(),
                }),
                routing_rule: None,
            }],
        };
        let file = file_with(vec![req], svc.clone());
        emit_rest_service(&file, &svc)
    }

    fn repeated(mut f: IrField) -> IrField {
        f.label = Label::Repeated;
        f
    }

    #[test]
    fn custom_verb_is_appended_after_the_path() {
        let e = one_method(vec![], "post", "/v2/entries:list", "*").unwrap();
        assert!(e.source.contains("path += String(\"/entries\")\n"), "{}", e.source);
        assert!(e.source.contains("path += String(\":list\")\n"), "{}", e.source);
    }

    #[test]
    fn pattern_capture_goes_through_the_checked_expansion() {
        let e = one_method(
            vec![scalar_field("parent", ScalarKind::String)],
            "get",
            "/v2/{parent=projects/*}/logs",
            "",
        )
        .unwrap();
        assert!(e.source.contains(
            "path += _rest_path_var(_rest_to_str(req.parent), String(\"projects/*\"), String(\"parent\"))"
        ));
        assert!(rest_helper_functions().contains("def _rest_path_var("));
    }

    #[test]
    fn repeated_query_field_appends_one_key_per_element() {
        let mut f = repeated(scalar_field("resource_names", ScalarKind::String));
        f.json_name = "resourceNames".into();
        let e = one_method(vec![f], "get", "/v2/logs", "").unwrap();
        assert!(e.source.contains("for _rest_v in req.resource_names:"), "{}", e.source);
        assert!(e.source.contains(
            "query += String(\"resourceNames=\") + _rest_pct_encode(_rest_to_str(_rest_v))"
        ));
    }

    #[test]
    fn repeated_path_variable_is_refused() {
        let f = repeated(scalar_field("name", ScalarKind::String));
        let err = one_method(vec![f], "get", "/v2/{name}", "").unwrap_err();
        assert!(err.contains("takes one value"), "{err}");
    }

    #[test]
    fn token_comes_from_the_source_and_errors_never_echo_the_body() {
        let e = one_method(vec![], "post", "/v2/entries:list", "*").unwrap();
        assert!(!e.source.contains("token: String"));
        assert!(e.source.contains("self._token_source.access_token()"));
        assert!(e.source.contains("if status_int < 200 or status_int >= 300:"));
        assert!(e.source.contains(
            "raise gcp_status_error(String(\"POST\"), String(\"M\"), status_int, resp_bytes)"
        ));
        assert!(e.source.contains("return decode_json_lenient[Req](resp_text)"));
        assert!(!e.source.contains("decode_json["));
        // The import line states exactly the names the contract constants name.
        assert_eq!(
            rest_imports()[0],
            format!("from {GCP_CORE} import {GCP_TOKEN_SOURCE}, {GCP_STATUS_ERROR}")
        );
    }

    #[test]
    fn default_valued_implicit_scalars_stay_out_of_the_query() {
        let e = one_method(
            vec![
                scalar_field("page_token", ScalarKind::String),
                scalar_field("page_size", ScalarKind::Int32),
                scalar_field("show_deleted", ScalarKind::Bool),
            ],
            "get",
            "/v2/logs",
            "",
        )
        .unwrap();
        assert!(e.source.contains("if req.page_token.byte_length() > 0:"), "{}", e.source);
        assert!(e.source.contains("if req.page_size != 0:"));
        assert!(e.source.contains("if req.show_deleted:"));
    }

    #[test]
    fn bytes_field_in_the_url_is_refused() {
        let err = one_method(vec![scalar_field("blob", ScalarKind::Bytes)], "get", "/v2/x", "")
            .unwrap_err();
        assert!(err.contains("is `bytes`"), "{err}");
    }

    #[test]
    fn one_segment_capture_goes_through_the_checked_segment() {
        // `{name}` and `{name=*}` expand alike: one segment, through the
        // helper that refuses an empty, `.` or `..` value.
        for path in ["/v1/{name}/things", "/v1/{name=*}/things"] {
            let e = one_method(vec![scalar_field("name", ScalarKind::String)], "get", path, "")
                .unwrap();
            assert!(
                e.source.contains(
                    "path += _rest_path_segment(_rest_to_str(req.name), String(\"name\"))"
                ),
                "{path}: {}",
                e.source
            );
        }
        assert!(rest_helper_functions().contains("def _rest_path_segment("));
    }

    #[test]
    fn root_template_builds_a_slash() {
        let e = one_method(vec![], "get", "/", "").unwrap();
        assert!(e.source.contains("var path = String(\"\")\n"), "{}", e.source);
        assert!(e.source.contains("path += String(\"/\")\n"), "{}", e.source);
    }
}
