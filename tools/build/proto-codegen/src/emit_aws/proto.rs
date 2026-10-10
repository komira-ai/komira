//! The protocol seam: which botocore protocol a model declares, what the
//! emitter does with it, and the two halves a protocol plugs in.
//!
//! A protocol is a [`BodyCodec`] (how a shape becomes body bytes and back)
//! and a [`Binding`] (where each member goes on the HTTP request and
//! response, and what the client adds around the signed send). The emitter
//! core writes everything else: the header, the shape structs, constraints,
//! the client and its send.

use super::json_codec::AwsJsonCodec;
use super::query::{AwsEc2Binding, AwsQueryBinding, AwsQueryCodec};
use super::rest::{AwsRestJson, AwsRestXml};
use super::rpc::AwsJsonRpc;
use super::xml_codec::AwsXmlCodec;
use super::{AwsEmitter, SUPPORTED_JSON_VERSIONS, SUPPORTED_PROTOCOLS};
use crate::aws_in::{AwsOperationFacts, AwsServiceMeta};
use crate::ir::{IrMessage, IrMethod};

/// A botocore `metadata.protocol` value. Each variant is a protocol a model
/// can declare; [`SUPPORTED_PROTOCOLS`] is the subset this emitter
/// implements.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum AwsProtocol {
    /// `json`: awsJson1_0 / awsJson1_1.
    Json,
    /// `rest-json`: restJson1.
    RestJson,
    /// `rest-xml`: restXml.
    RestXml,
    /// `query`: awsQuery.
    Query,
    /// `ec2`: ec2Query.
    Ec2,
    /// `smithy-rpc-v2-cbor`: Smithy RPC v2 CBOR.
    SmithyRpcV2Cbor,
}

/// Every protocol, in declaration order.
pub const ALL_PROTOCOLS: &[AwsProtocol] = &[
    AwsProtocol::Json,
    AwsProtocol::RestJson,
    AwsProtocol::RestXml,
    AwsProtocol::Query,
    AwsProtocol::Ec2,
    AwsProtocol::SmithyRpcV2Cbor,
];

/// The protocols whose request and response bodies are JSON documents, and
/// so whose generated code imports the `komira_json` runtime.
pub const JSON_BODY_PROTOCOLS: &[AwsProtocol] = &[AwsProtocol::Json, AwsProtocol::RestJson];

/// The protocols that bind members to the HTTP message (URI labels and
/// query, headers, payload, status), and so whose generated code imports the
/// REST binding runtime.
pub const REST_PROTOCOLS: &[AwsProtocol] = &[AwsProtocol::RestJson, AwsProtocol::RestXml];

/// The protocols whose request and response bodies are XML documents, and
/// so whose generated code imports the `komira_xml` runtime and the core's
/// restXml body codec.
pub const XML_BODY_PROTOCOLS: &[AwsProtocol] = &[AwsProtocol::RestXml];

/// The protocols whose request is a form body and whose response is an XML
/// document (awsQuery, ec2Query), and so whose generated code imports the
/// core's form writer and its XML readers.
pub const QUERY_PROTOCOLS: &[AwsProtocol] = &[AwsProtocol::Query, AwsProtocol::Ec2];

/// The protocols whose responses are XML documents: a module of one that
/// renders values in the MODEL convention (JSON) imports the JSON runtime
/// for that alone.
pub const XML_RESPONSE_PROTOCOLS: &[AwsProtocol] =
    &[AwsProtocol::RestXml, AwsProtocol::Query, AwsProtocol::Ec2];

impl AwsProtocol {
    /// The `metadata.protocol` spelling.
    pub fn botocore_name(self) -> &'static str {
        match self {
            AwsProtocol::Json => "json",
            AwsProtocol::RestJson => "rest-json",
            AwsProtocol::RestXml => "rest-xml",
            AwsProtocol::Query => "query",
            AwsProtocol::Ec2 => "ec2",
            AwsProtocol::SmithyRpcV2Cbor => "smithy-rpc-v2-cbor",
        }
    }

    /// The protocol a `metadata.protocol` value names, or `None` for a value
    /// botocore does not define.
    pub fn from_botocore(name: &str) -> Option<AwsProtocol> {
        ALL_PROTOCOLS.iter().copied().find(|p| p.botocore_name() == name)
    }
}

/// How a shape becomes body bytes and back: the methods a generated shape
/// struct carries after its fields, constructors and `validate()`.
pub(super) trait BodyCodec: Sync {
    /// The protocol-specific paragraphs of a shape's docstring, ending with
    /// the line that closes it.
    fn emit_shape_doc(&self, em: &mut AwsEmitter, is_union: bool, is_synthetic: bool);
    /// The encoder method.
    fn emit_encoder(&self, em: &mut AwsEmitter, msg: &IrMessage, is_union: bool)
        -> Result<(), String>;
    /// The decoder method.
    fn emit_decoder(&self, em: &mut AwsEmitter, msg: &IrMessage) -> Result<(), String>;
    /// The method rendering a value in botocore's MODEL convention, the one
    /// a protocol-test case states its params and results in.
    fn emit_model_value(&self, em: &mut AwsEmitter, msg: &IrMessage) -> Result<(), String>;
}

/// Where each member goes on the wire, per operation, and what the client
/// adds around the signed send.
pub(super) trait Binding: Sync {
    /// The value of the header's `protocol :` line.
    fn header_protocol(&self, em: &AwsEmitter) -> String;
    /// The protocol's `comptime` wire constants, after the service and
    /// endpoint-prefix ones.
    fn emit_wire_constants(&self, em: &mut AwsEmitter);
    /// `build_<op>_request`: the input as an unsigned `AwsRequest`.
    fn emit_request_builder(
        &self,
        em: &mut AwsEmitter,
        m: &IrMethod,
        facts: &AwsOperationFacts,
    ) -> Result<(), String>;
    /// `parse_<op>_response`: an `AwsResponse` as the output shape.
    fn emit_response_parser(
        &self,
        em: &mut AwsEmitter,
        m: &IrMethod,
        facts: &AwsOperationFacts,
    ) -> Result<(), String>;
    /// The Mojo expression for the content type `send` signs with when the
    /// request sets no `Content-Type` header.
    fn default_content_type(&self, em: &AwsEmitter) -> String;
    /// Docstring lines the client's `send` adds after the generic ones.
    fn send_notes(&self) -> &'static [&'static str];
    /// A statement the error builder runs before reading the code and the
    /// message, binding what both read so the response is parsed once.
    fn error_info_binding(&self) -> Option<&'static str> {
        None
    }
    /// The Mojo expressions, over `res: HttpResult` (and what
    /// `error_info_binding` binds), for a failed call's error code and
    /// message.
    fn error_code_and_message(&self) -> (&'static str, &'static str);
    /// What the error builder's docstring calls the code it extracts, as the
    /// phrase before "and message ride out".
    fn error_code_doc(&self) -> &'static str;
}

static AWS_JSON_CODEC: AwsJsonCodec = AwsJsonCodec;
static AWS_JSON_RPC: AwsJsonRpc = AwsJsonRpc;
static AWS_REST_JSON: AwsRestJson = AwsRestJson;
static AWS_XML_CODEC: AwsXmlCodec = AwsXmlCodec;
static AWS_REST_XML: AwsRestXml = AwsRestXml;
static AWS_QUERY_CODEC: AwsQueryCodec = AwsQueryCodec;
static AWS_QUERY_BINDING: AwsQueryBinding = AwsQueryBinding;
static AWS_EC2_BINDING: AwsEc2Binding = AwsEc2Binding;

/// The protocol a service is emitted with: its codec and binding, and the
/// `jsonVersion` an awsJson service dispatches on (empty otherwise).
pub(super) struct SelectedProtocol {
    pub protocol: AwsProtocol,
    pub codec: &'static dyn BodyCodec,
    pub binding: &'static dyn Binding,
    pub json_version: String,
}

/// The protocol `meta` is generated for (`AwsServiceMeta.protocol`, which
/// the front-end chose from the model's `protocols` list), if this emitter
/// implements it, and its signing scheme is one the generated client can
/// sign. Anything else is refused by name, with the list the model offers.
pub(super) fn select_protocol(meta: &AwsServiceMeta) -> Result<SelectedProtocol, String> {
    let chosen = AwsProtocol::from_botocore(&meta.protocol);
    let protocol = match chosen {
        Some(p) if SUPPORTED_PROTOCOLS.contains(&p.botocore_name()) => p,
        _ => {
            let listed = if meta.protocols.is_empty() {
                String::new()
            } else {
                format!(" and lists protocols {:?}", meta.protocols)
            };
            return Err(format!(
                "emit_aws: service `{}` declares protocol `{}`{listed}, and this emitter \
                 implements only {:?} (ec2Query, awsJson1_0 / awsJson1_1, awsQuery, restJson1, \
                 restXml). It is REFUSED by name \
                 rather than emitted half-right: a `{}` client emitted by a `json` \
                 serializer produces requests that are syntactically valid and \
                 semantically wrong, which is the failure mode a conformance corpus \
                 catches late and a service catches never.",
                meta.service, meta.protocol, SUPPORTED_PROTOCOLS, meta.protocol
            ));
        }
    };
    let selected = match protocol {
        AwsProtocol::Json => {
            let json_version = meta.json_version.clone().unwrap_or_default();
            if !SUPPORTED_JSON_VERSIONS.contains(&json_version.as_str()) {
                return Err(format!(
                    "emit_aws: service `{}` declares protocol `json` with jsonVersion \
                     {json_version:?}; this emitter implements {:?}. The version is not \
                     cosmetic — it is the `Content-Type` (`application/x-amz-json-<v>`) \
                     the service dispatches on.",
                    meta.service, SUPPORTED_JSON_VERSIONS
                ));
            }
            SelectedProtocol {
                protocol,
                codec: &AWS_JSON_CODEC,
                binding: &AWS_JSON_RPC,
                json_version,
            }
        }
        AwsProtocol::RestJson => SelectedProtocol {
            protocol,
            codec: &AWS_JSON_CODEC,
            binding: &AWS_REST_JSON,
            json_version: String::new(),
        },
        AwsProtocol::RestXml => SelectedProtocol {
            protocol,
            codec: &AWS_XML_CODEC,
            binding: &AWS_REST_XML,
            json_version: String::new(),
        },
        AwsProtocol::Query => SelectedProtocol {
            protocol,
            codec: &AWS_QUERY_CODEC,
            binding: &AWS_QUERY_BINDING,
            json_version: String::new(),
        },
        AwsProtocol::Ec2 => SelectedProtocol {
            protocol,
            codec: &AWS_QUERY_CODEC,
            binding: &AWS_EC2_BINDING,
            json_version: String::new(),
        },
        other => {
            return Err(format!(
                "emit_aws: protocol `{}` is listed as supported and has no codec and \
                 binding in the protocol seam",
                other.botocore_name()
            ))
        }
    };
    check_signature_version(meta)?;
    Ok(selected)
}

/// The `auth` value that names SigV4.
pub const SIGV4_AUTH: &str = "aws.auth#sigv4";

/// The generated client signs with SigV4 and nothing else, so a model's
/// SERVICE-LEVEL metadata must say SigV4: `signatureVersion` `v4`, or `s3`
/// (S3's own name for SigV4 with its payload and path rules). When the
/// model carries an `auth` list it is the authority — botocore resolves the
/// signer from `auth` ahead of `signatureVersion` — so a non-empty `auth`
/// must name [`SIGV4_AUTH`] in both cases, and `s3` needs it unconditionally.
/// Any other value (`v2`, `s3` alone, `bearer`, `v4a`, or `v4` beside an
/// `auth` of `sigv4a` only) is refused by name: a request signed with the
/// wrong scheme is rejected by the service as a signature mismatch, which
/// points at the credential.
///
/// This reads the service metadata only. A per-operation `authtype` or
/// `auth` (an anonymous or bearer operation inside a SigV4 service) is read
/// by `auth::operation_auth`: an anonymous operation is sent unsigned, and a
/// bearer one is refused in client mode.
pub fn check_signature_version(meta: &AwsServiceMeta) -> Result<(), String> {
    let auth_names_sigv4 = meta.auth.iter().any(|a| a == SIGV4_AUTH);
    match meta.signature_version.as_str() {
        "v4" if meta.auth.is_empty() || auth_names_sigv4 => Ok(()),
        "v4" => Err(format!(
            "emit_aws: service `{}` declares signatureVersion `v4`, and its `auth` \
             list {:?} does not name `{SIGV4_AUTH}`. A non-empty `auth` decides the \
             signer ahead of `signatureVersion`; the generated client signs with \
             SigV4 and nothing else.",
            meta.service, meta.auth
        )),
        "s3" if auth_names_sigv4 => Ok(()),
        "s3" => Err(format!(
            "emit_aws: service `{}` declares signatureVersion `s3`, and its `auth` \
             list {:?} does not name `{SIGV4_AUTH}`. `s3` is accepted only as SigV4, \
             which `auth` must say; the generated client signs with SigV4 and \
             nothing else.",
            meta.service, meta.auth
        )),
        other => Err(format!(
            "emit_aws: service `{}` declares signatureVersion `{other}`, and the \
             generated client signs only SigV4 (`v4`, or `s3` with `{SIGV4_AUTH}` \
             in `auth`). It is REFUSED by name: a request signed with another \
             scheme is rejected as a signature mismatch.",
            meta.service
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn meta(protocol: &str, json_version: Option<&str>, sig: &str, auth: &[&str]) -> AwsServiceMeta {
        AwsServiceMeta {
            service: "tiny".to_string(),
            protocol: protocol.to_string(),
            json_version: json_version.map(String::from),
            signature_version: sig.to_string(),
            auth: auth.iter().map(|s| s.to_string()).collect(),
            ..AwsServiceMeta::default()
        }
    }

    #[test]
    fn every_protocol_round_trips_its_botocore_name() {
        for p in ALL_PROTOCOLS {
            assert_eq!(AwsProtocol::from_botocore(p.botocore_name()), Some(*p));
        }
        assert_eq!(AwsProtocol::from_botocore("awsJson1_1"), None);
        assert_eq!(AwsProtocol::from_botocore(""), None);
    }

    #[test]
    fn every_supported_protocol_has_a_codec_and_binding() {
        for name in SUPPORTED_PROTOCOLS {
            let p = AwsProtocol::from_botocore(name).expect("a botocore protocol name");
            let jv = if p == AwsProtocol::Json { Some("1.1") } else { None };
            let s = select_protocol(&meta(name, jv, "v4", &[])).expect("selected");
            assert_eq!(s.protocol, p);
        }
    }

    #[test]
    fn an_unsupported_protocol_is_refused_by_name() {
        for name in ["smithy-rpc-v2-cbor", "nope"] {
            let e = select_protocol(&meta(name, None, "v4", &[])).err().expect("refused");
            assert!(e.contains(&format!("declares protocol `{name}`")), "{e}");
        }
    }

    #[test]
    fn rest_json_is_the_json_codec_behind_the_rest_binding() {
        let s = select_protocol(&meta("rest-json", None, "v4", &[])).expect("selected");
        assert_eq!(s.protocol, AwsProtocol::RestJson);
        assert!(s.json_version.is_empty());
        for p in REST_PROTOCOLS {
            assert!(ALL_PROTOCOLS.contains(p));
        }
        assert!(JSON_BODY_PROTOCOLS.contains(&AwsProtocol::RestJson));
    }

    #[test]
    fn rest_xml_is_the_xml_codec_behind_the_rest_binding() {
        let s = select_protocol(&meta("rest-xml", None, "s3", &[SIGV4_AUTH])).expect("selected");
        assert_eq!(s.protocol, AwsProtocol::RestXml);
        assert!(s.json_version.is_empty());
        assert!(REST_PROTOCOLS.contains(&AwsProtocol::RestXml));
        assert!(XML_BODY_PROTOCOLS.contains(&AwsProtocol::RestXml));
        assert!(!JSON_BODY_PROTOCOLS.contains(&AwsProtocol::RestXml));
    }

    #[test]
    fn query_and_ec2_are_the_query_codec_behind_their_own_bindings() {
        for (name, p) in [("query", AwsProtocol::Query), ("ec2", AwsProtocol::Ec2)] {
            let s = select_protocol(&meta(name, None, "v4", &[])).expect("selected");
            assert_eq!(s.protocol, p);
            assert!(s.json_version.is_empty());
            assert!(QUERY_PROTOCOLS.contains(&p));
            assert!(XML_RESPONSE_PROTOCOLS.contains(&p));
            assert!(!REST_PROTOCOLS.contains(&p));
            assert!(!JSON_BODY_PROTOCOLS.contains(&p));
            assert!(!XML_BODY_PROTOCOLS.contains(&p));
        }
    }

    #[test]
    fn a_json_version_outside_the_supported_set_is_refused() {
        let e = select_protocol(&meta("json", Some("2.0"), "v4", &[])).err().expect("refused");
        assert!(e.contains("jsonVersion \"2.0\""), "{e}");
        let e = select_protocol(&meta("json", None, "v4", &[])).err().expect("refused");
        assert!(e.contains("jsonVersion \"\""), "{e}");
    }

    #[test]
    fn signature_version_v4_is_accepted() {
        assert!(check_signature_version(&meta("json", None, "v4", &[])).is_ok());
        assert!(check_signature_version(&meta("json", None, "v4", &[SIGV4_AUTH])).is_ok());
    }

    #[test]
    fn signature_version_v4_beside_an_auth_without_sigv4_is_refused() {
        for auth in [&["aws.auth#sigv4a"][..], &["smithy.api#httpBearerAuth"][..]] {
            let e = check_signature_version(&meta("json", None, "v4", auth))
                .err()
                .expect("refused");
            assert!(e.contains("signatureVersion `v4`"), "{e}");
            assert!(e.contains(SIGV4_AUTH), "{e}");
        }
        assert!(
            check_signature_version(&meta("json", None, "v4", &["aws.auth#sigv4a", SIGV4_AUTH]))
                .is_ok()
        );
    }

    #[test]
    fn signature_version_s3_needs_sigv4_in_auth() {
        assert!(check_signature_version(&meta("rest-xml", None, "s3", &[SIGV4_AUTH])).is_ok());
        let e = check_signature_version(&meta("rest-xml", None, "s3", &[])).err().expect("refused");
        assert!(e.contains("signatureVersion `s3`"), "{e}");
        assert!(e.contains(SIGV4_AUTH), "{e}");
        let e = check_signature_version(&meta("rest-xml", None, "s3", &["aws.auth#sigv4a"]))
            .err()
            .expect("refused");
        assert!(e.contains("signatureVersion `s3`"), "{e}");
    }

    #[test]
    fn any_other_signature_version_is_refused_by_name() {
        for sig in ["v2", "v4a", "bearer", "s3v4", ""] {
            let e = check_signature_version(&meta("json", None, sig, &[SIGV4_AUTH]))
                .err()
                .expect("refused");
            assert!(e.contains(&format!("signatureVersion `{sig}`")), "{e}");
        }
    }

    #[test]
    fn select_protocol_applies_the_signature_check() {
        let e = select_protocol(&meta("json", Some("1.1"), "v2", &[])).err().expect("refused");
        assert!(e.contains("signatureVersion `v2`"), "{e}");
    }

    /// A one-operation model declaring `protocol` and listing `protocols`
    /// (a JSON array's text, or empty for no list), lowered and emitted as
    /// a pure module with its header.
    fn emit_listing(protocol: &str, protocols: &str) -> Result<(String, String), String> {
        let listed = if protocols.is_empty() {
            String::new()
        } else {
            format!(r#", "protocols": {protocols}"#)
        };
        let model = crate::json::parse(&format!(
            r#"{{"version": "2.0",
                "metadata": {{"apiVersion": "2026-10-06", "endpointPrefix": "tiny",
                    "jsonVersion": "1.0", "protocol": "{protocol}"{listed},
                    "serviceFullName": "Tiny", "serviceId": "Tiny",
                    "signatureVersion": "v4", "targetPrefix": "Tiny",
                    "uid": "tiny-2026-10-06"}},
                "operations": {{"Op": {{"name": "Op",
                    "http": {{"method": "POST", "requestUri": "/"}},
                    "input": {{"shape": "In"}}}}}},
                "shapes": {{"In": {{"type": "structure", "members": {{}}}}}}}}"#
        ))
        .unwrap();
        let lowering = crate::aws_in::lower_aws_service(
            &model,
            "tiny",
            &["Op".to_string()],
            "tiny.json",
            "aws.tiny",
        )?;
        let options = crate::emit_aws::AwsEmitOptions {
            pure_only: true,
            ..crate::emit_aws::AwsEmitOptions::default()
        };
        let prov = crate::emit_aws::AwsProvenance { model_key: "tiny/2026-10-06", model_sha256: "m" };
        let src = crate::emit_aws::emit_aws_module(
            &lowering,
            &crate::overrides::AwsOverrides::empty(),
            "tiny",
            options,
            Some(prov),
        )?
        .source;
        Ok((lowering.service.protocol, src))
    }

    #[test]
    fn the_first_supported_protocol_of_the_list_is_chosen() {
        // CloudWatch's pinned model: smithy-rpc-v2-cbor first, then json.
        let (chosen, src) =
            emit_listing("smithy-rpc-v2-cbor", r#"["smithy-rpc-v2-cbor", "json", "query"]"#)
                .unwrap();
        assert_eq!(chosen, "json");
        let header = "#   protocol     : json 1.0 (targetPrefix `Tiny`)\n\
                      #                  (the model declares `smithy-rpc-v2-cbor`; the first of \
                      its protocols [\"smithy-rpc-v2-cbor\", \"json\", \"query\"]\n\
                      #                  that this generator implements)\n";
        assert!(src.contains(header), "{src}");
        assert!(src.contains("application/x-amz-json-1.0"), "{src}");
        // The list's order decides, not the generator's.
        let (chosen, src) = emit_listing("json", r#"["query", "json"]"#).unwrap();
        assert_eq!(chosen, "query");
        assert!(src.contains("#   protocol     : query (awsQuery)\n"), "{src}");
        // A model whose list starts with its declared protocol reads as before.
        let (chosen, src) = emit_listing("json", r#"["json"]"#).unwrap();
        assert_eq!(chosen, "json");
        assert!(!src.contains("(the model declares"), "{src}");
    }

    #[test]
    fn a_list_with_no_supported_protocol_is_refused_naming_it() {
        let e = emit_listing("smithy-rpc-v2-cbor", r#"["smithy-rpc-v2-cbor"]"#).unwrap_err();
        assert_eq!(
            e,
            "emit_aws: service `tiny` declares protocol `smithy-rpc-v2-cbor` and lists \
             protocols [\"smithy-rpc-v2-cbor\"], and this emitter implements only \
             [\"ec2\", \"json\", \"query\", \"rest-json\", \"rest-xml\"] (ec2Query, \
             awsJson1_0 / awsJson1_1, awsQuery, restJson1, restXml). It is REFUSED by name \
             rather than emitted half-right: a `smithy-rpc-v2-cbor` client emitted by a \
             `json` serializer produces requests that are syntactically valid and \
             semantically wrong, which is the failure mode a conformance corpus catches late \
             and a service catches never."
        );
        // With no list, the message is the one it always was.
        let e = emit_listing("smithy-rpc-v2-cbor", "").unwrap_err();
        assert!(
            e.starts_with(
                "emit_aws: service `tiny` declares protocol `smithy-rpc-v2-cbor`, and this \
                 emitter implements only"
            ),
            "{e}"
        );
    }
}
