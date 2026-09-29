//! Deriving each RPC's client retry policy from the proto model: a method is
//! retried only when its idempotency level or HTTP verb says it is safe to.

use crate::ir::IrMethod;

/// The retry policy a generated method carries — the codegen half of
/// `komira_grpc.retry.RetryPolicy`.
///
/// Deliberately only TWO variants. A richer lattice (per-code sets, per-service
/// budgets) is expressible in the runtime type, but nothing in the proto model
/// can *justify* a third value, and a derivation that emits distinctions its
/// input cannot support is a guess wearing a type.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RetryClass {
    None,
    Idempotent,
}

impl RetryClass {
    pub fn mojo_expr(self) -> &'static str {
        match self {
            RetryClass::None => "RetryPolicy.none()",
            RetryClass::Idempotent => "RetryPolicy.idempotent()",
        }
    }

    pub fn rationale(self, reason: RetryReason) -> String {
        match self {
            RetryClass::None => format!(
                "# retry: NONE — {}. Replaying a non-idempotent verb can \
                 create a second resource.",
                reason.text()
            ),
            RetryClass::Idempotent => format!(
                "# retry: AIP-194 (UNAVAILABLE only) — {}.",
                reason.text()
            ),
        }
    }
}

/// Which signal decided the class. Carried so the emitted comment can name the
/// evidence, not just the verdict.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RetryReason {
    DeclaredIdempotent,
    IdempotentHttpVerb(&'static str),
    NonIdempotentHttpVerb(&'static str),
    /// No `(google.api.http)` annotation and no `idempotency_level`.
    NoSignal,
    /// A streaming method. Not eligible: a replay would have to re-drive a
    /// consumed stream.
    Streaming,
}

impl RetryReason {
    pub fn text(self) -> String {
        match self {
            RetryReason::DeclaredIdempotent => {
                "the model declares this method idempotent (proto \
                 idempotency_level = IDEMPOTENT, or an input front-end that \
                 derived it)"
                    .to_string()
            }
            RetryReason::IdempotentHttpVerb(v) => format!(
                "(google.api.http) verb is `{v}`, which RFC 9110 §9.2.2 \
                 defines as idempotent"
            ),
            RetryReason::NonIdempotentHttpVerb(v) => format!(
                "(google.api.http) verb is `{v}`, which RFC 9110 §9.2.2 does \
                 NOT define as idempotent"
            ),
            RetryReason::NoSignal => {
                "the proto carries neither (google.api.http) nor \
                 idempotency_level, so replay-safety is UNKNOWN"
                    .to_string()
            }
            RetryReason::Streaming => {
                "streaming RPCs are not replayable — the request stream is \
                 consumed by the first attempt"
                    .to_string()
            }
        }
    }
}

const IDEMPOTENT_HTTP_VERBS: &[&str] = &["get", "head", "put", "delete"];

pub fn derive_retry_class(m: &IrMethod) -> (RetryClass, RetryReason) {
    if m.client_streaming || m.server_streaming {
        return (RetryClass::None, RetryReason::Streaming);
    }
    if m.idempotent {
        return (
            RetryClass::Idempotent,
            RetryReason::DeclaredIdempotent,
        );
    }
    match m.http_rule.as_ref() {
        None => (RetryClass::None, RetryReason::NoSignal),
        Some(rule) => {
            let verb = rule.verb.as_str();
            match IDEMPOTENT_HTTP_VERBS.iter().find(|v| **v == verb) {
                Some(v) => (
                    RetryClass::Idempotent,
                    RetryReason::IdempotentHttpVerb(v),
                ),
                None => {
                    let known: Option<&'static str> = match verb {
                        "post" => Some("post"),
                        "patch" => Some("patch"),
                        _ => None,
                    };
                    match known {
                        Some(v) => (
                            RetryClass::None,
                            RetryReason::NonIdempotentHttpVerb(v),
                        ),
                        None => (RetryClass::None, RetryReason::NoSignal),
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::{IrHttpRule, TypeRef};

    fn method(verb: Option<&str>, idempotent: bool) -> IrMethod {
        IrMethod {
            name: "M".to_string(),
            input: TypeRef {
                fq_name: ".p.In".to_string(),
                mojo_name: "In".to_string(),
            },
            output: TypeRef {
                fq_name: ".p.Out".to_string(),
                mojo_name: "Out".to_string(),
            },
            client_streaming: false,
            server_streaming: false,
            idempotent,
            http_rule: verb.map(|v| IrHttpRule {
                verb: v.to_string(),
                path_template: "/v2/x".to_string(),
                body: String::new(),
            }),
            routing_rule: None,
        }
    }

    #[test]
    fn post_is_never_retried() {
        let (class, reason) = derive_retry_class(&method(Some("post"), false));
        assert_eq!(class, RetryClass::None);
        assert_eq!(reason, RetryReason::NonIdempotentHttpVerb("post"));
    }

    #[test]
    fn patch_is_never_retried() {
        assert_eq!(
            derive_retry_class(&method(Some("patch"), false)).0,
            RetryClass::None
        );
    }

    #[test]
    fn get_and_delete_and_put_are_retried() {
        for verb in ["get", "delete", "put", "head"] {
            let (class, reason) = derive_retry_class(&method(Some(verb), false));
            assert_eq!(
                class,
                RetryClass::Idempotent,
                "verb `{verb}` is idempotent per RFC 9110 §9.2.2"
            );
            assert!(matches!(reason, RetryReason::IdempotentHttpVerb(_)));
        }
    }

    #[test]
    fn an_unannotated_method_gets_no_retry() {
        let (class, reason) = derive_retry_class(&method(None, false));
        assert_eq!(class, RetryClass::None);
        assert_eq!(reason, RetryReason::NoSignal);
    }

    /// A declared `idempotency_level` outranks the verb heuristic — including
    /// on a `post`, which is the only way a first-party custom method can ever
    /// earn a retry from codegen.
    #[test]
    fn declared_idempotency_level_outranks_the_verb() {
        let (class, reason) = derive_retry_class(&method(Some("post"), true));
        assert_eq!(class, RetryClass::Idempotent);
        assert_eq!(reason, RetryReason::DeclaredIdempotent);
    }

    /// Streaming disqualifies whatever the verb says — a replay would re-drive
    /// a stream the first attempt consumed.
    #[test]
    fn streaming_is_never_retried_even_on_an_idempotent_verb() {
        let mut m = method(Some("get"), true);
        m.server_streaming = true;
        assert_eq!(derive_retry_class(&m).0, RetryClass::None);
        assert_eq!(derive_retry_class(&m).1, RetryReason::Streaming);

        let mut m2 = method(Some("get"), true);
        m2.client_streaming = true;
        assert_eq!(derive_retry_class(&m2).0, RetryClass::None);
    }

    /// An unrecognised verb is UNKNOWN, not "probably fine".
    #[test]
    fn an_unknown_verb_gets_no_retry() {
        let (class, reason) =
            derive_retry_class(&method(Some("custom"), false));
        assert_eq!(class, RetryClass::None);
        assert_eq!(reason, RetryReason::NoSignal);
    }

    #[test]
    fn the_emitted_expressions_are_the_runtime_constructors() {
        assert_eq!(RetryClass::None.mojo_expr(), "RetryPolicy.none()");
        assert_eq!(
            RetryClass::Idempotent.mojo_expr(),
            "RetryPolicy.idempotent()"
        );
    }

    #[test]
    fn every_rationale_names_its_evidence() {
        let cases = [
            (
                RetryClass::None,
                RetryReason::NonIdempotentHttpVerb("post"),
                "post",
            ),
            (RetryClass::None, RetryReason::NoSignal, "UNKNOWN"),
            (RetryClass::None, RetryReason::Streaming, "streaming"),
            (
                RetryClass::Idempotent,
                RetryReason::IdempotentHttpVerb("get"),
                "9110",
            ),
            (
                RetryClass::Idempotent,
                RetryReason::DeclaredIdempotent,
                "idempotency_level",
            ),
        ];
        for (class, reason, needle) in cases {
            let line = class.rationale(reason);
            assert!(
                line.starts_with("# retry: "),
                "the rationale must be a comment: {line}"
            );
            assert!(
                line.contains(needle),
                "the rationale must name its evidence (`{needle}`): {line}"
            );
        }
    }
}
