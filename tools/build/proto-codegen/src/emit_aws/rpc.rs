//! The awsJson RPC binding: every operation is a `POST` to the service's
//! single path, dispatched on `X-Amz-Target`, with the whole input shape as
//! the JSON body (`awsJson1_0` / `awsJson1_1`).

use super::proto::Binding;
use super::{escape, AwsEmitter};
use crate::aws_in::AwsOperationFacts;
use crate::ir::IrMethod;

/// The awsJson binding.
pub(super) struct AwsJsonRpc;

impl Binding for AwsJsonRpc {
    fn header_protocol(&self, em: &AwsEmitter) -> String {
        format!(
            "{} {} (targetPrefix `{}`)",
            em.meta.protocol,
            em.json_version,
            em.meta.target_prefix.clone().unwrap_or_default()
        )
    }

    fn emit_wire_constants(&self, em: &mut AwsEmitter) {
        let p = em.prefix.to_uppercase();
        em.line(&format!(
            "comptime {p}_CONTENT_TYPE: String = \"application/x-amz-json-{}\"",
            em.json_version
        ));
        let target_prefix = em.meta.target_prefix.clone().unwrap_or_default();
        em.line(&format!(
            "comptime {p}_TARGET_PREFIX: String = \"{target_prefix}\""
        ));
    }

    fn emit_request_builder(
        &self,
        em: &mut AwsEmitter,
        m: &IrMethod,
        facts: &AwsOperationFacts,
    ) -> Result<(), String> {
        let in_ty = em.op_input_type(m);
        let p = em.prefix.to_uppercase();
        let fp = em.fn_prefix();
        let target_prefix = em.meta.target_prefix.clone().unwrap_or_default();
        em.line(&format!(
            "def {fp}build_{}_request(input: {in_ty}) raises -> AwsRequest:",
            m.name
        ));
        em.push();
        em.line(&format!(
            "\"\"\"`{}` — the awsJson request, serialised and NOT signed.\"\"\"",
            facts.name
        ));
        em.emit_validate_call(m);
        em.line(&format!(
            "var req = AwsRequest(String(\"{}\"), String(\"{}\"))",
            facts.http_method.to_uppercase(),
            escape(&facts.path)
        ));
        em.line(&format!(
            "req.set_header(String(\"X-Amz-Target\"), String(\"{}.{}\"))",
            escape(&target_prefix),
            escape(&facts.name)
        ));
        em.line(&format!(
            "req.set_header(String(\"Content-Type\"), String({p}_CONTENT_TYPE))"
        ));
        if em.meta.aws_query_compatible {
            em.line("req.set_header(String(\"x-amzn-query-mode\"), String(\"true\"))");
        }
        // `endpoint.hostPrefix`, with its `hostLabel` members substituted.
        if let Some(hp) = &facts.host_prefix {
            let expr = em.host_prefix_expr(hp, &m.input.fq_name)?;
            em.line(&format!("req.host_prefix = {expr}"));
        }
        em.line("req.set_body_text(input.to_aws_json().serialize())");
        em.line("return req^");
        em.pop();
        em.blank();
        Ok(())
    }

    fn emit_response_parser(
        &self,
        em: &mut AwsEmitter,
        m: &IrMethod,
        facts: &AwsOperationFacts,
    ) -> Result<(), String> {
        let out_ty = em.op_output_type(m);
        let fp = em.fn_prefix();
        em.line(&format!(
            "def {fp}parse_{}_response(resp: AwsResponse) raises -> {out_ty}:",
            m.name
        ));
        em.push();
        em.line(&format!(
            "\"\"\"`{}` — the awsJson response. An EMPTY body is `{{}}`: awsJson",
            facts.name
        ));
        em.line("    operations with no output still answer 200 with no bytes, and");
        em.line("    `parses_operations_with_empty_json_bodies` states it.\"\"\"");
        em.line("if len(resp.body) == 0:");
        em.push();
        em.line(&format!(
            "return {out_ty}.from_aws_json(parse_json_value(String(\"{{}}\")))"
        ));
        em.pop();
        em.line(&format!(
            "return {out_ty}.from_aws_json(parse_json_bytes(resp.body))"
        ));
        em.pop();
        em.blank();
        Ok(())
    }

    fn default_content_type(&self, em: &AwsEmitter) -> String {
        format!("{}_CONTENT_TYPE", em.prefix.to_uppercase())
    }

    fn send_notes(&self) -> &'static [&'static str] {
        &[
            "    ⛔ `X-Amz-Target` MUST RIDE IN THE **SIGNED** SET, not merely on the",
            "    wire: an awsJson service includes it in the canonical request, so an",
            "    unsigned one comes back `SignatureDoesNotMatch` and sends every",
            "    reader to the credential. It is passed as an extra SIGNED header for",
            "    exactly that reason.",
        ]
    }

    fn error_info_binding(&self) -> Option<&'static str> {
        Some("var info = aws_json_error_info(res.to_response())")
    }

    fn error_code_and_message(&self) -> (&'static str, &'static str) {
        ("info.code.copy()", "info.message.copy()")
    }

    fn error_code_doc(&self) -> &'static str {
        "awsJson error code (`aws_json_error_info`)"
    }
}
