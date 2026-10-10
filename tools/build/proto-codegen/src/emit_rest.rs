//! The REST client emitter: for `ProtocolMode::Rest`, one client method per
//! unary or server-streaming method carrying a `(google.api.http)`
//! annotation, on a client that starts at the service's
//! `(google.api.default_host)`, or at the service configuration's `name`
//! that replaced it (`IrService::host_from_service_config`), or, with
//! neither, refuses to send until its caller names a host.

use std::fmt::Write as _;

use crate::ir::*;
use crate::mojo_names::rpc_method_name;
use crate::path_template::{
    percent_encode_simple, BodyDesignator, FieldPartition, PathSegment, PathTemplate, VarPattern,
};

/// The result of emitting one REST service.
#[derive(Clone, Debug)]
pub struct RestServiceEmit {
    /// The generated client-struct source (already indented; appended raw to
    /// the file buffer by the caller).
    pub source: String,
    /// Whether the source calls `komira_encoding.base64_encode` (a `bytes`
    /// query parameter), so the file must import it.
    pub needs_base64: bool,
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

/// The server-stream reader of [`GCP_CORE`]. Its contract:
/// `def gcp_rest_stream_items(verb: String, rpc: String, http_status: Int, body: List[UInt8]) raises -> List[String]`
/// returns the elements of the JSON array a server-streaming method answers
/// with over REST, each as its JSON text, in stream order; raises an element
/// that is a `google.rpc.Status` envelope (a failure after the 200 was sent)
/// through [`GCP_STATUS_ERROR`]; and refuses a body that is not a JSON array
/// by its byte count, never its bytes.
pub const GCP_REST_STREAM_ITEMS: &str = "gcp_rest_stream_items";

/// Whether `m` is emitted as a REST server-streaming method: it streams its
/// responses and not its requests. A client-streaming or bidi method has no
/// REST mapping (one HTTP request carries one request message) and is
/// refused by name (`emit_rest_service`).
pub fn is_rest_server_stream(m: &IrMethod) -> bool {
    m.server_streaming && !m.client_streaming
}

/// The import a REST-target file adds when one of its services has a
/// server-streaming method ([`is_rest_server_stream`]), and only then: the
/// other files' imports stay as they were.
pub fn rest_stream_import(file: &IrFile) -> Option<String> {
    let any = file
        .services
        .iter()
        .flat_map(|s| s.methods.iter())
        .any(|m| m.http_rule.is_some() && is_rest_server_stream(m));
    any.then(|| format!("from {GCP_CORE} import {GCP_REST_STREAM_ITEMS}"))
}

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
/// `file` alone ([`emit_rest_service_in`] with no other files). Returns the
/// generated source, or a hard error naming the service and method for: a
/// client-streaming or bidi method (it has no REST form, and a kept method
/// that silently generated nothing would be a client missing a method its
/// target listed), an un-annotated method (the missing-annotation rule), a
/// `(google.api.default_host)` that is not a plain host name, or a binding
/// or query field with no REST form.
pub fn emit_rest_service(
    file: &IrFile,
    svc: &IrService,
) -> Result<RestServiceEmit, String> {
    emit_rest_service_in(file, &[], svc)
}

/// [`emit_rest_service`], with the request messages (and the messages of
/// query parameters) looked up in `file` and then in `peers`, the other files
/// of the model: a method may take a request declared in an imported
/// `.proto`.
pub fn emit_rest_service_in(
    file: &IrFile,
    peers: &[IrFile],
    svc: &IrService,
) -> Result<RestServiceEmit, String> {
    let idx = MessageIndex { file, peers };
    let mut needs_base64 = false;
    let mut w = Writer::new();

    // Refusals first, before any text: a service is emitted whole or not at
    // all. A client-streaming or bidi method has no REST/JSON form (one HTTP
    // request carries one request message), annotated or not; a target names
    // every method it generates (`methods`), so one here was ASKED FOR, and
    // skipping it would leave the client silently without it. A
    // server-streaming method has one: its whole stream is one HTTP
    // response, a JSON array (`is_rest_server_stream`).
    for m in &svc.methods {
        if m.client_streaming {
            let shape = if m.server_streaming {
                "bidirectional-streaming"
            } else {
                "client-streaming"
            };
            return Err(format!(
                "service `{}` method `{}` is {shape}, and a `rest` target generates \
                 unary and server-streaming methods only (one HTTP request carries \
                 one request message, so it has no REST/JSON form): drop it from \
                 `methods`, or generate it with `default_protocol=grpc`",
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
    // `(google.api.default_host)`, or at the service configuration's `name`
    // that replaced it; with neither it starts empty, and
    // every method refuses to send (`_rest_require_host`) until the caller
    // names one. Never a placeholder: whatever host the URL names receives
    // the bearer token. The URL host feeds BOTH the dial-target DNS
    // resolution and the injected `Host:` header (SNI on the TLS connector is
    // not the dial target).
    let initial_host = default_host.as_deref().unwrap_or("");
    w.line("var _rest_host: String");
    w.line("\"\"\"The host the request URLs target: it drives BOTH the dial DNS");
    match &default_host {
        Some(h) if svc.host_from_service_config => {
            w.line("    target and the `Host:` header. Starts at the API's service");
            w.line(&format!(
                "    configuration `name`, `{h}`; `set_rest_host` replaces it.\"\"\""
            ));
        }
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
    // The port and scheme, for an endpoint other than the service's own: an
    // emulator speaks plaintext HTTP on a port of its own (the Firestore,
    // Pub/Sub and Datastore emulators), which Google's client libraries dial
    // when pointed at it. The defaults are the public endpoint's: https on
    // the scheme's port.
    w.line("var _rest_port: UInt16");
    w.line("\"\"\"The port the request URLs name; 0, the default, is the scheme's.\"\"\"");
    w.blank();
    w.line("var _rest_plaintext: Bool");
    w.line("\"\"\"Whether the request URLs are `http` rather than `https`. False");
    w.line("    unless `set_rest_endpoint` says otherwise.\"\"\"");
    w.blank();
    w.line("def __init__(out self, var client: HttpClient[Self.C], var token_source: Self.T):");
    w.indent();
    w.line("\"\"\"Construct with no default headers.\"\"\"");
    w.line("self._client = client^");
    w.line("self._token_source = token_source^");
    w.line("self._default_headers = HeaderMap()");
    w.line(&format!("self._rest_host = String(\"{initial_host}\")"));
    w.line("self._rest_port = UInt16(0)");
    w.line("self._rest_plaintext = False");
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
    w.line("self._rest_port = UInt16(0)");
    w.line("self._rest_plaintext = False");
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
    w.line("def set_rest_endpoint(mut self, var host: String, port: UInt16, plaintext: Bool):");
    w.indent();
    w.line("\"\"\"Point the request URLs at an endpoint other than the service's");
    w.line("    public one: `host`, `port` (0 for the scheme's own) and, with");
    w.line("    `plaintext`, `http` instead of `https`, which is how an emulator");
    w.line("    serves. The connector must match the scheme: the `HttpClient`");
    w.line("    refuses an `http` URL over a TLS connector and an `https` one over");
    w.line("    a plaintext connector. The bearer token is sent either way.\"\"\"");
    w.line("self._rest_host = host^");
    w.line("self._rest_port = port");
    w.line("self._rest_plaintext = plaintext");
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
        Some(h) if svc.host_from_service_config => format!(
            "the host was set empty (the API's service configuration name is {h}); \
             call set_rest_host(host) with a host before sending"
        ),
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
        needs_base64 |= emit_rest_method(&mut w, idx, m, rule)?;
    }

    w.dedent();
    Ok(RestServiceEmit {
        source: w.into_source(),
        needs_base64,
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
/// `(google.api.default_host)` (or the service configuration's `name` that
/// replaced it), or `None` when it has neither. googleapis
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
    if !dns_name && svc.host_from_service_config {
        return Err(format!(
            "service `{fq_service}` starts at its service configuration's `name`, \
             {declared:?}, which is not a host name (optionally `:443`): a REST client \
             sends to it over HTTPS on the default port"
        ));
    }
    if !dns_name {
        return Err(format!(
            "service `{fq_service}` declares `(google.api.default_host)` = {declared:?}, \
             which is not a host name (optionally `:443`): a REST client sends to it over \
             HTTPS on the default port"
        ));
    }
    Ok(Some(host.to_string()))
}

/// Where a REST method looks a message type up: the file being emitted
/// first, then the other files of the same model. A request declared in an
/// imported `.proto` (`google.iam.v1.GetIamPolicyRequest`, which IAM and
/// Resource Manager both take) and the message of a query parameter
/// (`google.iam.v1.GetPolicyOptions`) are found there.
#[derive(Clone, Copy)]
struct MessageIndex<'a> {
    file: &'a IrFile,
    peers: &'a [IrFile],
}

impl<'a> MessageIndex<'a> {
    fn get(&self, fq_name: &str) -> Option<&'a IrMessage> {
        std::iter::once(self.file)
            .chain(self.peers.iter())
            .flat_map(|f| f.messages.iter())
            .find(|msg| msg.fq_name == fq_name)
    }
}

/// The well-known types a query parameter carries as one value, its proto3
/// JSON string, which `google/api/http.proto` sends as the parameter's
/// value: a FieldMask's `title,includedPermissions`, a Timestamp's RFC 3339
/// `2026-10-01T00:00:00.5Z` and a Duration's `60s`. The generated code calls
/// komira_wkt's `to_proto3_json()`, the formatter its JSON codec uses, so the
/// query and a JSON body spell one value the same way. Sending their fields
/// instead (`at.seconds=&at.nanos=`) would be wrong even when the type is
/// declared among the generated files.
const QUERY_WKTS: [&str; 3] = [
    ".google.protobuf.FieldMask",
    ".google.protobuf.Timestamp",
    ".google.protobuf.Duration",
];

/// How one query value is rendered.
#[derive(Clone, Copy, PartialEq, Eq)]
enum LeafKind {
    /// `true` / `false`, lowercase.
    Bool,
    /// Standard base64, as proto3 JSON writes `bytes`.
    Bytes,
    String,
    /// Any other scalar.
    OtherScalar,
    Enum,
    /// One of [`QUERY_WKTS`]: its proto3 JSON string.
    WktString,
}

/// One query parameter: its key and where its value is read.
struct QueryLeaf {
    /// The key: the field's JSON name, or the dotted JSON names of the
    /// fields leading to it (`interval.startTime`) for a field of a
    /// message-typed request field.
    key: String,
    /// The Mojo expression of the field: `req.page_size`, or
    /// `_rest_options.requested_policy_version` inside its parent's guard.
    access: String,
    label: Label,
    kind: LeafKind,
}

/// A query field of the request: a value, or a message whose fields are
/// sent, each under its dotted key, when it is set.
enum QueryItem {
    Leaf(QueryLeaf),
    Nested {
        /// The expression of the field holding the message
        /// (`req.interval`, `_rest_mid.leaf_opts`).
        access: String,
        /// The name its value is bound to inside the presence check
        /// (`_rest_interval`, `_rest_mid__leaf_opts`): the field path, so no
        /// two bindings of one method share a name.
        binding: String,
        items: Vec<QueryItem>,
    },
}

impl QueryItem {
    fn any_leaf(&self, pred: &dyn Fn(&QueryLeaf) -> bool) -> bool {
        match self {
            QueryItem::Leaf(l) => pred(l),
            QueryItem::Nested { items, .. } => items.iter().any(|i| i.any_leaf(pred)),
        }
    }
}

/// The leaf for a scalar or enum field, or `None` for a message or a map.
fn scalar_leaf(key: String, access: String, fld: &IrField) -> Option<QueryLeaf> {
    let kind = match &fld.ty {
        IrType::Scalar(ScalarKind::Bool) => LeafKind::Bool,
        IrType::Scalar(ScalarKind::Bytes) => LeafKind::Bytes,
        IrType::Scalar(ScalarKind::String) => LeafKind::String,
        IrType::Scalar(_) => LeafKind::OtherScalar,
        IrType::Enum(_) => LeafKind::Enum,
        _ => return None,
    };
    Some(QueryLeaf { key, access, label: fld.label, kind })
}

/// The query items of `fields`, as `google/api/http.proto` maps them: a
/// scalar, enum or repeated scalar is one parameter (repeated: one per
/// element); a FieldMask, Timestamp or Duration is one parameter, its JSON
/// string; a non-repeated message is flattened, each of its fields sent
/// under the dotted JSON names of the path to it (`interval.startTime`,
/// `aggregation.alignmentPeriod`), to any depth, only when the message is
/// set. Fields go in declaration order at every level. Anything else (a
/// repeated message, a map, a oneof arm, another well-known type, a message
/// that holds itself) has no query form and is refused by name, with its
/// dotted path.
fn query_items(
    m: &IrMethod,
    idx: MessageIndex<'_>,
    req_msg: &IrMessage,
    fields: &[String],
) -> Result<Vec<QueryItem>, String> {
    let mut items = Vec::new();
    let mut stack = vec![req_msg.fq_name.clone()];
    for f in fields {
        let fld = req_msg
            .fields
            .iter()
            .find(|x| &x.name == f)
            .expect("partition field came from the message");
        let q = QueryPath {
            names: vec![f.clone()],
            json: fld.json_name.clone(),
            access: format!("req.{f}"),
        };
        items.push(query_item(m, idx, fld, &q, &mut stack)?);
    }
    Ok(items)
}

/// Where a query field sits: its proto field path (`interval.start_time`,
/// for messages and bindings), its dotted JSON key (`interval.startTime`)
/// and the Mojo expression that reads it.
struct QueryPath {
    names: Vec<String>,
    json: String,
    access: String,
}

impl QueryPath {
    fn dotted(&self) -> String {
        self.names.join(".")
    }
}

/// The query item of one field at `q`. `stack` holds the fully qualified
/// names of the messages enclosing it, so a message that holds itself is
/// refused rather than flattened forever.
fn query_item(
    m: &IrMethod,
    idx: MessageIndex<'_>,
    fld: &IrField,
    q: &QueryPath,
    stack: &mut Vec<String>,
) -> Result<QueryItem, String> {
    let f = q.dotted();
    if fld.oneof_index.is_some() {
        return Err(oneof_url_field(m, &f));
    }
    if let Some(leaf) = scalar_leaf(q.json.clone(), q.access.clone(), fld) {
        return Ok(QueryItem::Leaf(leaf));
    }
    let tref = match &fld.ty {
        IrType::Message(tref) => tref,
        IrType::Map(..) => {
            return Err(format!(
                "REST method `{}`: query field `{f}` is a map, which has no query form",
                m.name
            ))
        }
        // Scalars and enums were taken above; a nested list is built
        // only by the AWS front end, never for a proto field.
        _ => {
            return Err(format!(
                "REST method `{}`: query field `{f}` is a list of lists, which has no \
                 query form",
                m.name
            ))
        }
    };
    if fld.label == Label::Repeated {
        return Err(format!(
            "REST method `{}`: query field `{f}` is a repeated message, which has no \
             query form",
            m.name
        ));
    }
    if QUERY_WKTS.contains(&tref.fq_name.as_str()) {
        return Ok(QueryItem::Leaf(QueryLeaf {
            key: q.json.clone(),
            access: q.access.clone(),
            label: Label::Optional,
            kind: LeafKind::WktString,
        }));
    }
    // Any other well-known type is one parameter too, its JSON string,
    // which is not implemented here (a Struct or a wrapper in a query).
    if tref.fq_name.starts_with(".google.protobuf.") {
        return Err(format!(
            "REST method `{}`: query field `{f}` is a `{}`, whose query form would be its \
             JSON string, which is implemented only for `{}`, `{}` and `{}`",
            m.name, tref.fq_name, QUERY_WKTS[0], QUERY_WKTS[1], QUERY_WKTS[2]
        ));
    }
    if stack.contains(&tref.fq_name) {
        return Err(format!(
            "REST method `{}`: query field `{f}` is a `{}`, which holds itself, so it has \
             no finite query form",
            m.name, tref.fq_name
        ));
    }
    let sub = idx.get(&tref.fq_name).ok_or_else(|| {
        format!(
            "REST method `{}`: query field `{f}` is a `{}`, which is not declared in \
             the generated files, so its fields cannot be sent",
            m.name, tref.fq_name
        )
    })?;
    let binding = format!("_rest_{}", q.names.join("__"));
    stack.push(tref.fq_name.clone());
    let mut items = Vec::new();
    for sf in &sub.fields {
        let mut names = q.names.clone();
        names.push(sf.name.clone());
        let sq = QueryPath {
            names,
            json: format!("{}.{}", q.json, sf.json_name),
            access: format!("{binding}.{}", sf.name),
        };
        items.push(query_item(m, idx, sf, &sq, stack)?);
    }
    stack.pop();
    Ok(QueryItem::Nested { access: q.access.clone(), binding, items })
}

/// Emit one annotated unary or server-streaming REST method. Returns
/// whether its code calls
/// `base64_encode` (a `bytes` query parameter), whose import the file then
/// needs.
fn emit_rest_method(
    w: &mut Writer,
    idx: MessageIndex<'_>,
    m: &IrMethod,
    rule: &IrHttpRule,
) -> Result<bool, String> {
    let method_name = rpc_method_name(&m.name);
    let req_ty = &m.input.mojo_name;
    let resp_ty = &m.output.mojo_name;

    let req_msg = idx.get(&m.input.fq_name).ok_or_else(|| {
        format!(
            "REST method `{}`: request type `{}` is not declared in the generated files: \
             add the .proto declaring it to the files to generate",
            m.name, m.input.fq_name
        )
    })?;

    let leaf_fields: Vec<String> =
        req_msg.fields.iter().map(|f| f.name.clone()).collect();

    // The rule and its additional bindings: one generated method sends the
    // request to the first whose path variables its values match.
    let mut bindings: Vec<(&IrHttpRule, PathTemplate)> = Vec::new();
    let mut part: Option<FieldPartition> = None;
    for b in std::iter::once(rule).chain(rule.additional_bindings.iter()) {
        let template = PathTemplate::parse(&b.path_template)
            .map_err(|e| format!("REST method `{}`: {e}", m.name))?;
        let p = partition_or_err(m, &leaf_fields, &template, &b.body)?;
        if let Some(first) = &part {
            if b.verb != rule.verb || b.body != rule.body {
                return Err(format!(
                    "REST method `{}`: additional binding `{}` is `{}` with body {:?}, \
                     but `{}` is `{}` with body {:?}: a generated method sends one verb \
                     and one body form, so every binding must share them",
                    m.name, b.path_template, b.verb, b.body, rule.path_template,
                    rule.verb, rule.body
                ));
            }
            let mut a = first.path_fields.clone();
            let mut z = p.path_fields.clone();
            a.sort();
            z.sort();
            if a != z {
                return Err(format!(
                    "REST method `{}`: additional binding `{}` binds the path fields \
                     {z:?}, and `{}` binds {a:?}: every binding must bind the same \
                     fields, so that the query is the same whichever one matches",
                    m.name, b.path_template, rule.path_template
                ));
            }
        } else {
            part = Some(p);
        }
        bindings.push((b, template));
    }
    let part = part.expect("the rule itself is the first binding");

    let mut bool_fields: std::collections::BTreeSet<String> =
        std::collections::BTreeSet::new();
    let mut enum_fields: std::collections::BTreeSet<String> =
        std::collections::BTreeSet::new();
    // Each path variable's field, a dotted one resolved through the message
    // fields it names: the leaf is what is checked and rendered, and the
    // fields before it are the messages that must be present.
    let mut nested: std::collections::BTreeMap<String, Vec<String>> =
        std::collections::BTreeMap::new();
    for f in part.path_fields.iter() {
        let (via, fld) = resolve_path_field(idx, m, req_msg, f)?;
        if !via.is_empty() {
            nested.insert(f.clone(), via);
        }
        // A path variable is one value, so a repeated one has no expansion.
        if matches!(fld.label, Label::Repeated) {
            return Err(format!(
                "REST method `{}`: path variable `{}` is a `repeated` field; a \
                 path variable takes one value",
                m.name, f
            ));
        }
        // A oneof arm is held in its oneof's storage, not as `req.<field>`,
        // so the URL has no expression to read it through.
        if fld.oneof_index.is_some() {
            return Err(oneof_url_field(m, f));
        }
        // A path variable is read as `req.<field>` itself: a proto3
        // `optional` one is an `Optional`, with no value to put in the path
        // when unset.
        if fld.label == Label::Optional && is_scalar(&fld.ty) {
            return Err(format!(
                "REST method `{}`: path variable `{}` is a proto3 `optional` \
                 field; a path variable takes a value the request always has",
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
        if matches!(&fld.ty, IrType::Enum(_)) {
            enum_fields.insert(f.clone());
        }
    }
    let url_fields = UrlFields { bools: &bool_fields, enums: &enum_fields };
    let items = query_items(m, idx, req_msg, &part.query_fields)?;
    let needs_base64 = items.iter().any(|item| item.any_leaf(&|l| l.kind == LeafKind::Bytes));

    let verb = rule.verb.as_str();
    let has_body = !matches!(part.body, BodyDesignator::None);

    let streaming = is_rest_server_stream(m);
    let ret_ty = if streaming {
        format!("List[{resp_ty}]")
    } else {
        resp_ty.clone()
    };
    w.line(&format!(
        "def {method_name}[RT: Runtime](mut self, req: {req_ty}, \
         mut reactor: Reactor[RT.Sink]) raises -> {ret_ty}:"
    ));
    w.indent();
    let target = if bindings.len() == 1 {
        format!("`{}`", rule.path_template)
    } else {
        bindings
            .iter()
            .map(|(b, _)| format!("`{}`", b.path_template))
            .collect::<Vec<_>>()
            .join(", ")
    };
    if streaming {
        // The whole stream is one HTTP response, a JSON array of responses
        // (`GCP_REST_STREAM_ITEMS`), read to its end before this returns.
        let which = if bindings.len() == 1 {
            ""
        } else {
            ", to the first path the request's values match"
        };
        w.line(&format!(
            "\"\"\"{} {target} — REST/JSON, server-streaming{which}: every response",
            verb.to_uppercase(),
        ));
        w.line("    of the stream, in order, once the stream has ended.\"\"\"");
    } else if bindings.len() == 1 {
        w.line(&format!(
            "\"\"\"{} `{}` — REST/JSON.\"\"\"",
            verb.to_uppercase(),
            rule.path_template
        ));
    } else {
        w.line(&format!(
            "\"\"\"{} {target} — REST/JSON, to the first path the request's values match.\"\"\"",
            verb.to_uppercase(),
        ));
    }
    // No host, no request: refused before the token source is asked and
    // before anything is dialled.
    w.line(&format!("self._rest_require_host(String(\"{method_name}\"))"));

    // A dotted path variable reads through message fields; an unset one
    // leaves the path without its resource name, so the call is refused
    // before the token source is asked.
    for (var, via) in &nested {
        for depth in 1..=via.len() {
            let guard = access_expr(&via[..depth]);
            let unset = via[..depth].join(".");
            w.line(&format!("if not {guard}:"));
            w.indent();
            w.line(&format!(
                "raise Error(String(\"{method_name}: the request's `{unset}` is unset, \
                 and the path is built from `{var}`\"))"
            ));
            w.dedent();
        }
    }

    // -- path substitution ---------------------------------------------------
    if bindings.len() == 1 {
        w.line("var path = String(\"\")");
        emit_path_segments(w, &bindings[0].1, &url_fields);
    } else {
        emit_path_alternatives(w, m, &bindings, &url_fields);
    }

    // -- query params --------------------------------------------------------
    emit_query_build(w, &items);

    w.line("var url: Url");
    w.line("if self._rest_plaintext:");
    w.indent();
    w.line("url = Url.http(self._rest_host.copy(), self._rest_port, path^)");
    w.dedent();
    w.line("else:");
    w.indent();
    w.line("url = Url.https(self._rest_host.copy(), self._rest_port, path^)");
    w.dedent();
    if !items.is_empty() {
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
    if streaming {
        // Each element through the same lenient codec read as a unary
        // response; an error element raises in the core, not here.
        w.line(&format!(
            "var _rest_items = {GCP_REST_STREAM_ITEMS}(String(\"{}\"), String(\"{}\"), status_int, resp_bytes)",
            verb.to_uppercase(),
            m.name
        ));
        w.line(&format!("var _rest_out = List[{resp_ty}]()"));
        w.line("for _rest_item in _rest_items:");
        w.indent();
        w.line(&format!(
            "_rest_out.append(decode_json_lenient[{resp_ty}](_rest_item))"
        ));
        w.dedent();
        w.line("return _rest_out^");
        w.dedent();
        w.blank();
        return Ok(needs_base64);
    }
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
    Ok(needs_base64)
}

/// Emit the path of a method with additional bindings: each binding's path
/// is tried in declaration order, and the first whose variables the
/// request's values match is sent. A binding that does not match raises in
/// `_rest_path_var` / `_rest_path_segment`, which is caught, and the next is
/// tried; when none matches, the method raises naming every template (never
/// a value). A built path is never empty (it starts with `/`), so an empty
/// one means "not matched yet".
fn emit_path_alternatives(
    w: &mut Writer,
    m: &IrMethod,
    bindings: &[(&IrHttpRule, PathTemplate)],
    url_fields: &UrlFields,
) {
    w.line("var path = String(\"\")");
    for (i, (_, template)) in bindings.iter().enumerate() {
        if i > 0 {
            w.line("if path.byte_length() == 0:");
            w.indent();
        }
        // The bare `except` catches only a mismatch: the block is
        // `emit_path_segments`' `path += ...` lines alone, where a String
        // append and `_rest_to_str` / `_rest_bool_str` cannot raise, so the
        // only raises are `_rest_path_var` / `_rest_path_segment` refusing
        // this binding's value (the unit test
        // `a_binding_fallback_catches_only_the_path_helpers` holds this).
        w.line("# Only a path variable that does not match this binding raises here.");
        w.line("try:");
        w.indent();
        emit_path_segments(w, template, url_fields);
        w.dedent();
        w.line("except:");
        w.indent();
        w.line("path = String(\"\")");
        w.dedent();
        if i > 0 {
            w.dedent();
        }
    }
    let paths: Vec<String> = bindings
        .iter()
        .map(|(b, _)| b.path_template.replace('\\', "\\\\").replace('"', "\\\""))
        .collect();
    w.line("if path.byte_length() == 0:");
    w.indent();
    w.line(&format!(
        "raise Error(String(\"REST method {}: the request matches none of its paths: {}\"))",
        m.name,
        paths.join(", ")
    ));
    w.dedent();
}

/// Emit the `path += ...` lines of one template: each literal, each
/// variable filled from its request field, then the `:verb` suffix. The
/// caller declares `path`.
fn emit_path_segments(w: &mut Writer, template: &PathTemplate, url_fields: &UrlFields) {
    // Build the path incrementally so a variable's runtime value is encoded.
    for seg in &template.segments {
        match seg {
            PathSegment::Literal(lit) => {
                w.line(&format!(
                    "path += String(\"/{}\")",
                    percent_encode_simple(lit)
                ));
            }
            PathSegment::Var(var) => {
                let parts: Vec<&str> = var.field.split('.').collect();
                let value = url_fields.render(&access_expr(&parts), &var.field);
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

/// The path variables of one method whose URL rendering is not the generic
/// `_rest_to_str`: its `bool` fields and its enum fields.
struct UrlFields<'a> {
    bools: &'a std::collections::BTreeSet<String>,
    enums: &'a std::collections::BTreeSet<String>,
}

impl UrlFields<'_> {
    /// The Mojo expression that stringifies `expr`, a value of request field
    /// `field`, for the path. A proto `bool` MUST render as proto3-JSON
    /// lowercase `true`/`false` (`_rest_bool_str`); Mojo's generic
    /// `String(Bool)` yields `True`/`False`, which is wrong on the wire. An
    /// enum renders as its value's proto name ([`enum_url_str`]). Every
    /// other scalar uses `_rest_to_str`.
    fn render(&self, expr: &str, field: &str) -> String {
        if self.bools.contains(field) {
            format!("_rest_bool_str({expr})")
        } else if self.enums.contains(field) {
            enum_url_str(expr)
        } else {
            format!("_rest_to_str({expr})")
        }
    }
}

/// An enum value in the URL: its proto name (`json_name()`, the proto3 JSON
/// form, which `google.api.http` reads in a path or query), never its
/// number. The generated enum wrapper is not `Writable`, so `_rest_to_str`
/// would not compile.
fn enum_url_str(expr: &str) -> String {
    format!("{expr}.json_name()")
}

/// The refusal of a URL field (path or query) that is an arm of a oneof.
fn oneof_url_field(m: &IrMethod, f: &str) -> String {
    format!(
        "REST method `{}`: field `{f}` is used in the path/query but is an arm \
         of a oneof, which no URL field reads",
        m.name
    )
}

/// The Mojo expression reading the request field at `path`: `req.name`, or
/// through each singular message field before the last (each an
/// `Optional`, checked present first), `req.service.value().name`.
fn access_expr<S: AsRef<str>>(path: &[S]) -> String {
    let parts: Vec<&str> = path.iter().map(|s| s.as_ref()).collect();
    format!("req.{}", parts.join(".value()."))
}

/// Resolve the path variable `var` of method `m` against its request
/// `req_msg`: the message fields a dotted variable reads through (empty for
/// a plain one) and its leaf field. Each field before the leaf must be a
/// singular, non-oneof message field, held in its own `Optional` (not a
/// recursion box), declared in the generated files.
fn resolve_path_field<'a>(
    idx: MessageIndex<'a>,
    m: &IrMethod,
    req_msg: &'a IrMessage,
    var: &str,
) -> Result<(Vec<String>, &'a IrField), String> {
    let parts: Vec<&str> = var.split('.').collect();
    let mut msg = req_msg;
    let mut via: Vec<String> = Vec::new();
    for (i, part) in parts.iter().enumerate() {
        let fld = msg.fields.iter().find(|f| f.name == *part).ok_or_else(|| {
            format!(
                "REST method `{}`: path variable `{var}` names `{part}`, which is \
                 not a field of `{}`",
                m.name, msg.fq_name
            )
        })?;
        if i + 1 == parts.len() {
            return Ok((via, fld));
        }
        let next = match (&fld.ty, fld.label, fld.oneof_index) {
            (IrType::Message(t), Label::Single | Label::Optional, None) => t,
            _ => {
                return Err(format!(
                    "REST method `{}`: path variable `{var}` reads through `{part}`, \
                     which is not a singular message field outside a oneof",
                    m.name
                ))
            }
        };
        let owner = std::iter::once(idx.file)
            .chain(idx.peers.iter())
            .find(|f| f.messages.iter().any(|x| x.fq_name == msg.fq_name));
        if let Some(owner) = owner {
            if crate::lower::recursion_breaking_edges(owner)
                .contains(&(msg.mojo_name.clone(), fld.name.clone()))
            {
                return Err(format!(
                    "REST method `{}`: path variable `{var}` reads through `{part}`, \
                     a field that closes a message cycle (it is boxed, not an \
                     Optional)",
                    m.name
                ));
            }
        }
        msg = idx.get(&next.fq_name).ok_or_else(|| {
            format!(
                "REST method `{}`: path variable `{var}` reads through `{}`, which \
                 is not declared in the generated files",
                m.name, next.fq_name
            )
        })?;
        via.push(part.to_string());
    }
    unreachable!("a path variable has at least one component")
}

fn emit_query_build(w: &mut Writer, items: &[QueryItem]) {
    if items.is_empty() {
        return;
    }
    w.line("var query = String(\"\")");
    emit_query_items(w, items);
}

fn emit_query_items(w: &mut Writer, items: &[QueryItem]) {
    for item in items {
        match item {
            QueryItem::Leaf(leaf) => emit_query_leaf(w, leaf),
            // A message field: its fields are sent only when it is set, read
            // through a binding named for its field path.
            QueryItem::Nested { access, binding, items } => {
                w.line(&format!("if {access}:"));
                w.indent();
                w.line(&format!("ref {binding} = {access}.value()"));
                emit_query_items(w, items);
                w.dedent();
            }
        }
    }
}

/// Emit one query parameter. The KEY is the field's proto3-JSON `json_name`
/// (lowerCamel), NOT the snake_case proto field name: `google.api.http` maps
/// a query parameter to the field's JSON name, so the emitted key matches the
/// live wire (`includeArchived`, `pageToken`, ...); a field of a message
/// field is `parent.child`. The VALUE is read from the Mojo struct field,
/// which keeps the snake_case proto name.
fn emit_query_leaf(w: &mut Writer, leaf: &QueryLeaf) {
    let acc = &leaf.access;
    let stringify = |expr: &str| match leaf.kind {
        LeafKind::Bool => format!("_rest_bool_str({expr})"),
        LeafKind::Bytes => format!("base64_encode(Span({expr}))"),
        LeafKind::WktString => format!("{expr}.to_proto3_json()"),
        LeafKind::Enum => enum_url_str(expr),
        LeafKind::String | LeafKind::OtherScalar => format!("_rest_to_str({expr})"),
    };
    // An `Optional[T]` field reads through `.value()` INSIDE its presence
    // check; a repeated one appends its key once per element, in order
    // (`?resourceNames=a&resourceNames=b`); a plain field reads directly.
    let (guard, value_expr) = match leaf.label {
        Label::Optional => (Some(format!("if {acc}:")), stringify(&format!("{acc}.value()"))),
        Label::Repeated => (Some(format!("for _rest_v in {acc}:")), stringify("_rest_v")),
        // An implicit-presence scalar or enum at its default is omitted, as
        // the proto3 JSON mapping omits it: no `pageToken=` on a first page,
        // no `view=VIEW_UNSPECIFIED` when the caller set no view.
        Label::Single => {
            let guard = match leaf.kind {
                LeafKind::String => Some(format!("if {acc}.byte_length() > 0:")),
                LeafKind::Bool => Some(format!("if {acc}:")),
                LeafKind::Bytes => Some(format!("if len({acc}) > 0:")),
                LeafKind::OtherScalar => Some(format!("if {acc} != 0:")),
                LeafKind::Enum => Some(format!("if {acc}.number() != 0:")),
                LeafKind::WktString => None,
            };
            (guard, stringify(acc))
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
        percent_encode_simple(&leaf.key),
        value_expr
    ));
    if guard.is_some() {
        w.dedent();
    }
}

/// Emit the JSON-body build. For `body: "*"` the whole `req` serializes, less
/// the fields its path binds: `google/api/http.proto` defines that body as
/// every field *not* bound by the path template, so a field the URL carries is
/// left out of the body (`_rest_drop_members`). For a named field the single
/// field's message serializes. Both go through
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
        BodyDesignator::Whole if part.path_fields.is_empty() => {
            w.line("var body_text = encode_json(req)");
        }
        BodyDesignator::Whole => {
            // The members are dropped from the encoded text by JSON name, so
            // every other value keeps the codec's exact rendering.
            let mut names = Vec::new();
            for f in &part.path_fields {
                // The members are dropped by their top-level name; a dotted
                // path field is a member of a body message, which this does
                // not reach.
                if f.contains('.') {
                    return Err(format!(
                        "REST body `*` with the dotted path variable `{f}`: a \
                         whole-request body leaves out the fields its path binds, \
                         and a field of a body message cannot be left out"
                    ));
                }
                let fld = req_msg
                    .fields
                    .iter()
                    .find(|x| &x.name == f)
                    .expect("partition field came from the message");
                names.push(format!(
                    "String(\"{}\")",
                    fld.json_name.replace('\\', "\\\\").replace('"', "\\\"")
                ));
            }
            w.line(&format!(
                "var _rest_path_members: List[String] = [{}]",
                names.join(", ")
            ));
            w.line(
                "var body_text = _rest_drop_members(encode_json(req), _rest_path_members)",
            );
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


def _rest_drop_members(json: String, names: List[String]) raises -> String:
    """`json` without its top-level members whose key is in `names`: the
    `body: "*"` of a method whose path binds fields, which
    `google/api/http.proto` defines as every field the path does not bind.
    `json` is an object as `encode_json` writes it, with no whitespace; each
    kept member is copied byte for byte, so no value is rendered again. An
    error never echoes the text."""
    var b = json.as_bytes()
    var n = len(b)
    if n < 2 or b[0] != 0x7B or b[n - 1] != 0x7D:
        raise Error(String("REST body is not a JSON object"))
    var out = List[UInt8](capacity=n)
    out.append(0x7B)  # '{'
    var kept = 0
    var i = 1
    while i < n - 1:
        var start = i
        # The key: a JSON string, its escapes skipped.
        if b[i] != 0x22:
            raise Error(String("REST body member has no key"))
        var k = i + 1
        while k < n - 1 and b[k] != 0x22:
            if b[k] == 0x5C:
                k += 1
            k += 1
        if k + 1 >= n - 1 or b[k] != 0x22 or b[k + 1] != 0x3A:
            raise Error(String("REST body member has no key"))
        var drop = False
        for name in names:
            var nb = name.as_bytes()
            if len(nb) == k - i - 1:
                var same = True
                var t = 0
                while same and t < len(nb):
                    same = nb[t] == b[i + 1 + t]
                    t += 1
                if same:
                    drop = True
        # The value: up to the `,` at this depth, or the closing `}`.
        var depth = 0
        var in_str = False
        var j = k + 2
        while j < n - 1:
            var c = b[j]
            if in_str:
                if c == 0x5C:
                    j += 1
                elif c == 0x22:
                    in_str = False
            elif c == 0x22:
                in_str = True
            elif c == 0x7B or c == 0x5B:
                depth += 1
            elif c == 0x7D or c == 0x5D:
                depth -= 1
            elif c == 0x2C and depth == 0:
                break
            j += 1
        if in_str or depth != 0 or j > n - 1:
            raise Error(String("REST body member has an unterminated value"))
        if not drop:
            if kept > 0:
                out.append(0x2C)  # ','
            var x = start
            while x < j:
                out.append(b[x])
                x += 1
            kept += 1
        i = j + 1
    out.append(0x7D)  # '}'
    return String(unsafe_from_utf8=Span(out))


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
            host_from_service_config: false,
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
            host_from_service_config: false,
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
                    additional_bindings: vec![],
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
            host_from_service_config: false,
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
                    additional_bindings: vec![],
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

    fn stream_method(
        client_streaming: bool,
        server_streaming: bool,
        annotated: bool,
    ) -> (IrFile, IrService) {
        let req = IrMessage {
            name: "Req".into(),
            mojo_name: "Req".into(),
            fq_name: ".tiny.rest.v1.Req".into(),
            is_map_entry: false,
            fields: vec![scalar_field("parent", ScalarKind::String)],
            oneofs: vec![],
        };
        let ty = TypeRef { fq_name: ".tiny.rest.v1.Req".into(), mojo_name: "Req".into() };
        let svc = IrService {
            name: "Svc".into(),
            default_host: None,
            host_from_service_config: false,
            methods: vec![IrMethod {
                name: "RunQuery".into(),
                input: ty.clone(),
                output: ty,
                client_streaming,
                server_streaming,
                idempotent: false,
                http_rule: annotated.then(|| IrHttpRule {
                    verb: "post".into(),
                    path_template: "/v1/{parent=projects/*}:runQuery".into(),
                    body: "*".into(),
                    additional_bindings: vec![],
                }),
                routing_rule: None,
            }],
        };
        (file_with(vec![req], svc.clone()), svc)
    }

    #[test]
    fn server_streaming_method_reads_the_array_through_the_core() {
        let (file, svc) = stream_method(false, true, true);
        let emit = emit_rest_service(&file, &svc).unwrap();
        let src = &emit.source;
        assert!(
            src.contains("mut reactor: Reactor[RT.Sink]) raises -> List[Req]:"),
            "{src}"
        );
        // The no-host refusal comes first, as for a unary method.
        let guard = src.find("self._rest_require_host(String(\"run_query\"))").unwrap();
        // The status line is checked first, as for a unary method.
        let status = src.find("if status_int < 200 or status_int >= 300:").unwrap();
        let items = src
            .find("var _rest_items = gcp_rest_stream_items(String(\"POST\"), String(\"RunQuery\"), status_int, resp_bytes)")
            .unwrap();
        assert!(guard < status && status < items);
        assert!(src.contains("_rest_out.append(decode_json_lenient[Req](_rest_item))"));
        assert!(src.contains("return _rest_out^"));
        // No unary decode of the whole body.
        assert!(!src.contains("return decode_json_lenient[Req](resp_text)"));
        assert_eq!(
            rest_stream_import(&file).as_deref(),
            Some("from komira_gcp_core import gcp_rest_stream_items")
        );
    }

    #[test]
    fn a_file_without_a_stream_method_imports_no_stream_reader() {
        let (file, _) = stream_method(false, false, true);
        assert_eq!(rest_stream_import(&file), None);
    }

    #[test]
    fn client_streaming_and_bidi_methods_are_refused_by_name() {
        // Annotated or not: the shape is the reason it has no REST form, and
        // an annotation would not give it one.
        for annotated in [true, false] {
            for (server, shape) in [(false, "client-streaming"), (true, "bidirectional-streaming")] {
                let (file, svc) = stream_method(true, server, annotated);
                let err = emit_rest_service(&file, &svc).unwrap_err();
                assert!(
                    err.contains(&format!("service `Svc` method `RunQuery` is {shape}")),
                    "{err}"
                );
                assert!(err.contains("drop it from `methods`"), "{err}");
                assert!(err.contains("`default_protocol=grpc`"), "{err}");
                assert_eq!(rest_stream_import(&file), None);
            }
        }
    }

    #[test]
    fn unannotated_server_streaming_method_is_refused_for_its_annotation() {
        // A server-streaming method has a REST form, so what it lacks is the
        // `(google.api.http)` rule, and that is what the refusal names.
        let (file, svc) = stream_method(false, true, false);
        let err = emit_rest_service(&file, &svc).unwrap_err();
        assert!(
            err.contains("method `RunQuery` has no `(google.api.http)` annotation"),
            "{err}"
        );
    }

    fn with_host(host: Option<&str>) -> Result<RestServiceEmit, String> {
        with_host_in("tiny.rest.v1", host, false)
    }

    fn with_host_in(
        package: &str,
        host: Option<&str>,
        from_config: bool,
    ) -> Result<RestServiceEmit, String> {
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
            host_from_service_config: from_config,
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
                    additional_bindings: vec![],
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
        assert!(guard < body.find("var url").unwrap());
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
        let err = with_host_in("", Some("https://logging.googleapis.com"), false).unwrap_err();
        assert!(
            err.contains("service `Logging` declares `(google.api.default_host)`"),
            "{err}"
        );
    }

    #[test]
    fn a_host_from_the_service_configuration_is_named_as_such() {
        let e = with_host_in("tiny.rest.v1", Some("api.googleapis.com"), true).unwrap();
        assert_eq!(
            e.source.matches("self._rest_host = String(\"api.googleapis.com\")").count(),
            2
        );
        assert!(e.source.contains(
            "    target and the `Host:` header. Starts at the API's service\n\
             \x20       configuration `name`, `api.googleapis.com`; `set_rest_host` replaces it.\"\"\""
        ));
        assert!(e.source.contains(
            "no REST host: the host was set empty (the API's service configuration name is \
             api.googleapis.com); call set_rest_host(host) with a host before sending"
        ));
        assert!(!e.source.contains("default_host"), "{}", e.source);
        let err = with_host_in("tiny.rest.v1", Some("api.googleapis.com:8443"), true).unwrap_err();
        assert_eq!(
            err,
            "service `tiny.rest.v1.Logging` starts at its service configuration's `name`, \
             \"api.googleapis.com:8443\", which is not a host name (optionally `:443`): a REST \
             client sends to it over HTTPS on the default port"
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
            host_from_service_config: false,
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
                    additional_bindings: vec![],
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
            host_from_service_config: false,
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
                    additional_bindings: vec![],
                }),
                routing_rule: None,
            }],
        };
        let file = file_with(vec![req, out], svc.clone());
        let emit = emit_rest_service(&file, &svc).unwrap();
        // `shelf` is in the path, so it is not in the body: the body is
        // every field the path does not bind (google/api/http.proto).
        assert!(!emit.source.contains("var body_text = encode_json(req)\n"));
        assert!(emit
            .source
            .contains("var _rest_path_members: List[String] = [String(\"shelf\")]"));
        assert!(emit.source.contains(
            "var body_text = _rest_drop_members(encode_json(req), _rest_path_members)"
        ));
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
            host_from_service_config: false,
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
                    additional_bindings: vec![],
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
            host_from_service_config: false,
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
                    additional_bindings: vec![],
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
            host_from_service_config: false,
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
                    additional_bindings: vec![],
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
            host_from_service_config: false,
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
                    additional_bindings: vec![],
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
            host_from_service_config: false,
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
                    additional_bindings: vec![],
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
            host_from_service_config: false,
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
                    additional_bindings: vec![],
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
        // No field in the path: the whole request is the body.
        assert!(e.source.contains("var body_text = encode_json(req)\n"), "{}", e.source);
        assert!(!e.source.contains("_rest_path_members"), "{}", e.source);
    }

    #[test]
    fn a_whole_body_leaves_out_every_path_field_by_its_json_name() {
        let mut user = scalar_field("user_id", ScalarKind::String);
        user.json_name = "userId".into();
        let e = one_method(
            vec![scalar_field("shelf", ScalarKind::String), user, scalar_field("note", ScalarKind::String)],
            "post",
            "/v1/shelves/{shelf}/users/{user_id}:grant",
            "*",
        )
        .unwrap();
        assert!(e.source.contains(
            "var _rest_path_members: List[String] = [String(\"shelf\"), String(\"userId\")]\n"
        ), "{}", e.source);
        assert!(e.source.contains(
            "var body_text = _rest_drop_members(encode_json(req), _rest_path_members)\n"
        ), "{}", e.source);
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

    /// A service whose one method takes `.tiny.rest.v1.GetReq`, declared in
    /// `messages.proto` of the same package (not the service's file) and
    /// referenced through that file's module, as the lowering names a
    /// cross-file type.
    fn split_service() -> (IrFile, IrFile, IrService) {
        let req = msg_in(
            "tiny.rest.v1",
            "GetReq",
            vec![scalar_field("name", ScalarKind::String), scalar_field("view", ScalarKind::String)],
        );
        let ty = TypeRef { fq_name: ".tiny.rest.v1.GetReq".into(), mojo_name: "messages.GetReq".into() };
        let svc = IrService {
            name: "Svc".into(),
            default_host: None,
            host_from_service_config: false,
            methods: vec![IrMethod {
                name: "Get".into(),
                input: ty.clone(),
                output: ty,
                client_streaming: false,
                server_streaming: false,
                idempotent: false,
                http_rule: Some(rule("get", "/v1/{name=things/*}", "", &[])),
                routing_rule: None,
            }],
        };
        let service_file = file_with(vec![], svc.clone());
        let mut messages_file = file_with(vec![req], svc.clone());
        messages_file.proto_path = "messages.proto".into();
        messages_file.services = vec![];
        (service_file, messages_file, svc)
    }

    #[test]
    fn a_request_declared_in_another_file_of_the_same_package_is_found() {
        // The peers are every file of the model, the service's own among
        // them, as `emit_model_with_options` passes them.
        let (service_file, messages_file, svc) = split_service();
        let peers = vec![service_file.clone(), messages_file];
        let src = emit_rest_service_in(&service_file, &peers, &svc).unwrap().source;
        assert!(src.contains("req: messages.GetReq,"), "{src}");
        assert!(src.contains("_rest_path_var(_rest_to_str(req.name), String(\"things/*\"), String(\"name\"))"), "{src}");
        assert!(src.contains("query += String(\"view=\") + _rest_pct_encode(_rest_to_str(req.view))"), "{src}");
        // Without the declaring file, the request is refused by name.
        let err = emit_rest_service_in(&service_file, std::slice::from_ref(&service_file), &svc).unwrap_err();
        assert!(
            err.contains("REST method `Get`: request type `.tiny.rest.v1.GetReq` is not declared in the generated files"),
            "{err}"
        );
    }

    fn enum_field(name: &str) -> IrField {
        IrField {
            name: name.to_string(),
            ty: IrType::Enum(TypeRef {
                fq_name: ".tiny.rest.v1.View".into(),
                mojo_name: "View".into(),
            }),
            label: Label::Single,
            proto_field_number: 2,
            json_name: name.to_string(),
            oneof_index: None,
        }
    }

    #[test]
    fn an_enum_in_the_url_renders_its_proto_name() {
        // The enum wrapper is not `Writable`: `_rest_to_str(req.view)` would
        // not compile. A plain, an optional and a repeated enum query field,
        // and an enum path variable, all render through `json_name()`.
        let mut optional = enum_field("mode");
        optional.label = Label::Optional;
        let fields = vec![
            scalar_field("name", ScalarKind::String),
            enum_field("view"),
            optional,
            repeated(enum_field("kinds")),
            enum_field("tier"),
        ];
        let src = one_method(fields, "get", "/v1/{name=things/*}/tiers/{tier}", "").unwrap().source;
        // A plain enum at its zero value stays out of the query; an optional
        // one is sent whenever it is set, and a path variable always is.
        assert!(src.contains("if req.view.number() != 0:"), "{src}");
        assert!(!src.contains("if req.mode.number()"), "{src}");
        assert!(!src.contains("if req.tier.number()"), "{src}");
        assert!(src.contains("query += String(\"view=\") + _rest_pct_encode(req.view.json_name())"), "{src}");
        assert!(src.contains("query += String(\"mode=\") + _rest_pct_encode(req.mode.value().json_name())"), "{src}");
        assert!(src.contains("query += String(\"kinds=\") + _rest_pct_encode(_rest_v.json_name())"), "{src}");
        assert!(src.contains("path += _rest_path_segment(req.tier.json_name(), String(\"tier\"))"), "{src}");
        assert!(!src.contains("_rest_to_str(req.view)"), "{src}");
    }

    #[test]
    fn an_enum_of_a_message_query_field_renders_its_proto_name() {
        // A nested leaf goes through the same rendering as a top-level one.
        let opts = msg_in("tiny.rest.v1", "Opts", vec![enum_field("view")]);
        let req = msg_in(
            "tiny.rest.v1",
            "Req",
            vec![
                scalar_field("name", ScalarKind::String),
                msg_field("options", ".tiny.rest.v1.Opts", "Opts"),
            ],
        );
        let svc = svc_over(&req, rule("get", "/v1/{name=things/*}", "", &[]));
        let file = file_with(vec![req, opts], svc.clone());
        let src = emit_rest_service(&file, &svc).unwrap().source;
        assert!(src.contains("if _rest_options.view.number() != 0:"), "{src}");
        assert!(src.contains(
            "query += String(\"options.view=\") + _rest_pct_encode(_rest_options.view.json_name())"
        ), "{src}");
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
    fn an_endpoint_override_sets_host_port_and_scheme() {
        let e = one_method(vec![], "post", "/v2/entries:list", "*").unwrap();
        let src = &e.source;
        assert!(src.contains(
            "def set_rest_endpoint(mut self, var host: String, port: UInt16, plaintext: Bool):"
        ));
        // The public endpoint's defaults, in both constructors.
        assert_eq!(src.matches("self._rest_port = UInt16(0)").count(), 2);
        assert_eq!(src.matches("self._rest_plaintext = False").count(), 2);
        let http = src
            .find("url = Url.http(self._rest_host.copy(), self._rest_port, path^)")
            .unwrap();
        let https = src
            .find("url = Url.https(self._rest_host.copy(), self._rest_port, path^)")
            .unwrap();
        let branch = src.find("if self._rest_plaintext:").unwrap();
        assert!(branch < http && http < https, "{src}");
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
    fn bytes_field_in_the_path_is_refused() {
        let err = one_method(vec![scalar_field("blob", ScalarKind::Bytes)], "get", "/v2/{blob}", "")
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

    /// A message `name` of package `pkg` with `fields`.
    fn msg_in(pkg: &str, name: &str, fields: Vec<IrField>) -> IrMessage {
        IrMessage {
            name: name.into(),
            mojo_name: name.into(),
            fq_name: format!(".{pkg}.{name}"),
            is_map_entry: false,
            fields,
            oneofs: vec![],
        }
    }

    /// A service `Svc` with one method `M` taking `req` (by fq-name) under
    /// `rule`.
    fn svc_over(req: &IrMessage, rule: IrHttpRule) -> IrService {
        let ty = TypeRef { fq_name: req.fq_name.clone(), mojo_name: req.mojo_name.clone() };
        IrService {
            name: "Svc".into(),
            default_host: None,
            host_from_service_config: false,
            methods: vec![IrMethod {
                name: "M".into(),
                input: ty.clone(),
                output: ty,
                client_streaming: false,
                server_streaming: false,
                idempotent: false,
                http_rule: Some(rule),
                routing_rule: None,
            }],
        }
    }

    fn rule(verb: &str, path: &str, body: &str, more: &[&str]) -> IrHttpRule {
        IrHttpRule {
            verb: verb.into(),
            path_template: path.into(),
            body: body.into(),
            additional_bindings: more
                .iter()
                .map(|p| IrHttpRule {
                    verb: verb.into(),
                    path_template: (*p).into(),
                    body: body.into(),
                    additional_bindings: vec![],
                })
                .collect(),
        }
    }

    /// A file of package `tiny.rest.v1` holding `svc` and no messages.
    fn service_file(svc: IrService) -> IrFile {
        file_with(vec![], svc)
    }

    #[test]
    fn a_request_declared_in_another_file_is_found_among_the_peers() {
        let req = msg_in(
            "google.iam.v1",
            "GetIamPolicyRequest",
            vec![scalar_field("resource", ScalarKind::String)],
        );
        let svc = svc_over(&req, rule("post", "/v3/{resource=projects/*}:getIamPolicy", "*", &[]));
        let file = service_file(svc.clone());
        let peer = IrFile {
            proto_path: "google/iam/v1/iam_policy.proto".into(),
            proto_package: "google.iam.v1".into(),
            mojo_package: "komira_rpc_storage".into(),
            messages: vec![req],
            enums: vec![],
            services: vec![],
            imports: vec![],
        };
        // Alone, the file does not declare it, and the error says what to add.
        let err = emit_rest_service(&file, &svc).unwrap_err();
        assert!(err.contains("is not declared in the generated files"), "{err}");
        let peers = vec![peer];
        let e = emit_rest_service_in(&file, &peers, &svc).unwrap();
        assert!(e.source.contains(
            "def m[RT: Runtime](mut self, req: GetIamPolicyRequest, mut reactor: Reactor[RT.Sink]) raises -> GetIamPolicyRequest:"
        ), "{}", e.source);
        assert!(e.source.contains(
            "path += _rest_path_var(_rest_to_str(req.resource), String(\"projects/*\"), String(\"resource\"))"
        ));
        assert!(e.source.contains("path += String(\":getIamPolicy\")"));
        assert!(!e.needs_base64);
    }

    #[test]
    fn additional_bindings_are_tried_in_order_and_none_matching_raises() {
        let req = msg_in("tiny.rest.v1", "Req", vec![scalar_field("name", ScalarKind::String)]);
        let svc = svc_over(
            &req,
            rule("get", "/v1/{name=roles/*}", "", &["/v1/{name=organizations/*/roles/*}", "/v1/{name=projects/*/roles/*}"]),
        );
        let file = file_with(vec![req], svc.clone());
        let e = emit_rest_service(&file, &svc).unwrap();
        let src = &e.source;
        assert!(src.contains(
            "\"\"\"GET `/v1/{name=roles/*}`, `/v1/{name=organizations/*/roles/*}`, `/v1/{name=projects/*/roles/*}` — REST/JSON, to the first path the request's values match.\"\"\""
        ), "{src}");
        let first = src.find("String(\"roles/*\")").expect("first binding");
        let second = src.find("String(\"organizations/*/roles/*\")").expect("second binding");
        let third = src.find("String(\"projects/*/roles/*\")").expect("third binding");
        assert!(first < second && second < third, "{src}");
        // Each later binding runs only when the ones before it matched nothing,
        // and a binding that raises leaves no partial path behind.
        assert_eq!(src.matches("if path.byte_length() == 0:").count(), 3, "{src}");
        assert_eq!(src.matches("except:\n").count(), 3, "{src}");
        assert_eq!(src.matches("    path = String(\"\")\n").count(), 3, "{src}");
        assert!(src.contains(
            "raise Error(String(\"REST method M: the request matches none of its paths: /v1/{name=roles/*}, /v1/{name=organizations/*/roles/*}, /v1/{name=projects/*/roles/*}\"))"
        ), "{src}");
    }

    #[test]
    fn a_server_streaming_method_takes_bindings_and_a_whole_body_like_a_unary_one() {
        // The two halves of the REST method emitter meet here: a
        // server-streaming method (Firestore's RunQuery shape) whose rule has
        // an additional binding and `body: "*"` gets the path alternatives
        // and the whole body without its path-bound field, and still reads
        // its response as the stream's JSON array.
        let req = msg_in(
            "tiny.rest.v1",
            "Req",
            vec![scalar_field("parent", ScalarKind::String), scalar_field("q", ScalarKind::String)],
        );
        let mut svc = svc_over(
            &req,
            rule(
                "post",
                "/v1/{parent=projects/*/databases/*/documents}:runQuery",
                "*",
                &["/v1/{parent=projects/*/databases/*/documents/*/**}:runQuery"],
            ),
        );
        svc.methods[0].server_streaming = true;
        let file = file_with(vec![req], svc.clone());
        let e = emit_rest_service(&file, &svc).unwrap();
        let src = &e.source;
        assert!(src.contains("mut reactor: Reactor[RT.Sink]) raises -> List[Req]:"), "{src}");
        assert!(src.contains(
            "\"\"\"POST `/v1/{parent=projects/*/databases/*/documents}:runQuery`, \
             `/v1/{parent=projects/*/databases/*/documents/*/**}:runQuery` — REST/JSON, \
             server-streaming, to the first path the request's values match: every response\n"
        ), "{src}");
        assert_eq!(src.matches("if path.byte_length() == 0:").count(), 2, "{src}");
        assert!(src.contains(
            "var body_text = _rest_drop_members(encode_json(req), _rest_path_members)\n"
        ), "{src}");
        let items = src
            .find("var _rest_items = gcp_rest_stream_items(String(\"POST\"), String(\"M\"), status_int, resp_bytes)")
            .unwrap();
        assert!(src.find("_rest_drop_members(").unwrap() < items, "{src}");
        assert!(!src.contains("return decode_json_lenient[Req](resp_text)"), "{src}");
        assert!(!e.needs_base64);
    }

    #[test]
    fn a_binding_fallback_catches_only_the_path_helpers() {
        // The generated `except:` is bare, which is sound only while the
        // `try:` block holds nothing that can raise but the two path helpers
        // refusing a value: each line is a `path +=` of a literal, of
        // `_rest_path_var(...)` or of `_rest_path_segment(...)`.
        let req = msg_in(
            "tiny.rest.v1",
            "Req",
            vec![scalar_field("name", ScalarKind::String), scalar_field("flag", ScalarKind::Bool)],
        );
        let svc = svc_over(
            &req,
            rule("get", "/v1/{name=roles/*}/{flag}", "", &["/v1/{name=projects/*/roles/*}/{flag}:x"]),
        );
        let file = file_with(vec![req], svc.clone());
        let src = emit_rest_service(&file, &svc).unwrap().source;
        let lines: Vec<&str> = src.lines().collect();
        let mut blocks = 0;
        let mut i = 0;
        while i < lines.len() {
            if lines[i].trim() == "try:" {
                blocks += 1;
                let indent = lines[i].len() - lines[i].trim_start().len();
                i += 1;
                while lines[i].trim() != "except:" {
                    let l = lines[i].trim();
                    assert!(lines[i].len() - lines[i].trim_start().len() > indent, "{src}");
                    let ok = l.starts_with("path += String(\"")
                        || l.starts_with("path += _rest_path_var(")
                        || l.starts_with("path += _rest_path_segment(");
                    assert!(ok, "a line that may raise otherwise: {l}\n{src}");
                    i += 1;
                }
            }
            i += 1;
        }
        assert_eq!(blocks, 2, "{src}");
        // The helpers are called on `_rest_to_str` / `_rest_bool_str`, neither
        // of which raises.
        let helpers = rest_helper_functions();
        assert!(helpers.contains("def _rest_to_str[T: Writable](v: T) -> String:"));
        assert!(helpers.contains("def _rest_bool_str(b: Bool) -> String:"));
        assert!(src.contains("_rest_path_segment(_rest_bool_str(req.flag), String(\"flag\"))"), "{src}");
    }

    #[test]
    fn a_binding_with_another_verb_body_or_variables_is_refused() {
        let req = msg_in(
            "tiny.rest.v1",
            "Req",
            vec![scalar_field("name", ScalarKind::String), scalar_field("parent", ScalarKind::String)],
        );
        let mut verb = rule("get", "/v1/{name=a/*}", "", &[]);
        verb.additional_bindings.push(IrHttpRule {
            verb: "post".into(),
            path_template: "/v1/{name=b/*}".into(),
            body: "".into(),
            additional_bindings: vec![],
        });
        let mut body = rule("post", "/v1/{name=a/*}", "*", &[]);
        body.additional_bindings.push(IrHttpRule {
            verb: "post".into(),
            path_template: "/v1/{name=b/*}".into(),
            body: "".into(),
            additional_bindings: vec![],
        });
        let vars = rule("get", "/v1/{name=a/*}", "", &["/v1/{parent=b/*}"]);
        for (r, want) in [(verb, "share them"), (body, "share them"), (vars, "bind the same")] {
            let svc = svc_over(&req, r);
            let file = file_with(vec![req.clone()], svc.clone());
            let err = emit_rest_service(&file, &svc).unwrap_err();
            assert!(err.contains(want), "{err}");
        }
    }

    #[test]
    fn a_message_query_field_is_sent_as_its_fields_when_set() {
        // IAM's GetIamPolicy: no body, so `options` rides the query as
        // `options.requestedPolicyVersion`.
        let mut version = scalar_field("requested_policy_version", ScalarKind::Int32);
        version.json_name = "requestedPolicyVersion".into();
        let opts = msg_in("google.iam.v1", "GetPolicyOptions", vec![version]);
        let req = msg_in(
            "google.iam.v1",
            "GetIamPolicyRequest",
            vec![
                scalar_field("resource", ScalarKind::String),
                msg_field("options", ".google.iam.v1.GetPolicyOptions", "GetPolicyOptions"),
            ],
        );
        let svc = svc_over(
            &req,
            rule("post", "/v1/{resource=projects/*/serviceAccounts/*}:getIamPolicy", "", &[]),
        );
        let file = file_with(vec![req, opts], svc.clone());
        let e = emit_rest_service(&file, &svc).unwrap();
        assert!(e.source.contains(
            "        if req.options:\n            ref _rest_options = req.options.value()\n            if _rest_options.requested_policy_version != 0:\n"
        ), "{}", e.source);
        assert!(e.source.contains(
            "query += String(\"options.requestedPolicyVersion=\") + _rest_pct_encode(_rest_to_str(_rest_options.requested_policy_version))"
        ));
        assert!(e.source.contains("url.query = query^"));
    }

    #[test]
    fn a_field_mask_query_field_is_its_json_string() {
        let mut mask = msg_field("update_mask", ".google.protobuf.FieldMask", "FieldMask");
        mask.json_name = "updateMask".into();
        let req = msg_in(
            "tiny.rest.v1",
            "Req",
            vec![scalar_field("name", ScalarKind::String), mask, msg_field("role", ".tiny.rest.v1.Role", "Role")],
        );
        let role = msg_in("tiny.rest.v1", "Role", vec![scalar_field("title", ScalarKind::String)]);
        let svc = svc_over(&req, rule("patch", "/v1/{name=projects/*/roles/*}", "role", &[]));
        let file = file_with(vec![req, role], svc.clone());
        let e = emit_rest_service(&file, &svc).unwrap();
        assert!(e.source.contains("if req.update_mask:"), "{}", e.source);
        assert!(e.source.contains(
            "query += String(\"updateMask=\") + _rest_pct_encode(req.update_mask.value().to_proto3_json())"
        ), "{}", e.source);
    }

    fn named(mut f: IrField, json: &str, number: u32) -> IrField {
        f.json_name = json.into();
        f.proto_field_number = number;
        f
    }

    #[test]
    fn timestamp_and_duration_query_fields_are_their_json_strings() {
        let req = msg_in(
            "tiny.rest.v1",
            "Req",
            vec![
                msg_field("at", ".google.protobuf.Timestamp", "Timestamp"),
                named(msg_field("max_age", ".google.protobuf.Duration", "Duration"), "maxAge", 2),
            ],
        );
        let svc = svc_over(&req, rule("get", "/v1/x", "", &[]));
        let file = file_with(vec![req], svc.clone());
        let e = emit_rest_service(&file, &svc).unwrap();
        assert!(e.source.contains(
            "        if req.at:\n            if query.byte_length() > 0:\n                query += String(\"&\")\n            query += String(\"at=\") + _rest_pct_encode(req.at.value().to_proto3_json())\n"
        ), "{}", e.source);
        assert!(e.source.contains(
            "        if req.max_age:\n            if query.byte_length() > 0:\n                query += String(\"&\")\n            query += String(\"maxAge=\") + _rest_pct_encode(req.max_age.value().to_proto3_json())\n"
        ), "{}", e.source);
    }

    /// Cloud Monitoring's `ListTimeSeriesRequest`, cut to what its query
    /// carries: `interval` (two Timestamps, `end_time` declared first) and
    /// `aggregation` (a Duration, an enum and a repeated string).
    fn list_time_series() -> Result<RestServiceEmit, String> {
        let interval = msg_in(
            "google.monitoring.v3",
            "TimeInterval",
            vec![
                named(msg_field("end_time", ".google.protobuf.Timestamp", "Timestamp"), "endTime", 2),
                named(msg_field("start_time", ".google.protobuf.Timestamp", "Timestamp"), "startTime", 1),
            ],
        );
        let mut groups = named(scalar_field("group_by_fields", ScalarKind::String), "groupByFields", 5);
        groups.label = Label::Repeated;
        let aggregation = msg_in(
            "google.monitoring.v3",
            "Aggregation",
            vec![
                named(msg_field("alignment_period", ".google.protobuf.Duration", "Duration"), "alignmentPeriod", 1),
                named(enum_field("per_series_aligner"), "perSeriesAligner", 2),
                groups,
            ],
        );
        let req = msg_in(
            "google.monitoring.v3",
            "ListTimeSeriesRequest",
            vec![
                scalar_field("name", ScalarKind::String),
                scalar_field("filter", ScalarKind::String),
                msg_field("interval", ".google.monitoring.v3.TimeInterval", "TimeInterval"),
                msg_field("aggregation", ".google.monitoring.v3.Aggregation", "Aggregation"),
            ],
        );
        let svc = svc_over(&req, rule("get", "/v3/{name=projects/*}/timeSeries", "", &[]));
        let file = file_with(vec![req, interval, aggregation], svc.clone());
        emit_rest_service(&file, &svc)
    }

    #[test]
    fn a_message_holding_well_known_types_is_flattened_to_dotted_json_names() {
        let e = list_time_series().unwrap();
        let want = concat!(
            "        if req.interval:\n",
            "            ref _rest_interval = req.interval.value()\n",
            "            if _rest_interval.end_time:\n",
            "                if query.byte_length() > 0:\n",
            "                    query += String(\"&\")\n",
            "                query += String(\"interval.endTime=\") + _rest_pct_encode(_rest_interval.end_time.value().to_proto3_json())\n",
            "            if _rest_interval.start_time:\n",
            "                if query.byte_length() > 0:\n",
            "                    query += String(\"&\")\n",
            "                query += String(\"interval.startTime=\") + _rest_pct_encode(_rest_interval.start_time.value().to_proto3_json())\n",
            "        if req.aggregation:\n",
            "            ref _rest_aggregation = req.aggregation.value()\n",
            "            if _rest_aggregation.alignment_period:\n",
            "                if query.byte_length() > 0:\n",
            "                    query += String(\"&\")\n",
            "                query += String(\"aggregation.alignmentPeriod=\") + _rest_pct_encode(_rest_aggregation.alignment_period.value().to_proto3_json())\n",
            "            if _rest_aggregation.per_series_aligner.number() != 0:\n",
        );
        assert!(e.source.contains(want), "{}", e.source);
        assert!(e.source.contains(
            "                query += String(\"aggregation.perSeriesAligner=\") + _rest_pct_encode(_rest_aggregation.per_series_aligner.json_name())\n"
        ), "{}", e.source);
        assert!(e.source.contains(
            "            for _rest_v in _rest_aggregation.group_by_fields:\n"
        ), "{}", e.source);
        assert!(e.source.contains(
            "query += String(\"aggregation.groupByFields=\") + _rest_pct_encode(_rest_to_str(_rest_v))"
        ), "{}", e.source);
    }

    #[test]
    fn a_message_two_levels_down_is_bound_by_its_whole_path() {
        let leaf = msg_in("tiny.rest.v1", "Leaf", vec![named(scalar_field("max_items", ScalarKind::Int32), "maxItems", 1)]);
        let mid = msg_in(
            "tiny.rest.v1",
            "Mid",
            vec![named(msg_field("leaf_opts", ".tiny.rest.v1.Leaf", "Leaf"), "leafOpts", 1)],
        );
        let req = msg_in("tiny.rest.v1", "Req", vec![msg_field("mid", ".tiny.rest.v1.Mid", "Mid")]);
        let svc = svc_over(&req, rule("get", "/v1/x", "", &[]));
        let file = file_with(vec![req, mid, leaf], svc.clone());
        let e = emit_rest_service(&file, &svc).unwrap();
        let want = concat!(
            "        if req.mid:\n",
            "            ref _rest_mid = req.mid.value()\n",
            "            if _rest_mid.leaf_opts:\n",
            "                ref _rest_mid__leaf_opts = _rest_mid.leaf_opts.value()\n",
            "                if _rest_mid__leaf_opts.max_items != 0:\n",
            "                    if query.byte_length() > 0:\n",
            "                        query += String(\"&\")\n",
            "                    query += String(\"mid.leafOpts.maxItems=\") + _rest_pct_encode(_rest_to_str(_rest_mid__leaf_opts.max_items))\n",
        );
        assert!(e.source.contains(want), "{}", e.source);
    }

    #[test]
    fn a_recursive_message_in_the_query_is_refused() {
        let node = msg_in(
            "tiny.rest.v1",
            "Node",
            vec![scalar_field("v", ScalarKind::String), msg_field("next", ".tiny.rest.v1.Node", "Node")],
        );
        let req = msg_in("tiny.rest.v1", "Req", vec![msg_field("head", ".tiny.rest.v1.Node", "Node")]);
        let svc = svc_over(&req, rule("get", "/v1/x", "", &[]));
        let file = file_with(vec![req, node], svc.clone());
        let err = emit_rest_service(&file, &svc).unwrap_err();
        assert!(
            err.contains("query field `head.next` is a `.tiny.rest.v1.Node`, which holds itself, so it has no finite query form"),
            "{err}"
        );
    }

    #[test]
    fn a_bytes_query_field_is_base64_and_the_file_imports_the_encoder() {
        let req = msg_in(
            "tiny.rest.v1",
            "Req",
            vec![scalar_field("name", ScalarKind::String), scalar_field("etag", ScalarKind::Bytes)],
        );
        let svc = svc_over(&req, rule("delete", "/v1/{name=projects/*/roles/*}", "", &[]));
        let file = file_with(vec![req], svc.clone());
        let e = emit_rest_service(&file, &svc).unwrap();
        assert!(e.needs_base64);
        assert!(e.source.contains("if len(req.etag) > 0:"), "{}", e.source);
        assert!(e.source.contains(
            "query += String(\"etag=\") + _rest_pct_encode(base64_encode(Span(req.etag)))"
        ));
        let mojo = crate::emit::Emitter::with_protocol(&file, crate::ProtocolMode::Rest).emit();
        assert!(mojo.contains("\nfrom komira_encoding import base64_encode\n"), "{mojo}");
    }

    #[test]
    fn a_map_or_a_well_known_type_query_field_is_refused_by_its_own_name() {
        let map = IrField {
            name: "labels".into(),
            ty: IrType::Map(
                Box::new(IrType::Scalar(ScalarKind::String)),
                Box::new(IrType::Scalar(ScalarKind::String)),
            ),
            label: Label::Single,
            proto_field_number: 1,
            json_name: "labels".into(),
            oneof_index: None,
        };
        let ts = msg_field("doc", ".google.protobuf.Struct", "Struct");
        // Declared among the generated files, the Struct is still refused:
        // its fields are not its query form.
        let ts_msg = msg_in(
            "google.protobuf",
            "Struct",
            vec![scalar_field("seconds", ScalarKind::Int64), scalar_field("nanos", ScalarKind::Int32)],
        );
        let cases = [
            (map, "query field `labels` is a map, which has no query form"),
            (
                ts,
                "query field `doc` is a `.google.protobuf.Struct`, whose query form would be its \
                 JSON string, which is implemented only for `.google.protobuf.FieldMask`, \
                 `.google.protobuf.Timestamp` and `.google.protobuf.Duration`",
            ),
        ];
        for (fld, want) in cases {
            let req = msg_in("tiny.rest.v1", "Req", vec![fld]);
            let svc = svc_over(&req, rule("get", "/v1/x", "", &[]));
            let file = file_with(vec![req, ts_msg.clone()], svc.clone());
            let err = emit_rest_service(&file, &svc).unwrap_err();
            assert!(err.contains(want), "{err}");
        }
    }

    #[test]
    fn a_repeated_message_at_any_depth_of_the_query_is_refused() {
        let inner = msg_in("tiny.rest.v1", "Inner", vec![scalar_field("v", ScalarKind::String)]);
        let mut many = msg_field("items", ".tiny.rest.v1.Inner", "Inner");
        many.label = Label::Repeated;
        let a = msg_in("tiny.rest.v1", "Req", vec![many]);
        let b = msg_in("tiny.rest.v1", "Req", vec![msg_field("outer", ".tiny.rest.v1.Outer", "Outer")]);
        // `outer.inner` is a message two levels down, flattened; its own
        // repeated message is what has no query form.
        let mut many_inner = msg_field("inner", ".tiny.rest.v1.Inner", "Inner");
        many_inner.label = Label::Repeated;
        let outer = msg_in("tiny.rest.v1", "Outer", vec![many_inner]);
        for (req, want) in [
            (a, "query field `items` is a repeated message"),
            (b, "query field `outer.inner` is a repeated message"),
        ] {
            let svc = svc_over(&req, rule("get", "/v1/x", "", &[]));
            let file = file_with(vec![req, inner.clone(), outer.clone()], svc.clone());
            let err = emit_rest_service(&file, &svc).unwrap_err();
            assert!(err.contains(want), "{err}");
        }
    }

    #[test]
    fn a_file_with_no_bytes_query_does_not_import_the_encoder() {
        let req = msg_in("tiny.rest.v1", "Req", vec![scalar_field("name", ScalarKind::String)]);
        let svc = svc_over(&req, rule("get", "/v1/{name=projects/*}", "", &[]));
        let file = file_with(vec![req], svc);
        let mojo = crate::emit::Emitter::with_protocol(&file, crate::ProtocolMode::Rest).emit();
        assert!(!mojo.contains("komira_encoding"), "{mojo}");
    }

    fn message(name: &str, fields: Vec<IrField>) -> IrMessage {
        IrMessage {
            name: name.into(),
            mojo_name: name.into(),
            fq_name: format!(".tiny.rest.v1.{name}"),
            is_map_entry: false,
            fields,
            oneofs: vec![],
        }
    }

    fn method(name: &str, input: &str, output: &str, rule: (&str, &str, &str)) -> IrMethod {
        IrMethod {
            name: name.into(),
            input: TypeRef { fq_name: input.into(), mojo_name: input.rsplit('.').next().unwrap().into() },
            output: TypeRef { fq_name: output.into(), mojo_name: output.rsplit('.').next().unwrap().into() },
            client_streaming: false,
            server_streaming: false,
            idempotent: false,
            http_rule: Some(IrHttpRule {
                verb: rule.0.into(),
                path_template: rule.1.into(),
                body: rule.2.into(),
                additional_bindings: vec![],
            }),
            routing_rule: None,
        }
    }

    fn svc_of(methods: Vec<IrMethod>) -> IrService {
        IrService { name: "Jobs".into(), default_host: None, host_from_service_config: false, methods }
    }

    /// `UpdateJobRequest { Job job; FieldMask update_mask; bool validate_only }`
    /// with `Job { string name; string description }`, PATCHed at
    /// `/v1/{job.name=projects/*/jobs/*}` with `body: "job"`.
    fn update_job(body: &str) -> Result<RestServiceEmit, String> {
        let mut mask = msg_field("update_mask", ".google.protobuf.FieldMask", "FieldMask");
        mask.json_name = "updateMask".into();
        let mut validate = scalar_field("validate_only", ScalarKind::Bool);
        validate.json_name = "validateOnly".into();
        let req = message(
            "UpdateJobRequest",
            vec![msg_field("job", ".tiny.rest.v1.Job", "Job"), mask, validate],
        );
        let job = message(
            "Job",
            vec![
                scalar_field("name", ScalarKind::String),
                scalar_field("description", ScalarKind::String),
            ],
        );
        let svc = svc_of(vec![method(
            "UpdateJob",
            ".tiny.rest.v1.UpdateJobRequest",
            ".tiny.rest.v1.Job",
            ("patch", "/v1/{job.name=projects/*/jobs/*}", body),
        )]);
        let file = file_with(vec![req, job], svc.clone());
        emit_rest_service(&file, &svc)
    }

    #[test]
    fn dotted_path_var_reads_the_body_message_after_a_presence_check() {
        let e = update_job("job").unwrap();
        let s = &e.source;
        let guard = s
            .find("if not req.job:\n")
            .unwrap_or_else(|| panic!("no presence check:\n{s}"));
        assert!(s.contains(
            "raise Error(String(\"update_job: the request's `job` is unset, and the path is built from `job.name`\"))"
        ), "{s}");
        let fill = s
            .find("path += _rest_path_var(_rest_to_str(req.job.value().name), String(\"projects/*/jobs/*\"), String(\"job.name\"))")
            .unwrap_or_else(|| panic!("no path fill:\n{s}"));
        assert!(guard < fill, "the check comes before the path is built");
        // The token source is asked only after the check.
        assert!(guard < s.find("self._token_source.access_token()").unwrap());
        assert!(s.contains("body_text = encode_json(req.job.value())"), "{s}");
    }

    #[test]
    fn field_mask_query_param_is_its_json_string_when_set() {
        let e = update_job("job").unwrap();
        let s = &e.source;
        assert!(s.contains("if req.update_mask:\n"), "{s}");
        assert!(s.contains(
            "query += String(\"updateMask=\") + _rest_pct_encode(req.update_mask.value().to_proto3_json())"
        ), "{s}");
        assert!(s.contains("query += String(\"validateOnly=\") + _rest_pct_encode(_rest_bool_str(req.validate_only))"), "{s}");
        assert!(!s.contains("query += String(\"job="), "{s}");
    }

    #[test]
    fn dotted_path_var_outside_the_body_is_refused() {
        let err = update_job("").unwrap_err();
        assert!(err.contains("which is not the request body"), "{err}");
    }

    #[test]
    fn dotted_path_var_through_a_scalar_or_a_missing_field_is_refused() {
        let req = message(
            "R",
            vec![scalar_field("name", ScalarKind::String), msg_field("job", ".tiny.rest.v1.Job", "Job")],
        );
        let job = message("Job", vec![scalar_field("name", ScalarKind::String)]);
        for (path, want) in [
            ("/v1/{name.x}", "which is not a singular message field"),
            ("/v1/{job.missing}", "names `missing`, which is not a field of `.tiny.rest.v1.Job`"),
        ] {
            let svc = svc_of(vec![method("M", ".tiny.rest.v1.R", ".tiny.rest.v1.R", ("post", path, "*"))]);
            let file = file_with(vec![req.clone(), job.clone()], svc.clone());
            let err = emit_rest_service(&file, &svc).unwrap_err();
            assert!(err.contains(want), "{path}: {err}");
        }
    }

    #[test]
    fn a_path_leaf_must_be_a_plain_scalar_outside_a_oneof() {
        // The leaf of a dotted variable is held to what a plain one is: a
        // scalar the request always has, read as `req.<...>.<leaf>`.
        let mut opt_name = scalar_field("opt_name", ScalarKind::String);
        opt_name.label = Label::Optional;
        let mut arm = scalar_field("arm", ScalarKind::String);
        arm.oneof_index = Some(0);
        let job = message(
            "Job",
            vec![
                opt_name.clone(),
                arm.clone(),
                msg_field("spec", ".tiny.rest.v1.Job", "Job"),
            ],
        );
        let req = message(
            "R",
            vec![msg_field("job", ".tiny.rest.v1.Job", "Job"), opt_name, arm],
        );
        for (path, want) in [
            ("/v1/{job.opt_name}", "path variable `job.opt_name` is a proto3 `optional` field"),
            ("/v1/{job.arm}", "field `job.arm` is used in the path/query but is an arm of a oneof"),
            ("/v1/{job.spec}", "field `job.spec` is used in the path/query but is not a scalar"),
            ("/v1/{opt_name}", "path variable `opt_name` is a proto3 `optional` field"),
            ("/v1/{arm}", "field `arm` is used in the path/query but is an arm of a oneof"),
        ] {
            let svc = svc_of(vec![method("M", ".tiny.rest.v1.R", ".tiny.rest.v1.R", ("post", path, "*"))]);
            let file = file_with(vec![req.clone(), job.clone()], svc.clone());
            let err = emit_rest_service(&file, &svc).unwrap_err();
            assert!(err.contains(want), "{path}: {err}");
        }
    }

    #[test]
    fn a_field_mask_in_a_oneof_stays_out_of_the_query() {
        let mut mask = msg_field("update_mask", ".google.protobuf.FieldMask", "FieldMask");
        mask.oneof_index = Some(0);
        let req = message("ListReq", vec![mask]);
        let svc = svc_of(vec![method("List", ".tiny.rest.v1.ListReq", ".tiny.rest.v1.ListReq", ("get", "/v1/things", ""))]);
        let file = file_with(vec![req], svc.clone());
        let err = emit_rest_service(&file, &svc).unwrap_err();
        assert!(err.contains("field `update_mask` is used in the path/query but is an arm of a oneof"), "{err}");
    }

    #[test]
    fn a_dotted_path_var_in_a_whole_body_is_refused() {
        // `body: "*"` leaves out the fields the path binds, which a field of
        // a body message is not.
        let err = update_job("*").unwrap_err();
        assert!(err.contains("REST body `*` with the dotted path variable `job.name`"), "{err}");
    }
}
