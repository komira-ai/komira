//! The AWS client emitter: the IR plus the `aws_in` overlay, emitted as one
//! Mojo module per service.
//!
//! The module is split along the protocol seam ([`proto`]): this file is the
//! protocol-independent core (header, shape structs, constraints, the client
//! and its signed send); a protocol supplies a body codec and a binding.
//!
//! - [`proto`]: [`AwsProtocol`], the `BodyCodec` and `Binding` traits, and
//!   the protocol and signing-scheme checks.
//! - `json_codec`: the JSON body codec.
//! - `rpc`: the awsJson RPC binding.
//! - `rest`: the REST binding (restJson1 and restXml): URI labels and query,
//!   headers, prefix headers, the payload, the response status, and the
//!   restJson1 and restXml errors.
//! - `xml_codec`: the restXml body codec, whose reader the awsQuery and
//!   ec2Query responses use too.
//! - `query`: the awsQuery and ec2Query form-body codec and binding.
//! - [`endpoint`]: endpoint resolution through the service's endpoint
//!   ruleset, emitted when the generator is given one.

use std::collections::{BTreeMap, BTreeSet};

use crate::aws_in::{AwsFacts, AwsLowering, AwsServiceMeta, AwsTimestampFormat};
use crate::ir::{IrEnum, IrField, IrMessage, IrMethod, IrType, Label, ScalarKind};
use crate::lower::{recursion_breaking_edges_under, ContainerInlining};
use crate::overrides::AwsOverrides;

mod auth;
pub mod endpoint;
mod host_prefix;
mod json_codec;
#[cfg(test)]
mod prefix_headers_test;
pub mod proto;
mod query;
mod rest;
mod rpc;
mod xml_codec;

pub use endpoint::AwsEndpointRules;
pub use proto::{
    AwsProtocol, ALL_PROTOCOLS, JSON_BODY_PROTOCOLS, QUERY_PROTOCOLS, REST_PROTOCOLS,
    XML_BODY_PROTOCOLS, XML_RESPONSE_PROTOCOLS,
};
use auth::OperationAuth;
use proto::{select_protocol, Binding, BodyCodec};

/// Emitter options.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AwsEmitOptions {
    pub emit_model_json: bool,
    pub pure_only: bool,
    pub omit_preamble: bool,
    /// The `s3` customization (see [`S3_CUSTOMIZATION`]): refused unless the
    /// model's serviceId is `S3` and its protocol is restXml.
    pub s3: bool,
    /// The `route53` customization (see [`ROUTE53_CUSTOMIZATION`]): refused
    /// unless the model's serviceId is `Route 53` and its protocol is
    /// restXml.
    pub route53: bool,
}

/// The `s3` customization: what botocore does to S3 beyond the
/// model, each from `botocore/handlers.py` at the pinned tag.
///
/// - `_handle_200_error`: a 200 response whose body is an `<Error>` (or is
///   not XML) is an error, handled as an HTTP 500, for every operation that
///   has an output shape whose payload is not a blob or a string
///   (`_should_handle_200_error`). `parse_<op>_response` raises it in the
///   client's text for an HTTP 500 (`<Service>.<Op> failed: HTTP 500 <code>
///   <message>`). In client mode each such operation's verb also passes
///   `s3_200_error=True` to `send_sigv4_signed_request`, which then retries
///   the answer as the 500 botocore's `_update_status_code` makes it.
/// - `handle_expires_header`: an `Expires` header that is not a valid date
///   leaves the member unset, and the rest of the response still parses.
/// - `resolve_request_checksum_algorithm` / `apply_request_checksum`
///   (botocore/httpchecksum.py, under the default `when_supported`): an
///   operation whose `httpChecksum` names a `requestAlgorithmMember` sends
///   `x-amz-checksum-crc32` and the algorithm header, `CRC32` when the
///   caller chose none, unless the caller set an `x-amz-checksum-*` header
///   (`s3_apply_request_checksum`). That covers the operations where the
///   checksum is optional (PutObject, UploadPart) and those where it is
///   required (`requestChecksumRequired`: DeleteObjects, PutBucket* and the
///   like), which are refused without the customization
///   (`check_request_checksums`, applied by
///   [`emit_aws_module_with_endpoints`]).
/// - `remove_bucket_from_url_paths_from_model`: with an endpoint ruleset,
///   a requestUri's leading `/{Bucket}` is dropped, because the ruleset
///   puts the bucket in the URL it chooses (`rest_request_uri` in
///   `rest.rs`).
pub const S3_CUSTOMIZATION: &str = "s3";

/// The `route53` customization: what botocore does to Route 53 beyond the
/// model, from `botocore/handlers.py` at the pinned tag.
///
/// - `fix_route53_ids` (on `before-parameter-build.route53`): each
///   top-level input member whose shape is one of
///   [`ROUTE53_ID_SHAPES`] is sent as the part of its value after the last
///   `/`, so the `/hostedzone/Z…`, `/change/C…` and `/delegationset/N…`
///   Ids Route 53 answers with can be passed back as they came. A bare Id
///   is sent as itself. It applies wherever the member is bound (a label,
///   the query, the body) and before the request is validated, as
///   botocore's handler runs before its validator: `build_<op>_request`
///   copies the input, cuts those members, and builds the request from the
///   copy.
pub const ROUTE53_CUSTOMIZATION: &str = "route53";

/// The input shapes `fix_route53_ids` cuts to their last `/` segment.
pub const ROUTE53_ID_SHAPES: &[&str] = &["ResourceId", "DelegationSetId", "ChangeId"];

/// The protocols this emitter implements, by botocore name. Anything else is
/// refused.
pub const SUPPORTED_PROTOCOLS: &[&str] = &["ec2", "json", "query", "rest-json", "rest-xml"];

/// The `jsonVersion` values this emitter implements.
pub const SUPPORTED_JSON_VERSIONS: &[&str] = &["1.0", "1.1"];

/// The generator version written into every generated header. Bump it when
/// the emitted text changes for the same model, operation list and options.
pub const AWS_GENERATOR_VERSION: &str = "14";

/// The hand-written AWS core every generated module imports from: codecs,
/// SigV4, credential providers, endpoints, retry and the signed-request
/// transport. There is one core per cloud and no other AWS library.
pub const AWS_CORE: &str = "komira_aws_core";

/// When an emitted module needs an import.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AwsImportMode {
    /// Pure and client mode: the socket-free half.
    Always,
    /// Client mode only: anything that touches the transport.
    ClientOnly,
    /// Pure mode only: what a caller with its own transport reads a response
    /// with, which a client's own error builder does not call.
    PureOnly,
    /// A module generated with an endpoint ruleset, in either mode: the
    /// ruleset interpreter (see [`endpoint`]).
    EndpointRules,
    /// A module that renders values in botocore's MODEL convention (the
    /// conformance driver's), when its protocol's body is not JSON: that
    /// convention is JSON, so it needs the JSON runtime the body does not.
    ModelJson,
    /// A module generated with the `s3` customization, in either mode: the
    /// 200-with-`<Error>` check its parsers make.
    S3,
    /// Client mode, or a pure module generated with the `s3` customization:
    /// the error reader, which the client's error builder and the `s3`
    /// 200-with-`<Error>` check both call.
    ClientOrS3,
    /// Client mode of a module generated with an endpoint ruleset: what
    /// turns the endpoint the ruleset chose into the signer's target.
    ClientEndpointRules,
}

/// One `from <module> import <names>` group of [`AWS_IMPORTS`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AwsImport {
    pub module: &'static str,
    pub names: &'static [&'static str],
    pub mode: AwsImportMode,
    /// The protocols whose generated modules import this row.
    pub protocols: &'static [AwsProtocol],
}

/// EVERY module the emitted code imports, and every name it imports from
/// each. Nothing else in the emitter names a module: the import block, the
/// shared pure preamble and the prose that cites a core symbol all read
/// this table, so a layout change is an edit here and nowhere else.
///
/// The [`AWS_CORE`] rows are the contract `komira_aws_core` must meet, as
/// names re-exported from its package root. The `Always` rows are what a
/// pure-mode module needs, so the core's socket-free half can land before
/// any HTTP library; the `ClientOnly` rows need the transport. A row
/// applies to the protocols it lists: the JSON codec names and the
/// `komira_json` runtime only to [`JSON_BODY_PROTOCOLS`].
///
/// Rows of one module merge into one `from` statement, in table order, so
/// the row order is the order of the emitted names.
pub const AWS_IMPORTS: &[AwsImport] = &[
    AwsImport {
        module: AWS_CORE,
        names: &[
            "AWS_TS_ISO8601",
            "AWS_TS_RFC822",
            "AWS_TS_UNIX",
            "AwsRequest",
            "AwsResponse",
        ],
        mode: AwsImportMode::Always,
        protocols: ALL_PROTOCOLS,
    },
    AwsImport {
        module: AWS_CORE,
        names: &["aws_blob_from_json"],
        mode: AwsImportMode::Always,
        protocols: JSON_BODY_PROTOCOLS,
    },
    AwsImport {
        module: AWS_CORE,
        names: &["aws_error_code"],
        mode: AwsImportMode::Always,
        protocols: ALL_PROTOCOLS,
    },
    AwsImport {
        module: AWS_CORE,
        names: &["aws_error_code_from_body", "aws_error_message_from_body"],
        mode: AwsImportMode::PureOnly,
        protocols: JSON_BODY_PROTOCOLS,
    },
    AwsImport {
        module: AWS_CORE,
        names: &["aws_json_error_info"],
        mode: AwsImportMode::ClientOnly,
        protocols: &[AwsProtocol::Json],
    },
    AwsImport {
        module: AWS_CORE,
        names: &["aws_host_label"],
        mode: AwsImportMode::Always,
        protocols: ALL_PROTOCOLS,
    },
    AwsImport {
        module: AWS_CORE,
        names: &["aws_is_error_status"],
        mode: AwsImportMode::Always,
        protocols: ALL_PROTOCOLS,
    },
    AwsImport {
        module: AWS_CORE,
        names: &[
            "aws_f64_from_json",
            "aws_json_blob",
            "aws_json_bool",
            "aws_json_f32",
            "aws_json_f64",
            "aws_json_i32",
            "aws_json_i64",
            "aws_json_string",
            "aws_ts_from_json",
            "aws_ts_to_json",
        ],
        mode: AwsImportMode::Always,
        protocols: JSON_BODY_PROTOCOLS,
    },
    AwsImport {
        module: AWS_CORE,
        names: &[
            "AwsRestUri",
            "aws_blob_from_base64",
            "aws_bool_from_text",
            "aws_f64_from_text",
            "aws_header_field",
            "aws_header_http_date_list",
            "aws_header_http_date_list_from",
            "aws_header_list",
            "aws_header_list_from",
            "aws_i32_from_text",
            "aws_i64_from_text",
            "aws_media_from_text",
            "aws_prefix_headers",
            "aws_response_code",
            "aws_set_prefix_headers",
            "aws_text_blob",
            "aws_text_bool",
            "aws_text_f32",
            "aws_text_f64",
            "aws_text_int",
            "aws_text_media",
            "aws_text_ts",
            "aws_ts_from_text",
        ],
        mode: AwsImportMode::Always,
        protocols: REST_PROTOCOLS,
    },
    AwsImport {
        module: AWS_CORE,
        names: &[
            "AwsClock",
            "AwsCredential",
            "AwsCredsSource",
            "AwsEndpoint",
            "AwsHttpTransport",
            "AwsRetryQuota",
            "Header",
            "HttpResult",
            "resolve_endpoint",
            "send_sigv4_signed_request",
            "send_sigv4_signed_request_with",
        ],
        mode: AwsImportMode::ClientOnly,
        protocols: ALL_PROTOCOLS,
    },
    AwsImport {
        module: AWS_CORE,
        names: &[
            "aws_xml_blob_of",
            "aws_xml_bool_of",
            "aws_xml_child",
            "aws_xml_end",
            "aws_xml_f32_of",
            "aws_xml_f64_of",
            "aws_xml_int_of",
            "aws_xml_list_items",
            "aws_xml_namespace",
            "aws_xml_parse",
            "aws_xml_set_body",
            "aws_xml_start",
            "aws_xml_string_of",
            "aws_xml_ts_of",
            "aws_xml_write_blob",
            "aws_xml_write_bool",
            "aws_xml_write_f32",
            "aws_xml_write_f64",
            "aws_xml_write_int",
            "aws_xml_write_string",
            "aws_xml_write_ts",
        ],
        mode: AwsImportMode::Always,
        protocols: XML_BODY_PROTOCOLS,
    },
    AwsImport {
        module: AWS_CORE,
        names: &["aws_rest_json_error"],
        mode: AwsImportMode::ClientOnly,
        protocols: &[AwsProtocol::RestJson],
    },
    AwsImport {
        module: AWS_CORE,
        names: &["aws_rest_xml_error"],
        mode: AwsImportMode::ClientOrS3,
        protocols: XML_BODY_PROTOCOLS,
    },
    AwsImport {
        module: AWS_CORE,
        names: &["aws_xml_body_is_error", "s3_apply_request_checksum"],
        mode: AwsImportMode::S3,
        protocols: XML_BODY_PROTOCOLS,
    },
    AwsImport {
        module: AWS_CORE,
        names: &[
            "AWS_QUERY_CONTENT_TYPE",
            "AwsQueryWriter",
            "aws_query_key",
            "aws_query_rename_last",
            "aws_query_result",
            "aws_query_set_body",
            "aws_text_blob",
            "aws_text_bool",
            "aws_text_f32",
            "aws_text_f64",
            "aws_text_int",
            "aws_text_ts",
            "aws_xml_blob_of",
            "aws_xml_bool_of",
            "aws_xml_child",
            "aws_xml_entry_key",
            "aws_xml_entry_value",
            "aws_xml_f32_of",
            "aws_xml_f64_of",
            "aws_xml_int_of",
            "aws_xml_list_items",
            "aws_xml_map_entries",
            "aws_xml_parse",
            "aws_xml_string_of",
            "aws_xml_ts_of",
        ],
        mode: AwsImportMode::Always,
        protocols: QUERY_PROTOCOLS,
    },
    AwsImport {
        module: AWS_CORE,
        names: &["aws_query_error"],
        mode: AwsImportMode::ClientOnly,
        protocols: QUERY_PROTOCOLS,
    },
    AwsImport {
        module: AWS_CORE,
        names: &[
            "aws_json_bool",
            "aws_json_f32",
            "aws_json_f64",
            "aws_json_i32",
            "aws_json_i64",
            "aws_json_string",
        ],
        mode: AwsImportMode::ModelJson,
        protocols: XML_RESPONSE_PROTOCOLS,
    },
    AwsImport {
        module: AWS_CORE,
        names: &[
            "AwsPartitionSet",
            "EndpointParams",
            "EndpointRuleSet",
            "ResolvedEndpoint",
        ],
        mode: AwsImportMode::EndpointRules,
        protocols: ALL_PROTOCOLS,
    },
    AwsImport {
        module: AWS_CORE,
        names: &["AwsSigningTarget", "aws_signing_target"],
        mode: AwsImportMode::ClientEndpointRules,
        protocols: ALL_PROTOCOLS,
    },
    AwsImport {
        module: "komira_json",
        names: &["JsonValue", "parse_json_bytes", "parse_json_value"],
        mode: AwsImportMode::Always,
        protocols: JSON_BODY_PROTOCOLS,
    },
    AwsImport {
        module: "komira_json",
        names: &["JsonValue"],
        mode: AwsImportMode::ModelJson,
        protocols: XML_RESPONSE_PROTOCOLS,
    },
    AwsImport {
        module: "komira_xml",
        names: &["XmlNode", "XmlWriter"],
        mode: AwsImportMode::Always,
        protocols: XML_BODY_PROTOCOLS,
    },
    AwsImport {
        module: "komira_xml",
        names: &["XmlNode"],
        mode: AwsImportMode::Always,
        protocols: QUERY_PROTOCOLS,
    },
    AwsImport {
        module: "komira_http_client.client",
        names: &["HttpClientConfig"],
        mode: AwsImportMode::ClientOnly,
        protocols: ALL_PROTOCOLS,
    },
    AwsImport {
        module: "komira_http_core.transport.io_stream",
        names: &["Connector"],
        mode: AwsImportMode::ClientOnly,
        protocols: ALL_PROTOCOLS,
    },
    AwsImport {
        module: "komira_retry",
        names: &["MonotonicClock", "RetryBudget", "RetryLoop", "RetryRng", "Sleeper"],
        mode: AwsImportMode::ClientOnly,
        protocols: ALL_PROTOCOLS,
    },
];

/// The import section of a `protocol` module: one `from` statement per
/// module of the [`AWS_IMPORTS`] rows that apply to `protocol`, in table
/// order, holding every name that `pure_only` needs. Rows that share a
/// module merge into one statement.
pub fn aws_import_section(protocol: AwsProtocol, pure_only: bool) -> String {
    aws_import_section_for(&[protocol], pure_only, false)
}

/// [`aws_import_section`] for a module holding code of several protocols:
/// every row that applies to any of `protocols`, each once, with the
/// [`AwsImportMode::EndpointRules`] rows when `endpoint_rules` is set.
pub fn aws_import_section_for(
    protocols: &[AwsProtocol],
    pure_only: bool,
    endpoint_rules: bool,
) -> String {
    aws_import_section_with(protocols, pure_only, endpoint_rules, false, false)
}

/// [`aws_import_section_for`], with the [`AwsImportMode::ModelJson`] rows
/// when `model_json` is set and the [`AwsImportMode::S3`] rows when `s3` is
/// (the `s3` customization). A name two applying rows both hold is imported
/// once, where its first row puts it.
pub fn aws_import_section_with(
    protocols: &[AwsProtocol],
    pure_only: bool,
    endpoint_rules: bool,
    model_json: bool,
    s3: bool,
) -> String {
    let mut groups: Vec<(&str, Vec<&str>)> = Vec::new();
    for row in AWS_IMPORTS {
        if pure_only && row.mode == AwsImportMode::ClientOnly {
            continue;
        }
        if !pure_only && row.mode == AwsImportMode::PureOnly {
            continue;
        }
        if !endpoint_rules && row.mode == AwsImportMode::EndpointRules {
            continue;
        }
        if (pure_only || !endpoint_rules) && row.mode == AwsImportMode::ClientEndpointRules {
            continue;
        }
        if !model_json && row.mode == AwsImportMode::ModelJson {
            continue;
        }
        if !s3 && row.mode == AwsImportMode::S3 {
            continue;
        }
        if pure_only && !s3 && row.mode == AwsImportMode::ClientOrS3 {
            continue;
        }
        if !row.protocols.iter().any(|p| protocols.contains(p)) {
            continue;
        }
        match groups.iter_mut().find(|(m, _)| *m == row.module) {
            Some((_, names)) => {
                for n in row.names {
                    if !names.contains(n) {
                        names.push(*n);
                    }
                }
            }
            None => groups.push((row.module, row.names.to_vec())),
        }
    }
    let mut s = String::new();
    for (module, names) in groups {
        if names.len() == 1 {
            s.push_str(&format!("from {module} import {}\n", names[0]));
        } else {
            s.push_str(&format!("from {module} import (\n"));
            for n in names {
                s.push_str(&format!("    {n},\n"));
            }
            s.push_str(")\n");
        }
    }
    s
}

/// Where the model came from, for the generated header. The emitter does
/// not check it; `aws-client-gen` verifies the digest against the model
/// bytes before it builds one.
#[derive(Clone, Copy, Debug)]
pub struct AwsProvenance<'a> {
    /// The botocore data key, `<service>/<api version>`, e.g.
    /// `logs/2014-03-28`.
    pub model_key: &'a str,
    /// The sha256 of the model file, as the pin records it.
    pub model_sha256: &'a str,
}

/// One generated module.
#[derive(Clone, Debug)]
pub struct AwsEmitted {
    /// `<module>.mojo`.
    pub path: String,
    pub source: String,
    /// Every non-parameterised top-level struct the module declares, in
    /// emission order: what a layout probe can `size_of`.
    pub structs: Vec<String>,
    /// The parameterised ones (the client), which a probe cannot name
    /// without choosing parameters.
    pub parameterised: Vec<String>,
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Emit ONE Mojo module for `lowering`, honouring `overrides`.
///
/// Returns `(relative_path, source)`. Deterministic: the same inputs produce
/// byte-identical output, which is what makes "regenerate and diff" a usable
/// falsifier for the override seam.
pub fn emit_aws_client(
    lowering: &AwsLowering,
    overrides: &AwsOverrides,
    module_name: &str,
    options: AwsEmitOptions,
) -> Result<(String, String), String> {
    let e = emit_aws_module(lowering, overrides, module_name, options, None)?;
    Ok((e.path, e.source))
}

/// [`emit_aws_client`], with the provenance the header records and the
/// struct lists a layout probe needs.
///
/// Without `options.omit_preamble` the provenance is required: a standalone
/// module whose header cannot say which model bytes it came from is refused.
pub fn emit_aws_module(
    lowering: &AwsLowering,
    overrides: &AwsOverrides,
    module_name: &str,
    options: AwsEmitOptions,
    provenance: Option<AwsProvenance<'_>>,
) -> Result<AwsEmitted, String> {
    emit_aws_module_with_endpoints(lowering, overrides, module_name, options, provenance, None)
}

/// [`emit_aws_module`], resolving endpoints through `endpoint_rules` when it
/// is given: the module embeds the ruleset and gets an endpoint config and a
/// `resolve_<op>_endpoint` per operation ([`endpoint`]). Every binding of the
/// model is checked against the ruleset first. Refused in `omit_preamble`
/// mode, whose concatenated modules have no header to record it in.
pub fn emit_aws_module_with_endpoints(
    lowering: &AwsLowering,
    overrides: &AwsOverrides,
    module_name: &str,
    options: AwsEmitOptions,
    provenance: Option<AwsProvenance<'_>>,
    endpoint_rules: Option<&AwsEndpointRules>,
) -> Result<AwsEmitted, String> {
    if endpoint_rules.is_some() && options.omit_preamble {
        return Err(format!(
            "emit_aws: module `{module_name}` is given an endpoint ruleset in \
             omit_preamble mode, which has no header to record it in"
        ));
    }
    if provenance.is_none() && !options.omit_preamble {
        return Err(format!(
            "emit_aws: module `{module_name}` has a header but no provenance; the \
             header must name the model key and its sha256"
        ));
    }
    let selected = select_protocol(&lowering.service)?;
    if options.s3
        && (lowering.service.service_id != "S3" || selected.protocol != AwsProtocol::RestXml)
    {
        return Err(format!(
            "emit_aws: the `{S3_CUSTOMIZATION}` customization is refused unless the model's \
             serviceId is `S3` and its protocol is restXml, and service `{}` has serviceId \
             `{}` and protocol `{}`",
            lowering.service.service, lowering.service.service_id, lowering.service.protocol
        ));
    }
    if options.route53
        && (lowering.service.service_id != "Route 53"
            || selected.protocol != AwsProtocol::RestXml)
    {
        return Err(format!(
            "emit_aws: the `{ROUTE53_CUSTOMIZATION}` customization is refused unless the \
             model's serviceId is `Route 53` and its protocol is restXml, and service `{}` \
             has serviceId `{}` and protocol `{}`",
            lowering.service.service, lowering.service.service_id, lowering.service.protocol
        ));
    }
    check_request_checksums(&lowering.facts, options)?;
    check_modeled_retryable_errors(&lowering.facts, options)?;
    auth::check_operation_auth(&lowering.service.service, &lowering.facts, options.pure_only)?;
    if selected.protocol == AwsProtocol::RestXml {
        xml_codec::check_rest_xml_features(&lowering.facts)?;
    }
    if QUERY_PROTOCOLS.contains(&selected.protocol) {
        query::check_query_features(&lowering.facts, selected.protocol)?;
    }
    overrides.check_against(lowering)?;

    let mut em = AwsEmitter::new(lowering, overrides, module_name, selected, options)?;
    em.endpoint_rules = endpoint_rules;
    em.provenance = provenance.map(|p| (p.model_key.to_string(), p.model_sha256.to_string()));
    let source = em.emit()?;
    Ok(AwsEmitted {
        path: format!("{module_name}.mojo"),
        source,
        structs: em.structs,
        parameterised: em.parameterised,
    })
}

/// REFUSED, by name (`checksum-required`): an operation whose every request
/// must carry a checksum (`httpChecksumRequired`, or
/// `httpChecksum.requestChecksumRequired`), unless the module sends one.
/// Only the `s3` customization does, for an operation whose `httpChecksum`
/// names a `requestAlgorithmMember` (`emit_s3_request_checksum` in
/// `rest.rs`): botocore sends CRC32 there whether the checksum is required
/// or only supported (`resolve_request_checksum_algorithm`), and so does the
/// generated builder. Anywhere else the generated client sends none, and
/// the service would reject every request.
///
/// That refusal is this generator's choice, not botocore's behaviour:
/// botocore also sends `x-amz-checksum-crc32` (with no algorithm header)
/// for `httpChecksumRequired` with no algorithm member, and for any
/// service. No S3 operation in the pinned model is in that case: each one
/// requiring a checksum names a `requestAlgorithmMember`.
fn check_request_checksums(facts: &AwsFacts, options: AwsEmitOptions) -> Result<(), String> {
    for (name, op) in facts.operations() {
        if !op.request_checksum_required() {
            continue;
        }
        let sent = options.s3
            && op
                .http_checksum
                .as_ref()
                .is_some_and(|c| c.request_algorithm_member.is_some());
        if !sent {
            return Err(format!(
                "emit_aws: REFUSED checksum-required: operation `{name}` requires a \
                 request checksum, and the generated client sends one only with the \
                 `{S3_CUSTOMIZATION}` customization, for an operation whose httpChecksum \
                 names a requestAlgorithmMember"
            ));
        }
    }
    Ok(())
}

/// REFUSED, by name (`modeled-retryable`), in client mode: an operation that
/// can return an error shape the model marks `retryable`. botocore's
/// standard mode retries such an error (`ModeledRetryableChecker`), and the
/// generated send (`send_sigv4_signed_request`) retries by status, error
/// code and transport failure only, so the client would give up where
/// botocore retries. A pure-mode module has no send and is not refused.
fn check_modeled_retryable_errors(
    facts: &AwsFacts,
    options: AwsEmitOptions,
) -> Result<(), String> {
    if options.pure_only {
        return Ok(());
    }
    for (name, op) in facts.operations() {
        for fq in &op.errors {
            let shape = fq.rsplit('#').next().unwrap_or(fq);
            if facts.shape(shape)?.retryable {
                return Err(format!(
                    "emit_aws: REFUSED modeled-retryable: operation `{name}` can return \
                     `{shape}`, which the model marks retryable; botocore's standard mode \
                     retries it (ModeledRetryableChecker), and the generated send retries \
                     by status, error code and transport failure only"
                ));
            }
        }
    }
    Ok(())
}

/// The layout probe for `emitted`: one `size_of` per struct it declares.
///
/// A generator that accepts an operation does not prove the emitted code
/// lays out: an import alone does not make Mojo compute a struct's layout,
/// and `size_of[T]()` does. Each `size_of` is a `comptime` value, and `main`
/// prints their sum so none can be dropped. `import_path` is the dotted path
/// a consumer imports the module by. A module with no struct to probe is
/// refused, because an empty probe compiles and proves nothing. The CLI
/// cannot reach this: every operation lowers to a Request and a Response
/// struct, so the refusal guards other callers of this function.
pub fn emit_layout_probe(emitted: &AwsEmitted, import_path: &str) -> Result<String, String> {
    if emitted.structs.is_empty() {
        return Err(format!(
            "layout probe: `{import_path}` declares no non-parameterised struct, so a \
             probe would compile while checking nothing"
        ));
    }
    let mut s = String::new();
    s.push_str(&format!(
        "# GENERATED by //tools/build/proto-codegen:aws-client-gen (version {}) \
         -- DO NOT EDIT.\n",
        AWS_GENERATOR_VERSION
    ));
    s.push_str(&format!(
        "# Layout probe for `{import_path}`: one size_of per struct it declares.\n"
    ));
    if emitted.parameterised.is_empty() {
        s.push_str("# Parameterised structs, not probed: none.\n");
    } else {
        s.push_str(&format!(
            "# Parameterised structs, not probed: {}.\n",
            emitted.parameterised.join(", ")
        ));
    }
    s.push_str("\nfrom std.sys import size_of\n\n");
    s.push_str(&format!("from {import_path} import (\n"));
    for (i, name) in emitted.structs.iter().enumerate() {
        s.push_str(&format!("    {name} as _P{i},\n"));
    }
    s.push_str(")\n\n");
    for i in 0..emitted.structs.len() {
        s.push_str(&format!("comptime _SIZE_P{i} = size_of[_P{i}]()\n"));
    }
    let sum: Vec<String> = (0..emitted.structs.len()).map(|i| format!("_SIZE_P{i}")).collect();
    s.push_str("\n\ndef main():\n");
    s.push_str(&format!("    print({})\n", sum.join(" + ")));
    Ok(s)
}

// ---------------------------------------------------------------------------
// The emitter
// ---------------------------------------------------------------------------

struct AwsEmitter<'a> {
    lowering: &'a AwsLowering,
    facts: &'a AwsFacts,
    meta: &'a AwsServiceMeta,
    overrides: &'a AwsOverrides,
    module_name: String,
    /// The protocol, and the codec and binding it plugs into the seam.
    protocol: AwsProtocol,
    codec: &'static dyn BodyCodec,
    binding: &'static dyn Binding,
    /// The awsJson `jsonVersion`; empty for any other protocol.
    json_version: String,
    options: AwsEmitOptions,
    /// The Mojo name prefix every emitted type carries, so two generated
    /// services can be imported into one module without colliding.
    prefix: String,
    /// `(message.mojo_name, field.name)` pairs that must be heap-indirected.
    boxed: BTreeSet<(String, String)>,
    /// mojo_name -> the enum, for the string-valued lowering.
    enums: BTreeMap<String, &'a IrEnum>,
    /// mojo_name -> the message.
    messages: BTreeMap<String, &'a IrMessage>,
    /// fq_name -> mojo_name.
    by_fq: BTreeMap<String, String>,
    /// The `mojo_name`s that get a `validate()` — those with a model-stated
    /// size/range constraint on a member, PLUS every shape that reaches one,
    /// so the call forwards. See [`AwsEmitter::validating_set`].
    validating: BTreeSet<String>,
    /// `(model key, model sha256)` for the header.
    provenance: Option<(String, String)>,
    /// The endpoint ruleset, when endpoints resolve through one.
    endpoint_rules: Option<&'a AwsEndpointRules>,
    /// Non-parameterised top-level structs, in emission order.
    structs: Vec<String>,
    /// Parameterised top-level structs.
    parameterised: Vec<String>,
    out: String,
    indent: usize,
}

/// What a botocore `min` / `max` on a shape MEASURES, which is not the same
/// quantity in each case and decides both the Mojo expression and whether the
/// check is emitted at all.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ConstraintKind {
    StringChars,
    /// A `blob`: byte count. A `list`/`map`: element / entry count. Both are
    /// exactly what Mojo's `len()` answers.
    ElementCount,
    NumericRange,
}

/// One member's model-stated constraint, already reduced to the form the
/// emitter needs.
#[derive(Clone, Copy, Debug)]
struct MemberConstraint {
    min: Option<f64>,
    max: Option<f64>,
    kind: ConstraintKind,
}

impl<'a> AwsEmitter<'a> {
    fn new(
        lowering: &'a AwsLowering,
        overrides: &'a AwsOverrides,
        module_name: &str,
        selected: proto::SelectedProtocol,
        options: AwsEmitOptions,
    ) -> Result<Self, String> {
        let file = lowering
            .model
            .files
            .first()
            .ok_or_else(|| "emit_aws: the lowering carries no IrFile".to_string())?;
        let mut enums = BTreeMap::new();
        let mut messages = BTreeMap::new();
        let mut by_fq = BTreeMap::new();
        for e in &file.enums {
            enums.insert(e.mojo_name.clone(), e);
            by_fq.insert(e.fq_name.clone(), e.mojo_name.clone());
        }
        for m in &file.messages {
            messages.insert(m.mojo_name.clone(), m);
            by_fq.insert(m.fq_name.clone(), m.mojo_name.clone());
        }
        Ok(AwsEmitter {
            lowering,
            facts: &lowering.facts,
            meta: &lowering.service,
            overrides,
            module_name: module_name.to_string(),
            protocol: selected.protocol,
            codec: selected.codec,
            binding: selected.binding,
            json_version: selected.json_version,
            options,
            prefix: service_type_prefix(&lowering.service),
            boxed: recursion_breaking_edges_under(
                file,
                ContainerInlining::ViaOptionalWrapper,
            ),
            enums,
            messages,
            by_fq,
            validating: BTreeSet::new(),
            provenance: None,
            endpoint_rules: None,
            structs: Vec::new(),
            parameterised: Vec::new(),
            out: String::new(),
            indent: 0,
        })
    }

    fn file(&self) -> &'a crate::ir::IrFile {
        &self.lowering.model.files[0]
    }

    // -- text helpers ------------------------------------------------------
    fn line(&mut self, s: &str) {
        if !s.is_empty() {
            for _ in 0..self.indent {
                self.out.push_str("    ");
            }
            self.out.push_str(s);
        }
        self.out.push('\n');
    }
    fn blank(&mut self) {
        self.out.push('\n');
    }
    fn push(&mut self) {
        self.indent += 1;
    }
    fn pop(&mut self) {
        self.indent -= 1;
    }

    // -- naming ------------------------------------------------------------
    fn ty_name(&self, mojo_name: &str) -> String {
        format!("{}{}", self.prefix, mojo_name)
    }

    /// The prefix on module-level FUNCTION names.
    ///
    /// Empty in normal use — one service per module, so `build_create_secret_request`
    /// is unambiguous. In `omit_preamble` (single-file) mode it is the type
    /// prefix lowercased, because that mode concatenates many services into one
    /// module and two suites that both define `EmptyOperation` would otherwise
    /// emit two `build_empty_operation_request` definitions, the second silently
    /// shadowing the first.
    fn fn_prefix(&self) -> String {
        if self.options.omit_preamble {
            format!("{}_", self.prefix.to_lowercase())
        } else {
            String::new()
        }
    }

    // ======================================================================
    // emit
    // ======================================================================
    fn emit(&mut self) -> Result<String, String> {
        // Before ANY message is written: which shapes get a `validate()`.
        // `emit_message` and `emit_operations` both ask, and a shape's answer
        // depends on shapes emitted after it, so it cannot be decided inline.
        self.validating = self.validating_set();
        if let Some(rules) = self.endpoint_rules {
            self.check_endpoint_bindings(rules)?;
        }
        if !self.options.omit_preamble {
            let unapplied = match self.endpoint_rules {
                Some(_) => Vec::new(),
                None => self.unapplied_endpoint_bindings()?,
            };
            self.emit_header(&unapplied);
            self.emit_imports()?;
        }
        self.emit_constants();
        self.emit_enum_constants();
        for name in self.messages.keys().cloned().collect::<Vec<_>>() {
            let msg = self.messages[&name];
            self.emit_message(msg)?;
        }
        if self.options.emit_model_json && !self.options.omit_preamble {
            self.emit_bytes_helper();
        }
        self.emit_operations()?;
        if let Some(rules) = self.endpoint_rules {
            self.emit_endpoint_section(rules)?;
        }
        if !self.options.pure_only {
            self.emit_client()?;
        }
        if !self.options.omit_preamble {
            // The last line, so a reader of the module (mojo_aws_client's
            // environment scan) can tell it read all of it.
            let end = format!("# End of {}, generated by aws-client-gen.", self.module_name);
            self.line(&end);
        }
        Ok(std::mem::take(&mut self.out))
    }

    fn emit_header(&mut self, unapplied_endpoint_bindings: &[String]) {
        let n_messages = self.lowering.model.files[0].messages.len();
        let n_enums = self.lowering.model.files[0].enums.len();
        let ops: Vec<String> = self
            .facts
            .operations()
            .map(|(n, _)| n.clone())
            .collect();
        self.line(&format!(
            "# {}",
            "=".repeat(75)
        ));
        self.line(&format!(
            "# GENERATED by //tools/build/proto-codegen:aws-client-gen — DO NOT EDIT."
        ));
        self.line("#");
        self.line("# Regenerating this file OVERWRITES it whole. Hand-written behaviour");
        self.line("# belongs in the override module named below, never here — see the");
        self.line("# HAND-OVERRIDE SEAM section at the end of this header.");
        self.line("#");
        self.line(&format!("#   service      : {}", self.meta.service_full_name));
        self.line(&format!("#   botocore id  : {}", self.meta.service));
        self.line(&format!("#   api version  : {}", self.meta.api_version));
        let protocol_line = self.binding.header_protocol(self);
        self.line(&format!("#   protocol     : {protocol_line}"));
        if self.meta.protocol != self.meta.declared_protocol {
            self.line(&format!(
                "#                  (the model declares `{}`; the first of its protocols {:?}",
                self.meta.declared_protocol, self.meta.protocols
            ));
            self.line("#                  that this generator implements)");
        }
        let (model_key, model_sha256) = self.provenance.clone().unwrap_or_default();
        self.line(&format!("#   model key    : {model_key}"));
        self.line(&format!("#   model sha256 : {model_sha256}"));
        self.line(&format!("#   operations   : {}", ops.join(", ")));
        if let Some(rules) = self.endpoint_rules {
            self.line(&format!(
                "#   endpoints    : ruleset sha256 {}",
                rules.ruleset_sha256
            ));
            self.line(&format!(
                "#                  partitions sha256 {}",
                rules.partitions_sha256
            ));
        } else if !unapplied_endpoint_bindings.is_empty() {
            // Generated without the service's ruleset (mojo_aws_client's
            // `endpoint_rules`): requests go to the static service host, and
            // what the model binds into the ruleset is said here, not dropped
            // silently.
            self.line("#   endpoints    : NO RULESET. Requests go to the static service host,");
            self.line("#                  and these endpoint bindings of the model are NOT");
            self.line("#                  applied (mojo_aws_client `endpoint_rules` applies them):");
            for b in unapplied_endpoint_bindings {
                for (i, l) in wrap(b, 58).iter().enumerate() {
                    let lead = if i == 0 { "-" } else { " " };
                    self.line(&format!("#                  {lead} {l}"));
                }
            }
        }
        self.line(&format!(
            "#   shapes       : {} messages, {} enums",
            n_messages,
            n_enums
        ));
        self.line(&format!("#   generator    : aws-client-gen version {AWS_GENERATOR_VERSION}"));
        self.line(&format!(
            "#   mode         : {}",
            if self.options.pure_only { "pure (no transport)" } else { "client" }
        ));
        if self.options.s3 {
            self.line("#   customize    : s3 (botocore handlers.py: 200-with-<Error> as an");
            self.line("#                  error, an invalid Expires header left unset)");
            if self.endpoint_rules.is_some() {
                self.line("#                  and a leading /{Bucket} dropped from each path:");
                self.line("#                  the endpoint ruleset puts the bucket in the URL");
            }
        }
        if self.options.route53 {
            self.line("#   customize    : route53 (botocore handlers.py: each top-level");
            self.line("#                  ResourceId, DelegationSetId or ChangeId input");
            self.line("#                  member sent as the part after its last `/`)");
        }
        self.line("#");
        if !self.options.pure_only {
            self.line("# THE SIGNER AND THE CREDENTIAL CHAIN ARE NOT GENERATED. The transport");
            self.line(&format!(
                "# call below goes to the hand-written `{}.send_sigv4_signed_request`,",
                AWS_CORE
            ));
            self.line("# which is tested against the AWS SigV4 test vectors. Nothing here signs.");
            self.line("#");
        }
        if !self.validating.is_empty() {
            self.line("# ── §CONSTRAINTS — the model's `min` / `max`, checked ─────────────");
            self.line("#");
            self.line("# ⛔ `required` AND `non-empty` ARE DIFFERENT CLAIMS AND THE MODEL");
            self.line("# MAKES BOTH. A required member is taken positionally by `__init__`,");
            self.line("# which forces a caller to pass one and says nothing whatever about it");
            self.line("# being non-empty. `min` is where botocore says the second thing —");
            self.line("# a string shape declared `{\"type\":\"string\",\"min\":1}` may not be");
            self.line("# empty — and the shapes below check it in a `validate()`. Every bound");
            self.line("# here is READ FROM THE MODEL; none is a policy this generator invented.");
            self.line("#");
            self.line("# `validate()` is called by `build_<op>_request`, which is the only");
            self.line("# entry point that produces an `AwsRequest` — so a value that reaches");
            self.line("# AWS has been through it. It is not a convention a caller upholds.");
            self.line("#");
            self.line("# ⚠ STRING `max` IS DELIBERATELY NOT CHECKED, AND THE ASYMMETRY IS");
            self.line("# SOUNDNESS. Smithy `@length` counts CHARACTERS; `byte_length()`");
            self.line("# counts BYTES, and UTF-8 gives bytes >= chars. So `bytes < min`");
            self.line("# always implies `chars < min` (a real violation), while `bytes > max`");
            self.line("# implies nothing — a multi-byte value inside the limit would be");
            self.line("# REFUSED HERE and ACCEPTED BY AWS. Rejecting a request the service");
            self.line("# would have honoured is worse than letting the service reject it,");
            self.line("# because its error names the parameter and ours would name a limit");
            self.line("# the caller did not violate. Blob / list / map sizes and numeric");
            self.line("# ranges have no such gap and check BOTH bounds.");
            self.line("#");
            self.line("# ⚠ `pattern` IS NOT CHECKED — this emitter has no regex, so a shape's");
            self.line("# `pattern` is dropped. That is a stated gap, not an absence.");
            self.line("#");
        }
        if self.overrides.is_empty() {
            self.line("# HAND-OVERRIDE SEAM: no overrides are declared for this service.");
        } else {
            self.line("# ── HAND-OVERRIDE SEAM ────────────────────────────────────────────");
            self.line("# These operations have HAND-WRITTEN behaviour that this generator must");
            self.line("# not shadow. For each, the plain verb name is NOT emitted on the");
            self.line("# client — only `<verb>_raw` — so the un-overridden call is not");
            self.line("# reachable by accident and a regeneration cannot restore it. The");
            self.line("# named module owns the plain name.");
            for (op, ov) in self.overrides.iter() {
                self.line("#");
                self.line(&format!("#   {op}"));
                self.line(&format!("#     owner  : {}.{}", ov.hand_module, ov.hand_symbol));
                for l in wrap(&ov.reason, 66) {
                    self.line(&format!("#     reason : {l}"));
                }
            }
        }
        for note in &self.lowering.notes {
            let _ = note;
        }
        self.line(&format!("# {}", "=".repeat(75)));
        self.blank();
    }

    fn emit_imports(&mut self) -> Result<(), String> {
        let fills_token = self.fills_idempotency_tokens()?;
        let section = aws_import_section_with(
            &[self.protocol],
            self.options.pure_only,
            self.endpoint_rules.is_some(),
            self.options.emit_model_json,
            self.options.s3,
        );
        self.out.push_str(&section);
        if fills_token {
            self.out.push_str(&format!("from {AWS_CORE} import aws_idempotency_token\n"));
        }
        if self.sends_unsigned()? {
            self.out.push_str(&format!(
                "from {AWS_CORE} import (\n    send_unsigned_request,\n    \
                 send_unsigned_request_with,\n)\n"
            ));
        }
        self.blank();
        self.blank();
        Ok(())
    }

    fn emit_constants(&mut self) {
        let p = &self.prefix.to_uppercase();
        self.line(&format!("# {}", "-".repeat(75)));
        self.line("# §0 — wire constants. Every one is read from the model's `metadata`.");
        self.line(&format!("# {}", "-".repeat(75)));
        self.line(&format!(
            "comptime {p}_SERVICE: String = \"{}\"",
            self.meta.signing_name
        ));
        self.line(&format!(
            "comptime {p}_ENDPOINT_PREFIX: String = \"{}\"",
            self.meta.endpoint_prefix
        ));
        let binding = self.binding;
        binding.emit_wire_constants(self);
        self.blank();
        let global = self.meta.global_endpoint.clone();
        let mn = self.module_name.clone();
        self.line(&format!("def {mn}_host(region: String) raises -> String:"));
        self.push();
        if let Some(g) = &global {
            self.line(&format!(
                "\"\"\"`{g}` — this service declares a GLOBAL endpoint in its model, so"
            ));
            self.line("    `region` is signed with but not spelled into the host.\"\"\"");
            self.line("_ = region");
            self.line(&format!("return String(\"{g}\")"));
        } else {
            self.line(&format!(
                "\"\"\"`{}.<region>.amazonaws.com`.",
                self.meta.endpoint_prefix
            ));
            self.blank();
            self.line("    ⚠ REGIONAL. An empty region here would sign against a host with a");
            self.line("    doubled dot and fail as DNS — an error that says nothing about the");
            self.line("    composition that left the region unset. So it is refused by name.\"\"\"");
            self.line("if region.byte_length() == 0:");
            self.push();
            self.line("raise Error(");
            self.push();
            self.line(&format!(
                "\"{}_host: REFUSED an EMPTY region — this is a REGIONAL\"",
                self.module_name
            ));
            self.line("\" service and there is no global endpoint to fall back to.\"");
            self.pop();
            self.line(")");
            self.pop();
            self.line(&format!(
                "return String(\"{}.\") + region + String(\".amazonaws.com\")",
                self.meta.endpoint_prefix
            ));
        }
        self.pop();
        self.blank();
        self.blank();
    }

    fn emit_bytes_helper(&mut self) {
        self.line("def _aws_bytes_to_string(b: List[UInt8]) -> String:");
        self.push();
        self.line("\"\"\"Decoded blob bytes as text — the MODEL convention for a blob.\"\"\"");
        self.line("var out = String(\"\")");
        self.line("for _i in range(len(b)):");
        self.push();
        self.line("out += chr(Int(b[_i]))");
        self.pop();
        self.line("return out^");
        self.pop();
        self.blank();
        self.blank();
    }

    /// AWS enums are OPEN and STRING-valued. They are emitted as named
    /// constants over `String`, never as a closed wrapper type — see the
    /// module doc.
    fn emit_enum_constants(&mut self) {
        if self.enums.is_empty() {
            return;
        }
        self.line(&format!("# {}", "-".repeat(75)));
        self.line("# §1 — enum values.");
        self.line("#");
        self.line("# ⚠ AWS ENUMS ARE OPEN AND STRING-VALUED ON THE WIRE. A member typed by");
        self.line("# one of these is a plain `String`, and these constants are the values the");
        self.line("# MODEL knows about — not the values that may ARRIVE. A closed wrapper");
        self.line("# type would turn a service adding a value into a client-side crash on a");
        self.line("# response that is entirely valid.");
        self.line(&format!("# {}", "-".repeat(75)));
        let names: Vec<String> = self.enums.keys().cloned().collect();
        for n in names {
            let en = self.enums[&n];
            let ty = self.ty_name(&n);
            self.line(&format!("# `{}` — {} values.", en.name, en.values.len()));
            for v in &en.values {
                self.line(&format!(
                    "comptime {}_{}: String = \"{}\"",
                    to_screaming(&ty),
                    to_screaming(&v.mojo_name),
                    escape(&v.name)
                ));
            }
            self.blank();
        }
        self.blank();
    }

    fn emit_explicit_deinit(&mut self) {
        self.line("# PORT(1.0.0): explicit destructor — 1.0.0's `Deinitable`");
        self.line("# synthesis is not co-inductive and its cycle guard caches a");
        self.line("# negative, so a shape that reaches itself through the recursion");
        self.line("# box cannot prove itself. Field destructors still run;");
        self.line("# ownership is unchanged.");
        self.line("def __deinit__(deinit self):");
        self.push();
        self.line("pass");
        self.pop();
        self.blank();
    }

    fn emit_message(&mut self, msg: &IrMessage) -> Result<(), String> {
        let ty = self.ty_name(&msg.mojo_name);
        let shape_facts = self.facts.shape(&msg.name).ok();
        let is_union = shape_facts.map(|f| f.union).unwrap_or(false);
        let is_synthetic = shape_facts.map(|f| f.synthetic).unwrap_or(false);

        self.line(&format!("# {}", "-".repeat(75)));
        self.line(&format!("# `{}` — AWS shape `{}`.", ty, msg.name));
        self.line(&format!("# {}", "-".repeat(75)));
        self.structs.push(ty.clone());
        self.line(&format!("struct {ty}(Copyable, Movable, Deinitable):"));
        self.push();

        // -- docstring -----------------------------------------------------
        let required: Vec<&IrField> = msg
            .fields
            .iter()
            .filter(|f| self.required(msg, f))
            .collect();
        self.line(&format!(
            "\"\"\"AWS shape `{}` — {} member(s), {} required by the model.",
            msg.name,
            msg.fields.len(),
            required.len()
        ));
        self.blank();
        let codec = self.codec;
        codec.emit_shape_doc(self, is_union, is_synthetic);
        self.blank();

        // -- fields --------------------------------------------------------
        for f in &msg.fields {
            let wire = self.wire_name(msg, f);
            self.line(&format!(
                "# `{}` -> wire `{}`{}",
                f.name,
                wire,
                if self.required(msg, f) { " (required)" } else { "" }
            ));
            self.line(&format!("var {}: {}", f.name, self.storage_type(msg, f)?));
        }
        self.blank();
        self.emit_explicit_deinit();

        // -- __init__ ------------------------------------------------------
        let mut sig = String::from("def __init__(out self");
        for f in &required {
            sig.push_str(&format!(", var {}: {}", f.name, self.value_type(msg, f)?));
        }
        sig.push_str("):");
        self.line(&sig);
        self.push();
        if msg.fields.is_empty() {
            self.line("pass");
        }
        for f in &msg.fields {
            if self.required(msg, f) {
                if self.is_boxed(msg, f) {
                    self.line(&format!("self.{} = List[{}]()", f.name, self.bare_type(msg, f)?));
                    self.line(&format!("self.{}.append({}^)", f.name, f.name));
                } else {
                    self.line(&format!("self.{0} = {0}^", f.name));
                }
            } else {
                self.line(&format!(
                    "self.{} = {}()",
                    f.name,
                    self.storage_type(msg, f)?
                ));
            }
        }
        self.pop();
        self.blank();

        // -- copy ----------------------------------------------------------
        // An explicit copy constructor: the 1.0.0 compiler can report the
        // synthesized one as trivial (it did for S3's `DeletedObject`: three
        // `Optional[String]` and an `Optional[Bool]`; the trigger is the field
        // order, https://github.com/modular/modular/issues/7256), and
        // `List.copy()` then copies the elements with memcpy, so two lists
        // share each String buffer and the first one destroyed frees it under
        // the other. A user-defined constructor is never trivial; remove this
        // once that issue is fixed in the pinned compiler.
        self.line("def __init__(out self, *, copy: Self):");
        self.push();
        self.line("\"\"\"Explicit, never bitwise: a List copies its elements with it.\"\"\"");
        self.line("self = copy.copy()");
        self.pop();
        self.blank();
        self.line("def copy(self) -> Self:");
        self.push();
        self.line("\"\"\"Deep clone. Explicit, not implicit: every member is heap-owning.\"\"\"");
        if required.is_empty() {
            self.line("var out = Self()");
        } else {
            let args: Vec<String> = required
                .iter()
                .map(|f| {
                    if self.is_boxed(msg, f) {
                        format!("self.{}[0].copy()", f.name)
                    } else {
                        self.copy_expr(msg, f, &format!("self.{}", f.name))
                    }
                })
                .collect();
            self.line(&format!("var out = Self({})", args.join(", ")));
        }
        for f in &msg.fields {
            if !self.required(msg, f) {
                self.line(&format!("out.{0} = self.{0}.copy()", f.name));
            }
        }
        self.line("return out^");
        self.pop();
        self.blank();

        // -- setters -------------------------------------------------------
        let optional_fields: Vec<IrField> = msg
            .fields
            .iter()
            .filter(|f| !self.required(msg, f))
            .cloned()
            .collect();
        for f in &optional_fields {
            let vt = self.value_type(msg, f)?;
            self.line(&format!("def set_{}(mut self, var value: {vt}):", f.name));
            self.push();
            if self.is_boxed(msg, f) {
                self.line(&format!("self.{}.clear()", f.name));
                self.line(&format!("self.{}.append(value^)", f.name));
            } else {
                self.line(&format!(
                    "self.{} = Optional[{vt}](value^)",
                    f.name
                ));
            }
            self.pop();
            self.blank();
        }

        // -- validate ------------------------------------------------------
        // Only for a shape that HAS something to check, or that reaches one.
        // A method on every shape would be pure compile mass on the ones the
        // model states nothing about.
        if self.validating.contains(&msg.mojo_name) {
            self.emit_validate(msg)?;
            self.blank();
        }

        // -- the body codec: encoder, decoder, and the model convention ---
        codec.emit_encoder(self, msg, is_union)?;
        self.blank();
        codec.emit_decoder(self, msg)?;
        if self.options.emit_model_json {
            self.blank();
            codec.emit_model_value(self, msg)?;
        }

        self.pop();
        self.blank();
        self.blank();
        Ok(())
    }

    /// `validate()` — the model's own `min` / `max`, checked before the value
    /// can reach `to_aws_json`.
    fn emit_validate(&mut self, msg: &IrMessage) -> Result<(), String> {
        let ty = self.ty_name(&msg.mojo_name);
        self.line("def validate(self) raises:");
        self.push();
        self.line(&format!(
            "\"\"\"The model's `min` / `max` on `{}` — see §CONSTRAINTS.\"\"\"",
            msg.name
        ));
        let mut emitted = false;
        for f in &msg.fields {
            let wire = self.wire_name(msg, f);
            let required = self.required(msg, f);
            if let Some(c) = self.member_constraint(msg, f) {
                let access = if required {
                    format!("self.{}", f.name)
                } else {
                    self.optional_access(msg, f)
                };
                if !required {
                    self.line(&format!("if {}:", self.presence_test(msg, f)));
                    self.push();
                }
                let (quantity, noun) = match c.kind {
                    ConstraintKind::StringChars => {
                        (format!("{access}.byte_length()"), "length")
                    }
                    ConstraintKind::ElementCount => (format!("len({access})"), "size"),
                    ConstraintKind::NumericRange => (access.clone(), "value"),
                };
                if let Some(min) = c.min {
                    let lit = Self::bound_literal(min, c.kind);
                    self.line(&format!("if {quantity} < {lit}:"));
                    self.push();
                    self.raise_constraint(&ty, &wire, noun, "min", min, c.kind, &quantity);
                    self.pop();
                }
                if let Some(max) = c.max {
                    let lit = Self::bound_literal(max, c.kind);
                    self.line(&format!("if {quantity} > {lit}:"));
                    self.push();
                    self.raise_constraint(&ty, &wire, noun, "max", max, c.kind, &quantity);
                    self.pop();
                }
                if !required {
                    self.pop();
                }
                emitted = true;
            }
            // Forward into a member whose own shape has something to check.
            let inner: Vec<String> = self
                .field_message_types(f)
                .into_iter()
                .filter(|n| self.validating.contains(n))
                .collect();
            if inner.is_empty() {
                continue;
            }
            let base = if required {
                format!("self.{}", f.name)
            } else {
                self.optional_access(msg, f)
            };
            if !required {
                self.line(&format!("if {}:", self.presence_test(msg, f)));
                self.push();
            }
            match (&f.label, &f.ty) {
                (Label::Repeated, _) | (_, IrType::List(_)) => {
                    self.line(&format!("for _vi in range(len({base})):"));
                    self.push();
                    self.line(&format!("{base}[_vi].validate()"));
                    self.pop();
                }
                (_, IrType::Map(_, _)) => {
                    self.line(&format!("for _vk in {base}.keys():"));
                    self.push();
                    self.line(&format!("{base}[_vk].validate()"));
                    self.pop();
                }
                _ => self.line(&format!("{base}.validate()")),
            }
            if !required {
                self.pop();
            }
            emitted = true;
        }
        if !emitted {
            // `validating_set` put this shape in only because it REACHES a
            // constrained one, and every path turned out to be through a
            // container this emitter does not walk. Say so rather than emit a
            // method whose body is a bare `pass` that reads as "nothing to
            // check here".
            self.line("pass");
        }
        self.pop();
        Ok(())
    }

    /// The Mojo literal for a bound. botocore carries every bound as a JSON
    /// number; a length or count is compared against an `Int`, and a numeric
    /// range against the member's own arithmetic type.
    fn bound_literal(v: f64, kind: ConstraintKind) -> String {
        match kind {
            ConstraintKind::StringChars | ConstraintKind::ElementCount => {
                format!("{}", v as i64)
            }
            ConstraintKind::NumericRange => {
                if v.fract() == 0.0 {
                    format!("{}", v as i64)
                } else {
                    format!("{v}")
                }
            }
        }
    }

    fn raise_constraint(
        &mut self,
        ty: &str,
        wire: &str,
        noun: &str,
        bound: &str,
        v: f64,
        kind: ConstraintKind,
        quantity: &str,
    ) {
        let lit = Self::bound_literal(v, kind);
        self.line("raise Error(");
        self.push();
        self.line(&format!(
            "String(\"{ty}.{wire}: the model states {bound} {noun} {lit}, got \")"
        ));
        self.line(&format!("+ String({quantity})"));
        self.pop();
        self.line(")");
    }

    /// The declared field type, including the `Optional[...]` wrapper for a
    /// non-required member and the `List[...]` recursion box.
    fn storage_type(&self, msg: &IrMessage, f: &IrField) -> Result<String, String> {
        if self.is_boxed(msg, f) {
            return Ok(format!("List[{}]", self.bare_type(msg, f)?));
        }
        let inner = self.value_type(msg, f)?;
        if self.required(msg, f) {
            Ok(inner)
        } else {
            Ok(format!("Optional[{inner}]"))
        }
    }

    /// The type a caller passes to `__init__` / `set_<field>` — the container
    /// shape without the `Optional` wrapper and without the recursion box.
    fn value_type(&self, msg: &IrMessage, f: &IrField) -> Result<String, String> {
        match (&f.label, &f.ty) {
            (Label::Repeated, ty) => Ok(format!("List[{}]", self.elem_type(msg, f, ty)?)),
            (_, IrType::Map(_, v)) => {
                Ok(format!("Dict[String, {}]", self.elem_type(msg, f, v)?))
            }
            (_, ty) => self.elem_type(msg, f, ty),
        }
    }

    /// The type inside the recursion box.
    fn bare_type(&self, msg: &IrMessage, f: &IrField) -> Result<String, String> {
        self.value_type(msg, f)
    }

    fn elem_type(&self, msg: &IrMessage, f: &IrField, ty: &IrType) -> Result<String, String> {
        Ok(match ty {
            IrType::Message(t) => {
                let n = self
                    .by_fq
                    .get(&t.fq_name)
                    .cloned()
                    .unwrap_or_else(|| t.mojo_name.clone());
                self.ty_name(&n)
            }
            // AWS enums are OPEN and string-valued — see the module doc.
            IrType::Enum(_) => "String".to_string(),
            IrType::Map(_, v) => format!("Dict[String, {}]", self.elem_type(msg, f, v)?),
            IrType::List(e) => format!("List[{}]", self.elem_type(msg, f, e)?),
            IrType::Scalar(ScalarKind::String) => {
                if self.timestamp_format(msg, f).is_some() {
                    // A timestamp is EPOCH SECONDS, not its wire text. The same
                    // instant has three renderings in this corpus and a field
                    // typed as one of them could not be moved between them.
                    "Float64".to_string()
                } else {
                    "String".to_string()
                }
            }
            IrType::Scalar(s) => s.mojo_type().to_string(),
        })
    }

    fn default_expr(&self, msg: &IrMessage, f: &IrField) -> Result<String, String> {
        match (&f.label, &f.ty) {
            (Label::Repeated, ty) => Ok(format!("List[{}]()", self.elem_type(msg, f, ty)?)),
            (_, IrType::Map(_, v)) => {
                Ok(format!("Dict[String, {}]()", self.elem_type(msg, f, v)?))
            }
            (_, IrType::Message(_)) => Ok(format!("{}()", self.value_type(msg, f)?)),
            (_, IrType::Enum(_)) => Ok("String(\"\")".to_string()),
            (_, IrType::Scalar(s)) => Ok(match s {
                ScalarKind::String => {
                    if self.timestamp_format(msg, f).is_some() {
                        "Float64(0.0)".to_string()
                    } else {
                        "String(\"\")".to_string()
                    }
                }
                ScalarKind::Bytes => "List[UInt8]()".to_string(),
                ScalarKind::Bool => "False".to_string(),
                ScalarKind::Double => "Float64(0.0)".to_string(),
                ScalarKind::Float => "Float32(0.0)".to_string(),
                other => format!("{}(0)", other.mojo_type()),
            }),
            (_, IrType::List(_)) => Ok(format!("{}()", self.value_type(msg, f)?)),
        }
    }

    fn copy_expr(&self, msg: &IrMessage, f: &IrField, access: &str) -> String {
        match (&f.label, &f.ty) {
            (Label::Repeated, _)
            | (_, IrType::Map(_, _))
            | (_, IrType::List(_))
            | (_, IrType::Message(_)) => {
                format!("{access}.copy()")
            }
            (_, IrType::Scalar(ScalarKind::String)) => {
                if self.timestamp_format(msg, f).is_some() {
                    access.to_string()
                } else {
                    format!("{access}.copy()")
                }
            }
            (_, IrType::Scalar(ScalarKind::Bytes)) | (_, IrType::Enum(_)) => {
                format!("{access}.copy()")
            }
            _ => access.to_string(),
        }
    }

    // -- overlay lookups ---------------------------------------------------
    fn required(&self, msg: &IrMessage, f: &IrField) -> bool {
        self.facts
            .member(&msg.fq_name, &f.name)
            .map(|m| m.required)
            .unwrap_or(false)
    }

    fn wire_name(&self, msg: &IrMessage, f: &IrField) -> String {
        self.facts
            .member(&msg.fq_name, &f.name)
            .map(|m| m.wire_name.clone())
            .unwrap_or_else(|_| f.json_name.clone())
    }

    /// The member's name in the model (not its `locationName`).
    fn member_name(&self, msg: &IrMessage, f: &IrField) -> String {
        self.facts
            .member(&msg.fq_name, &f.name)
            .map(|m| m.member_name.clone())
            .unwrap_or_else(|_| f.json_name.clone())
    }


    /// The model-stated constraint on one member, or `None`.
    fn member_constraint(&self, msg: &IrMessage, f: &IrField) -> Option<MemberConstraint> {
        if self.is_boxed(msg, f) {
            return None;
        }
        let member = self.facts.member(&msg.fq_name, &f.name).ok()?;
        let shape = self.facts.shape(&member.shape).ok()?;
        if shape.min.is_none() && shape.max.is_none() {
            return None;
        }
        if !shape.enum_values.is_empty() {
            return None;
        }
        let kind = match shape.aws_type.as_str() {
            "string" => ConstraintKind::StringChars,
            "blob" | "list" | "map" => ConstraintKind::ElementCount,
            "integer" | "long" | "float" | "double" => ConstraintKind::NumericRange,
            // `structure` / `boolean` / `timestamp` carry no size the model
            // means, so a bound on one is not something to guess at.
            _ => return None,
        };
        let max = match kind {
            // See the block comment: unsound without a codepoint count.
            ConstraintKind::StringChars => None,
            _ => shape.max,
        };
        if shape.min.is_none() && max.is_none() {
            return None;
        }
        Some(MemberConstraint {
            min: shape.min,
            max,
            kind,
        })
    }

    fn validating_set(&self) -> BTreeSet<String> {
        let file = self.file();
        let mut set: BTreeSet<String> = BTreeSet::new();
        for m in &file.messages {
            if m.fields.iter().any(|f| self.member_constraint(m, f).is_some()) {
                set.insert(m.mojo_name.clone());
            }
        }
        loop {
            let mut grew = false;
            for m in &file.messages {
                if set.contains(&m.mojo_name) {
                    continue;
                }
                let reaches = m.fields.iter().any(|f| {
                    self.field_message_types(f)
                        .iter()
                        .any(|n| set.contains(n))
                });
                if reaches {
                    set.insert(m.mojo_name.clone());
                    grew = true;
                }
            }
            if !grew {
                return set;
            }
        }
    }

    /// Every message `mojo_name` reachable from one field's type, at any
    /// container depth — `List[Dict[String, T]]` yields `T`.
    fn field_message_types(&self, f: &IrField) -> Vec<String> {
        fn walk(e: &AwsEmitter, ty: &IrType, out: &mut Vec<String>) {
            match ty {
                IrType::Message(t) => {
                    if let Some(n) = e.by_fq.get(&t.fq_name) {
                        out.push(n.clone());
                    } else {
                        out.push(t.mojo_name.clone());
                    }
                }
                IrType::Map(_, v) => walk(e, v, out),
                IrType::List(x) => walk(e, x, out),
                _ => {}
            }
        }
        let mut out = Vec::new();
        walk(self, &f.ty, &mut out);
        out
    }

    fn timestamp_format(&self, msg: &IrMessage, f: &IrField) -> Option<AwsTimestampFormat> {
        self.facts
            .member(&msg.fq_name, &f.name)
            .ok()
            .and_then(|m| m.timestamp_format)
    }

    fn is_boxed(&self, msg: &IrMessage, f: &IrField) -> bool {
        self.boxed
            .contains(&(msg.mojo_name.clone(), f.name.clone()))
    }

    fn needs_no_nullary(&self, f: &IrField) -> bool {
        f.label != Label::Repeated && matches!(f.ty, IrType::Message(_))
    }

    /// The Mojo expression that is TRUE when a non-required member is present.
    ///
    /// `Optional` answers `if self.x:`; the recursion BOX answers
    /// `if len(self.x) > 0:`. One accessor, so the two storage shapes cannot
    /// drift apart across the four sites that ask (the union arity check,
    /// `to_aws_json`, `to_model_json`, and the box's own setter).
    fn presence_test(&self, msg: &IrMessage, f: &IrField) -> String {
        self.presence_test_on("self", msg, f)
    }

    /// [`Self::presence_test`] for a member of `base` rather than of `self`
    /// (a request builder's `input`).
    fn presence_test_on(&self, base: &str, msg: &IrMessage, f: &IrField) -> String {
        if self.is_boxed(msg, f) {
            format!("len({base}.{}) > 0", f.name)
        } else {
            format!("{base}.{}", f.name)
        }
    }

    /// The Mojo expression that READS a present non-required member.
    fn optional_access(&self, msg: &IrMessage, f: &IrField) -> String {
        self.optional_access_on("self", msg, f)
    }

    /// [`Self::optional_access`] for a member of `base`.
    fn optional_access_on(&self, base: &str, msg: &IrMessage, f: &IrField) -> String {
        if self.is_boxed(msg, f) {
            format!("{base}.{}[0]", f.name)
        } else {
            format!("{base}.{}.value()", f.name)
        }
    }

    /// The Mojo name of an operation's input message, before the type prefix.
    fn op_input_mojo(&self, m: &IrMethod) -> String {
        self.by_fq
            .get(&m.input.fq_name)
            .cloned()
            .unwrap_or_else(|| m.input.mojo_name.clone())
    }

    /// The Mojo type of an operation's input.
    fn op_input_type(&self, m: &IrMethod) -> String {
        self.ty_name(&self.op_input_mojo(m))
    }

    /// The Mojo type of an operation's output.
    fn op_output_type(&self, m: &IrMethod) -> String {
        self.ty_name(
            &self
                .by_fq
                .get(&m.output.fq_name)
                .cloned()
                .unwrap_or_else(|| m.output.mojo_name.clone()),
        )
    }

    /// The input's `validate()` call, first in a request builder, when the
    /// input shape has one.
    ///
    /// ⛔ THE CONSTRAINT CHECK IS ON THE PATH TO THE WIRE, NOT BESIDE IT. A
    /// `validate()` a caller must remember to call is a convention; the
    /// request builder is the only entry point that produces an
    /// `AwsRequest`, so a value that reaches AWS has been through it.
    fn emit_validate_call(&mut self, m: &IrMethod) {
        if self.validating.contains(&self.op_input_mojo(m)) {
            self.line("input.validate()");
        }
    }

    /// §4: per operation, the binding's request builder and response parser.
    fn emit_operations(&mut self) -> Result<(), String> {
        self.line(&format!("# {}", "=".repeat(75)));
        self.line("# §4 — request builders + response parsers. PURE: no connector, no");
        self.line("# credential, no clock, no network.");
        self.line("#");
        self.line("# ⚠ THE SPLIT IS WHAT MAKES THE PROTOCOL CONFORMANCE CORPUS RUNNABLE.");
        self.line("# `//tools/build/proto-codegen:aws_conformance_test` compares a BUILT request");
        self.line("# against botocore's own expected serialization; a client whose only");
        self.line("# entry point also signs and sends could only be tested against a live");
        self.line("# AWS account, which is not a gate anyone can run per-commit.");
        self.line(&format!("# {}", "=".repeat(75)));
        self.blank();

        let methods: Vec<IrMethod> = {
            let svc = self.lowering.model.files[0]
                .services
                .first()
                .ok_or_else(|| "emit_aws: the lowering carries no IrService".to_string())?;
            svc.methods.clone()
        };
        let binding = self.binding;
        if self.options.route53 {
            self.emit_route53_bare_id_helper();
        }
        for m in &methods {
            let facts = self.facts.operation_by_ir_method(&m.name)?.clone();
            binding.emit_request_builder(self, m, &facts)?;
            binding.emit_response_parser(self, m, &facts)?;
        }
        self.blank();
        Ok(())
    }

    /// The first half of a client send: the credential, and the headers
    /// split into the content type (the substrate's own argument) and the
    /// rest, the endpoint's own first when `ruleset`.
    fn emit_send_assembly(&mut self, ruleset: bool, signed: bool) {
        if signed {
            self.line("var cred = self._creds_source.credentials()");
        }
        self.line("var extra = List[Header]()");
        if ruleset {
            self.line("for _i in range(len(target.header_names)):");
            self.push();
            self.line("extra.append(Header(target.header_names[_i].copy(), target.header_values[_i].copy()))");
            self.pop();
        }
        self.line("var content_type = String(String(");
        self.push();
        let default_content_type = self.binding.default_content_type(self);
        self.line(&default_content_type);
        self.pop();
        self.line("))");
        self.line("for _i in range(len(req.header_names)):");
        self.push();
        self.line("var n = req.header_names[_i].copy()");
        self.line("if n.lower() == String(\"content-type\"):");
        self.push();
        self.line("# Header names are case-insensitive, and the substrate refuses an");
        self.line("# `extra` Content-Type in any case.");
        if signed {
            self.line("# The substrate takes the content type as its own argument and");
            self.line("# puts it in BOTH the signed set and the wire headers. Passing it");
            self.line("# again here would emit it twice and break the signature.");
        } else {
            self.line("# The substrate takes the content type as its own argument and");
            self.line("# puts it in the wire headers; passing it again would send it twice.");
        }
        self.line("content_type = req.header_values[_i].copy()");
        self.pop();
        self.line("else:");
        self.push();
        self.line("extra.append(Header(n^, req.header_values[_i].copy()))");
        self.pop();
        self.pop();
    }

    /// The request arguments every send passes on, after their transport
    /// arguments: method, credential and region (`signed` only), service,
    /// endpoint, target, content type, body and the other headers. The
    /// endpoint carries the request's `host_prefix` (an operation's
    /// `endpoint.hostPrefix`, labels substituted) ahead of its host, as
    /// botocore prepends it after resolving the endpoint; an empty prefix
    /// leaves the endpoint as resolved.
    fn emit_send_args(&mut self, ruleset: bool, p: &str, signed: bool) {
        self.line("req.method.copy(),");
        if signed {
            self.line("cred,");
        }
        if ruleset {
            if signed {
                self.line("target.signing_region.copy(),");
            }
            self.line("target.signing_name.copy(),");
            self.line("target.endpoint.with_host_prefix(req.host_prefix),");
        } else {
            if signed {
                self.line("self._region.copy(),");
            }
            self.line(&format!("String({p}_SERVICE),"));
            self.line(&format!(
                "resolve_endpoint(self._endpoint_override, {}_host(self._region.copy())).with_host_prefix(req.host_prefix),",
                self.module_name
            ));
        }
        self.line("req.uri.copy(),");
        self.line("content_type^,");
        self.line("req.body.copy(),");
        self.line("extra^,");
    }

    /// The input fields of `m` a client verb fills with a fresh token when
    /// the caller leaves them unset: its input's members the model marks
    /// `idempotencyToken`. botocore fills these, and only these top-level
    /// members, before the request is built (`generate_idempotent_uuid`,
    /// `if name not in params`), so every attempt of one call resends the
    /// same token and the service can tell a retry from a new request. A
    /// required member is taken by `__init__` and so always set by the
    /// caller; it is never filled. REFUSED, by name (`idempotency-token`):
    /// a token member that is not a string, which botocore would fill with
    /// a string the shape cannot hold.
    fn idempotency_fills(&self, m: &IrMethod) -> Result<Vec<String>, String> {
        let Some(msg) = self.messages.values().find(|x| x.fq_name == m.input.fq_name) else {
            return Ok(Vec::new());
        };
        let mut out = Vec::new();
        for f in &msg.fields {
            let mf = self.facts.member(&msg.fq_name, &f.name)?;
            if !mf.idempotency_token || mf.required {
                continue;
            }
            let ty = self.storage_type(msg, f)?;
            if ty != "Optional[String]" {
                return Err(format!(
                    "emit_aws: REFUSED idempotency-token: the input `{}` of `{}` marks \
                     `{}` as its idempotency token, and its type is `{ty}`; botocore fills \
                     an unset token with a UUID string",
                    msg.name, m.name, mf.member_name
                ));
            }
            out.push(f.name.clone());
        }
        Ok(out)
    }

    /// Whether any client verb fills an idempotency token, and so whether
    /// the module imports `aws_idempotency_token`. A pure-mode module has no
    /// verb.
    fn fills_idempotency_tokens(&self) -> Result<bool, String> {
        if self.options.pure_only {
            return Ok(false);
        }
        for m in &self.lowering.model.files[0].services[0].methods {
            if !self.idempotency_fills(m)?.is_empty() {
                return Ok(true);
            }
        }
        Ok(false)
    }

    /// Whether a client verb sends unsigned ([`auth::operation_auth`]),
    /// and so whether the client has `send_unsigned` and the module imports
    /// the core's unsigned send. A pure-mode module has no verb.
    fn sends_unsigned(&self) -> Result<bool, String> {
        if self.options.pure_only {
            return Ok(false);
        }
        for m in &self.lowering.model.files[0].services[0].methods {
            let facts = self.facts.operation_by_ir_method(&m.name)?;
            if auth::operation_auth(&self.meta.service, facts)? == OperationAuth::Anonymous {
                return Ok(true);
            }
        }
        Ok(false)
    }

    /// An operation's request, and with a ruleset the target it resolves
    /// to: `req` and `target`, as both of its verbs send them. A client
    /// verb builds and resolves from a copy of its input whose unset
    /// idempotency tokens are filled (`idempotency_fills`), once, before
    /// the retry loop, which resends the same bytes.
    fn emit_op_request(&mut self, m: &IrMethod, ruleset: bool, p: &str) -> Result<(), String> {
        let fp = self.fn_prefix();
        let fills = self.idempotency_fills(m)?;
        let input = if fills.is_empty() {
            "input"
        } else {
            // Filled once per call, before the request is built: the retry
            // loop resends the request's bytes, token and all.
            self.line("var filled = input.copy()");
            for f in &fills {
                self.line(&format!("if not filled.{f}:"));
                self.push();
                self.line(&format!("filled.{f} = Optional[String](aws_idempotency_token())"));
                self.pop();
            }
            "filled"
        };
        self.line(&format!("var req = {fp}build_{}_request({input})", m.name));
        if ruleset {
            self.line("var target = aws_signing_target(");
            self.push();
            self.line(&format!(
                "{fp}resolve_{}_endpoint(self._rules, self._endpoint_config, {input}),",
                m.name
            ));
            self.line("self._region.copy(),");
            self.line(&format!("String({p}_SERVICE),"));
            self.pop();
            self.line(")");
        }
        Ok(())
    }

    fn emit_client(&mut self) -> Result<(), String> {
        let methods = self.lowering.model.files[0].services[0].methods.clone();
        // The prefix alone names the service: it is the serviceId, which the
        // IR service name repeats, so `ty_name` of that name would carry it
        // twice.
        let cls = format!("{}Client", self.prefix);
        if self.structs.contains(&cls) {
            return Err(format!(
                "emit_aws: REFUSED client-name: the model has a shape named `Client`, \
                 emitted as `{cls}`, which is the client's own name"
            ));
        }
        self.parameterised.push(cls.clone());
        let p = self.prefix.to_uppercase();

        self.line(&format!("# {}", "=".repeat(75)));
        self.line(&format!("# §5 — {cls}."));
        self.line(&format!("# {}", "=".repeat(75)));
        self.line(&format!(
            "struct {cls}[C: Connector, T: AwsCredsSource](Movable, Deinitable):"
        ));
        self.push();
        self.line(&format!(
            "\"\"\"The generated {} client, parametric over the HTTP connector `C`",
            self.meta.service_full_name
        ));
        self.line("    and the credential source `T`.");
        self.blank();
        self.line("    The connector factory is a `def () raises thin -> C` function");
        self.line("    pointer (a code pointer, no heap); the credential source is moved");
        self.line("    in. No field is an `UnsafePointer`.");
        self.blank();
        self.line("    `http_config` is the caller's and has no default: the HTTP client is");
        self.line("    built inside `send_sigv4_signed_request`, so this argument is the only");
        self.line("    way to bound it. A process serving requests under a platform deadline");
        self.line("    passes `HttpClientConfig.for_serving_ceiling(ceiling_us)`, the ceiling");
        self.line("    in microseconds; a process with no containing deadline (a job, a CLI,");
        self.line("    a test) passes `HttpClientConfig.defaults()`.\"\"\"");
        self.blank();
        let ruleset = self.endpoint_rules.is_some();
        let cfg = format!("{}EndpointConfig", self.prefix);
        let mn = self.module_name.clone();
        self.line("var _mk_connector: def () raises thin -> Self.C");
        self.line("# Handed to `send_sigv4_signed_request` on every send, unchanged.");
        self.line("var _http_config: HttpClientConfig");
        self.line("var _creds_source: Self.T");
        self.line("var _region: String");
        self.line("# The retry quota this client's calls share (botocore's standard mode");
        self.line("# keeps one per client): every retry spends from it, and a call that");
        self.line("# succeeds refills it.");
        self.line("var _retry_quota: AwsRetryQuota");
        if ruleset {
            self.line("# WHERE this client sends: the service's endpoint ruleset, resolved per");
            self.line("# call over this configuration (`endpoint` for a local emulator,");
            self.line("# `force_path_style`, FIPS, dual-stack). A VALUE, never an ambient env");
            self.line("# var. The ruleset is loaded once, here.");
            self.line(&format!("var _endpoint_config: {cfg}"));
            self.line("var _rules: EndpointRuleSet");
        } else {
            self.line("# WHERE this client sends. `None` = real AWS (the host derived from");
            self.line("# the region). A VALUE, never an ambient env var — see");
            self.line(&format!(
                "# `{}.AwsEndpoint`. This is what makes every verb this",
                AWS_CORE
            ));
            self.line("# generator emits exercisable against a local emulator.");
            self.line("var _endpoint_override: Optional[AwsEndpoint]");
        }
        self.blank();
        self.line("def __init__(");
        self.push();
        self.line("out self,");
        self.line("mk_connector: def () raises thin -> Self.C,");
        self.line("http_config: HttpClientConfig,");
        self.line("var creds_source: Self.T,");
        self.line("region: String,");
        if ruleset {
            self.line(&format!("var endpoint_config: {cfg} = {cfg}(),"));
            self.pop();
            self.line(") raises:");
            self.push();
            self.line("\"\"\"`endpoint_config`'s region, when unset, is `region`.\"\"\"");
            self.line(&format!("var rules = {mn}_endpoint_rules()"));
        } else {
            self.line("endpoint_override: Optional[AwsEndpoint] = Optional[AwsEndpoint](),");
            self.pop();
            self.line("):");
            self.push();
        }
        self.line("self._mk_connector = mk_connector");
        self.line("self._http_config = http_config.copy()");
        self.line("self._creds_source = creds_source^");
        self.line("self._region = region");
        self.line("self._retry_quota = AwsRetryQuota()");
        if ruleset {
            self.line("if not endpoint_config.region and region.byte_length() > 0:");
            self.push();
            self.line("endpoint_config.region = Optional[String](region)");
            self.pop();
            self.line("self._endpoint_config = endpoint_config^");
            self.line("self._rules = rules^");
        } else {
            self.line("self._endpoint_override = endpoint_override.copy()");
        }
        self.pop();
        self.blank();
        self.line("def into_creds_source(deinit self) -> Self.T:");
        self.push();
        self.line("\"\"\"Consume the client, handing the moved-in credential source back");
        self.line("    out — so ONE Movable-but-not-Copyable source threads through");
        self.line("    several clients in a bootstrap.\"\"\"");
        self.line("return self._creds_source^");
        self.pop();
        self.blank();
        self.line("def region(self) -> String:");
        self.push();
        self.line("return self._region.copy()");
        self.pop();
        self.blank();

        // -- the send primitive ------------------------------------------
        let s3_flag = if self.options.s3 {
            ", s3_200_error: Bool = False"
        } else {
            ""
        };
        if ruleset {
            self.line(&format!(
                "def send(mut self, var req: AwsRequest, target: AwsSigningTarget{s3_flag}) raises -> HttpResult:"
            ));
        } else {
            self.line(&format!(
                "def send(mut self, var req: AwsRequest{s3_flag}) raises -> HttpResult:"
            ));
        }
        self.push();
        let mut doc: Vec<String> = vec![
            "\"\"\"Sign and send `req`. THE SIGNER IS NOT GENERATED — this is a call".to_string(),
            format!(
                "    into the hand-written `{}.send_sigv4_signed_request`, which is",
                AWS_CORE
            ),
            "    tested against the AWS SigV4 test vectors.".to_string(),
        ];
        let notes = self.binding.send_notes();
        if !notes.is_empty() {
            doc.push(String::new());
            doc.extend(notes.iter().map(|l| l.to_string()));
        }
        if ruleset {
            doc.push(String::new());
            doc.push("    `target` is where the endpoint ruleset sent this call and how it".to_string());
            doc.push("    is signed (`aws_signing_target`): its endpoint, signing name and".to_string());
            doc.push("    region, and the headers the endpoint adds.".to_string());
        }
        if self.options.s3 {
            doc.push(String::new());
            doc.push("    `s3_200_error`: S3 can answer this operation with a 200 whose".to_string());
            doc.push("    body is an `<Error>`, which the send then retries as a 500.".to_string());
        }
        if let Some(last) = doc.last_mut() {
            last.push_str("\"\"\"");
        }
        for l in &doc {
            self.line(l);
        }
        self.emit_send_assembly(ruleset, true);
        self.line("return send_sigv4_signed_request[Self.C](");
        self.push();
        self.line("self._mk_connector,");
        self.line("self._http_config.copy(),");
        self.line("self._retry_quota,");
        self.emit_send_args(ruleset, &p, true);
        if self.options.s3 {
            self.line("s3_200_error=s3_200_error,");
        }
        self.pop();
        self.line(")");
        self.pop();
        self.blank();

        // -- the send over injected seams ----------------------------------
        let seams = "X: AwsHttpTransport, K: AwsClock, L: MonotonicClock, S: Sleeper, R: RetryRng, B: RetryBudget";
        let seam_args = "mut transport: X, mut clock: K, mut retry: RetryLoop[L, S, R], mut budget: B";
        let target_arg = if ruleset { ", target: AwsSigningTarget" } else { "" };
        self.line(&format!(
            "def send_with[{seams}](mut self, var req: AwsRequest{target_arg}, {seam_args}{s3_flag}) raises -> HttpResult:"
        ));
        self.push();
        self.line("\"\"\"`send`, over the transport, signing clock, retry loop and budget");
        self.line(&format!(
            "    given (`{}.send_sigv4_signed_request_with`) instead of a",
            AWS_CORE
        ));
        self.line("    connector from this client's factory, the wall clock and the");
        self.line("    standard retry loop. It returns the response, successful or not.");
        self.blank();
        self.line("    The transport carries the HTTP config: `AwsConnectorTransport(");
        self.line("    http_config, connector)` is built from the caller's");
        self.line("    `HttpClientConfig`, as `send` builds its own from this client's. The");
        self.line("    budget is the retry quota: an `AwsRetryQuota` the caller keeps, one");
        self.line("    for all the calls it makes over this client, as botocore keeps one");
        self.line("    per client. `send` spends this client's own quota instead.");
        self.blank();
        self.line("    A request carrying `If-Match` or `If-None-Match` is resent only");
        self.line("    when the service cannot have acted on it (`aws_request_is_conditional`).\"\"\"");
        self.emit_send_assembly(ruleset, true);
        self.line("return send_sigv4_signed_request_with(");
        self.push();
        self.line("transport,");
        self.line("clock,");
        self.line("retry,");
        self.line("budget,");
        self.emit_send_args(ruleset, &p, true);
        if self.options.s3 {
            self.line("s3_200_error=s3_200_error,");
        }
        self.pop();
        self.line(")");
        self.pop();
        self.blank();

        let unsigned = self.sends_unsigned()?;
        if unsigned {
            self.emit_unsigned_sends(ruleset, &p, s3_flag);
        }

        // -- per-operation verbs ------------------------------------------
        for m in &methods {
            let facts = self.facts.operation_by_ir_method(&m.name)?.clone();
            let overridden = self.overrides.get(&facts.name);
            let verb = if overridden.is_some() {
                format!("{}_raw", m.name)
            } else {
                m.name.clone()
            };
            let in_ty = self.op_input_type(m);
            let out_ty = self.op_output_type(m);
            self.line(&format!(
                "def {verb}(mut self, input: {in_ty}) raises -> {out_ty}:"
            ));
            self.push();
            if let Some(ov) = overridden {
                self.line(&format!(
                    "\"\"\"`{}` — ⛔ THE RAW VERB. HAND-OVERRIDDEN.",
                    facts.name
                ));
                self.blank();
                self.line(&format!(
                    "    The plain name `{}` is NOT emitted on this client. It belongs",
                    m.name
                ));
                self.line(&format!(
                    "    to `{}.{}`, which is hand-written because:",
                    ov.hand_module, ov.hand_symbol
                ));
                self.blank();
                for l in wrap(&ov.reason, 66) {
                    self.line(&format!("    {l}"));
                }
                self.blank();
                self.line("    Call the owner, not this. This exists so the hand-written");
                self.line("    wrapper has a mechanical body to delegate to — it is the");
                self.line("    generated half of a split verb, not a way around the split.\"\"\"");
            } else {
                self.line(&format!(
                    "\"\"\"`{}` — {} {}\"\"\"",
                    facts.name,
                    facts.http_method.to_uppercase(),
                    facts.path
                ));
            }
            let fp = self.fn_prefix();
            let s3_200 = if self.s3_send_reads_200_error(m, &facts)? {
                ", s3_200_error=True"
            } else {
                ""
            };
            // The send this operation's auth names (`auth.rs`): an
            // anonymous operation is sent unsigned.
            let send = match auth::operation_auth(&self.meta.service, &facts)? {
                OperationAuth::SigV4 => "send",
                OperationAuth::Anonymous => "send_unsigned",
            };
            self.emit_op_request(m, ruleset, &p)?;
            if ruleset {
                self.line(&format!("var res = self.{send}(req^, target{s3_200})"));
            } else {
                self.line(&format!("var res = self.{send}(req^{s3_200})"));
            }
            self.line("if not aws_is_error_status(res.status):");
            self.push();
            self.line(&format!("return {fp}parse_{}_response(res^.into_response())", m.name));
            self.pop();
            self.line(&format!(
                "raise _{}_error(String(\"{}\"), res)",
                self.module_name,
                escape(&facts.name)
            ));
            self.pop();
            self.blank();

            // The same operation over injected seams, answering the raw
            // response: a caller that branches on the status (a 412, a 206)
            // or owns its clock and retry loop reads it with the parser.
            self.line(&format!(
                "def {verb}_with[{seams}](mut self, input: {in_ty}, {seam_args}) raises -> HttpResult:"
            ));
            self.push();
            self.line(&format!(
                "\"\"\"`{}` over the given seams (`{send}_with`): the response, successful",
                facts.name
            ));
            self.line(&format!(
                "    or not. `{fp}parse_{}_response` reads a successful one.\"\"\"",
                m.name
            ));
            self.emit_op_request(m, ruleset, &p)?;
            let tgt = if ruleset { "target, " } else { "" };
            // The unsigned send reads no clock: nothing is signed.
            let seam_vals = if send == "send" {
                "transport, clock, retry, budget"
            } else {
                "transport, retry, budget"
            };
            self.line(&format!(
                "return self.{send}_with(req^, {tgt}{seam_vals}{s3_200})"
            ));
            self.pop();
            self.blank();
        }
        self.pop();
        self.blank();

        // -- the error builder --------------------------------------------
        self.line(&format!(
            "def _{}_error(op: String, res: HttpResult) -> Error:",
            self.module_name
        ));
        self.push();
        self.line("\"\"\"A non-2xx as an `Error`.");
        self.blank();
        self.line("    ⛔ IT NEVER ECHOES THE RESPONSE BODY. Only the HTTP status plus the");
        self.line(&format!(
            "    {} and message ride out. A generated client",
            self.binding.error_code_doc()
        ));
        self.line("    cannot know which of its shapes carry a secret, so the discipline is");
        self.line("    unconditional — the `secrets_manager_client._sm_error` rule, applied");
        self.line("    everywhere because the generator has no way to make the exception.\"\"\"");
        if let Some(binding) = self.binding.error_info_binding() {
            self.line(binding);
        }
        let (code_expr, msg_expr) = self.binding.error_code_and_message();
        self.line(&format!("var code = {code_expr}"));
        self.line(&format!("var msg = {msg_expr}"));
        self.line("return Error(");
        self.push();
        self.line(&format!("String(\"{}.\")", self.prefix));
        self.line("+ op");
        self.line("+ String(\" failed: HTTP \")");
        self.line("+ String(res.status)");
        self.line("+ String(\" \")");
        self.line("+ code");
        self.line("+ String(\" \")");
        self.line("+ msg");
        self.pop();
        self.line(")");
        self.pop();
        self.blank();
        Ok(())
    }
}

/// The import block + shared helper every generated PURE module of
/// `protocols` needs. The conformance driver emits this ONCE ahead of its
/// concatenated suites.
pub fn pure_preamble(protocols: &[AwsProtocol], with_model_json: bool) -> String {
    let mut em = aws_import_section_with(protocols, true, false, with_model_json, false);
    em.push_str("\n\n");
    if with_model_json {
        em.push_str("def _aws_bytes_to_string(b: List[UInt8]) -> String:\n");
        em.push_str("    \"\"\"Decoded blob bytes as text — the MODEL convention for a blob.\"\"\"\n");
        em.push_str("    var out = String(\"\")\n");
        em.push_str("    for _i in range(len(b)):\n");
        em.push_str("        out += chr(Int(b[_i]))\n");
        em.push_str("    return out^\n\n\n");
    }
    em
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn ts_const(f: AwsTimestampFormat) -> &'static str {
    match f {
        AwsTimestampFormat::UnixTimestamp => "AWS_TS_UNIX",
        AwsTimestampFormat::Iso8601 => "AWS_TS_ISO8601",
        AwsTimestampFormat::Rfc822 => "AWS_TS_RFC822",
    }
}

/// The type-name prefix for a service — its `serviceId` with non-alphanumerics
/// stripped and lowercased-but-for-the-initial. Two generated services can then
/// be imported into one module without a collision.
fn service_type_prefix(meta: &AwsServiceMeta) -> String {
    let id: String = meta
        .service_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect();
    if id.is_empty() {
        let s: String = meta
            .service
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .collect();
        return capitalize(&s);
    }
    capitalize(&id)
}

fn capitalize(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_ascii_uppercase().to_string() + c.as_str(),
        None => String::new(),
    }
}

fn to_screaming(s: &str) -> String {
    let mut out = String::new();
    let mut prev_lower = false;
    for ch in s.chars() {
        if ch.is_ascii_uppercase() && prev_lower {
            out.push('_');
        }
        if ch == '-' || ch == '.' || ch == ' ' || ch == ':' {
            out.push('_');
            prev_lower = false;
            continue;
        }
        out.push(ch.to_ascii_uppercase());
        prev_lower = ch.is_ascii_lowercase() || ch.is_ascii_digit();
    }
    out
}

fn escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

fn wrap(s: &str, width: usize) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    for w in s.split_whitespace() {
        if !cur.is_empty() && cur.len() + 1 + w.len() > width {
            out.push(std::mem::take(&mut cur));
        }
        if !cur.is_empty() {
            cur.push(' ');
        }
        cur.push_str(w);
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    if out.is_empty() {
        out.push(String::new());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The rows of [`AWS_IMPORTS`] that apply to `protocol`.
    fn rows_for(protocol: AwsProtocol) -> Vec<&'static AwsImport> {
        AWS_IMPORTS
            .iter()
            .filter(|row| row.protocols.contains(&protocol))
            .collect()
    }

    #[test]
    fn json_runtime_is_komira_json_in_every_mode() {
        for p in JSON_BODY_PROTOCOLS {
            let rows: Vec<&AwsImport> = rows_for(*p)
                .into_iter()
                .filter(|row| row.names.contains(&"JsonValue"))
                .collect();
            assert_eq!(rows.len(), 1, "{p:?}: exactly one row imports JsonValue");
            let row = rows[0];
            assert_eq!(row.module, "komira_json");
            assert_eq!(row.names, &["JsonValue", "parse_json_bytes", "parse_json_value"]);
            assert_eq!(row.mode, AwsImportMode::Always);
            for pure_only in [true, false] {
                assert!(
                    aws_import_section(*p, pure_only).contains("from komira_json import ("),
                    "{p:?} pure_only={pure_only}"
                );
            }
        }
    }

    #[test]
    fn no_other_protocol_imports_the_json_runtime() {
        // Only the MODEL-convention rows, which a client module never takes.
        for p in ALL_PROTOCOLS.iter().filter(|p| !JSON_BODY_PROTOCOLS.contains(p)) {
            for row in rows_for(*p)
                .into_iter()
                .filter(|row| row.mode != AwsImportMode::ModelJson)
            {
                assert_ne!(row.module, "komira_json", "{p:?}");
                assert!(
                    !row.names.iter().any(|n| n.contains("json")),
                    "{p:?} imports a JSON codec name from {}: {:?}",
                    row.module,
                    row.names
                );
            }
            for pure_only in [true, false] {
                assert!(!aws_import_section(*p, pure_only).contains("komira_json"), "{p:?}");
            }
        }
    }

    #[test]
    fn rest_xml_takes_the_xml_runtime_and_json_only_for_the_model_convention() {
        let p = AwsProtocol::RestXml;
        for pure_only in [true, false] {
            let s = aws_import_section(p, pure_only);
            assert!(s.contains("from komira_xml import (\n    XmlNode,\n    XmlWriter,\n)"), "{s}");
            assert!(s.contains("    aws_xml_write_string,"), "{s}");
            assert!(!s.contains("komira_json"), "{s}");
            let m = aws_import_section_with(&[p], pure_only, false, true, false);
            assert!(m.contains("from komira_json import JsonValue"), "{m}");
            assert!(m.contains("    aws_json_f64,"), "{m}");
        }
        // A client reads restXml errors; a pure module only with the `s3`
        // customization, whose 200-with-<Error> check raises one. Only that
        // customization takes the check itself.
        let plain_pure = aws_import_section(p, true);
        assert!(!plain_pure.contains("aws_rest_xml_error"), "{plain_pure}");
        assert!(!plain_pure.contains("aws_xml_body_is_error"), "{plain_pure}");
        let plain_client = aws_import_section(p, false);
        assert!(plain_client.contains("    aws_rest_xml_error,"), "{plain_client}");
        assert!(!plain_client.contains("aws_xml_body_is_error"), "{plain_client}");
        for pure_only in [true, false] {
            let s3 = aws_import_section_with(&[p], pure_only, false, false, true);
            assert!(s3.contains("    aws_rest_xml_error,\n    aws_xml_body_is_error,\n"), "{s3}");
        }
        // The model rows add nothing a JSON-body module does not already
        // import: the section is the same text with and without them.
        for p in JSON_BODY_PROTOCOLS {
            assert_eq!(
                aws_import_section_with(&[*p], true, false, true, false),
                aws_import_section(*p, true)
            );
        }
    }

    #[test]
    fn a_name_two_rows_hold_is_imported_once() {
        let s = aws_import_section_with(
            &[AwsProtocol::Json, AwsProtocol::RestXml],
            true,
            false,
            true,
            false,
        );
        assert_eq!(s.matches("    JsonValue,").count(), 1, "{s}");
        assert_eq!(s.matches("    aws_json_f64,").count(), 1, "{s}");
    }

    #[test]
    fn every_row_names_a_protocol_and_no_name_twice() {
        for row in AWS_IMPORTS {
            assert!(!row.protocols.is_empty(), "{}: {:?}", row.module, row.names);
            assert!(!row.names.is_empty(), "{}: a row with no names", row.module);
        }
        for p in ALL_PROTOCOLS {
            let mut seen: BTreeSet<(&str, &str)> = BTreeSet::new();
            for row in rows_for(*p) {
                for n in row.names {
                    assert!(seen.insert((row.module, n)), "{p:?}: `{n}` is imported twice");
                }
            }
        }
    }

    /// The client-mode module of a one-operation awsJson model whose input
    /// and output each hold `Stamps`, a list of timestamps.
    fn json_module_with_a_list_of_timestamps() -> String {
        let model = crate::json::parse(
            r#"{"version": "2.0",
                "metadata": {"apiVersion": "2026-10-02", "endpointPrefix": "tiny",
                    "jsonVersion": "1.1", "protocol": "json", "serviceFullName": "Tiny",
                    "serviceId": "Tiny", "signatureVersion": "v4",
                    "targetPrefix": "Tiny", "uid": "tiny-2026-10-02"},
                "operations": {"Op": {"name": "Op",
                    "http": {"method": "POST", "requestUri": "/"},
                    "input": {"shape": "In"}, "output": {"shape": "Out"}}},
                "shapes": {"In": {"type": "structure",
                                  "members": {"Stamps": {"shape": "Stamps"}}},
                           "Out": {"type": "structure",
                                   "members": {"Stamps": {"shape": "Stamps"}}},
                           "Stamps": {"type": "list", "member": {"shape": "Stamp"}},
                           "Stamp": {"type": "timestamp"}}}"#,
        )
        .unwrap();
        let lowering = crate::aws_in::lower_aws_service(
            &model,
            "tiny",
            &["Op".to_string()],
            "tiny.json",
            "aws.tiny",
        )
        .unwrap();
        let options = AwsEmitOptions {
            omit_preamble: true,
            ..AwsEmitOptions::default()
        };
        emit_aws_module(&lowering, &AwsOverrides::empty(), "tiny", options, None)
            .unwrap()
            .source
    }

    #[test]
    fn an_aws_json_list_of_timestamps_is_epoch_seconds_on_the_wire() {
        // awsJson's timestamps are epoch-seconds numbers, so the elements are
        // held as Float64 and written and read by the timestamp codec, not as
        // JSON strings.
        let src = json_module_with_a_list_of_timestamps();
        assert!(src.contains("List[Float64]"), "{src}");
        assert!(!src.contains("List[String]"), "{src}");
        assert!(src.contains("aws_ts_to_json("), "{src}");
        assert!(src.contains("aws_ts_from_json("), "{src}");
    }

    #[test]
    fn a_module_without_a_header_has_no_last_line() {
        // The last line (`# End of <module>, generated by aws-client-gen.`)
        // is written only with the header: a single-file module
        // (omit_preamble) leaves it out.
        let src = json_module_with_a_list_of_timestamps();
        assert!(!src.contains("# End of "), "{src}");
    }

    #[test]
    fn the_service_prefix_names_the_client_and_its_errors_once() {
        // The type prefix is the serviceId, and so is the IR service name:
        // the client is `<prefix>Client` and a failed call is raised as
        // `<prefix>.<Op> failed`, never with the prefix twice.
        let src = json_module_with_a_list_of_timestamps();
        assert!(
            src.contains("\nstruct TinyClient[C: Connector, T: AwsCredsSource](Movable, Deinitable):\n"),
            "{src}"
        );
        assert!(src.contains("        String(\"Tiny.\")\n        + op\n"), "{src}");
        assert!(!src.contains("TinyTiny"), "{src}");
    }

    #[test]
    fn a_shape_named_client_is_refused_in_client_mode() {
        // With the prefix applied once, a shape named `Client` would be
        // emitted under the client's own name.
        let model = crate::json::parse(
            r#"{"version": "2.0",
                "metadata": {"apiVersion": "2026-10-02", "endpointPrefix": "tiny",
                    "jsonVersion": "1.1", "protocol": "json", "serviceFullName": "Tiny",
                    "serviceId": "Tiny", "signatureVersion": "v4",
                    "targetPrefix": "Tiny", "uid": "tiny-2026-10-02"},
                "operations": {"Op": {"name": "Op",
                    "http": {"method": "POST", "requestUri": "/"},
                    "input": {"shape": "In"}}},
                "shapes": {"In": {"type": "structure",
                                  "members": {"C": {"shape": "Client"}}},
                           "Client": {"type": "structure",
                                      "members": {"Id": {"shape": "Str"}}},
                           "Str": {"type": "string"}}}"#,
        )
        .unwrap();
        let lowering = crate::aws_in::lower_aws_service(
            &model,
            "tiny",
            &["Op".to_string()],
            "tiny.json",
            "aws.tiny",
        )
        .unwrap();
        let emit = |pure_only| {
            let options = AwsEmitOptions {
                omit_preamble: true,
                pure_only,
                ..AwsEmitOptions::default()
            };
            emit_aws_module(&lowering, &AwsOverrides::empty(), "tiny", options, None)
        };
        let e = emit(false).err().expect("refused");
        assert!(e.contains("REFUSED client-name"), "{e}");
        assert!(e.contains("`TinyClient`"), "{e}");
        // A pure module has no client, and so no collision.
        assert!(emit(true).is_ok());
    }

    #[test]
    fn send_finds_the_content_type_header_in_any_case() {
        let src = json_module_with_a_list_of_timestamps();
        assert!(src.contains("if n.lower() == String(\"content-type\"):"), "{src}");
        assert!(!src.contains("if n == String(\"Content-Type\"):"), "{src}");
    }

    #[test]
    fn an_aws_json_client_reads_its_error_code_through_the_error_info() {
        // The client's error builder takes the code aws_json_error_info
        // reads: an awsQueryCompatible service's x-amzn-query-error code
        // first, so an SQS QueueDoesNotExist is raised under its query code.
        let src = json_module_with_a_list_of_timestamps();
        let builder = &src[src.find("def _tiny_error(").unwrap()..];
        for want in [
            "    var info = aws_json_error_info(res.to_response())\n",
            "    var code = info.code.copy()\n",
            "    var msg = info.message.copy()\n",
        ] {
            assert!(builder.contains(want), "`{want}` missing");
        }
        assert!(!builder.contains("aws_error_code_from_body(res.body)"));
        let imports = aws_import_section(AwsProtocol::Json, false);
        assert!(imports.contains("    aws_json_error_info,\n"), "{imports}");
        assert!(!aws_import_section(AwsProtocol::Json, true).contains("aws_json_error_info"));
        assert!(!aws_import_section(AwsProtocol::RestJson, false).contains("aws_json_error_info"));
        // Grouped with the other error readers, ahead of the transport's
        // types.
        assert!(
            imports.find("aws_json_error_info").unwrap() < imports.find("AwsCredential").unwrap(),
            "{imports}"
        );
        // A client's error builder reads through its protocol's error info,
        // so a client module does not import the body readers; a pure
        // module keeps them for a caller with its own transport.
        for p in JSON_BODY_PROTOCOLS {
            assert!(!aws_import_section(*p, false).contains("aws_error_code_from_body"), "{p:?}");
            assert!(aws_import_section(*p, true).contains("aws_error_code_from_body"), "{p:?}");
        }
        // The builder's doc line stays inside the block's wrap.
        let doc = builder.lines().find(|l| l.contains("ride out")).unwrap();
        assert!(doc.len() <= 80, "{doc}");
    }

    #[test]
    fn every_protocol_gets_the_transport_in_client_mode_only() {
        for p in ALL_PROTOCOLS {
            assert!(!aws_import_section(*p, true).contains("Connector"), "{p:?}");
            assert!(aws_import_section(*p, false).contains("Connector"), "{p:?}");
            assert!(aws_import_section(*p, true).contains("    AwsRequest,"), "{p:?}");
        }
    }

    /// A one-operation model whose operation carries `checksum` (its
    /// httpChecksum traits), emitted with or without the `s3`
    /// customization. `protocol` is `rest-xml` (serviceId S3, so the
    /// customization applies) or `json`.
    fn emit_checksum_op(protocol: &str, checksum: &str, s3: bool) -> Result<String, String> {
        let (service_id, extra_meta, method) = match protocol {
            "json" => ("Tiny", r#", "jsonVersion": "1.0", "targetPrefix": "Tiny""#, "POST"),
            _ => ("S3", "", "PUT"),
        };
        let model = crate::json::parse(&format!(
            r#"{{"version": "2.0",
                "metadata": {{"apiVersion": "2026-10-02", "endpointPrefix": "s3",
                    "protocol": "{protocol}", "serviceFullName": "Tiny",
                    "serviceId": "{service_id}", "signatureVersion": "v4",
                    "uid": "tiny-2026-10-02"{extra_meta}}},
                "operations": {{"Op": {{"name": "Op",
                    "http": {{"method": "{method}", "requestUri": "/op"}},
                    "input": {{"shape": "In"}}{checksum}}}}},
                "shapes": {{"In": {{"type": "structure", "members": {{
                    "ChecksumAlgorithm": {{"shape": "Str", "location": "header",
                        "locationName": "x-amz-sdk-checksum-algorithm"}},
                    "A": {{"shape": "Str"}}}}}},
                    "Str": {{"type": "string"}}}}}}"#
        ))
        .map_err(|e| e.to_string())?;
        let lowering = crate::aws_in::lower_aws_service(
            &model,
            "s3",
            &["Op".to_string()],
            "s3.json",
            "aws.s3",
        )?;
        let options = AwsEmitOptions {
            pure_only: true,
            omit_preamble: true,
            s3,
            ..AwsEmitOptions::default()
        };
        emit_aws_client(&lowering, &AwsOverrides::empty(), "s3", options).map(|(_, s)| s)
    }

    #[test]
    fn a_client_keeps_one_retry_quota_and_spends_it_on_every_send() {
        // botocore's standard mode keeps one retry quota per client; the
        // generated client holds it and hands it to every send.
        let src = json_module_with_a_list_of_timestamps();
        assert!(src.contains("    var _retry_quota: AwsRetryQuota\n"), "{src}");
        assert!(src.contains("        self._retry_quota = AwsRetryQuota()\n"), "{src}");
        assert!(
            src.contains(
                "        return send_sigv4_signed_request[Self.C](\n            \
                 self._mk_connector,\n            self._http_config.copy(),\n            \
                 self._retry_quota,\n"
            ),
            "{src}"
        );
        assert_eq!(src.matches("self._retry_quota").count(), 2, "{src}");
        for p in ALL_PROTOCOLS {
            assert!(aws_import_section(*p, false).contains("    AwsRetryQuota,\n"), "{p:?}");
            assert!(!aws_import_section(*p, true).contains("AwsRetryQuota"), "{p:?}");
        }
    }

    /// The module of a one-operation awsJson model whose operation can
    /// return `Busy`, an error shape with the given `retryable` trait (or
    /// none, for "").
    fn emit_with_error(retryable: &str, pure_only: bool) -> Result<String, String> {
        let model = crate::json::parse(&format!(
            r#"{{"version": "2.0",
                "metadata": {{"apiVersion": "2026-10-02", "endpointPrefix": "tiny",
                    "jsonVersion": "1.1", "protocol": "json", "serviceFullName": "Tiny",
                    "serviceId": "Tiny", "signatureVersion": "v4",
                    "targetPrefix": "Tiny", "uid": "tiny-2026-10-02"}},
                "operations": {{"Op": {{"name": "Op",
                    "http": {{"method": "POST", "requestUri": "/"}},
                    "input": {{"shape": "In"}}, "output": {{"shape": "Out"}},
                    "errors": [{{"shape": "Busy"}}]}}}},
                "shapes": {{"In": {{"type": "structure", "members": {{}}}},
                           "Out": {{"type": "structure", "members": {{}}}},
                           "Busy": {{"type": "structure", "members": {{}},
                                    "exception": true{retryable}}}}}}}"#
        ))
        .unwrap();
        let lowering = crate::aws_in::lower_aws_service(
            &model,
            "tiny",
            &["Op".to_string()],
            "tiny.json",
            "aws.tiny",
        )
        .unwrap();
        let options = AwsEmitOptions {
            omit_preamble: true,
            pure_only,
            ..AwsEmitOptions::default()
        };
        emit_aws_module(&lowering, &AwsOverrides::empty(), "tiny", options, None).map(|e| e.source)
    }

    #[test]
    fn a_modeled_retryable_error_is_refused_in_client_mode() {
        // botocore retries an error the model marks retryable, and the
        // generated send does not read the model: a client of such an
        // operation would give up where botocore retries.
        for retryable in [
            r#", "retryable": {"throttling": false}"#,
            r#", "retryable": {"throttling": true}"#,
        ] {
            let e = emit_with_error(retryable, false).unwrap_err();
            assert_eq!(
                crate::aws_conformance::refusal_name(&e).as_deref(),
                Some("modeled-retryable"),
                "{e}"
            );
            assert!(e.contains("operation `Op` can return `Busy`"), "{e}");
            // A pure-mode module has no send.
            emit_with_error(retryable, true).unwrap();
        }
        emit_with_error("", false).unwrap();
    }

    /// A one-operation awsJson module whose input `In` holds `Token`, with
    /// the given member text and `required` list, emitted with its preamble
    /// (so its imports) in client or pure mode.
    fn emit_with_token(member: &str, required: &str, pure_only: bool) -> Result<String, String> {
        let model = crate::json::parse(&format!(
            r#"{{"version": "2.0",
                "metadata": {{"apiVersion": "2026-10-02", "endpointPrefix": "tiny",
                    "jsonVersion": "1.1", "protocol": "json", "serviceFullName": "Tiny",
                    "serviceId": "Tiny", "signatureVersion": "v4",
                    "targetPrefix": "Tiny", "uid": "tiny-2026-10-02"}},
                "operations": {{"Op": {{"name": "Op",
                    "http": {{"method": "POST", "requestUri": "/"}},
                    "input": {{"shape": "In"}}, "output": {{"shape": "Out"}}}}}},
                "shapes": {{"In": {{"type": "structure", "required": [{required}],
                                   "members": {{"Token": {member},
                                               "Name": {{"shape": "S"}}}}}},
                           "Out": {{"type": "structure", "members": {{}}}},
                           "S": {{"type": "string"}},
                           "N": {{"type": "integer"}}}}}}"#
        ))
        .unwrap();
        let lowering = crate::aws_in::lower_aws_service(
            &model,
            "tiny",
            &["Op".to_string()],
            "tiny.json",
            "aws.tiny",
        )
        .unwrap();
        let options = AwsEmitOptions { pure_only, ..AwsEmitOptions::default() };
        let prov = AwsProvenance { model_key: "tiny/2026-10-02", model_sha256: "m" };
        emit_aws_module(&lowering, &AwsOverrides::empty(), "tiny", options, Some(prov))
            .map(|e| e.source)
    }

    #[test]
    fn an_unset_idempotency_token_is_filled_once_per_call() {
        let token = r#"{"shape": "S", "idempotencyToken": true}"#;
        let src = emit_with_token(token, "", false).unwrap();
        let import = "from komira_aws_core import aws_idempotency_token\n";
        assert_eq!(src.matches(import).count(), 1, "{src}");
        // Both verbs fill it before building the request, and build from
        // the filled copy.
        let fill = "        var filled = input.copy()\n        if not filled.token:\n            \
                    filled.token = Optional[String](aws_idempotency_token())\n        \
                    var req = build_op_request(filled)\n";
        assert_eq!(src.matches(fill).count(), 2, "{src}");
        assert!(!src.contains("build_op_request(input)"), "{src}");
        // One draw in each verb, and nowhere else.
        assert_eq!(src.matches("aws_idempotency_token()").count(), 2, "{src}");
        // Only the token member is filled.
        assert!(!src.contains("filled.name"), "{src}");

        // A pure-mode module has no verb, and so no fill.
        let src = emit_with_token(token, "", true).unwrap();
        assert!(!src.contains("aws_idempotency_token"), "{src}");
        assert!(!src.contains("filled"), "{src}");
        // A required token is the caller's: `__init__` takes it.
        let src = emit_with_token(token, r#""Token""#, false).unwrap();
        assert!(!src.contains("aws_idempotency_token"), "{src}");
        assert!(!src.contains("filled"), "{src}");
        // No token, no fill and no import.
        let src = emit_with_token(r#"{"shape": "S"}"#, "", false).unwrap();
        assert!(!src.contains("aws_idempotency_token"), "{src}");
        assert!(!src.contains("filled"), "{src}");
        assert!(src.contains("var req = build_op_request(input)\n"), "{src}");
    }

    #[test]
    fn a_token_that_is_not_a_string_is_refused() {
        let e = emit_with_token(r#"{"shape": "N", "idempotencyToken": true}"#, "", false)
            .unwrap_err();
        assert_eq!(
            crate::aws_conformance::refusal_name(&e).as_deref(),
            Some("idempotency-token"),
            "{e}"
        );
        assert!(e.contains("`Token`"), "{e}");
        // The refusal is the fill's: a pure module, which has no verb to
        // fill it, sends the member as given and is not refused.
        let src = emit_with_token(r#"{"shape": "N", "idempotencyToken": true}"#, "", true)
            .unwrap();
        assert!(!src.contains("aws_idempotency_token"), "{src}");
    }

    #[test]
    fn a_required_checksum_is_refused_where_the_client_sends_none() {
        let refusal = |protocol: &str, checksum: &str, s3: bool| {
            let e = emit_checksum_op(protocol, checksum, s3).unwrap_err();
            crate::aws_conformance::refusal_name(&e)
        };
        let required = r#", "httpChecksumRequired": true"#;
        let with_member = r#", "httpChecksum": {"requestAlgorithmMember": "ChecksumAlgorithm",
            "requestChecksumRequired": true}"#;
        let no_member = r#", "httpChecksum": {"requestChecksumRequired": true}"#;
        // Without the customization nothing computes one, in any protocol.
        for (protocol, checksum) in [
            ("rest-xml", with_member),
            ("rest-xml", required),
            ("json", with_member),
            ("json", required),
        ] {
            assert_eq!(
                refusal(protocol, checksum, false).as_deref(),
                Some("checksum-required"),
                "{protocol} {checksum}"
            );
        }
        // With it, only where the model names the algorithm member: the
        // older trait names none.
        for checksum in [required, no_member] {
            assert_eq!(
                refusal("rest-xml", checksum, true).as_deref(),
                Some("checksum-required"),
                "{checksum}"
            );
        }
        let src = emit_checksum_op("rest-xml", with_member, true).unwrap();
        assert_eq!(src.matches("s3_apply_request_checksum(").count(), 1, "{src}");
        // An optional checksum is never refused. Without the customization
        // none is sent; with it, only where the model names the algorithm
        // member.
        let optional = r#", "httpChecksum": {"requestAlgorithmMember": "ChecksumAlgorithm"}"#;
        for checksum in [r#", "httpChecksumRequired": false"#, optional] {
            let src = emit_checksum_op("rest-xml", checksum, false).unwrap();
            assert!(!src.contains("s3_apply_request_checksum"), "{src}");
        }
        for checksum in [
            "",
            r#", "httpChecksumRequired": false"#,
            r#", "httpChecksum": {"requestChecksumRequired": false}"#,
        ] {
            let src = emit_checksum_op("rest-xml", checksum, true).unwrap();
            assert!(!src.contains("s3_apply_request_checksum"), "{checksum}: {src}");
        }
        let src = emit_checksum_op("rest-xml", optional, true).unwrap();
        assert_eq!(src.matches("s3_apply_request_checksum(").count(), 1, "{src}");
    }
}
