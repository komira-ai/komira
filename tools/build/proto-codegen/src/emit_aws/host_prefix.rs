//! The host prefix: an operation's `endpoint.hostPrefix` (the Smithy
//! endpoint trait), protocol-independent and shared by every binding.

use super::{escape, AwsEmitter};

impl AwsEmitter<'_> {
    /// The Mojo expression for an `endpoint.hostPrefix`, substituting each
    /// `{member}` placeholder with the input's `hostLabel` member, checked
    /// at run time by the core's `aws_host_label` (a value that is not a
    /// host label raises before anything is sent). The template is the same
    /// in every protocol, and every binding's request builder applies it to
    /// `AwsRequest.host_prefix`, which the client's sends prepend to the
    /// resolved endpoint host (`AwsEndpoint.with_host_prefix`).
    ///
    /// ⚠ A HOST LABEL IS A MEMBER, NOT A CONSTANT. `AwsJson11EndpointTraitWithHostLabel`
    /// declares `hostPrefix: "{foo}.bar."`, and a generator that emitted the
    /// template verbatim would send a request to the literal host `{foo}.bar.…`
    /// — a DNS failure naming a brace.
    ///
    /// A label names an input member by its MODEL name, not its wire name:
    /// `RestXmlEndpointTraitWithHostLabelAndHttpBinding` binds `accountId`
    /// to the header `X-Amz-Account-Id` and names it `{accountId}`. The
    /// Smithy endpoint trait requires each label to name a required string
    /// member of the input marked `hostLabel`; a template naming any other
    /// member is refused here, before any text is written.
    pub(super) fn host_prefix_expr(&self, hp: &str, input_fq: &str) -> Result<String, String> {
        let mut parts: Vec<String> = Vec::new();
        let mut lit = String::new();
        let mut rest = hp;
        let stray_close =
            || format!("emit_aws: hostPrefix `{hp}` has a `}}` outside a label");
        while let Some(i) = rest.find('{') {
            if rest[..i].contains('}') {
                return Err(stray_close());
            }
            lit.push_str(&rest[..i]);
            let j = rest[i..].find('}').ok_or_else(|| {
                format!("emit_aws: unterminated `{{` in hostPrefix `{hp}`")
            })? + i;
            let member = &rest[i + 1..j];
            if !lit.is_empty() {
                parts.push(format!("String(\"{}\")", escape(&lit)));
                lit.clear();
            }
            let msg = self
                .messages
                .values()
                .find(|m| m.fq_name == input_fq)
                .ok_or_else(|| format!("emit_aws: no input message {input_fq}"))?;
            let field = msg
                .fields
                .iter()
                .find(|f| {
                    self.facts
                        .member(&msg.fq_name, &f.name)
                        .is_ok_and(|mf| mf.member_name == member)
                })
                .ok_or_else(|| {
                    format!(
                        "emit_aws: hostPrefix `{hp}` names `{{{member}}}`, and the input \
                         shape `{}` has no such member. A host label that resolves to \
                         nothing is a request to a host with a literal brace in it.",
                        msg.name
                    )
                })?;
            let mf = self.facts.member(&msg.fq_name, &field.name)?;
            // A required string member, an enum-valued one included, is
            // stored as `String`; an optional one is `Optional[String]` and
            // a timestamp is `Float64`.
            let ty = self.storage_type(msg, field)?;
            if !mf.host_label || ty != "String" {
                return Err(format!(
                    "emit_aws: hostPrefix `{hp}` names `{{{member}}}`, and the input shape \
                     `{}` member `{member}` is not a required string member marked \
                     `hostLabel`, which the endpoint trait requires of a host label",
                    msg.name
                ));
            }
            parts.push(format!("aws_host_label(input.{})", field.name));
            rest = &rest[j + 1..];
        }
        if rest.contains('}') {
            return Err(stray_close());
        }
        lit.push_str(rest);
        if !lit.is_empty() {
            parts.push(format!("String(\"{}\")", escape(&lit)));
        }
        if parts.is_empty() {
            parts.push("String(\"\")".to_string());
        }
        Ok(parts.join(" + "))
    }
}


#[cfg(test)]
mod tests {
    use crate::emit_aws::{emit_aws_module, AwsEmitOptions, AwsProvenance};
    use crate::overrides::AwsOverrides;

    /// A one-operation awsJson module in client mode whose operation `Op`
    /// has the host prefix `host_prefix`, and whose input `In` holds the
    /// string members `Label` (with the text `label`) and `Other`, `Label`
    /// in the `required` list when `required`.
    fn emit_with_prefix(host_prefix: &str, label: &str, required: bool) -> Result<String, String> {
        let required = if required { r#""Label""# } else { "" };
        emit_with_members(host_prefix, label, r#"{"shape": "S"}"#, required)
    }

    /// As `emit_with_prefix`, with the member texts of `Label` and `Other`
    /// and the `required` list's contents given verbatim.
    fn emit_with_members(
        host_prefix: &str,
        label: &str,
        other: &str,
        required: &str,
    ) -> Result<String, String> {
        let model = crate::json::parse(&format!(
            r#"{{"version": "2.0",
                "metadata": {{"apiVersion": "2026-10-06", "endpointPrefix": "tiny",
                    "jsonVersion": "1.1", "protocol": "json", "serviceFullName": "Tiny",
                    "serviceId": "Tiny", "signatureVersion": "v4",
                    "targetPrefix": "Tiny", "uid": "tiny-2026-10-06"}},
                "operations": {{"Op": {{"name": "Op",
                    "http": {{"method": "POST", "requestUri": "/"}},
                    "endpoint": {{"hostPrefix": "{host_prefix}"}},
                    "input": {{"shape": "In"}}, "output": {{"shape": "Out"}}}}}},
                "shapes": {{"In": {{"type": "structure", "required": [{required}],
                                   "members": {{"Label": {label},
                                               "Other": {other}}}}},
                           "Out": {{"type": "structure", "members": {{}}}},
                           "S": {{"type": "string"}}}}}}"#
        ))
        .unwrap();
        let lowering = crate::aws_in::lower_aws_service(
            &model,
            "tiny",
            &["Op".to_string()],
            "tiny.json",
            "aws.tiny",
        )?;
        let prov = AwsProvenance { model_key: "tiny/2026-10-06", model_sha256: "m" };
        emit_aws_module(&lowering, &AwsOverrides::empty(), "tiny", AwsEmitOptions::default(), Some(prov))
            .map(|e| e.source)
    }

    /// The emitted `build_op_request`, for a failure message.
    fn builder_of(src: &str) -> &str {
        let at = src.find("def build_op_request").unwrap_or(0);
        &src[at..(at + 900).min(src.len())]
    }

    const LABEL: &str = r#"{"shape": "S", "hostLabel": true}"#;

    #[test]
    fn the_builder_substitutes_each_label_and_every_send_prepends_the_prefix() {
        let src = emit_with_prefix("foo.{Label}.", LABEL, true).unwrap();
        let build = "    req.host_prefix = String(\"foo.\") + aws_host_label(input.label) + \
                     String(\".\")\n";
        assert_eq!(src.matches(build).count(), 1, "{}", builder_of(&src));
        // `send` and `send_with` both hand the transport the prefixed
        // endpoint; there is no other send in a signed module.
        let endpoint = "            resolve_endpoint(self._endpoint_override, \
                        tiny_host(self._region.copy())).with_host_prefix(req.host_prefix),\n";
        assert_eq!(src.matches(endpoint).count(), 2, "{src}");
        assert_eq!(src.matches("resolve_endpoint(self._endpoint_override").count(), 2, "{src}");
        assert!(src.contains("    aws_host_label,\n"), "{src}");
    }

    #[test]
    fn a_prefix_with_two_labels_substitutes_both() {
        let src = emit_with_members("{Label}-{Other}.", LABEL, LABEL, r#""Label", "Other""#)
            .unwrap();
        let build = "    req.host_prefix = aws_host_label(input.label) + String(\"-\") + \
                     aws_host_label(input.other) + String(\".\")\n";
        assert_eq!(src.matches(build).count(), 1, "{}", builder_of(&src));
    }

    #[test]
    fn a_label_names_the_member_by_its_model_name_not_its_wire_name() {
        let renamed = r#"{"shape": "S", "hostLabel": true, "locationName": "lbl"}"#;
        let src = emit_with_prefix("{Label}.", renamed, true).unwrap();
        let build = "    req.host_prefix = aws_host_label(input.label) + String(\".\")\n";
        assert_eq!(src.matches(build).count(), 1, "{}", builder_of(&src));
        let e = emit_with_prefix("{lbl}.", renamed, true).unwrap_err();
        assert_eq!(
            e,
            "emit_aws: hostPrefix `{lbl}.` names `{lbl}`, and the input shape `In` has no \
             such member. A host label that resolves to nothing is a request to a host with \
             a literal brace in it."
        );
    }

    #[test]
    fn a_prefix_without_labels_is_a_literal() {
        let src = emit_with_prefix("data-", LABEL, true).unwrap();
        assert!(src.contains("    req.host_prefix = String(\"data-\")\n"), "{}", builder_of(&src));
        assert!(!src.contains("aws_host_label(input"), "{src}");
    }

    #[test]
    fn a_label_that_is_not_a_required_host_label_string_is_refused() {
        let want = "emit_aws: hostPrefix `foo.{Label}.` names `{Label}`, and the input shape \
                    `In` member `Label` is not a required string member marked `hostLabel`, \
                    which the endpoint trait requires of a host label";
        // Not marked hostLabel.
        let e = emit_with_prefix("foo.{Label}.", r#"{"shape": "S"}"#, true).unwrap_err();
        assert_eq!(e, want);
        // Marked, but optional.
        let e = emit_with_prefix("foo.{Label}.", LABEL, false).unwrap_err();
        assert_eq!(e, want);
    }

    #[test]
    fn a_label_naming_no_member_or_a_stray_brace_is_refused() {
        let e = emit_with_prefix("{Nope}.", LABEL, true).unwrap_err();
        assert_eq!(
            e,
            "emit_aws: hostPrefix `{Nope}.` names `{Nope}`, and the input shape `In` has no \
             such member. A host label that resolves to nothing is a request to a host with \
             a literal brace in it."
        );
        for hp in ["a}.{Label}.", "{Label}.b}."] {
            let e = emit_with_prefix(hp, LABEL, true).unwrap_err();
            assert_eq!(e, format!("emit_aws: hostPrefix `{hp}` has a `}}` outside a label"));
        }
        let e = emit_with_prefix("{Label.", LABEL, true).unwrap_err();
        assert_eq!(e, "emit_aws: unterminated `{` in hostPrefix `{Label.`");
    }
}
