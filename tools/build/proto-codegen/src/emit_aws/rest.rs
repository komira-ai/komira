//! The REST binding: each member of an operation's input and output shape
//! is bound to a part of the HTTP message by its `location`, and whatever
//! is left is the body: restJson1 with the JSON body codec, restXml with the
//! XML body codec (`xml_codec`).
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
//! - restXml differs only in the body: a structure payload is an XML
//!   document whose root element is named by the payload member's
//!   `locationName` (else the target shape's, else the shape name), and
//!   nothing when unset; the members with no location are the children of
//!   a root element named by the operation input's `locationName` (else
//!   the input shape's, else its name), and nothing when none is set (as
//!   botocore's `RestXMLSerializer` writes them). A root carries the
//!   `xmlNamespace` of its reference, else of its shape.
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

use super::proto::{AwsProtocol, Binding};
use super::{escape, ts_const, AwsEmitter, ROUTE53_ID_SHAPES};
use crate::aws_in::{AwsLocation, AwsOperationFacts, AwsPathParam, AwsTimestampFormat, AwsXmlNamespace};
use crate::ir::{IrField, IrMessage, IrMethod, IrType, Label, ScalarKind};

/// The restJson1 binding.
pub(super) struct AwsRestJson;

/// The restXml binding: the REST binding with the XML body codec.
pub(super) struct AwsRestXml;

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

    fn error_info_binding(&self) -> Option<&'static str> {
        Some("var info = aws_rest_json_error(res.to_response())")
    }

    fn error_code_and_message(&self) -> (&'static str, &'static str) {
        ("info.code.copy()", "info.message.copy()")
    }

    fn error_code_doc(&self) -> &'static str {
        "restJson1 error code"
    }
}

impl Binding for AwsRestXml {
    fn header_protocol(&self, em: &AwsEmitter) -> String {
        format!("{} (restXml)", em.meta.protocol)
    }

    fn emit_wire_constants(&self, em: &mut AwsEmitter) {
        let p = em.prefix.to_uppercase();
        em.line(&format!(
            "comptime {p}_CONTENT_TYPE: String = \"application/xml\""
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
        "String(\"\")".to_string()
    }

    fn send_notes(&self) -> &'static [&'static str] {
        &[
            "    A request with a body carries its own `Content-Type` header; one",
            "    without a body is signed and sent with none.",
        ]
    }

    fn error_info_binding(&self) -> Option<&'static str> {
        Some("var info = aws_rest_xml_error(res.to_response())")
    }

    fn error_code_and_message(&self) -> (&'static str, &'static str) {
        ("info.code.copy()", "info.message.copy()")
    }

    fn error_code_doc(&self) -> &'static str {
        "restXml error code"
    }
}

/// Where one member of a top-level shape goes, and the facts the binding
/// needs about it.
struct Bound {
    field: IrField,
    /// The member's name in the model.
    member: String,
    wire: String,
    location: AwsLocation,
    required: bool,
    json_value: bool,
    timestamp: Option<AwsTimestampFormat>,
    streaming: bool,
    is_payload: bool,
}

impl AwsEmitter<'_> {
    /// The REST protocol's name in docstrings.
    fn rest_name(&self) -> &'static str {
        match self.protocol {
            AwsProtocol::RestXml => "restXml",
            _ => "restJson1",
        }
    }

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
                member: mf.member_name.clone(),
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

    /// The `requestUri` a request is built from, its labels, and the label
    /// the endpoint ruleset fills instead (`None`: the model's, unchanged).
    ///
    /// `s3` with an endpoint ruleset drops a leading `/{Bucket}` label: the
    /// ruleset puts the bucket in the URL it chooses (the virtual host, or
    /// the endpoint's path for path-style addressing), so the model's path
    /// would name it twice. botocore drops it for the same reason
    /// (`remove_bucket_from_url_paths_from_model`, botocore/handlers.py). A
    /// path left empty is the root, `/`, which `AwsEndpoint.target_for`
    /// joins to the endpoint's path as botocore's `_urljoin` does
    /// (`/{Bucket}?list-type=2` is `/?list-type=2`, sent to a path-style
    /// endpoint as `/<bucket>?list-type=2`). The dropped member must be the
    /// ruleset's `Bucket` context parameter, or the bucket would be sent
    /// nowhere: anything else is refused.
    fn rest_request_uri(
        &self,
        facts: &AwsOperationFacts,
        msg: &IrMessage,
        members: &[Bound],
    ) -> Result<(String, Vec<AwsPathParam>, Option<&'static str>), String> {
        const LABEL: &str = "Bucket";
        let unchanged = Ok((facts.request_uri.clone(), facts.path_params.clone(), None));
        if !self.options.s3 || self.endpoint_rules.is_none() {
            return unchanged;
        }
        let rest = match facts.request_uri.strip_prefix("/{Bucket}") {
            Some(rest) if rest.is_empty() || rest.starts_with('/') || rest.starts_with('?') => rest,
            _ => return unchanged,
        };
        let b = members
            .iter()
            .find(|b| b.location == AwsLocation::Uri && b.wire == LABEL)
            .ok_or_else(|| {
                format!(
                    "emit_aws: `{}` requestUri `{}` has the label `{{{LABEL}}}`, and the \
                     input shape `{}` binds no `uri` member to it",
                    facts.name, facts.request_uri, msg.name
                )
            })?;
        let mf = self.facts.member(&msg.fq_name, &b.field.name)?;
        if mf.context_param.as_deref() != Some(LABEL) {
            return Err(format!(
                "emit_aws: `{}`.{} fills the label `{{{LABEL}}}` of requestUri `{}`, which \
                 the `s3` customization leaves to the endpoint ruleset, and it is not \
                 the ruleset's `{LABEL}` context parameter: the bucket would be sent nowhere",
                msg.name, b.field.name, facts.request_uri
            ));
        }
        let uri = if rest.starts_with('/') { rest.to_string() } else { format!("/{rest}") };
        let params = facts.path_params.iter().filter(|p| p.name != LABEL).cloned().collect();
        Ok((uri, params, Some(LABEL)))
    }

    fn emit_rest_request_builder(&mut self, m: &IrMethod, facts: &AwsOperationFacts) -> Result<(), String> {
        let in_ty = self.op_input_type(m);
        let fp = self.fn_prefix();
        let p = self.prefix.to_uppercase();
        let msg = self.message_by_fq(&m.input.fq_name)?.clone();
        let members = self.bound_members(&msg)?;
        let builder = if self.emit_route53_id_cut(m, facts, &msg)? {
            format!("_{fp}build_{}_request_bare_ids", m.name)
        } else {
            format!("{fp}build_{}_request", m.name)
        };
        self.line(&format!(
            "def {builder}(input: {in_ty}) raises -> AwsRequest:"
        ));
        self.push();
        self.line(&format!(
            "\"\"\"`{}` — the {} request, serialised and NOT signed.\"\"\"",
            facts.name,
            self.rest_name()
        ));
        self.emit_validate_call(m);

        // -- the URI: labels, then the query --------------------------------
        let (request_uri, path_params, ruleset_label) = self.rest_request_uri(facts, &msg, &members)?;
        self.line("var _ln = List[String]()");
        self.line("var _lv = List[String]()");
        for param in &path_params {
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
            if ruleset_label == Some(b.wire.as_str()) {
                continue;
            }
            if !path_params.iter().any(|p| p.name == b.wire) {
                return Err(format!(
                    "emit_aws: `{}`.{} is a `uri` member named `{}`, and requestUri `{}` \
                     has no such label",
                    msg.name, b.field.name, b.wire, facts.request_uri
                ));
            }
        }
        self.line(&format!(
            "var _uri = AwsRestUri.expand(String(\"{}\"), _ln, _lv)",
            escape(&request_uri)
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

        // `endpoint.hostPrefix`, with its `hostLabel` members substituted;
        // the client's sends prepend it to the resolved endpoint host.
        if let Some(hp) = &facts.host_prefix {
            let expr = self.host_prefix_expr(hp, &m.input.fq_name)?;
            self.line(&format!("req.host_prefix = {expr}"));
        }

        // -- the body --------------------------------------------------------
        if self.protocol == AwsProtocol::RestXml {
            self.emit_xml_request_body(facts, &msg, &members)?;
        } else if let Some(b) = members.iter().find(|b| b.is_payload) {
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
        self.emit_s3_request_checksum(facts, &msg, &members)?;
        self.line("return req^");
        self.pop();
        self.blank();
        Ok(())
    }

    /// `route53` (`fix_route53_ids`, see
    /// [`super::ROUTE53_CUSTOMIZATION`]): for an operation whose input has
    /// top-level members of a [`ROUTE53_ID_SHAPES`] shape, emits
    /// `build_<op>_request`, which copies the input, cuts each such member
    /// to the part after its last `/`, and builds the request from the copy
    /// through `_build_<op>_request_bare_ids`, emitted next by the caller.
    /// True when it did; nothing, and false, without the customization or
    /// for an operation with no such member.
    fn emit_route53_id_cut(
        &mut self,
        m: &IrMethod,
        facts: &AwsOperationFacts,
        msg: &IrMessage,
    ) -> Result<bool, String> {
        if !self.options.route53 {
            return Ok(false);
        }
        let mut cut = Vec::new();
        for f in &msg.fields {
            let mf = self.facts.member(&msg.fq_name, &f.name)?;
            if !ROUTE53_ID_SHAPES.contains(&mf.shape.as_str()) {
                continue;
            }
            if f.label == Label::Repeated || f.ty != IrType::Scalar(ScalarKind::String) {
                return Err(format!(
                    "emit_aws: `{}`.{} has the shape `{}`, which the `route53` \
                     customization cuts as one string, and it is not one",
                    msg.name, f.name, mf.shape
                ));
            }
            cut.push(f.clone());
        }
        if cut.is_empty() {
            return Ok(false);
        }
        let in_ty = self.op_input_type(m);
        let fp = self.fn_prefix();
        self.line(&format!(
            "def {fp}build_{}_request(input: {in_ty}) raises -> AwsRequest:",
            m.name
        ));
        self.push();
        self.line(&format!(
            "\"\"\"`{}` — the {} request, serialised and NOT signed. Each Route 53 Id",
            facts.name,
            self.rest_name()
        ));
        self.line("is sent as the part after its last `/`, as botocore's `fix_route53_ids`");
        self.line("sends it, so an Id Route 53 answered with can be passed back as it came.\"\"\"");
        self.line("var _bare = input.copy()");
        for f in &cut {
            let access = if self.required(msg, f) {
                if self.is_boxed(msg, f) {
                    format!("_bare.{}[0]", f.name)
                } else {
                    format!("_bare.{}", f.name)
                }
            } else {
                self.line(&format!("if {}:", self.presence_test_on("_bare", msg, f)));
                self.push();
                self.optional_access_on("_bare", msg, f)
            };
            self.line(&format!("{access} = _{fp}route53_bare_id({access})"));
            if !self.required(msg, f) {
                self.pop();
            }
        }
        self.line(&format!("return _{fp}build_{}_request_bare_ids(_bare)", m.name));
        self.pop();
        self.blank();
        Ok(true)
    }

    /// `route53`: the helper each `build_<op>_request` that cuts an Id
    /// calls, emitted once before the operations.
    pub(super) fn emit_route53_bare_id_helper(&mut self) {
        let fp = self.fn_prefix();
        self.line(&format!("def _{fp}route53_bare_id(id: String) -> String:"));
        self.push();
        self.line("\"\"\"The part of a Route 53 Id after its last `/`, as botocore's");
        self.line("`fix_route53_ids` sends it: `/hostedzone/Z1D633PJN98FT9` is");
        self.line("`Z1D633PJN98FT9`, and an Id with no `/` is itself.\"\"\"");
        self.line("var slash = id.rfind(\"/\")");
        self.line("if slash < 0:");
        self.push();
        self.line("return id.copy()");
        self.pop();
        self.line("return String(id[byte=slash + 1 :])");
        self.pop();
        self.blank();
    }

    /// `s3`: an operation whose `httpChecksum` names a
    /// `requestAlgorithmMember` sends the request checksum current AWS SDKs
    /// send by default (`when_supported`): `s3_apply_request_checksum`, over
    /// the built body, with the header that member is bound to. The same
    /// call serves an operation that requires the checksum
    /// (`requestChecksumRequired`), as botocore's does. Nothing without the
    /// customization, or for an operation with no such member; one of those
    /// that requires a checksum never gets here (`check_request_checksums`).
    fn emit_s3_request_checksum(
        &mut self,
        facts: &AwsOperationFacts,
        msg: &IrMessage,
        members: &[Bound],
    ) -> Result<(), String> {
        if !self.options.s3 {
            return Ok(());
        }
        let Some(member) = facts
            .http_checksum
            .as_ref()
            .and_then(|c| c.request_algorithm_member.as_ref())
        else {
            return Ok(());
        };
        let b = members.iter().find(|b| &b.member == member).ok_or_else(|| {
            format!(
                "emit_aws: `{}` names `{member}` as its httpChecksum \
                 requestAlgorithmMember, and its input shape `{}` has no such member",
                facts.name, msg.name
            )
        })?;
        if b.location != AwsLocation::Header {
            return Err(format!(
                "emit_aws: `{}`.{member} is `{}`'s httpChecksum requestAlgorithmMember \
                 and is not bound to a header; the checksum algorithm travels as one",
                msg.name, facts.name
            ));
        }
        // Whether the caller can carry another algorithm's value: an input
        // member bound to an `x-amz-checksum-*` header (PutObject's
        // ChecksumSHA256 and the like; DeleteObjects has none).
        let value_members = members.iter().any(|m| {
            m.location == AwsLocation::Header
                && m.wire.to_ascii_lowercase().starts_with("x-amz-checksum-")
        });
        self.line(&format!(
            "s3_apply_request_checksum(req, String(\"{}\"), value_members={})",
            escape(&b.wire),
            if value_members { "True" } else { "False" }
        ));
        Ok(())
    }

    /// The restXml request body (see the module doc): the structure payload
    /// as a document, a blob or string payload as its bytes, or the body
    /// members as the children of the input's root element.
    fn emit_xml_request_body(
        &mut self,
        facts: &AwsOperationFacts,
        msg: &IrMessage,
        members: &[Bound],
    ) -> Result<(), String> {
        let p = self.prefix.to_uppercase();
        if let Some(b) = members.iter().find(|b| b.is_payload) {
            match (&b.field.label, &b.field.ty) {
                (Label::Repeated, _) | (_, IrType::List(_)) | (_, IrType::Map(_, _)) => {
                    return Err(format!(
                        "emit_aws: `{}`.{} is the payload and is a list or a map; a \
                         payload is a structure, a blob or a string",
                        msg.name, b.field.name
                    ))
                }
                (_, IrType::Message(_)) => {
                    let (root, ns) = self.xml_payload_root(msg, b)?;
                    // An unset structure payload is no body at all.
                    let access = self.open_member(msg, b, "input");
                    self.line("var _w = XmlWriter()");
                    self.xml_root_open(&root, &ns);
                    self.line(&format!("{access}.write_aws_xml(_w)"));
                    self.line("aws_xml_end(_w)");
                    self.line("aws_xml_set_body(req, _w)");
                    self.set_content_type_default(&format!("String({p}_CONTENT_TYPE)"));
                    self.close_member(b);
                }
                (_, IrType::Scalar(ScalarKind::Bytes)) => {
                    let access = self.open_member(msg, b, "input");
                    self.line(&format!("req.body = {access}.copy()"));
                    self.set_content_type_default(&format!("String(\"{BLOB_CONTENT_TYPE}\")"));
                    self.close_member(b);
                }
                (_, IrType::Scalar(ScalarKind::String)) | (_, IrType::Enum(_))
                    if b.timestamp.is_none() =>
                {
                    let access = self.open_member(msg, b, "input");
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
            return Ok(());
        }
        let mut body: Vec<&Bound> = members
            .iter()
            .filter(|b| b.location == AwsLocation::Body)
            .collect();
        if body.is_empty() {
            return Ok(());
        }
        body.sort_by_key(|b| {
            self.facts
                .member(&msg.fq_name, &b.field.name)
                .map(|m| m.declared_index)
                .unwrap_or(usize::MAX)
        });
        let shape = self.facts.shape(&msg.name)?;
        let root = facts
            .input_location_name
            .clone()
            .or_else(|| shape.location_name.clone())
            .unwrap_or_else(|| msg.name.clone());
        let ns = facts
            .input_xml_namespace
            .clone()
            .or_else(|| shape.xml_namespace.clone());
        // No body member set is no body at all.
        if body.iter().any(|b| b.required) {
            self.line("var _xb = True");
        } else {
            self.line("var _xb = False");
            for b in &body {
                self.line(&format!("if {}:", self.presence_test_on("input", msg, &b.field)));
                self.push();
                self.line("_xb = True");
                self.pop();
            }
        }
        self.line("if _xb:");
        self.push();
        self.line("var _w = XmlWriter()");
        self.xml_root_open(&root, &ns);
        for b in &body {
            self.emit_xml_member_write(msg, &b.field, "input", "_w")?;
        }
        self.line("aws_xml_end(_w)");
        self.line("aws_xml_set_body(req, _w)");
        self.set_content_type_default(&format!("String({p}_CONTENT_TYPE)"));
        self.pop();
        Ok(())
    }

    /// Opens the document's root element `root` on the writer `_w`.
    fn xml_root_open(&mut self, root: &str, ns: &Option<AwsXmlNamespace>) {
        self.line(&format!("aws_xml_start(_w, String(\"{}\"))", escape(root)));
        if let Some(ns) = ns {
            self.line(&format!(
                "aws_xml_namespace(_w, String(\"{}\"), String(\"{}\"))",
                escape(&ns.prefix),
                escape(&ns.uri)
            ));
        }
    }

    /// The root element of a structure payload `b` of `msg`: the member's
    /// `locationName`, else the target shape's, else the shape's name; and
    /// the member's `xmlNamespace`, else the target shape's.
    fn xml_payload_root(
        &self,
        msg: &IrMessage,
        b: &Bound,
    ) -> Result<(String, Option<AwsXmlNamespace>), String> {
        let mf = self.facts.member(&msg.fq_name, &b.field.name)?;
        let target = self.facts.shape(&mf.shape)?;
        let root = if mf.has_location_name {
            mf.wire_name.clone()
        } else {
            target
                .location_name
                .clone()
                .unwrap_or_else(|| mf.shape.clone())
        };
        let ns = mf
            .xml_namespace
            .clone()
            .or_else(|| target.xml_namespace.clone());
        Ok((root, ns))
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
                "\"\"\"`{}` — the {} response without its body: the status and",
                facts.name,
                self.rest_name()
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
                "\"\"\"`{}` — the {} response: `parse_{}_head`, and the body",
                facts.name,
                self.rest_name(),
                m.name
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
            "\"\"\"`{}` — the {} response: the bound headers and status, and",
            facts.name,
            self.rest_name()
        ));
        self.line("    the body (an empty body sets nothing).\"\"\"");
        self.emit_s3_200_error_check(facts, &members);
        self.emit_rest_response_body(&msg, &members, true)?;
        self.pop();
        self.blank();
        Ok(())
    }

    /// `s3`: a 200 response whose body is an `<Error>` (or is not XML) is
    /// raised as the error an HTTP 500 is, in the client's text for one
    /// (`<Service>.<Op> failed: HTTP 500 <code> <message>`), for an
    /// operation that has an output shape whose payload is not a blob or a
    /// string (botocore `_handle_200_error` and `_should_handle_200_error`).
    /// A streaming payload is read by `parse_<op>_head`, which never checks.
    /// Nothing without the customization.
    fn emit_s3_200_error_check(&mut self, facts: &AwsOperationFacts, members: &[Bound]) {
        if !self.s3_answers_200_error(facts, members) {
            return;
        }
        // The service as the client's error builder names it: the prefix.
        let svc = self.prefix.clone();
        self.line("if aws_xml_body_is_error(resp):");
        self.push();
        self.line("var _ei = aws_rest_xml_error(resp)");
        self.line("raise Error(");
        self.push();
        self.line(&format!(
            "String(\"{}.{} failed: HTTP 500 \")",
            escape(&svc),
            escape(&facts.name)
        ));
        self.line("+ _ei.code");
        self.line("+ String(\" \")");
        self.line("+ _ei.message");
        self.pop();
        self.line(")");
        self.pop();
    }

    /// `s3`: whether S3 can answer the operation `facts` names, whose
    /// output members are `members`, with a 200 whose body is an `<Error>`
    /// (botocore `_should_handle_200_error`): it has an output shape, and
    /// that shape's payload, if it has one, is not a blob or a string.
    fn s3_answers_200_error(&self, facts: &AwsOperationFacts, members: &[Bound]) -> bool {
        if !self.options.s3 || facts.output_shape.is_none() {
            return false;
        }
        !members.iter().any(|b| {
            b.is_payload
                && matches!(
                    b.field.ty,
                    IrType::Scalar(ScalarKind::Bytes | ScalarKind::String) | IrType::Enum(_)
                )
        })
    }

    /// `s3`: whether the client must tell the send that S3 can answer the
    /// operation of `m` with a 200 whose body is an `<Error>`
    /// (`s3_answers_200_error`), so the send retries one as the 500 it is.
    pub(super) fn s3_send_reads_200_error(
        &self,
        m: &IrMethod,
        facts: &AwsOperationFacts,
    ) -> Result<bool, String> {
        if !self.options.s3 {
            return Ok(false);
        }
        let msg = self.message_by_fq(&m.output.fq_name)?.clone();
        let members = self.bound_members(&msg)?;
        Ok(self.s3_answers_200_error(facts, &members))
    }

    /// `s3`: whether the header member `b` is S3's optional `Expires`
    /// timestamp, which is left unset when it does not parse (botocore
    /// `handle_expires_header`).
    fn s3_expires_is_lenient(&self, b: &Bound, required: bool) -> bool {
        self.options.s3
            && !required
            && b.timestamp.is_some()
            && b.wire.eq_ignore_ascii_case("Expires")
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
        let xml = self.protocol == AwsProtocol::RestXml;
        // A response has no URI or query, so a restXml member bound to one
        // is read from the body (Smithy restXml; `IgnoreQueryParamsInResponse`).
        let from_body = |b: &Bound| {
            b.location == AwsLocation::Body
                || (xml && matches!(b.location, AwsLocation::Uri | AwsLocation::QueryString))
        };
        let body = !has_payload && members.iter().any(|b| from_body(b));
        if body && xml {
            // An empty body is a root with no members.
            self.line("var node = aws_xml_parse(resp.body)");
        } else if body {
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
            if from_body(b) && !has_payload {
                if xml {
                    self.emit_xml_read_required(msg, &b.field, &what, true)?;
                } else {
                    self.emit_json_read_required(msg, &b.field, &what)?;
                }
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
            if from_body(b) && !has_payload {
                if xml {
                    self.emit_xml_read_optional(msg, &b.field, true)?;
                } else {
                    self.emit_json_read_optional(msg, &b.field)?;
                }
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
            (Label::Single | Label::Optional, IrType::Message(_))
                if self.protocol == AwsProtocol::RestXml =>
            {
                let ty = self.value_type(msg, &b.field)?;
                format!("{ty}.from_aws_xml(aws_xml_parse(resp.body))")
            }
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
                        if self.s3_expires_is_lenient(b, required) {
                            // `s3`: an Expires that is not a date is left
                            // unset (botocore handle_expires_header).
                            self.line("try:");
                            self.push();
                            assign(self, &v);
                            self.pop();
                            self.line("except:");
                            self.push();
                            self.line("pass");
                            self.pop();
                        } else {
                            assign(self, &v);
                        }
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
                // botocore sets a prefix-header map whether or not a header
                // carries the prefix (`BaseRestParser._parse_non_payload_attrs`,
                // shared by every REST protocol; the restXml corpus's
                // `HttpPrefixHeadersAreNotPresent`), so every REST protocol
                // sets it here, empty when no header carries the prefix.
                self.line(&format!("var {tmp} = Dict[String, {vt}]()"));
                self.line(&format!("for _i in range(len({raw})):"));
                self.push();
                let value = self.rest_from_text(msg, b, v, &format!("{raw}[_i].value"))?;
                self.line(&format!("{tmp}[{raw}[_i].name] = {value}"));
                self.pop();
                assign(self, &format!("{tmp}^"));
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

    /// A restXml model with serviceId `service_id` holding Route 53's Id
    /// shapes as a label, an optional query value and a body member, and an
    /// operation with none; `ids` is the shape `Zones.Ids` targets.
    fn emit_route53(service_id: &str, route53: bool, ids: &str) -> Result<String, String> {
        emit_route53_with(service_id, route53, ids, "", true)
    }

    /// [`emit_route53`], with `token` more members of `MakeZoneIn` (empty for
    /// none) and in client mode unless `pure_only`.
    fn emit_route53_with(
        service_id: &str,
        route53: bool,
        ids: &str,
        token: &str,
        pure_only: bool,
    ) -> Result<String, String> {
        let model = parse(&format!(
            r#"{{"version": "2.0",
                "metadata": {{"apiVersion": "2026-10-02", "endpointPrefix": "route53",
                    "protocol": "rest-xml", "serviceFullName": "Tiny Route 53",
                    "serviceId": "{service_id}", "signatureVersion": "v4",
                    "uid": "route53-2026-10-02"}},
                "operations": {{
                    "GetZone": {{"name": "GetZone",
                        "http": {{"method": "GET", "requestUri": "/zone/{{Id}}"}},
                        "input": {{"shape": "GetZoneIn"}}}},
                    "ListZones": {{"name": "ListZones",
                        "http": {{"method": "GET", "requestUri": "/zones"}},
                        "input": {{"shape": "ListZonesIn"}}}},
                    "MakeZone": {{"name": "MakeZone",
                        "http": {{"method": "POST", "requestUri": "/zone"}},
                        "input": {{"shape": "MakeZoneIn", "locationName": "MakeZoneRequest"}}}},
                    "Ping": {{"name": "Ping",
                        "http": {{"method": "GET", "requestUri": "/ping"}},
                        "input": {{"shape": "PingIn"}}}}}},
                "shapes": {{
                    "GetZoneIn": {{"type": "structure", "required": ["Id"], "members": {{
                        "Id": {{"shape": "ResourceId", "location": "uri", "locationName": "Id"}}}}}},
                    "ListZonesIn": {{"type": "structure", "members": {{
                        "HostedZoneId": {{"shape": "ResourceId", "location": "querystring",
                            "locationName": "hostedzoneid"}},
                        "Name": {{"shape": "Str", "location": "querystring", "locationName": "name"}},
                        "Ids": {{"shape": "{ids}", "location": "querystring", "locationName": "ids"}}}}}},
                    "MakeZoneIn": {{"type": "structure", "members": {{
                        "DelegationSetId": {{"shape": "DelegationSetId"}}{token}}}}},
                    "PingIn": {{"type": "structure", "members": {{
                        "Name": {{"shape": "Str", "location": "querystring", "locationName": "name"}}}}}},
                    "ResourceId": {{"type": "string", "max": 32}},
                    "DelegationSetId": {{"type": "string", "max": 48}},
                    "ResourceIds": {{"type": "list", "member": {{"shape": "ResourceId"}}}},
                    "Strs": {{"type": "list", "member": {{"shape": "Str"}}}},
                    "Str": {{"type": "string"}}}}}}"#
        ))
        .map_err(|e| e.to_string())?;
        let lowering = lower_aws_service(
            &model,
            "route53",
            &["GetZone", "ListZones", "MakeZone", "Ping"].map(String::from),
            "route53.json",
            "aws.route53",
        )?;
        let options = AwsEmitOptions {
            pure_only,
            omit_preamble: true,
            route53,
            ..AwsEmitOptions::default()
        };
        emit_aws_client(&lowering, &AwsOverrides::empty(), "route53", options).map(|(_, s)| s)
    }

    #[test]
    fn the_route53_customization_is_refused_for_another_service() {
        let e = emit_route53("Tiny", true, "Strs").unwrap_err();
        assert!(e.contains("is refused unless the model's serviceId is `Route 53`"), "{e}");
    }

    #[test]
    fn the_route53_customization_cuts_each_top_level_id_before_building() {
        let src = emit_route53("Route 53", true, "Strs").unwrap();
        // The helper, once.
        assert_eq!(src.matches("_route53_bare_id(id: String) -> String:").count(), 1, "{src}");
        assert!(src.contains("var slash = id.rfind(\"/\")"), "{src}");
        // A required label: the public builder cuts the copy and calls the
        // builder proper, which validates and builds from it.
        assert!(src.contains("build_get_zone_request(input: "), "{src}");
        assert!(src.contains("_build_get_zone_request_bare_ids(input: "), "{src}");
        assert!(src.contains("_bare.id = "), "{src}");
        assert!(src.contains("return _"), "{src}");
        // An optional query value, cut only when present; another member
        // of the same input, and a list of strings, are left alone.
        assert!(src.contains("if _bare.hosted_zone_id:"), "{src}");
        assert!(src.contains("_bare.hosted_zone_id.value() = "), "{src}");
        assert!(!src.contains("_bare.name"), "{src}");
        assert!(!src.contains("_bare.ids"), "{src}");
        // A body member.
        assert!(src.contains("_bare.delegation_set_id.value() = "), "{src}");
        // An operation with no Id has one builder.
        assert!(!src.contains("build_ping_request_bare_ids"), "{src}");
        assert!(src.contains("build_ping_request(input: "), "{src}");
    }

    #[test]
    fn the_route53_customization_leaves_a_list_of_ids_alone() {
        // botocore matches the member's own shape, and a list of ResourceId
        // is a list shape, so it is sent as given.
        let src = emit_route53("Route 53", true, "ResourceIds").unwrap();
        assert!(!src.contains("_bare.ids"), "{src}");
        assert!(src.contains("_bare.hosted_zone_id.value() = "), "{src}");
    }

    #[test]
    fn a_filled_idempotency_token_and_a_cut_id_compose() {
        // A client verb fills the unset token on its own copy and hands it
        // to the public builder, which cuts the Id on a second copy and
        // builds from that: the request carries both, and neither step
        // undoes the other.
        let token = r#", "Token": {"shape": "Str", "idempotencyToken": true}"#;
        let src = emit_route53_with("Route 53", true, "Strs", token, false).unwrap();
        let fill = "        var filled = input.copy()\n        if not filled.token:\n            \
                    filled.token = Optional[String](aws_idempotency_token())\n        \
                    var req = route53_build_make_zone_request(filled)\n";
        assert_eq!(src.matches(fill).count(), 2, "{src}");
        assert_eq!(src.matches("aws_idempotency_token()").count(), 2, "{src}");
        assert!(src.contains("_bare.delegation_set_id.value() = "), "{src}");
        assert!(src.contains("return _route53_build_make_zone_request_bare_ids(_bare)"), "{src}");
        // The cut copies the filled input whole, so the token rides through
        // it untouched, and the cut is not applied to the token.
        assert!(!src.contains("_bare.token"), "{src}");
        // The verbs build only through the public builder, never around
        // the cut.
        assert!(!src.contains("_bare_ids(filled)"), "{src}");
        assert!(!src.contains("_bare_ids(input)"), "{src}");
        // Operations with no token build from the input as given.
        assert!(src.contains("var req = route53_build_get_zone_request(input)\n"), "{src}");
    }

    #[test]
    fn without_the_route53_customization_no_id_is_cut() {
        let src = emit_route53("Route 53", false, "Strs").unwrap();
        assert!(!src.contains("_route53_bare_id"), "{src}");
        assert!(!src.contains("_bare_ids"), "{src}");
        assert!(!src.contains("_bare."), "{src}");
    }
}
