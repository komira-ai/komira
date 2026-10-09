//! The awsQuery (`query`) and ec2Query (`ec2`) protocols: the input as the
//! form parameters of a `POST` body, the output read from an XML document.
//!
//! Request (`build_<op>_request`), as botocore's `QuerySerializer` and
//! `EC2Serializer` write it (botocore/serialize.py):
//!
//! - The body is `application/x-www-form-urlencoded; charset=utf-8`:
//!   `Action=<operation>&Version=<apiVersion>`, then one parameter per
//!   scalar the input holds, in declared member order
//!   (`komira_aws_core.AwsQueryWriter`, which percent-encodes as botocore
//!   does). Every member is a parameter, whatever its `location`.
//! - A member is named by its `locationName`, else its member name, and a
//!   member of a nested structure is `<outer>.<name>`. ec2Query names it by
//!   its `queryName`, else its `locationName` with the first letter
//!   capitalized, else its member name.
//! - A scalar is `komira_aws_core`'s `aws_text_*` text: "true" / "false",
//!   the decimal integer, the number or "NaN" / "Infinity" / "-Infinity",
//!   standard base64, a timestamp in the member's format (date-time by
//!   default). One divergence from botocore: a fraction of a second is
//!   written as milliseconds (`aws_text_ts`) in date-time and epoch-seconds,
//!   where botocore writes six digits and whole seconds respectively
//!   (`komira_aws_core/aws_query.mojo`'s header; pinned by test_aws_query).
//! - awsQuery lists: wrapped, `<name>.<member>.<i>` from 1, the item name the
//!   list member's `locationName` or `member`; flattened (the member or the
//!   list shape says `flattened`), `<name>.<i>`, and when the list member
//!   has a `locationName` that name replaces the last segment of
//!   `<name>`, as botocore does (`Hi.1` becomes `item.1`). An empty list is
//!   the one parameter `<name>=`.
//! - ec2Query lists: always `<name>.<i>`, and an empty list writes nothing.
//! - Maps: `<name>.entry.<i>.key` and `<name>.entry.<i>.value` (flattened:
//!   no `entry`), the key and value named by their `locationName`
//!   (ec2Query: `queryName`, else the capitalized `locationName`), in the
//!   map's order; an empty map writes nothing.
//!
//! Response (`parse_<op>_response`): the members are read by the XML codec
//! (`xml_codec`, maps included) from the element the operation's
//! `resultWrapper` names under the root (`komira_aws_core.aws_query_result`,
//! botocore's `QueryParser`), else from the root itself (ec2Query has no
//! wrapper). An operation with no output reads nothing. An empty body is
//! read as an empty element, so a 200 with no body sets no member. That is
//! what the awsQuery protocol tests require: `QueryEmptyInputAndEmptyOutput`
//! and `QueryNoInputAndOutput` answer an operation with an output shape
//! with a 200 and no body, and expect an empty result. botocore's
//! `QueryParser` and `EC2QueryParser` raise a `ResponseParserError` on an
//! empty body; its protocol-test harness passes those two cases only by
//! substituting `<xml/>` for a query response that has no body
//! (`tests/unit/test_protocols.py`).
//!
//! Errors: `komira_aws_core.aws_query_error`, which reads
//! `<ErrorResponse><Error>` and ec2Query's `<Response><Errors><Error>`
//! through the shared XML error reader (`aws_xml_error_info`).
//!
//! REFUSED by name before any text is emitted ([`check_query_features`]): a
//! `union` and an `xmlAttribute` member, which the XML codec does not read.

use super::proto::{AwsProtocol, Binding, BodyCodec};
use super::{escape, ts_const, AwsEmitter};
use crate::aws_in::{AwsFacts, AwsMemberFacts, AwsOperationFacts};
use crate::ir::{IrField, IrMessage, IrMethod, IrType, Label, ScalarKind};

/// The awsQuery and ec2Query body codec: the form encoder, and the XML
/// codec's decoder.
pub(super) struct AwsQueryCodec;

/// The awsQuery binding.
pub(super) struct AwsQueryBinding;

/// The ec2Query binding.
pub(super) struct AwsEc2Binding;

impl BodyCodec for AwsQueryCodec {
    fn emit_shape_doc(&self, em: &mut AwsEmitter, _is_union: bool, is_synthetic: bool) {
        if is_synthetic {
            em.line("    SYNTHESISED: the operation declares no shape here, so its request");
            em.line("    sends only Action and Version, or its response reads nothing.");
            em.blank();
        }
        em.line("    Required members are plain fields taken by `__init__`; every other");
        em.line("    member is `Optional[...]` and writes no parameter when unset.\"\"\"");
    }

    fn emit_encoder(&self, em: &mut AwsEmitter, msg: &IrMessage, _is_union: bool) -> Result<(), String> {
        em.emit_to_query(msg)
    }

    fn emit_decoder(&self, em: &mut AwsEmitter, msg: &IrMessage) -> Result<(), String> {
        em.emit_from_xml(msg)
    }

    fn emit_model_value(&self, em: &mut AwsEmitter, msg: &IrMessage) -> Result<(), String> {
        em.emit_model_json(msg)
    }
}

impl Binding for AwsQueryBinding {
    fn header_protocol(&self, em: &AwsEmitter) -> String {
        format!("{} (awsQuery)", em.meta.protocol)
    }

    fn emit_wire_constants(&self, em: &mut AwsEmitter) {
        emit_api_version(em);
    }

    fn emit_request_builder(&self, em: &mut AwsEmitter, m: &IrMethod, facts: &AwsOperationFacts) -> Result<(), String> {
        em.emit_query_request_builder(m, facts)
    }

    fn emit_response_parser(&self, em: &mut AwsEmitter, m: &IrMethod, facts: &AwsOperationFacts) -> Result<(), String> {
        em.emit_query_response_parser(m, facts)
    }

    fn default_content_type(&self, _em: &AwsEmitter) -> String {
        "AWS_QUERY_CONTENT_TYPE".to_string()
    }

    fn send_notes(&self) -> &'static [&'static str] {
        QUERY_SEND_NOTES
    }

    fn error_info_binding(&self) -> Option<&'static str> {
        Some("var info = aws_query_error(res.to_response())")
    }

    fn error_code_and_message(&self) -> (&'static str, &'static str) {
        ("info.code.copy()", "info.message.copy()")
    }

    fn error_code_doc(&self) -> &'static str {
        "awsQuery error code"
    }
}

impl Binding for AwsEc2Binding {
    fn header_protocol(&self, em: &AwsEmitter) -> String {
        format!("{} (ec2Query)", em.meta.protocol)
    }

    fn emit_wire_constants(&self, em: &mut AwsEmitter) {
        emit_api_version(em);
    }

    fn emit_request_builder(&self, em: &mut AwsEmitter, m: &IrMethod, facts: &AwsOperationFacts) -> Result<(), String> {
        em.emit_query_request_builder(m, facts)
    }

    fn emit_response_parser(&self, em: &mut AwsEmitter, m: &IrMethod, facts: &AwsOperationFacts) -> Result<(), String> {
        em.emit_query_response_parser(m, facts)
    }

    fn default_content_type(&self, _em: &AwsEmitter) -> String {
        "AWS_QUERY_CONTENT_TYPE".to_string()
    }

    fn send_notes(&self) -> &'static [&'static str] {
        QUERY_SEND_NOTES
    }

    fn error_info_binding(&self) -> Option<&'static str> {
        Some("var info = aws_query_error(res.to_response())")
    }

    fn error_code_and_message(&self) -> (&'static str, &'static str) {
        ("info.code.copy()", "info.message.copy()")
    }

    fn error_code_doc(&self) -> &'static str {
        "ec2Query error code"
    }
}

const QUERY_SEND_NOTES: &[&str] = &[
    "    The request is a form body (`Action`, `Version` and the input's",
    "    parameters), sent as `application/x-www-form-urlencoded`.",
];

/// `<PREFIX>_API_VERSION`: the `Version` every request carries.
fn emit_api_version(em: &mut AwsEmitter) {
    let p = em.prefix.to_uppercase();
    em.line(&format!(
        "comptime {p}_API_VERSION: String = \"{}\"",
        escape(&em.meta.api_version)
    ));
}

/// The awsQuery / ec2Query features this module refuses, checked over every
/// shape and member a lowering reaches. The error carries the refusal
/// marker the conformance harness reads (`REFUSED <name>:`).
pub(super) fn check_query_features(facts: &AwsFacts, protocol: AwsProtocol) -> Result<(), String> {
    let name = protocol.botocore_name();
    for (shape, s) in facts.shapes() {
        if s.union {
            return Err(format!(
                "emit_aws: REFUSED union: shape `{shape}` is a `union`, and the `{name}` \
                 codec writes and reads structures only. A union has exactly one member, \
                 which a structure codec would neither enforce on write nor check on read."
            ));
        }
    }
    for ((owner, field), m) in facts.members() {
        if m.xml_attribute {
            return Err(format!(
                "emit_aws: REFUSED xml-attribute: member `{}` of `{owner}` (`{field}`) is \
                 bound to an XML attribute (`xmlAttribute`), and the `{name}` response \
                 codec reads members as elements only.",
                m.member_name
            ));
        }
    }
    Ok(())
}

/// The first letter of `s` upper-cased, as ec2Query names a member by its
/// `locationName`.
fn capitalized(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

impl AwsEmitter<'_> {
    fn is_ec2(&self) -> bool {
        self.protocol == AwsProtocol::Ec2
    }

    /// The parameter name of member `mf`: its `locationName`, else its
    /// member name; ec2Query: its `queryName`, else its `locationName`
    /// capitalized, else its member name.
    fn query_member_name(&self, mf: &AwsMemberFacts) -> String {
        if self.is_ec2() {
            if let Some(q) = &mf.query_name {
                return q.clone();
            }
            if mf.has_location_name {
                return capitalized(&mf.wire_name);
            }
            return mf.member_name.clone();
        }
        mf.wire_name.clone()
    }

    /// The name of a map's key or value parameter: `location_name`, else
    /// `default`; ec2Query: `query_name`, else `location_name` capitalized,
    /// else `default`.
    fn query_map_part(
        &self,
        query_name: &Option<String>,
        location_name: &Option<String>,
        default: &str,
    ) -> String {
        if self.is_ec2() {
            if let Some(q) = query_name {
                return q.clone();
            }
            return location_name
                .as_deref()
                .map(capitalized)
                .unwrap_or_else(|| default.to_string());
        }
        location_name.clone().unwrap_or_else(|| default.to_string())
    }

    // ======================================================================
    // The encoder
    // ======================================================================

    pub(super) fn emit_to_query(&mut self, msg: &IrMessage) -> Result<(), String> {
        self.line("def write_aws_query(self, mut q: AwsQueryWriter, prefix: String) raises:");
        self.push();
        self.line("\"\"\"This shape's members, as form parameters named under `prefix`.\"\"\"");
        let mut fields: Vec<IrField> = msg.fields.clone();
        self.sort_by_declared(msg, &mut fields);
        if fields.is_empty() {
            self.line("pass");
        }
        for f in &fields {
            let mf = self.facts.member(&msg.fq_name, &f.name)?.clone();
            let key = format!(
                "aws_query_key(prefix, String(\"{}\"))",
                escape(&self.query_member_name(&mf))
            );
            let required = self.required(msg, f);
            let access = if required {
                if self.is_boxed(msg, f) {
                    format!("self.{}[0]", f.name)
                } else {
                    format!("self.{}", f.name)
                }
            } else {
                self.line(&format!("if {}:", self.presence_test(msg, f)));
                self.push();
                self.optional_access(msg, f)
            };
            match (&f.label, &f.ty) {
                (Label::Repeated, ty) => {
                    self.query_write_list(msg, f, ty, &mf.shape, mf.flattened, &key, &access, 1)?
                }
                (_, ty) => {
                    self.query_write_value(msg, f, ty, &mf.shape, mf.flattened, &key, &access, 1)?
                }
            }
            if !required {
                self.pop();
            }
        }
        self.pop();
        Ok(())
    }

    /// The statements writing ONE value of type `ty` (AWS shape `shape`) as
    /// the parameters named by the Mojo expression `key`. `member_flattened`
    /// is the referring member's own `flattened`, for a list or a map.
    #[allow(clippy::too_many_arguments)]
    fn query_write_value(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        ty: &IrType,
        shape: &str,
        member_flattened: bool,
        key: &str,
        access: &str,
        depth: usize,
    ) -> Result<(), String> {
        match ty {
            IrType::List(e) => {
                self.query_write_list(msg, f, e, shape, member_flattened, key, access, depth)
            }
            IrType::Map(_, v) => {
                self.query_write_map(msg, f, v, shape, member_flattened, key, access, depth)
            }
            IrType::Message(_) => {
                self.line(&format!("{access}.write_aws_query(q, {key})"));
                Ok(())
            }
            scalar => {
                let text = query_scalar_text(scalar, self.timestamp_format(msg, f), access)?;
                self.line(&format!("q.add({key}, {text})"));
                Ok(())
            }
        }
    }

    /// A list of `elem_ty` (list shape `shape`) under `key`.
    #[allow(clippy::too_many_arguments)]
    fn query_write_list(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        elem_ty: &IrType,
        shape: &str,
        member_flattened: bool,
        key: &str,
        access: &str,
        depth: usize,
    ) -> Result<(), String> {
        let s = self.facts.shape(shape)?.clone();
        let elem_shape = s
            .element_shape
            .clone()
            .ok_or_else(|| format!("emit_aws: list shape `{shape}` has no member shape"))?;
        let k = format!("_qk{depth}_{}", f.name);
        let pfx = format!("_qp{depth}_{}", f.name);
        let iv = format!("_qi{depth}_{}", f.name);
        self.line(&format!("var {k} = {key}"));
        if self.is_ec2() {
            // EC2Serializer._serialize_type_list: `<name>.<i>`, nothing for
            // an empty list.
            self.line(&format!("for {iv} in range(len({access})):"));
            self.push();
            let item_key = format!("aws_query_key({k}, String({iv} + 1))");
            self.query_write_value(msg, f, elem_ty, &elem_shape, false, &item_key, &format!("{access}[{iv}]"), depth + 1)?;
            self.pop();
            return Ok(());
        }
        // QuerySerializer._serialize_type_list.
        self.line(&format!("if len({access}) == 0:"));
        self.push();
        self.line(&format!("q.add({k}, String(\"\"))"));
        self.pop();
        self.line("else:");
        self.push();
        if member_flattened || s.flattened {
            match &s.list_member_location_name {
                Some(name) => self.line(&format!(
                    "var {pfx} = aws_query_rename_last({k}, String(\"{}\"))",
                    escape(name)
                )),
                None => self.line(&format!("var {pfx} = {k}.copy()")),
            }
        } else {
            let item = s
                .list_member_location_name
                .clone()
                .unwrap_or_else(|| "member".to_string());
            self.line(&format!(
                "var {pfx} = aws_query_key({k}, String(\"{}\"))",
                escape(&item)
            ));
        }
        self.line(&format!("for {iv} in range(len({access})):"));
        self.push();
        let item_key = format!("aws_query_key({pfx}, String({iv} + 1))");
        self.query_write_value(msg, f, elem_ty, &elem_shape, false, &item_key, &format!("{access}[{iv}]"), depth + 1)?;
        self.pop();
        self.pop();
        Ok(())
    }

    /// A map of `value_ty` (map shape `shape`) under `key`.
    #[allow(clippy::too_many_arguments)]
    fn query_write_map(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        value_ty: &IrType,
        shape: &str,
        member_flattened: bool,
        key: &str,
        access: &str,
        depth: usize,
    ) -> Result<(), String> {
        let s = self.facts.shape(shape)?.clone();
        let value_shape = s
            .element_shape
            .clone()
            .ok_or_else(|| format!("emit_aws: map shape `{shape}` has no value shape"))?;
        let key_name = self.query_map_part(&s.map_key_query_name, &s.map_key_location_name, "key");
        let value_name =
            self.query_map_part(&s.map_value_query_name, &s.map_value_location_name, "value");
        let k = format!("_qk{depth}_{}", f.name);
        let n = format!("_qn{depth}_{}", f.name);
        let e = format!("_qe{depth}_{}", f.name);
        let ep = format!("_qp{depth}_{}", f.name);
        if member_flattened || s.flattened {
            self.line(&format!("var {k} = {key}"));
        } else {
            self.line(&format!("var {k} = aws_query_key({key}, String(\"entry\"))"));
        }
        self.line(&format!("var {n} = 0"));
        self.line(&format!("for {e} in {access}.items():"));
        self.push();
        self.line(&format!("{n} += 1"));
        self.line(&format!("var {ep} = aws_query_key({k}, String({n}))"));
        self.line(&format!(
            "q.add(aws_query_key({ep}, String(\"{}\")), {e}.key)",
            escape(&key_name)
        ));
        let value_key = format!("aws_query_key({ep}, String(\"{}\"))", escape(&value_name));
        self.query_write_value(msg, f, value_ty, &value_shape, false, &value_key, &format!("{e}.value"), depth + 1)?;
        self.pop();
        Ok(())
    }

    // ======================================================================
    // The binding
    // ======================================================================

    fn query_protocol_name(&self) -> &'static str {
        if self.is_ec2() {
            "ec2Query"
        } else {
            "awsQuery"
        }
    }

    pub(super) fn emit_query_request_builder(
        &mut self,
        m: &IrMethod,
        facts: &AwsOperationFacts,
    ) -> Result<(), String> {
        let in_ty = self.op_input_type(m);
        let p = self.prefix.to_uppercase();
        let fp = self.fn_prefix();
        self.line(&format!(
            "def {fp}build_{}_request(input: {in_ty}) raises -> AwsRequest:",
            m.name
        ));
        self.push();
        self.line(&format!(
            "\"\"\"`{}` — the {} request, a form body, serialised and NOT signed.\"\"\"",
            facts.name,
            self.query_protocol_name()
        ));
        self.emit_validate_call(m);
        self.line(&format!(
            "var req = AwsRequest(String(\"{}\"), String(\"{}\"))",
            facts.http_method.to_uppercase(),
            escape(&facts.path)
        ));
        // `endpoint.hostPrefix`, with its `hostLabel` members substituted;
        // the client's sends prepend it to the resolved endpoint host.
        if let Some(hp) = &facts.host_prefix {
            let expr = self.host_prefix_expr(hp, &m.input.fq_name)?;
            self.line(&format!("req.host_prefix = {expr}"));
        }
        self.line(&format!(
            "var q = AwsQueryWriter(String(\"{}\"), String({p}_API_VERSION))",
            escape(&facts.name)
        ));
        self.line("input.write_aws_query(q, String(\"\"))");
        self.line("aws_query_set_body(req, q)");
        self.line("return req^");
        self.pop();
        self.blank();
        Ok(())
    }

    pub(super) fn emit_query_response_parser(
        &mut self,
        m: &IrMethod,
        facts: &AwsOperationFacts,
    ) -> Result<(), String> {
        let out_ty = self.op_output_type(m);
        let fp = self.fn_prefix();
        self.line(&format!(
            "def {fp}parse_{}_response(resp: AwsResponse) raises -> {out_ty}:",
            m.name
        ));
        self.push();
        if facts.synthesized_output {
            self.line(&format!(
                "\"\"\"`{}` — the operation declares no output, so nothing is read.\"\"\"",
                facts.name
            ));
            self.line("_ = resp");
            self.line(&format!("return {out_ty}()"));
        } else if let Some(wrapper) = &facts.result_wrapper {
            self.line(&format!(
                "\"\"\"`{}` — the {} response: the members of `<{}>`, under the",
                facts.name,
                self.query_protocol_name(),
                wrapper
            ));
            self.line("    root element (an empty body sets nothing).\"\"\"");
            self.line(&format!(
                "return {out_ty}.from_aws_xml(aws_query_result(resp.body, String(\"{}\")))",
                escape(wrapper)
            ));
        } else {
            self.line(&format!(
                "\"\"\"`{}` — the {} response: the members of the root element",
                facts.name,
                self.query_protocol_name()
            ));
            self.line("    (an empty body sets nothing).\"\"\"");
            self.line(&format!("return {out_ty}.from_aws_xml(aws_xml_parse(resp.body))"));
        }
        self.pop();
        self.blank();
        Ok(())
    }
}

/// The text of one scalar `access` as a form value.
fn query_scalar_text(
    ty: &IrType,
    ts: Option<crate::aws_in::AwsTimestampFormat>,
    access: &str,
) -> Result<String, String> {
    Ok(match ty {
        IrType::Enum(_) => access.to_string(),
        IrType::Scalar(ScalarKind::String) => match ts {
            Some(fmt) => format!("aws_text_ts({access}, {})", ts_const(fmt)),
            None => access.to_string(),
        },
        IrType::Scalar(ScalarKind::Bool) => format!("aws_text_bool({access})"),
        IrType::Scalar(ScalarKind::Double) => format!("aws_text_f64({access})"),
        IrType::Scalar(ScalarKind::Float) => format!("aws_text_f32({access})"),
        IrType::Scalar(ScalarKind::Bytes) => format!("aws_text_blob(Span({access}))"),
        IrType::Scalar(_) => format!("aws_text_int(Int64({access}))"),
        other => return Err(format!("emit_aws: {other:?} is not a query scalar")),
    })
}

#[cfg(test)]
mod tests {
    use crate::aws_in::lower_aws_service;
    use crate::emit_aws::{emit_aws_client, AwsEmitOptions};
    use crate::json::parse;
    use crate::overrides::AwsOverrides;

    /// A one-operation model of `protocol` (`query` or `ec2`): `input` and
    /// `output` are the operation's references, `shapes` the model's shapes.
    fn emit_in(
        protocol: &str,
        input: &str,
        output: &str,
        shapes: &str,
        pure_only: bool,
    ) -> Result<String, String> {
        let model = parse(&format!(
            r#"{{"version": "2.0",
                "metadata": {{"apiVersion": "2026-10-02", "endpointPrefix": "tiny",
                    "protocol": "{protocol}", "serviceFullName": "Tiny",
                    "serviceId": "Tiny", "signatureVersion": "v4",
                    "uid": "tiny-2026-10-02"}},
                "operations": {{"Op": {{"name": "Op",
                    "http": {{"method": "POST", "requestUri": "/"}},
                    "input": {input}, "output": {output}}}}},
                "shapes": {{{shapes}}}}}"#
        ))
        .map_err(|e| e.to_string())?;
        let lowering =
            lower_aws_service(&model, "tiny", &["Op".to_string()], "tiny.json", "aws.tiny")?;
        let options = AwsEmitOptions {
            pure_only,
            omit_preamble: true,
            ..AwsEmitOptions::default()
        };
        emit_aws_client(&lowering, &AwsOverrides::empty(), "tiny", options).map(|(_, s)| s)
    }

    fn emit(protocol: &str, shapes: &str) -> String {
        emit_in(
            protocol,
            r#"{"shape": "In"}"#,
            r#"{"shape": "Out", "resultWrapper": "OpResult"}"#,
            &format!(r#"{shapes}, "Out": {{"type": "structure", "members": {{"A": {{"shape": "Str"}}}}}}"#),
            true,
        )
        .unwrap()
    }

    /// The text of the function `name` in `src`, up to the next definition
    /// at the same indent.
    fn function<'a>(src: &'a str, name: &str) -> &'a str {
        let at = src.find(&format!("def {name}(")).expect(name);
        let rest = &src[at..];
        let end = rest[1..].find("\ndef ").map_or(rest.len(), |e| e + 1);
        &rest[..end]
    }

    /// The `write_aws_query` method of the shape `ty`.
    fn encoder<'a>(src: &'a str, ty: &str) -> &'a str {
        let at = src.find(&format!("struct {ty}(")).expect(ty);
        let rest = &src[at..];
        let w = rest.find("def write_aws_query(").expect("write_aws_query");
        let rest = &rest[w..];
        let end = rest[1..].find("\n    @staticmethod").map_or(rest.len(), |e| e + 1);
        &rest[..end]
    }

    const STR: &str = r#""Str": {"type": "string"}"#;

    #[test]
    fn the_request_is_a_form_body_with_action_and_version() {
        let src = emit("query", &format!(
            r#""In": {{"type": "structure", "members": {{"A": {{"shape": "Str"}}}}}}, {STR}"#
        ));
        assert!(src.contains("comptime TINY_API_VERSION: String = \"2026-10-02\""), "{src}");
        let b = function(&src, "tiny_build_op_request");
        for want in [
            "var req = AwsRequest(String(\"POST\"), String(\"/\"))",
            "var q = AwsQueryWriter(String(\"Op\"), String(TINY_API_VERSION))",
            "input.write_aws_query(q, String(\"\"))",
            "aws_query_set_body(req, q)",
        ] {
            assert!(b.contains(want), "`{want}` missing:\n{b}");
        }
    }

    #[test]
    fn members_are_named_by_location_name_in_declared_order() {
        let src = emit("query", &format!(
            r#""In": {{"type": "structure", "members": {{
                   "Zed": {{"shape": "Str"}},
                   "Alpha": {{"shape": "Str", "locationName": "alpha"}},
                   "Flag": {{"shape": "Bool"}},
                   "N": {{"shape": "Int"}},
                   "B": {{"shape": "Blob"}},
                   "T": {{"shape": "Ts"}},
                   "S": {{"shape": "Sub"}}}}}},
               "Sub": {{"type": "structure", "members": {{"X": {{"shape": "Str"}}}}}},
               "Bool": {{"type": "boolean"}}, "Int": {{"type": "integer"}},
               "Blob": {{"type": "blob"}}, "Ts": {{"type": "timestamp"}}, {STR}"#
        ));
        let e = encoder(&src, "TinyIn");
        let zed = e.find("String(\"Zed\")").expect("Zed");
        let alpha = e.find("String(\"alpha\")").expect("alpha");
        assert!(zed < alpha, "{e}");
        for want in [
            "aws_text_bool(self.flag.value())",
            "aws_text_int(Int64(self.n.value()))",
            "aws_text_blob(Span(self.b.value()))",
            "aws_text_ts(self.t.value(), AWS_TS_ISO8601)",
            "self.s.value().write_aws_query(q, aws_query_key(prefix, String(\"S\")))",
        ] {
            assert!(e.contains(want), "`{want}` missing:\n{e}");
        }
    }

    #[test]
    fn query_lists_are_wrapped_flattened_or_renamed_and_empty_is_one_parameter() {
        let src = emit("query", &format!(
            r#""In": {{"type": "structure", "members": {{
                   "W": {{"shape": "L"}},
                   "R": {{"shape": "Named"}},
                   "F": {{"shape": "L", "flattened": true}},
                   "H": {{"shape": "Named", "flattened": true, "locationName": "Hi"}}}}}},
               "L": {{"type": "list", "member": {{"shape": "Str"}}}},
               "Named": {{"type": "list", "member": {{"shape": "Str", "locationName": "item"}}}},
               {STR}"#
        ));
        let e = encoder(&src, "TinyIn");
        for want in [
            "q.add(_qk1_w, String(\"\"))",
            "var _qp1_w = aws_query_key(_qk1_w, String(\"member\"))",
            "var _qp1_r = aws_query_key(_qk1_r, String(\"item\"))",
            "var _qp1_f = _qk1_f.copy()",
            // botocore replaces the last segment with the member's name.
            "var _qp1_h = aws_query_rename_last(_qk1_h, String(\"item\"))",
            "q.add(aws_query_key(_qp1_w, String(_qi1_w + 1)), self.w.value()[_qi1_w])",
        ] {
            assert!(e.contains(want), "`{want}` missing:\n{e}");
        }
    }

    #[test]
    fn maps_are_entries_with_their_key_and_value_names() {
        let src = emit("query", &format!(
            r#""In": {{"type": "structure", "members": {{
                   "M": {{"shape": "M"}},
                   "F": {{"shape": "Kv", "flattened": true, "locationName": "Attr"}}}}}},
               "M": {{"type": "map", "key": {{"shape": "Str"}}, "value": {{"shape": "Str"}}}},
               "Kv": {{"type": "map", "key": {{"shape": "Str", "locationName": "Name"}},
                      "value": {{"shape": "Str", "locationName": "Value"}}}},
               {STR}"#
        ));
        let e = encoder(&src, "TinyIn");
        for want in [
            "var _qk1_m = aws_query_key(aws_query_key(prefix, String(\"M\")), String(\"entry\"))",
            "q.add(aws_query_key(_qp1_m, String(\"key\")), _qe1_m.key)",
            "q.add(aws_query_key(_qp1_m, String(\"value\")), _qe1_m.value)",
            "var _qk1_f = aws_query_key(prefix, String(\"Attr\"))",
            "q.add(aws_query_key(_qp1_f, String(\"Name\")), _qe1_f.key)",
            "q.add(aws_query_key(_qp1_f, String(\"Value\")), _qe1_f.value)",
        ] {
            assert!(e.contains(want), "`{want}` missing:\n{e}");
        }
    }

    #[test]
    fn ec2_names_by_query_name_then_capitalized_location_name_and_never_wraps_a_list() {
        let src = emit("ec2", &format!(
            r#""In": {{"type": "structure", "members": {{
                   "plain": {{"shape": "Str"}},
                   "Q": {{"shape": "Str", "queryName": "QueryOne", "locationName": "q"}},
                   "U": {{"shape": "Str", "locationName": "usesXmlName"}},
                   "L": {{"shape": "L"}}}}}},
               "L": {{"type": "list", "member": {{"shape": "Str", "locationName": "item"}}}},
               {STR}"#
        ));
        let e = encoder(&src, "TinyIn");
        for want in [
            "aws_query_key(prefix, String(\"plain\"))",
            "aws_query_key(prefix, String(\"QueryOne\"))",
            "aws_query_key(prefix, String(\"UsesXmlName\"))",
            "q.add(aws_query_key(_qk1_l, String(_qi1_l + 1)), self.l.value()[_qi1_l])",
        ] {
            assert!(e.contains(want), "`{want}` missing:\n{e}");
        }
        // No `member` segment and no empty-list parameter.
        assert!(!e.contains("String(\"member\")"), "{e}");
        assert!(!e.contains("String(\"item\")"), "{e}");
        assert!(!e.contains("String(\"\"))"), "{e}");
    }

    #[test]
    fn the_response_is_read_from_the_result_wrapper_or_the_root() {
        let src = emit("query", &format!(
            r#""In": {{"type": "structure", "members": {{}}}}, {STR}"#
        ));
        let p = function(&src, "tiny_parse_op_response");
        assert!(
            p.contains("return TinyOut.from_aws_xml(aws_query_result(resp.body, String(\"OpResult\")))"),
            "{p}"
        );
        let ec2 = emit_in(
            "ec2",
            r#"{"shape": "In"}"#,
            r#"{"shape": "Out"}"#,
            &format!(
                r#""In": {{"type": "structure", "members": {{}}}},
                   "Out": {{"type": "structure", "members": {{"A": {{"shape": "Str"}}}}}}, {STR}"#
            ),
            true,
        )
        .unwrap();
        let p = function(&ec2, "tiny_parse_op_response");
        assert!(p.contains("return TinyOut.from_aws_xml(aws_xml_parse(resp.body))"), "{p}");
    }

    #[test]
    fn an_output_map_is_read_entry_by_entry() {
        let src = emit_in(
            "query",
            r#"{"shape": "In"}"#,
            r#"{"shape": "Out", "resultWrapper": "OpResult"}"#,
            &format!(
                r#""In": {{"type": "structure", "members": {{}}}},
                   "Out": {{"type": "structure", "members": {{
                       "M": {{"shape": "Kv", "flattened": true, "locationName": "Attr"}},
                       "W": {{"shape": "Kv"}}}}}},
                   "Kv": {{"type": "map", "key": {{"shape": "Str", "locationName": "Name"}},
                          "value": {{"shape": "Str", "locationName": "Value"}}}}, {STR}"#
            ),
            true,
        )
        .unwrap();
        for want in [
            "var _xs_m = aws_xml_map_entries(node, String(\"Attr\"), True)",
            "var _xs_w = aws_xml_map_entries(node, String(\"W\"), False)",
            "aws_xml_entry_value(_xs_m.value()[_xk1], String(\"Name\"), String(\"Value\"))",
        ] {
            assert!(src.contains(want), "`{want}` missing:\n{src}");
        }
    }

    #[test]
    fn an_operation_with_no_output_reads_nothing() {
        let model = parse(
            r#"{"version": "2.0",
                "metadata": {"apiVersion": "2026-10-02", "endpointPrefix": "tiny",
                    "protocol": "query", "serviceFullName": "Tiny",
                    "serviceId": "Tiny", "signatureVersion": "v4",
                    "uid": "tiny-2026-10-02"},
                "operations": {"Op": {"name": "Op",
                    "http": {"method": "POST", "requestUri": "/"}}},
                "shapes": {}}"#,
        )
        .unwrap();
        let lowering =
            lower_aws_service(&model, "tiny", &["Op".to_string()], "tiny.json", "aws.tiny")
                .unwrap();
        let options = AwsEmitOptions {
            pure_only: true,
            omit_preamble: true,
            ..AwsEmitOptions::default()
        };
        let (_, src) =
            emit_aws_client(&lowering, &AwsOverrides::empty(), "tiny", options).unwrap();
        let p = function(&src, "tiny_parse_op_response");
        assert!(p.contains("_ = resp"), "{p}");
        assert!(!p.contains("aws_xml_parse"), "{p}");
    }

    #[test]
    fn a_client_reads_its_errors_with_aws_query_error() {
        for protocol in ["query", "ec2"] {
            let src = emit_in(
                protocol,
                r#"{"shape": "In"}"#,
                r#"{"shape": "In"}"#,
                &format!(r#""In": {{"type": "structure", "members": {{}}}}, {STR}"#),
                false,
            )
            .unwrap();
            let b = &src[src.find("def _tiny_error(").expect("error builder")..];
            assert!(b.contains("    var info = aws_query_error(res.to_response())\n"), "{b}");
            assert!(src.contains("AWS_QUERY_CONTENT_TYPE"), "{src}");
        }
    }

    #[test]
    fn a_union_and_an_xml_attribute_are_refused_by_name() {
        let union = format!(
            r#""In": {{"type": "structure", "members": {{"U": {{"shape": "U"}}}}}},
               "U": {{"type": "structure", "union": true,
                      "members": {{"A": {{"shape": "Str"}}}}}}, {STR}"#
        );
        let attr = format!(
            r#""In": {{"type": "structure", "members": {{
                   "A": {{"shape": "Str", "xmlAttribute": true, "locationName": "a"}}}}}},
               {STR}"#
        );
        for protocol in ["query", "ec2"] {
            for (shapes, name) in [(&union, "union"), (&attr, "xml-attribute")] {
                let e = emit_in(protocol, r#"{"shape": "In"}"#, r#"{"shape": "In"}"#, shapes, true)
                    .unwrap_err();
                assert_eq!(
                    crate::aws_conformance::refusal_name(&e).as_deref(),
                    Some(name),
                    "{e}"
                );
            }
        }
    }
}
