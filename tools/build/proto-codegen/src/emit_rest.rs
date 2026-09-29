//! The REST client emitter: for `ProtocolMode::Rest`, one client method per
//! unary method carrying a `(google.api.http)` annotation.

use std::fmt::Write as _;

use crate::ir::*;
use crate::mojo_names::rpc_method_name;
use crate::path_template::{
    percent_encode_simple, BodyDesignator, FieldPartition, PathSegment, PathTemplate,
};

const REST_HOST: &str = "localhost";
const REST_PORT: &str = "0";

/// The result of emitting one REST service — the generated text plus any
/// per-method validation notes (streaming methods skipped, etc.).
#[derive(Clone, Debug)]
pub struct RestServiceEmit {
    /// The generated client-struct source (already indented; appended raw to
    /// the file buffer by the caller).
    pub source: String,
    pub notes: Vec<String>,
}

/// The import block a REST-target file needs (replaces the gRPC import set in
/// `emit.rs::emit_header` when `ProtocolMode::Rest`). One source line per
/// emitted entry, no trailing blank — the header owns surrounding blanks.
pub fn rest_imports() -> &'static [&'static str] {
    &[
        "from komira_serde.proto3_json import JsonEncoder, JsonDecoder",
        "from komira_http.client.client import (",
        "    HttpClient,",
        "    build_get_request,",
        "    build_request_with_body,",
        ")",
        "from komira_http.client.body import BytesBody, EmptyBody",
        "from komira_http.client.header_map import HeaderMap",
        "from komira_http.client.url import Url",
        "from komira_http.codec.types import HttpMethod",
        "from komira_http.transport.io_stream import Connector",
        "from komira_async.reactor.reactor import Reactor",
        "from komira_async.runtime.runtime_trait import Runtime",
    ]
}

/// Emit the REST client struct for `svc`, looking up request messages in
/// `file`. Returns the generated source + validation notes, or a hard error
/// for an un-annotated unary method (the missing-annotation LOUD rule).
pub fn emit_rest_service(
    file: &IrFile,
    svc: &IrService,
) -> Result<RestServiceEmit, String> {
    let mut w = Writer::new();
    let mut notes = Vec::new();

    let struct_name = format!("{}Client", svc.name);
    w.blank();
    w.line(&format!(
        "# REST service client for `{}.{}`. (REST-CODEGEN Phase 1)",
        file.proto_package, svc.name
    ));
    w.line(&format!(
        "struct {struct_name}[C: Connector](Movable, Deinitable):"
    ));
    w.indent();
    w.line(&format!(
        "\"\"\"Generated REST/JSON client for service `{}`.",
        svc.name
    ));
    w.line(&format!(
        "    Per rest_codegen_extension_design §1.2. Host: {REST_HOST}."
    ));
    w.line("    \"\"\"");
    w.blank();
    w.line("var _client: HttpClient[Self.C]");
    w.line("\"\"\"The HTTP transport substrate.\"\"\"");
    w.blank();
    w.line("var _default_headers: HeaderMap");
    w.line(
        "\"\"\"Default headers merged into every request (e.g. a private-ingress",
    );
    w.line("    `X-Serverless-Authorization` token). Empty unless set.\"\"\"");
    w.blank();
    // The REST base host. Defaults to the offline `localhost` placeholder (the
    // scripted-loopback fast path — no DNS); a LIVE caller re-points it at the
    // real public host via `set_rest_host`. The URL host feeds BOTH the
    // dial-target DNS resolution and the injected `Host:` header, so the live
    // dial requires the real host HERE (SNI on the TLS connector is not the
    // dial target).
    w.line("var _rest_host: String");
    w.line("\"\"\"The REST base host the verb URLs target. Defaults to the offline");
    w.line(&format!(
        "    `{REST_HOST}` placeholder; a live caller sets the real public host via"
    ));
    w.line("    `set_rest_host` (it drives BOTH the dial DNS target and the `Host:`");
    w.line("    header).\"\"\"");
    w.blank();
    w.line("def __init__(out self, var client: HttpClient[Self.C]):");
    w.indent();
    w.line("\"\"\"Construct with no default headers.\"\"\"");
    w.line("self._client = client^");
    w.line("self._default_headers = HeaderMap()");
    w.line(&format!("self._rest_host = String(\"{REST_HOST}\")"));
    w.dedent();
    w.blank();
    w.line(
        "def __init__(out self, var client: HttpClient[Self.C], var default_headers: HeaderMap):",
    );
    w.indent();
    w.line(
        "\"\"\"Construct with per-client DEFAULT headers merged into every request.",
    );
    w.line(
        "        (e.g. `X-Serverless-Authorization` for a private-ingress board).\"\"\"",
    );
    w.line("self._client = client^");
    w.line("self._default_headers = default_headers^");
    w.line(&format!("self._rest_host = String(\"{REST_HOST}\")"));
    w.dedent();
    w.blank();
    w.line("def set_rest_host(mut self, var host: String):");
    w.indent();
    w.line("\"\"\"Point the verb URLs at a real public host (e.g.");
    w.line("    `compute.googleapis.com`) for a LIVE dial. The URL host feeds BOTH");
    w.line("    the dial-target DNS resolution and the injected `Host:` header;");
    w.line(&format!(
        "    the default `{REST_HOST}` is the offline scripted-loopback path.\"\"\""
    ));
    w.line("self._rest_host = host^");
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
        if m.client_streaming || m.server_streaming {
            notes.push(format!(
                "skipped streaming method `{}.{}` (REST Phase 1 is unary-only; \
                 `(google.api.http)` on a streaming method has no REST mapping)",
                svc.name, m.name
            ));
            w.line(&format!(
                "# NOTE: streaming method `{}` skipped (REST Phase 1 is unary-only).",
                m.name
            ));
            w.blank();
            continue;
        }
        emit_rest_method(&mut w, file, m, rule)?;
    }

    w.dedent();
    Ok(RestServiceEmit {
        source: w.into_source(),
        notes,
    })
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
        if matches!(fld.label, Label::Repeated) {
            return Err(format!(
                "REST method `{}`: field `{}` is used in the path/query but is \
                 `repeated` (Phase 1 has no RFC 6570 list-expansion; a repeated \
                 scalar path/query field is unsupported)",
                m.name, f
            ));
        }
        if !is_scalar(&fld.ty) {
            return Err(format!(
                "REST method `{}`: field `{}` is used in the path/query but is \
                 not a scalar (Phase 1 only renders scalar path/query fields)",
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
        "def {method_name}[RT: Runtime](mut self, req: {req_ty}, token: String, \
         mut connector: Self.C, mut reactor: Reactor[RT.Sink]) raises -> {resp_ty}:"
    ));
    w.indent();
    w.line(&format!(
        "\"\"\"{} `{}` — REST/JSON.\"\"\"",
        verb.to_uppercase(),
        rule.path_template
    ));


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
        "headers.append(String(\"Authorization\"), String(\"Bearer \") + token)",
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
    // `call[RT, C, B]` binding below: GET builds a `ClientRequest[EmptyBody]`
    // (`build_get_request`), every other verb a `ClientRequest[BytesBody]`.
    // The `call`'s `B` parameter MUST match the constructed request's body
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
    // `Self.C` (NOT bare `C`) — same struct-parameter qualification rule.
    w.line(&format!("var resp = self._client.call[RT, Self.C, {body_ty}]("));
    w.line("    req_http^, connector, reactor,");
    w.line(")");

    // -- status check --------------------------------------------------------
    w.line("var status_int = Int(resp.status)");
    w.line("if status_int >= 400:");
    w.indent();
    w.line(&format!(
        "raise Error(String(\"REST {} {} failed: HTTP \") + String(status_int))",
        verb.to_uppercase(),
        m.name
    ));
    w.dedent();

    // -- response decode -----------------------------------------------------
    w.line("var resp_bytes = resp.body.take_bytes()");
    w.line(
        "var resp_text = String(unsafe_from_utf8=Span(resp_bytes))",
    );
    w.line("if resp_text.byte_length() == 0:");
    w.indent();
    w.line("resp_text = String(\"{}\")");
    w.dedent();
    w.line("var dec = JsonDecoder.from_text(resp_text)");
    w.line(&format!("return {resp_ty}.decode(dec)"));
    w.dedent();
    w.blank();
    Ok(())
}

/// Emit the path-string build: `var path = String("/") + seg + ...`, with
/// each `{var}` substituted by the percent-encoded same-named request field.
fn emit_path_build(
    w: &mut Writer,
    template: &PathTemplate,
    bool_fields: &std::collections::BTreeSet<String>,
) {
    // Build the path incrementally so a `{var}`'s runtime value is encoded.
    w.line("var path = String(\"\")");
    for seg in &template.segments {
        match seg {
            PathSegment::Literal(lit) => {
                w.line(&format!(
                    "path += String(\"/{}\")",
                    percent_encode_simple(lit)
                ));
            }
            PathSegment::Var(name) => {
                // A `{var}` segment — the same-named scalar field, stringified
                // and percent-encoded at runtime via `_rest_pct_encode`.
                w.line("path += String(\"/\")");
                w.line(&format!(
                    "path += _rest_pct_encode({})",
                    field_to_str_expr(name, bool_fields)
                ));
            }
        }
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
        let optional = fld
            .map(|x| matches!(x.label, Label::Optional))
            .unwrap_or(false);
        // An `Optional[T]` field reads through `.value()` INSIDE its presence
        // check; a plain field reads directly (`field_to_str_expr`).
        let value_expr = if optional {
            if bool_fields.contains(f) {
                format!("_rest_bool_str(req.{f}.value())")
            } else {
                format!("_rest_to_str(req.{f}.value())")
            }
        } else {
            field_to_str_expr(f, bool_fields)
        };
        if optional {
            w.line(&format!("if req.{f}:"));
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
        if optional {
            w.dedent();
        }
    }
}

/// Emit the JSON-body build. For `body: "*"` the whole `req` serializes; for a
/// named field the single field's message serializes.
fn emit_body_build(
    w: &mut Writer,
    part: &FieldPartition,
    req_msg: &IrMessage,
) -> Result<(), String> {
    w.line("var benc = JsonEncoder()");
    match &part.body {
        BodyDesignator::Whole => {
            w.line("req.encode(benc)");
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
                w.line(&format!("if req.{name}:"));
                w.indent();
                w.line(&format!("req.{name}.value().encode(benc)"));
                w.dedent();
            } else {
                w.line(&format!("req.{name}.encode(benc)"));
            }
        }
        BodyDesignator::None => unreachable!("emit_body_build only on a body verb"),
    }
    w.line("benc.finish()");
    w.line("var body_text = benc^.into_string()");
    w.line("var body = BytesBody.from_str(body_text)");
    Ok(())
}

/// The percent-encode + stringify helpers the generated path/query code calls.
/// Emitted ONCE per REST file (free functions, module level). Kept in the
/// generated file so the runtime has no extra import dependency.
pub fn rest_helper_functions() -> &'static str {
    "\
def _rest_pct_encode(s: String) -> String:
    \"\"\"RFC 6570 simple-string percent-encoding — escape every byte except
    the unreserved set `-._~` + alnum.\"\"\"
    var out = String(\"\")
    var bs = s.as_bytes()
    var i = 0
    while i < len(bs):
        var b = bs[i]
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
            out += String(\"%\")
            out += _rest_hex_upper(b >> 4)
            out += _rest_hex_upper(b & 0x0F)
        i += 1
    return out^


def _rest_hex_upper(nibble: UInt8) -> String:
    \"\"\"One uppercase hex digit for a 4-bit nibble.\"\"\"
    if nibble < 10:
        return chr(Int(0x30 + nibble))
    return chr(Int(0x41 + (nibble - 10)))


def _rest_to_str[T: Writable](v: T) -> String:
    \"\"\"Stringify a scalar path/query field value. `T: Writable` (NOT
    `Stringable`, which is not available unqualified in a generated module
    in Mojo 1.0.0b1) — `String(v)` is the canonical conversion and every
    scalar (String / Int* / Float* / Bool) conforms to `Writable`.\"\"\"
    return String(v)


def _rest_bool_str(b: Bool) -> String:
    \"\"\"Stringify a proto `bool` for the URL as proto3-JSON lowercase
    `true`/`false`. Mojo's `String(Bool)` yields `True`/`False`, which is
    wrong on the wire — proto3 JSON mandates lowercase.\"\"\"
    if b:
        return String(\"true\")
    return String(\"false\")
"
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
        assert!(emit.source.contains("_rest_pct_encode(_rest_to_str(req.shelf))"));
        assert!(emit.source.contains("page_size="));
        assert!(emit.source.contains("build_get_request(url^, headers^)"));
        assert!(emit.source.contains("GetReq.decode(dec)"));
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
                .contains("struct SvcClient[C: Connector](Movable, Deinitable):"),
            "the generated REST client must conform to 1.0.0's `Deinitable`; got:\n{}",
            emit.source
        );
        assert!(
            !emit.source.contains("ImplicitlyDestructible"),
            "the b2 trait name must not survive into generated 1.0.0 code; got:\n{}",
            emit.source
        );
    }

    #[test]
    fn streaming_method_is_skipped_with_note() {
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
            methods: vec![IrMethod {
                name: "Stream".into(),
                input: TypeRef {
                    fq_name: ".tiny.rest.v1.Req".into(),
                    mojo_name: "Req".into(),
                },
                output: TypeRef {
                    fq_name: ".tiny.rest.v1.Req".into(),
                    mojo_name: "Req".into(),
                },
                client_streaming: false,
                server_streaming: true,
                idempotent: false,
                http_rule: Some(IrHttpRule {
                    verb: "get".into(),
                    path_template: "/v1/stream".into(),
                    body: "".into(),
                }),
                routing_rule: None,
            }],
        };
        let file = file_with(vec![req], svc.clone());
        let emit = emit_rest_service(&file, &svc).unwrap();
        assert_eq!(emit.notes.len(), 1);
        assert!(emit.notes[0].contains("streaming"));
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
        // so it serializes via `req.book.value().encode(benc)` guarded by a
        // presence check — NOT `req.book.encode(benc)` (Optional has no
        // `.encode`). The post constructor + Content-Type are emitted.
        assert!(emit.source.contains("if req.book:"));
        assert!(emit.source.contains("req.book.value().encode(benc)"));
        assert!(emit.source.contains("BytesBody.from_str(body_text)"));
        assert!(emit.source.contains("HttpMethod.post()"));
        assert!(emit.source.contains("Content-Type"));
        // POST routes through `call[RT, Self.C, BytesBody]` (the body verb).
        assert!(emit
            .source
            .contains("self._client.call[RT, Self.C, BytesBody]"));
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
        assert!(emit.source.contains("req.encode(benc)"));
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
            .contains("self._client.call[RT, Self.C, EmptyBody]"));
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
            .contains("def __init__(out self, var client: HttpClient[Self.C]):"));
        assert!(emit.source.contains(
            "def __init__(out self, var client: HttpClient[Self.C], \
             var default_headers: HeaderMap):"
        ));
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
}
