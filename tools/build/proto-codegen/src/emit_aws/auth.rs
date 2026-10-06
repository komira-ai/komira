//! Per-operation authentication: how the generated send authenticates one
//! operation.
//!
//! The service metadata names the default, which
//! [`super::proto::check_signature_version`] admits only as SigV4. An
//! operation can override it, as botocore resolves it
//! (`botocore/auth.py` `resolve_auth_type`, `botocore/client.py`): its
//! `auth` list when it has one, read in order, else its `authtype`, else
//! the service's. The generated client applies two schemes, SigV4 and none
//! (an unsigned request, no credential read). Anything else is refused by
//! name in client mode; a pure module has no send, and its caller
//! authenticates the request it builds.

use super::proto::SIGV4_AUTH;
use super::{AwsEmitter, AWS_CORE};
use crate::aws_in::AwsOperationFacts;

/// The `auth` value of an anonymous operation.
pub const NO_AUTH: &str = "smithy.api#noAuth";

/// The `auth` value of a bearer-token operation.
pub const BEARER_AUTH: &str = "smithy.api#httpBearerAuth";

/// The `auth` value naming SigV4a, which botocore applies only with its
/// optional CRT signer and otherwise passes over for the next scheme.
pub const SIGV4A_AUTH: &str = "aws.auth#sigv4a";

/// How the generated send authenticates one operation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OperationAuth {
    /// Signed with SigV4, as the service is.
    SigV4,
    /// Sent unsigned, with no credential read: `authtype` `none` or
    /// `auth` [`NO_AUTH`].
    Anonymous,
}

/// The scheme the generated send applies to `op` of `service`. REFUSED, by
/// name: `bearer-auth`, an operation authenticated with a bearer token
/// (the client holds no token source, and a SigV4 signature is the wrong
/// credential); `operation-auth`, any other scheme it cannot apply.
pub fn operation_auth(service: &str, op: &AwsOperationFacts) -> Result<OperationAuth, String> {
    let name = &op.name;
    if !op.auth.is_empty() {
        for scheme in &op.auth {
            match scheme.as_str() {
                SIGV4_AUTH => return Ok(OperationAuth::SigV4),
                NO_AUTH => return Ok(OperationAuth::Anonymous),
                SIGV4A_AUTH => continue,
                BEARER_AUTH => {
                    return Err(bearer_refusal(service, name, &format!("auth `{BEARER_AUTH}`")))
                }
                other => {
                    return Err(format!(
                        "emit_aws: REFUSED operation-auth: operation `{name}` of service \
                         `{service}` names auth scheme `{other}`; the generated client \
                         signs with SigV4 (`{SIGV4_AUTH}`) or sends unsigned (`{NO_AUTH}`)"
                    ))
                }
            }
        }
        return Err(format!(
            "emit_aws: REFUSED operation-auth: operation `{name}` of service `{service}` \
             has auth {:?}, which names no scheme the generated client applies: it \
             signs with SigV4 (`{SIGV4_AUTH}`) or sends unsigned (`{NO_AUTH}`), and \
             has no SigV4a signer",
            op.auth
        ));
    }
    match op.auth_type.as_deref() {
        // `v4-unsigned-body` allows an unsigned payload; the body hash the
        // send signs is accepted as well.
        None | Some("v4") | Some("v4-unsigned-body") => Ok(OperationAuth::SigV4),
        Some("none") => Ok(OperationAuth::Anonymous),
        Some("bearer") => Err(bearer_refusal(service, name, "authtype `bearer`")),
        Some(other) => Err(format!(
            "emit_aws: REFUSED operation-auth: operation `{name}` of service `{service}` \
             declares authtype `{other}`; the generated client signs with SigV4 (`v4`) or \
             sends unsigned (`none`)"
        )),
    }
}

fn bearer_refusal(service: &str, name: &str, how: &str) -> String {
    format!(
        "emit_aws: REFUSED bearer-auth: operation `{name}` of service `{service}` is \
         authenticated with a bearer token ({how}), and the generated client has no \
         token source: it signs with SigV4 or sends unsigned, and a SigV4-signed call \
         would present the wrong credential. Leave `{name}` out of --operations, or \
         generate the module in pure mode and authenticate its requests yourself."
    )
}

/// [`operation_auth`] of every operation in a client-mode module, so a
/// refusal comes before any text is written. A pure module is not checked.
pub fn check_operation_auth(
    service: &str,
    facts: &crate::aws_in::AwsFacts,
    pure_only: bool,
) -> Result<(), String> {
    if pure_only {
        return Ok(());
    }
    for (_, op) in facts.operations() {
        operation_auth(service, op)?;
    }
    Ok(())
}

impl AwsEmitter<'_> {
    /// `send_unsigned` and `send_unsigned_with`, the sends of an anonymous
    /// operation: `send` and `send_with` without the signature. The request
    /// goes to the same endpoint over the same transport, retried alike;
    /// nothing is signed, so neither reads the client's key source, and
    /// `send_unsigned_with` takes no signing clock.
    pub(super) fn emit_unsigned_sends(&mut self, ruleset: bool, p: &str, s3_flag: &str) {
        let target_arg = if ruleset { ", target: AwsSigningTarget" } else { "" };
        self.line(&format!(
            "def send_unsigned(mut self, var req: AwsRequest{target_arg}{s3_flag}) raises -> HttpResult:"
        ));
        self.push();
        self.line("\"\"\"Send `req` UNSIGNED: no signature and no access key, as botocore");
        self.line("    sends an operation the model marks anonymous (`authtype` `none`,");
        self.line(&format!("    `auth` `{NO_AUTH}`). A call into the hand-written"));
        self.line(&format!(
            "    `{AWS_CORE}.send_unsigned_request`, retried as `send` is.\"\"\""
        ));
        self.emit_send_assembly(ruleset, false);
        self.line("return send_unsigned_request[Self.C](");
        self.push();
        self.line("self._mk_connector,");
        self.line("self._http_config.copy(),");
        self.line("self._retry_quota,");
        self.emit_send_args(ruleset, p, false);
        if self.options.s3 {
            self.line("s3_200_error=s3_200_error,");
        }
        self.pop();
        self.line(")");
        self.pop();
        self.blank();

        let seams = "X: AwsHttpTransport, L: MonotonicClock, S: Sleeper, R: RetryRng, B: RetryBudget";
        let seam_args = "mut transport: X, mut retry: RetryLoop[L, S, R], mut budget: B";
        self.line(&format!(
            "def send_unsigned_with[{seams}](mut self, var req: AwsRequest{target_arg}, {seam_args}{s3_flag}) raises -> HttpResult:"
        ));
        self.push();
        self.line("\"\"\"`send_unsigned`, over the transport, retry loop and budget given");
        self.line(&format!(
            "    (`{AWS_CORE}.send_unsigned_request_with`), as `send_with` is.\"\"\""
        ));
        self.emit_send_assembly(ruleset, false);
        self.line("return send_unsigned_request_with(");
        self.push();
        self.line("transport,");
        self.line("retry,");
        self.line("budget,");
        self.emit_send_args(ruleset, p, false);
        if self.options.s3 {
            self.line("s3_200_error=s3_200_error,");
        }
        self.pop();
        self.line(")");
        self.pop();
        self.blank();
    }
}

#[cfg(test)]
mod tests {
    use crate::emit_aws::{emit_aws_module, AwsEmitOptions, AwsProvenance};
    use crate::overrides::AwsOverrides;

    /// An awsJson service whose operations differ only in their auth traits.
    const MODEL: &str = r#"{"version": "2.0",
        "metadata": {"apiVersion": "2026-10-02", "endpointPrefix": "tiny",
            "jsonVersion": "1.1", "protocol": "json", "serviceFullName": "Tiny",
            "serviceId": "Tiny", "signatureVersion": "v4",
            "targetPrefix": "Tiny", "uid": "tiny-2026-10-02"},
        "operations": {
            "Signed": {"name": "Signed", "http": {"method": "POST", "requestUri": "/"},
                "input": {"shape": "In"}},
            "Anon": {"name": "Anon", "http": {"method": "POST", "requestUri": "/"},
                "input": {"shape": "In"}, "authtype": "none"},
            "NoAuth": {"name": "NoAuth", "http": {"method": "POST", "requestUri": "/"},
                "input": {"shape": "In"}, "auth": ["smithy.api#noAuth"]},
            "Bearer": {"name": "Bearer", "http": {"method": "POST", "requestUri": "/"},
                "input": {"shape": "In"}, "authtype": "bearer"},
            "BearerTrait": {"name": "BearerTrait",
                "http": {"method": "POST", "requestUri": "/"},
                "input": {"shape": "In"}, "auth": ["smithy.api#httpBearerAuth"]},
            "SkipsUnsignable": {"name": "SkipsUnsignable",
                "http": {"method": "POST", "requestUri": "/"},
                "input": {"shape": "In"}, "auth": ["aws.auth#sigv4a", "aws.auth#sigv4"]},
            "OnlyUnsignable": {"name": "OnlyUnsignable",
                "http": {"method": "POST", "requestUri": "/"},
                "input": {"shape": "In"}, "auth": ["aws.auth#sigv4a"]},
            "SignedFirst": {"name": "SignedFirst",
                "http": {"method": "POST", "requestUri": "/"},
                "input": {"shape": "In"}, "auth": ["aws.auth#sigv4", "smithy.api#noAuth"]},
            "SkipsToNoAuth": {"name": "SkipsToNoAuth",
                "http": {"method": "POST", "requestUri": "/"},
                "input": {"shape": "In"}, "auth": ["aws.auth#sigv4a", "smithy.api#noAuth"]},
            "NoAuthFirst": {"name": "NoAuthFirst",
                "http": {"method": "POST", "requestUri": "/"},
                "input": {"shape": "In"}, "auth": ["smithy.api#noAuth", "aws.auth#sigv4"]},
            "AuthOverAuthtype": {"name": "AuthOverAuthtype",
                "http": {"method": "POST", "requestUri": "/"},
                "input": {"shape": "In"}, "authtype": "none", "auth": ["aws.auth#sigv4"]},
            "UnsignedBody": {"name": "UnsignedBody",
                "http": {"method": "POST", "requestUri": "/"},
                "input": {"shape": "In"}, "authtype": "v4-unsigned-body"},
            "OtherAuthtype": {"name": "OtherAuthtype",
                "http": {"method": "POST", "requestUri": "/"},
                "input": {"shape": "In"}, "authtype": "v2"},
            "OtherAuth": {"name": "OtherAuth",
                "http": {"method": "POST", "requestUri": "/"},
                "input": {"shape": "In"}, "auth": ["example.auth#custom"]}},
        "shapes": {"In": {"type": "structure", "members": {}}}}"#;

    fn emit(ops: &[&str], pure_only: bool) -> Result<String, String> {
        let model = crate::json::parse(MODEL).map_err(|e| e.to_string())?;
        let ops: Vec<String> = ops.iter().map(|s| s.to_string()).collect();
        let lowering =
            crate::aws_in::lower_aws_service(&model, "tiny", &ops, "tiny.json", "aws.tiny")?;
        let options = AwsEmitOptions {
            pure_only,
            ..AwsEmitOptions::default()
        };
        let provenance = AwsProvenance {
            model_key: "tiny/2026-10-02",
            model_sha256: "0000000000000000000000000000000000000000000000000000000000000000",
        };
        emit_aws_module(&lowering, &AwsOverrides::empty(), "tiny", options, Some(provenance))
            .map(|e| e.source)
    }

    /// The text of the client method `name`, up to the next method.
    fn method<'a>(src: &'a str, name: &str) -> &'a str {
        let at = src
            .find(&format!("\n    def {name}("))
            .or_else(|| src.find(&format!("\n    def {name}[")))
            .unwrap_or_else(|| panic!("no method `{name}` in:\n{src}"));
        let rest = &src[at + 1..];
        let end = rest[1..].find("\n    def ").map_or(rest.len(), |e| e + 2);
        &rest[..end]
    }

    /// Whether the verb `name` and its `_with` twin send signed (`true`) or
    /// unsigned (`false`); panics when they disagree or do neither.
    fn sends_signed(src: &str, name: &str) -> bool {
        let verb = method(src, name);
        let with = method(src, &format!("{name}_with"));
        let signed = verb.contains("var res = self.send(req^)")
            && with.contains("return self.send_with(req^, transport, clock, retry, budget)");
        let unsigned = verb.contains("var res = self.send_unsigned(req^)")
            && with.contains("return self.send_unsigned_with(req^, transport, retry, budget)");
        assert!(signed != unsigned, "`{name}` is neither or both:\n{verb}\n{with}");
        signed
    }

    #[test]
    fn none_and_no_auth_operations_are_sent_unsigned() {
        let src = emit(&["Signed", "Anon", "NoAuth"], false).unwrap();
        assert!(sends_signed(&src, "signed"), "{src}");
        assert!(!sends_signed(&src, "anon"), "{src}");
        assert!(!sends_signed(&src, "no_auth"), "{src}");
        // The unsigned send reads no credential and calls the core's
        // unsigned send, which signs nothing.
        let send = method(&src, "send_unsigned");
        assert!(send.contains("return send_unsigned_request[Self.C]("), "{send}");
        assert!(!send.contains("_creds_source"), "{send}");
        assert!(!send.contains("cred"), "{send}");
        let send_with = method(&src, "send_unsigned_with");
        assert!(send_with.contains("return send_unsigned_request_with("), "{send_with}");
        assert!(!send_with.contains("cred"), "{send_with}");
        assert!(!send_with.contains("clock"), "{send_with}");
        assert!(
            src.contains(
                "from komira_aws_core import (\n    send_unsigned_request,\n    \
                 send_unsigned_request_with,\n)\n"
            ),
            "{src}"
        );
        // The signed send is unchanged.
        assert!(method(&src, "send").contains("return send_sigv4_signed_request[Self.C]("));
    }

    #[test]
    fn a_module_with_no_anonymous_operation_has_no_unsigned_send() {
        let src = emit(&["Signed"], false).unwrap();
        assert!(!src.contains("send_unsigned"), "{src}");
    }

    #[test]
    fn an_operation_auth_list_is_read_in_order_and_ahead_of_authtype() {
        let src = emit(
            &[
                "SkipsUnsignable",
                "SignedFirst",
                "SkipsToNoAuth",
                "NoAuthFirst",
                "AuthOverAuthtype",
                "UnsignedBody",
            ],
            false,
        )
        .unwrap();
        // SigV4a needs a signer this client does not have, and botocore
        // without it moves on to the next scheme.
        assert!(sends_signed(&src, "skips_unsignable"), "{src}");
        // The first scheme the client applies wins: SigV4 listed ahead of
        // noAuth is signed, never sent unsigned because noAuth is listed.
        assert!(sends_signed(&src, "signed_first"), "{src}");
        assert!(!sends_signed(&src, "skips_to_no_auth"), "{src}");
        assert!(!sends_signed(&src, "no_auth_first"), "{src}");
        assert!(sends_signed(&src, "auth_over_authtype"), "{src}");
        // `v4-unsigned-body` is SigV4; the body hash is sent.
        assert!(sends_signed(&src, "unsigned_body"), "{src}");
    }

    #[test]
    fn a_bearer_operation_is_refused_by_name_in_client_mode() {
        for (op, how) in [
            ("Bearer", "authtype `bearer`"),
            ("BearerTrait", "auth `smithy.api#httpBearerAuth`"),
        ] {
            let e = emit(&["Signed", op], false).err().expect("refused");
            assert!(e.contains("REFUSED bearer-auth"), "{e}");
            assert!(e.contains(&format!("operation `{op}`")), "{e}");
            assert!(e.contains(how), "{e}");
            // A pure module has no send, and the caller authenticates.
            assert!(emit(&["Signed", op], true).is_ok(), "{op}");
        }
    }

    #[test]
    fn an_operation_auth_the_client_cannot_apply_is_refused_by_name() {
        for (op, what) in [
            ("OtherAuthtype", "authtype `v2`"),
            ("OtherAuth", "`example.auth#custom`"),
            ("OnlyUnsignable", "[\"aws.auth#sigv4a\"]"),
        ] {
            let e = emit(&[op], false).err().expect("refused");
            assert!(e.contains("REFUSED operation-auth"), "{e}");
            assert!(e.contains(&format!("operation `{op}`")), "{e}");
            assert!(e.contains(what), "{e}");
            assert!(emit(&[op], true).is_ok(), "{op}");
        }
    }
}
