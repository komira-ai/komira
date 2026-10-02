//! The REST binding: each member of an operation's input and output shape
//! is bound to a part of the HTTP message by its `location`, and whatever
//! is left is the body (restJson1, with the JSON body codec).
//!
//! Request (`build_<op>_request`):
//!
//! - `uri` members fill the labels of `requestUri` (`{Name}`, greedy
//!   `{Name+}`), and the literal query of `requestUri` comes first;
//!   `komira_aws_core.AwsRestUri` encodes both.
//! - `querystring` members are query parameters, in declared order: a list
//!   is one parameter per element, and a map is one parameter per entry
//!   (a map of lists, one per element), which a named member of the same
//!   key takes precedence over.
//! - `header` members are headers; a list is one header, its elements
//!   joined by ", " (an empty list sends none). `headers` (prefix) maps
//!   write one header per entry, after every `header` member.
//! - The body: the `payload` member alone when the shape names one (a
//!   structure as JSON, `{}` when unset; a blob as its bytes; a string as
//!   its text), else a JSON object of every member with no location (`{}`
//!   when none is set), else nothing. A body carries a `Content-Type`
//!   unless a `header` member already set one.
//!
//! Response (`parse_<op>_response`): `header` and `headers` members from
//! the response headers, a `statusCode` member from the status, and the
//! body as above; `uri` and `querystring` members are not in a response
//! and stay unset. An operation whose output payload is a streaming blob
//! also gets `parse_<op>_head`, which reads everything but the body, so a
//! caller can read the status and headers before the body arrives.
//!
//! Scalar text (labels, query values, headers) is `komira_aws_core`'s
//! `aws_text_*` writers and `aws_*_from_text` readers; a timestamp uses the
//! member's resolved format (`aws_in::resolve_timestamp_format`).

use super::proto::Binding;
use super::{escape, ts_const, AwsEmitter};
use crate::aws_in::{AwsLocation, AwsOperationFacts, AwsTimestampFormat};
use crate::ir::{IrField, IrMessage, IrMethod, IrType, Label, ScalarKind};

/// The restJson1 binding.
pub(super) struct AwsRestJson;

/// The content type of a body that is not JSON: a blob payload, a string
/// payload. A JSON body is `<PREFIX>_CONTENT_TYPE`.
const BLOB_CONTENT_TYPE: &str = "application/octet-stream";
const TEXT_CONTENT_TYPE: &str = "text/plain";

impl Binding for AwsRestJson {
    fn header_protocol(&self, em: &AwsEmitter) -> String {
        format!("{} (restJson1)", em.meta.protocol)
    }

    fn emit_wire_constants(&self, em: &mut AwsEmitter) {
        let p = em.prefix.to_uppercase();
        em.line(&format!(
            "comptime {p}_CONTENT_TYPE: String = \"application/json\""
        ));
    }

    fn emit_request_builder(
        &self,
        em: &mut AwsEmitter,
        m: &IrMethod,
        facts: &AwsOperationFacts,
    ) -> Result<(), String> {
        em.emit_rest_request_builder(m, facts)
    }

    fn emit_response_parser(
        &self,
        em: &mut AwsEmitter,
        m: &IrMethod,
        facts: &AwsOperationFacts,
    ) -> Result<(), String> {
        em.emit_rest_response_parsers(m, facts)
    }

    fn default_content_type(&self, _em: &AwsEmitter) -> String {
        // A REST request with a body sets its own Content-Type; one without
        // a body is sent without one.
        "String(\"\")".to_string()
    }

    fn send_notes(&self) -> &'static [&'static str] {
        &[
            "    A request with a body carries its own `Content-Type` header; one",
            "    without a body is signed and sent with none.",
        ]
    }

    fn error_code_and_message(&self) -> (&'static str, &'static str) {
        (
            "aws_rest_json_error(res.to_response()).code.copy()",
            "aws_rest_json_error(res.to_response()).message.copy()",
        )
    }

    fn error_code_doc(&self) -> &'static str {
        "restJson1 error code"
    }
}

/// Where one member of a top-level shape goes, and the facts the binding
/// needs about it.
struct Bound {
    field: IrField,
    wire: String,
    location: AwsLocation,
    required: bool,
    json_value: bool,
    timestamp: Option<AwsTimestampFormat>,
    streaming: bool,
    is_payload: bool,
}

impl AwsEmitter<'_> {
    fn message_by_fq(&self, fq: &str) -> Result<&IrMessage, String> {
        self.messages
            .values()
            .copied()
            .find(|m| m.fq_name == fq)
            .ok_or_else(|| format!("emit_aws: no message {fq}"))
    }

    fn bound_members(&self, msg: &IrMessage) -> Result<Vec<Bound>, String> {
        let shape = self.facts.shape(&msg.name)?;
        let mut out = Vec::new();
        for f in &msg.fields {
            let mf = self.facts.member(&msg.fq_name, &f.name)?;
            let member_shape_streaming = self
                .facts
                .shape(&mf.shape)
                .map(|s| s.streaming)
                .unwrap_or(false);
            out.push(Bound {
                field: f.clone(),
                wire: mf.wire_name.clone(),
                location: mf.location,
                required: mf.required,
                json_value: mf.json_value,
                timestamp: mf.timestamp_format,
                streaming: mf.streaming || member_shape_streaming,
                is_payload: shape.payload.as_deref() == Some(mf.member_name.as_str()),
            });
        }
        Ok(out)
    }

    /// The text a scalar `access` of type `ty` travels as in a label, a
    /// query value or a header.
    fn rest_text(&self, msg: &IrMessage, b: &Bound, ty: &IrType, access: &str) -> Result<String, String> {
        Ok(match ty {
            IrType::Enum(_) => format!("{access}.copy()"),
            IrType::Scalar(ScalarKind::String) => match b.timestamp {
                Some(fmt) => format!("aws_text_ts({access}, {})", ts_const(fmt)),
                None if b.json_value && b.location == AwsLocation::Header => {
                    format!("aws_text_media({access})")
                }
                None => format!("{access}.copy()"),
            },
            IrType::Scalar(ScalarKind::Bool) => format!("aws_text_bool({access})"),
            IrType::Scalar(ScalarKind::Double) => format!("aws_text_f64({access})"),
            IrType::Scalar(ScalarKind::Float) => format!("aws_text_f32({access})"),
            IrType::Scalar(ScalarKind::Bytes) => format!("aws_text_blob(Span({access}))"),
            IrType::Scalar(_) => format!("aws_text_int(Int64({access}))"),
            IrType::Message(_) | IrType::List(_) | IrType::Map(_, _) => {
                return Err(format!(
                    "emit_aws: {}.{} is bound to `{}` and is not a scalar; a REST \
                     binding writes only scalars (and, in a query or a header, lists \
                     of them) as text",
                    msg.name,
                    b.field.name,
                    b.location.token()
                ))
            }
        })
    }

    /// The value a scalar of type `ty` reads from its header text `text`.
    fn rest_from_text(&self, msg: &IrMessage, b: &Bound, ty: &IrType, text: &str) -> Result<String, String> {
        Ok(match ty {
            IrType::Enum(_) => text.to_string(),
            IrType::Scalar(ScalarKind::String) => match b.timestamp {
                Some(fmt) => format!("aws_ts_from_text({text}, {})", ts_const(fmt)),
                None if b.json_value => format!("aws_media_from_text({text})"),
                None => text.to_string(),
            },
            IrType::Scalar(ScalarKind::Bool) => format!("aws_bool_from_text({text})"),
            IrType::Scalar(ScalarKind::Double) => format!("aws_f64_from_text({text})"),
            IrType::Scalar(ScalarKind::Float) => format!("Float32(aws_f64_from_text({text}))"),
            IrType::Scalar(ScalarKind::Bytes) => format!("aws_blob_from_base64({text})"),
            IrType::Scalar(
                ScalarKind::Int64 | ScalarKind::Sint64 | ScalarKind::Sfixed64,
            ) => format!("aws_i64_from_text({text})"),
            IrType::Scalar(
                ScalarKind::Int32 | ScalarKind::Sint32 | ScalarKind::Sfixed32,
            ) => format!("aws_i32_from_text({text})"),
            IrType::Scalar(ScalarKind::Uint64 | ScalarKind::Fixed64) => {
                format!("UInt64(aws_i64_from_text({text}))")
            }
            IrType::Scalar(ScalarKind::Uint32 | ScalarKind::Fixed32) => {
                format!("UInt32(aws_i32_from_text({text}))")
            }
            IrType::Message(_) | IrType::List(_) | IrType::Map(_, _) => {
                return Err(format!(
                    "emit_aws: {}.{} is bound to `{}` and is not a scalar",
                    msg.name,
                    b.field.name,
                    b.location.token()
                ))
            }
        })
    }

    /// `access` of member `b` (of `input`): itself when required, else its
    /// value behind `if <presence>:`, opened here; the caller pops it.
    fn open_member(&mut self, msg: &IrMessage, b: &Bound, base: &str) -> String {
        if b.required {
            if self.is_boxed(msg, &b.field) {
                format!("{base}.{}[0]", b.field.name)
            } else {
                format!("{base}.{}", b.field.name)
            }
        } else {
            self.line(&format!("if {}:", self.presence_test_on(base, msg, &b.field)));
            self.push();
            self.optional_access_on(base, msg, &b.field)
        }
    }

    fn close_member(&mut self, b: &Bound) {
        if !b.required {
            self.pop();
        }
    }

    fn set_content_type_default(&mut self, value_expr: &str) {
        self.line("if not req.has_header(String(\"Content-Type\")):");
        self.push();
        self.line(&format!("req.set_header(String(\"Content-Type\"), {value_expr})"));
        self.pop();
    }

    // ======================================================================
    // The request
    // ======================================================================

    fn emit_rest_request_builder(&mut self, m: &IrMethod, facts: &AwsOperationFacts) -> Result<(), String> {
        let in_ty = self.op_input_type(m);
        let fp = self.fn_prefix();
        let p = self.prefix.to_uppercase();
        let msg = self.message_by_fq(&m.input.fq_name)?.clone();
        let members = self.bound_members(&msg)?;
        self.line(&format!(
            "def {fp}build_{}_request(input: {in_ty}) raises -> AwsRequest:",
            m.name
        ));
        self.push();
        self.line(&format!(
            "\"\"\"`{}` — the restJson1 request, serialised and NOT signed.\"\"\"",
            facts.name
        ));
        self.emit_validate_call(m);

        // -- the URI: labels, then the query --------------------------------
        self.line("var _ln = List[String]()");
        self.line("var _lv = List[String]()");
        for param in &facts.path_params {
            let b = members
                .iter()
                .find(|b| b.location == AwsLocation::Uri && b.wire == param.name)
                .ok_or_else(|| {
                    format!(
                        "emit_aws: `{}` requestUri `{}` has the label `{{{}}}`, and the \
                         input shape `{}` binds no `uri` member to it",
                        facts.name, facts.request_uri, param.name, msg.name
                    )
                })?;
            if b.field.label == Label::Repeated {
                return Err(format!(
                    "emit_aws: {}.{} is bound to `uri` and is not a scalar; a label \
                     holds one value",
                    msg.name, b.field.name
                ));
            }
            self.line(&format!("_ln.append(String(\"{}\"))", escape(&param.name)));
            if b.required {
                let access = if self.is_boxed(&msg, &b.field) {
                    format!("input.{}[0]", b.field.name)
                } else {
                    format!("input.{}", b.field.name)
                };
                let text = self.rest_text(&msg, b, &b.field.ty, &access)?;
                self.line(&format!("_lv.append({text})"));
            } else {
                // An unset label is the empty value, which AwsRestUri.expand
                // refuses, naming the label.
                self.line(&format!("if {}:", self.presence_test_on("input", &msg, &b.field)));
                self.push();
                let access = self.optional_access_on("input", &msg, &b.field);
                let text = self.rest_text(&msg, b, &b.field.ty, &access)?;
                self.line(&format!("_lv.append({text})"));
                self.pop();
                self.line("else:");
                self.push();
                self.line("_lv.append(String(\"\"))");
                self.pop();
            }
        }
        for b in members.iter().filter(|b| b.location == AwsLocation::Uri) {
            if !facts.path_params.iter().any(|p| p.name == b.wire) {
                return Err(format!(
                    "emit_aws: `{}`.{} is a `uri` member named `{}`, and requestUri `{}` \
                     has no such label",
                    msg.name, b.field.name, b.wire, facts.request_uri
                ));
            }
        }
        self.line(&format!(
            "var _uri = AwsRestUri.expand(String(\"{}\"), _ln, _lv)",
            escape(&facts.request_uri)
        ));
        for b in members.iter().filter(|b| b.location == AwsLocation::QueryString) {
            self.emit_query_member(&msg, b)?;
        }

        self.line(&format!(
            "var req = AwsRequest(String(\"{}\"), _uri.target())",
            facts.http_method.to_uppercase()
        ));

        // -- headers, then prefix headers -----------------------------------
        for b in members.iter().filter(|b| b.location == AwsLocation::Header) {
            self.emit_header_member(&msg, b)?;
        }
        for b in members.iter().filter(|b| b.location == AwsLocation::HeaderPrefix) {
            self.emit_prefix_header_member(&msg, b)?;
        }
        if let Some(b) = members.iter().find(|b| b.location == AwsLocation::StatusCode) {
            return Err(format!(
                "emit_aws: `{}`.{} is a `statusCode` member of an input shape; a \
                 request has no status",
                msg.name, b.field.name
            ));
        }

        // `endpoint.hostPrefix`, with its `hostLabel` members substituted.
        if let Some(hp) = &facts.host_prefix {
            let expr = self.host_prefix_expr(hp, &m.input.fq_name)?;
            self.line(&format!("req.host_prefix = {expr}"));
        }

        // -- the body --------------------------------------------------------
        if let Some(b) = members.iter().find(|b| b.is_payload) {
            let access = self.open_member(&msg, b, "input");
            match (&b.field.label, &b.field.ty) {
                (Label::Repeated, _) | (_, IrType::List(_)) | (_, IrType::Map(_, _)) => {
                    return Err(format!(
                        "emit_aws: `{}`.{} is the payload and is a list or a map; a \
                         payload is a structure, a blob or a string",
                        msg.name, b.field.name
                    ))
                }
                (_, IrType::Message(_)) => {
                    self.line(&format!("req.set_body_text({access}.to_aws_json().serialize())"));
                    if !b.required {
                        self.pop();
                        self.line("else:");
                        self.push();
                        self.line("req.set_body_text(String(\"{}\"))");
                        self.pop();
                    }
                    self.set_content_type_default(&format!("String({p}_CONTENT_TYPE)"));
                }
                (_, IrType::Scalar(ScalarKind::Bytes)) => {
                    self.line(&format!("req.body = {access}.copy()"));
                    self.set_content_type_default(&format!("String(\"{BLOB_CONTENT_TYPE}\")"));
                    self.close_member(b);
                }
                (_, IrType::Scalar(ScalarKind::String)) | (_, IrType::Enum(_))
                    if b.timestamp.is_none() =>
                {
                    self.line(&format!("req.set_body_text({access})"));
                    self.set_content_type_default(&format!("String(\"{TEXT_CONTENT_TYPE}\")"));
                    self.close_member(b);
                }
                _ => {
                    return Err(format!(
                        "emit_aws: `{}`.{} is the payload and is neither a structure, a \
                         blob nor a string",
                        msg.name, b.field.name
                    ))
                }
            }
        } else if members.iter().any(|b| b.location == AwsLocation::Body) {
            self.line("var _body = JsonValue.empty_object()");
            for b in members.iter().filter(|b| b.location == AwsLocation::Body) {
                self.emit_json_member_write(&msg, &b.field, "input", "_body")?;
            }
            self.line("req.set_body_text(_body.serialize())");
            self.set_content_type_default(&format!("String({p}_CONTENT_TYPE)"));
        }
        self.line("return req^");
        self.pop();
        self.blank();
        Ok(())
    }

    fn emit_query_member(&mut self, msg: &IrMessage, b: &Bound) -> Result<(), String> {
        let key = format!("String(\"{}\")", escape(&b.wire));
        let access = self.open_member(msg, b, "input");
        match (&b.field.label, &b.field.ty) {
            (Label::Repeated, ty) => {
                self.line(&format!("for _i in range(len({access})):"));
                self.push();
                let text = self.rest_text(msg, b, ty, &format!("{access}[_i]"))?;
                self.line(&format!("_uri.add_query({key}, {text})"));
                self.pop();
            }
            (_, IrType::Map(_, v)) => {
                // A map is the query's free-form parameters: each entry is a
                // parameter of its own key, which a named member takes
                // precedence over (AwsRestUri.add_query_param).
                self.line(&format!("for _k in {access}.keys():"));
                self.push();
                match v.as_ref() {
                    IrType::List(e) => {
                        self.line(&format!("for _j in range(len({access}[_k])):"));
                        self.push();
                        let text = self.rest_text(msg, b, e, &format!("{access}[_k][_j]"))?;
                        self.line(&format!("_uri.add_query_param(_k, {text})"));
                        self.pop();
                    }
                    other => {
                        let text = self.rest_text(msg, b, other, &format!("{access}[_k]"))?;
                        self.line(&format!("_uri.add_query_param(_k, {text})"));
                    }
                }
                self.pop();
            }
            (_, ty) => {
                let text = self.rest_text(msg, b, ty, &access)?;
                self.line(&format!("_uri.add_query({key}, {text})"));
            }
        }
        self.close_member(b);
        Ok(())
    }

    fn emit_header_member(&mut self, msg: &IrMessage, b: &Bound) -> Result<(), String> {
        let name = format!("String(\"{}\")", escape(&b.wire));
        let access = self.open_member(msg, b, "input");
        match (&b.field.label, &b.field.ty) {
            (Label::Repeated, ty) => {
                // An empty list sends no header.
                self.line(&format!("if len({access}) > 0:"));
                self.push();
                if b.timestamp == Some(AwsTimestampFormat::Rfc822) {
                    self.line(&format!(
                        "req.set_header({name}, aws_header_http_date_list({access}))"
                    ));
                } else {
                    let tmp = format!("_h_{}", b.field.name);
                    self.line(&format!("var {tmp} = List[String]()"));
                    self.line(&format!("for _i in range(len({access})):"));
                    self.push();
                    let text = self.rest_text(msg, b, ty, &format!("{access}[_i]"))?;
                    self.line(&format!("{tmp}.append({text})"));
                    self.pop();
                    self.line(&format!("req.set_header({name}, aws_header_list({tmp}))"));
                }
                self.pop();
            }
            (_, ty) => {
                let text = self.rest_text(msg, b, ty, &access)?;
                self.line(&format!("req.set_header({name}, {text})"));
            }
        }
        self.close_member(b);
        Ok(())
    }

    fn emit_prefix_header_member(&mut self, msg: &IrMessage, b: &Bound) -> Result<(), String> {
        let IrType::Map(_, v) = &b.field.ty else {
            return Err(format!(
                "emit_aws: `{}`.{} is a `headers` (prefix) member and is not a map",
                msg.name, b.field.name
            ));
        };
        let access = self.open_member(msg, b, "input");
        let keys = format!("_pk_{}", b.field.name);
        let values = format!("_pv_{}", b.field.name);
        self.line(&format!("var {keys} = List[String]()"));
        self.line(&format!("var {values} = List[String]()"));
        self.line(&format!("for _k in {access}.keys():"));
        self.push();
        self.line(&format!("{keys}.append(_k.copy())"));
        let text = self.rest_text(msg, b, v, &format!("{access}[_k]"))?;
        self.line(&format!("{values}.append({text})"));
        self.pop();
        self.line(&format!(
            "aws_set_prefix_headers(req, String(\"{}\"), {keys}, {values})",
            escape(&b.wire)
        ));
        self.close_member(b);
        Ok(())
    }

    // ======================================================================
    // The response
    // ======================================================================

    fn emit_rest_response_parsers(&mut self, m: &IrMethod, facts: &AwsOperationFacts) -> Result<(), String> {
        let msg = self.message_by_fq(&m.output.fq_name)?.clone();
        let members = self.bound_members(&msg)?;
        let streaming_payload = members.iter().find(|b| {
            b.is_payload
                && b.streaming
                && matches!(b.field.ty, IrType::Scalar(ScalarKind::Bytes))
                && b.field.label != Label::Repeated
        });
        let out_ty = self.op_output_type(m);
        let fp = self.fn_prefix();
        if let Some(payload) = streaming_payload {
            let payload_name = payload.field.name.clone();
            let payload_required = payload.required;
            self.line(&format!(
                "def {fp}parse_{}_head(resp: AwsResponse) raises -> {out_ty}:",
                m.name
            ));
            self.push();
            self.line(&format!(
                "\"\"\"`{}` — the restJson1 response without its body: the status and",
                facts.name
            ));
            self.line(&format!(
                "    the headers. `resp.body` is not read, so a caller can parse these"
            ));
            self.line(&format!(
                "    before the streaming `{}` body arrives.\"\"\"",
                payload.wire
            ));
            self.emit_rest_response_body(&msg, &members, false)?;
            self.pop();
            self.blank();

            self.line(&format!(
                "def {fp}parse_{}_response(resp: AwsResponse) raises -> {out_ty}:",
                m.name
            ));
            self.push();
            self.line(&format!(
                "\"\"\"`{}` — the restJson1 response: `parse_{}_head`, and the body",
                facts.name, m.name
            ));
            self.line("    as the payload (unset when the body is empty).\"\"\"");
            self.line(&format!("var out = {fp}parse_{}_head(resp)", m.name));
            self.line("if len(resp.body) > 0:");
            self.push();
            if payload_required {
                self.line(&format!("out.{payload_name} = resp.body.copy()"));
            } else {
                self.line(&format!("out.set_{payload_name}(resp.body.copy())"));
            }
            self.pop();
            self.line("return out^");
            self.pop();
            self.blank();
            return Ok(());
        }
        self.line(&format!(
            "def {fp}parse_{}_response(resp: AwsResponse) raises -> {out_ty}:",
            m.name
        ));
        self.push();
        self.line(&format!(
            "\"\"\"`{}` — the restJson1 response: the bound headers and status, and",
            facts.name
        ));
        self.line("    the body (an empty body sets nothing).\"\"\"");
        self.emit_rest_response_body(&msg, &members, true)?;
        self.pop();
        self.blank();
        Ok(())
    }

    /// The parser's body: every member read from its location into `out`,
    /// which is returned. The payload is read only when `with_payload`.
    fn emit_rest_response_body(
        &mut self,
        msg: &IrMessage,
        members: &[Bound],
        with_payload: bool,
    ) -> Result<(), String> {
        let out_ty = self.ty_name(&msg.mojo_name);
        let has_payload = members.iter().any(|b| b.is_payload);
        let json_body = !has_payload && members.iter().any(|b| b.location == AwsLocation::Body);
        if json_body {
            self.line("var v = JsonValue.empty_object()");
            self.line("if len(resp.body) > 0:");
            self.push();
            self.line("v = parse_json_bytes(resp.body)");
            self.pop();
        } else if members.is_empty() {
            self.line("_ = resp");
        }
        let what = format!("{out_ty} response");
        // Required members are constructor arguments: read into locals.
        for b in members.iter().filter(|b| b.required) {
            let local = format!("_r_{}", b.field.name);
            if b.location == AwsLocation::Body && !has_payload {
                self.emit_json_read_required(msg, &b.field, &what)?;
                continue;
            }
            self.line(&format!("var {local} = {}", self.default_expr(msg, &b.field)?));
            if b.is_payload {
                if with_payload {
                    self.line("if len(resp.body) > 0:");
                    self.push();
                    let e = self.rest_payload_read(msg, b)?;
                    self.line(&format!("{local} = {e}"));
                    self.pop();
                }
                continue;
            }
            self.emit_rest_bound_read(msg, b, &local, true)?;
        }
        let args: Vec<String> = members
            .iter()
            .filter(|b| b.required)
            .map(|b| format!("_r_{}^", b.field.name))
            .collect();
        self.line(&format!("var out = {out_ty}({})", args.join(", ")));
        for b in members.iter().filter(|b| !b.required) {
            if b.location == AwsLocation::Body && !has_payload {
                self.emit_json_read_optional(msg, &b.field)?;
                continue;
            }
            if b.is_payload {
                if with_payload {
                    self.line("if len(resp.body) > 0:");
                    self.push();
                    let e = self.rest_payload_read(msg, b)?;
                    self.line(&format!("out.set_{}({e})", b.field.name));
                    self.pop();
                }
                continue;
            }
            self.emit_rest_bound_read(msg, b, &format!("_v_{}", b.field.name), false)?;
        }
        self.line("return out^");
        Ok(())
    }

    /// The payload member's value from the (non-empty) body.
    fn rest_payload_read(&self, msg: &IrMessage, b: &Bound) -> Result<String, String> {
        Ok(match (&b.field.label, &b.field.ty) {
            (Label::Single | Label::Optional, IrType::Message(_)) => {
                let ty = self.value_type(msg, &b.field)?;
                format!("{ty}.from_aws_json(parse_json_bytes(resp.body))")
            }
            (Label::Single | Label::Optional, IrType::Scalar(ScalarKind::Bytes)) => {
                "resp.body.copy()".to_string()
            }
            (Label::Single | Label::Optional, IrType::Scalar(ScalarKind::String) | IrType::Enum(_))
                if b.timestamp.is_none() =>
            {
                "resp.body_text()".to_string()
            }
            _ => {
                return Err(format!(
                    "emit_aws: `{}`.{} is the payload and is neither a structure, a blob \
                     nor a string",
                    msg.name, b.field.name
                ))
            }
        })
    }

    /// Reads a member bound to a header, a header prefix or the status. A
    /// required one fills the local `local` (already declared); an
    /// optional one is set on `out` when present. `uri` and `querystring`
    /// members are not in a response.
    fn emit_rest_bound_read(
        &mut self,
        msg: &IrMessage,
        b: &Bound,
        local: &str,
        required: bool,
    ) -> Result<(), String> {
        let name = format!("String(\"{}\")", escape(&b.wire));
        let assign = |em: &mut AwsEmitter, value: &str| {
            if required {
                em.line(&format!("{local} = {value}"));
            } else {
                em.line(&format!("out.set_{}({value})", b.field.name));
            }
        };
        match b.location {
            AwsLocation::Uri | AwsLocation::QueryString => {}
            AwsLocation::Body => {
                return Err(format!(
                    "emit_aws: `{}`.{} is a body member beside a payload",
                    msg.name, b.field.name
                ))
            }
            AwsLocation::StatusCode => {
                let e = match &b.field.ty {
                    _ if b.field.label == Label::Repeated => {
                        return Err(format!(
                            "emit_aws: `{}`.{} is a `statusCode` member and is a list",
                            msg.name, b.field.name
                        ))
                    }
                    IrType::Scalar(ScalarKind::Int32) => "aws_response_code(resp)".to_string(),
                    IrType::Scalar(ScalarKind::Int64) => {
                        "Int64(aws_response_code(resp))".to_string()
                    }
                    _ => {
                        return Err(format!(
                            "emit_aws: `{}`.{} is a `statusCode` member and is not an integer",
                            msg.name, b.field.name
                        ))
                    }
                };
                assign(self, &e);
            }
            AwsLocation::Header => {
                self.line(&format!("if resp.has_header({name}):"));
                self.push();
                let field = format!("aws_header_field(resp, {name})");
                match (&b.field.label, &b.field.ty) {
                    (Label::Repeated, _) if b.timestamp == Some(AwsTimestampFormat::Rfc822) => {
                        assign(self, &format!("aws_header_http_date_list_from({field})"));
                    }
                    (Label::Repeated, ty) => {
                        let parts = format!("_hl_{}", b.field.name);
                        let tmp = format!("_hv_{}", b.field.name);
                        let elem = self.elem_type(msg, &b.field, ty)?;
                        self.line(&format!("var {parts} = aws_header_list_from({field})"));
                        self.line(&format!("var {tmp} = List[{elem}]()"));
                        self.line(&format!("for _i in range(len({parts})):"));
                        self.push();
                        let v = self.rest_from_text(msg, b, ty, &format!("{parts}[_i]"))?;
                        self.line(&format!("{tmp}.append({v})"));
                        self.pop();
                        assign(self, &format!("{tmp}^"));
                    }
                    (_, ty) => {
                        let v = self.rest_from_text(msg, b, ty, &field)?;
                        assign(self, &v);
                    }
                }
                self.pop();
            }
            AwsLocation::HeaderPrefix => {
                let IrType::Map(_, v) = &b.field.ty else {
                    return Err(format!(
                        "emit_aws: `{}`.{} is a `headers` (prefix) member and is not a map",
                        msg.name, b.field.name
                    ));
                };
                let vt = self.elem_type(msg, &b.field, v)?;
                let raw = format!("_ph_{}", b.field.name);
                let tmp = format!("_pm_{}", b.field.name);
                self.line(&format!(
                    "var {raw} = aws_prefix_headers(resp, String(\"{}\"))",
                    escape(&b.wire)
                ));
                self.line(&format!("if len({raw}) > 0:"));
                self.push();
                self.line(&format!("var {tmp} = Dict[String, {vt}]()"));
                self.line(&format!("for _i in range(len({raw})):"));
                self.push();
                let value = self.rest_from_text(msg, b, v, &format!("{raw}[_i].value"))?;
                self.line(&format!("{tmp}[{raw}[_i].name] = {value}"));
                self.pop();
                assign(self, &format!("{tmp}^"));
                self.pop();
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use crate::aws_in::lower_aws_service;
    use crate::emit_aws::{emit_aws_client, AwsEmitOptions};
    use crate::json::parse;
    use crate::overrides::AwsOverrides;

    /// A one-operation restJson1 model: `uri` is its requestUri, `members`
    /// the input's members, `extra` more shapes, `payload` the input's
    /// `payload` member (empty for none).
    fn emit(uri: &str, members: &str, extra: &str, payload: &str) -> Result<String, String> {
        let payload = if payload.is_empty() {
            String::new()
        } else {
            format!(r#", "payload": "{payload}""#)
        };
        let model = parse(&format!(
            r#"{{"version": "2.0",
                "metadata": {{"apiVersion": "2026-10-02", "endpointPrefix": "tiny",
                    "protocol": "rest-json", "serviceFullName": "Tiny",
                    "serviceId": "Tiny", "signatureVersion": "v4",
                    "uid": "tiny-2026-10-02"}},
                "operations": {{"Op": {{"name": "Op",
                    "http": {{"method": "POST", "requestUri": "{uri}"}},
                    "input": {{"shape": "In"}}}}}},
                "shapes": {{"In": {{"type": "structure",
                                   "members": {{{members}}}{payload}}},
                           "Str": {{"type": "string"}},
                           "Strs": {{"type": "list", "member": {{"shape": "Str"}}}}{extra}}}}}"#
        ))
        .map_err(|e| e.to_string())?;
        let lowering =
            lower_aws_service(&model, "tiny", &["Op".to_string()], "tiny.json", "aws.tiny")?;
        let options = AwsEmitOptions {
            pure_only: true,
            omit_preamble: true,
            ..AwsEmitOptions::default()
        };
        emit_aws_client(&lowering, &AwsOverrides::empty(), "tiny", options).map(|(_, s)| s)
    }

    #[test]
    fn a_label_with_no_uri_member_is_an_error_naming_it() {
        let e = emit("/things/{Id}", r#""Name": {"shape": "Str"}"#, "", "").unwrap_err();
        assert!(e.contains("has the label `{Id}`"), "{e}");
    }

    #[test]
    fn a_uri_member_with_no_label_is_an_error_naming_it() {
        let members = r#""Id": {"shape": "Str", "location": "uri", "locationName": "Id"}"#;
        let e = emit("/things", members, "", "").unwrap_err();
        assert!(e.contains("is a `uri` member named `Id`"), "{e}");
    }

    #[test]
    fn a_list_payload_is_an_error() {
        let e = emit("/p", r#""P": {"shape": "Strs"}"#, "", "P").unwrap_err();
        assert!(e.contains("is the payload and is a list or a map"), "{e}");
    }

    #[test]
    fn a_label_bound_to_a_list_is_an_error() {
        let members = r#""Id": {"shape": "Strs", "location": "uri", "locationName": "Id"}"#;
        let e = emit("/things/{Id}", members, "", "").unwrap_err();
        assert!(e.contains("is bound to `uri` and is not a scalar"), "{e}");
    }

    #[test]
    fn the_request_has_no_rpc_target_and_binds_by_location() {
        let members = r#""Id": {"shape": "Str", "location": "uri", "locationName": "Id"},
                         "Q": {"shape": "Strs", "location": "querystring", "locationName": "q"},
                         "H": {"shape": "Str", "location": "header", "locationName": "X-H"},
                         "B": {"shape": "Str", "locationName": "b"}"#;
        let src = emit("/things/{Id}?lit", members, "", "").unwrap();
        assert!(!src.contains("X-Amz-Target"), "{src}");
        assert!(src.contains("AwsRestUri.expand(String(\"/things/{Id}?lit\"), _ln, _lv)"), "{src}");
        assert!(src.contains("_uri.add_query(String(\"q\"), "), "{src}");
        assert!(src.contains("req.set_header(String(\"X-H\"), "), "{src}");
        // Only the body member is in the JSON body, under its wire name.
        assert!(src.contains("_body.set_member(String(\"b\"), "), "{src}");
        assert!(!src.contains("_body.set_member(String(\"X-H\")"), "{src}");
        assert!(!src.contains("_body.set_member(String(\"q\")"), "{src}");
    }
}
