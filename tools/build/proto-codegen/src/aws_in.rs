//! The AWS front-end: a botocore `service-2.json` model plus a list of
//! operations, lowered to an `IrModel` and an overlay of the AWS facts the IR
//! cannot carry (HTTP bindings, timestamp formats, XML names, ...).

use std::collections::{BTreeMap, BTreeSet};

use crate::ir::*;
use crate::json::{Json, JsonObject};
use crate::mojo_names::{escape_member, flatten, CollisionResolver};

// ===========================================================================
// The result
// ===========================================================================

/// The result of lowering one AWS service's named operations.
///
/// `model` is a plain [`IrModel`] any IR consumer can read. `service` and
/// `facts` carry everything AWS-specific; an emitter that ignores them
/// emits a client that cannot talk to AWS, which is why they are returned
/// together and why [`check_totality`](Self::check_totality) exists.
#[derive(Clone, Debug, PartialEq)]
pub struct AwsLowering {
    pub model: IrModel,
    pub service: AwsServiceMeta,
    pub facts: AwsFacts,
    /// Non-fatal notes — representational choices a reader should see
    /// (e.g. a `timestamp` carried as a string plus a recorded format).
    pub notes: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct AwsServiceMeta {
    pub service: String,
    pub api_version: String,
    /// The protocol the client is generated for: the first entry of
    /// `protocols` the generator implements
    /// ([`crate::emit_aws::SUPPORTED_PROTOCOLS`]), else (no entry is
    /// implemented, or the model lists none) `metadata.protocol`, which the
    /// emitter then refuses unless it implements it. One of `json` /
    /// `rest-json` / `rest-xml` / `query` / `ec2` / `smithy-rpc-v2-cbor`.
    pub protocol: String,
    /// `metadata.protocol` as the model declares it.
    pub declared_protocol: String,
    /// `metadata.protocols` — the multi-protocol list newer models carry, in
    /// the model's order.
    pub protocols: Vec<String>,
    /// `metadata.jsonVersion` (`"1.0"` / `"1.1"`), for the awsJson family.
    pub json_version: Option<String>,
    /// `metadata.targetPrefix` — the `X-Amz-Target` prefix for awsJson.
    pub target_prefix: Option<String>,
    pub endpoint_prefix: String,
    /// `metadata.signingName`, defaulted to `endpoint_prefix` when absent
    /// (botocore's rule). ⚠ They differ in the vendored corpus: `ecr` has
    /// `endpointPrefix = api.ecr` and `signingName = ecr`.
    pub signing_name: String,
    pub signature_version: String,
    /// `metadata.auth` — e.g. `["aws.auth#sigv4"]`.
    pub auth: Vec<String>,
    pub service_id: String,
    pub service_full_name: String,
    pub service_abbreviation: Option<String>,
    pub global_endpoint: Option<String>,
    /// `metadata.xmlNamespace` — the default XML namespace for `rest-xml`
    /// request documents.
    pub xml_namespace: Option<AwsXmlNamespace>,
    pub aws_query_compatible: bool,
    pub checksum_format: Option<String>,
    pub uid: String,
    /// The model's `clientContextParams`: endpoint-ruleset parameters a
    /// client is configured with, in declared order.
    pub client_context_params: Vec<AwsClientContextParam>,
}

/// An `xmlNamespace` trait: the namespace URI, and the prefix it is bound
/// to (empty for the default namespace). botocore models spell it as an
/// object (`{"uri": ..., "prefix": ...}`) or as the bare URI string.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct AwsXmlNamespace {
    pub prefix: String,
    pub uri: String,
}

/// One `clientContextParams` entry: a ruleset parameter a client is
/// configured with, and its model type (`boolean` or `string`).
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct AwsClientContextParam {
    pub name: String,
    pub ty: String,
}

/// The value of one `staticContextParams` entry: the ruleset parameter an
/// operation always resolves its endpoint with.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AwsStaticValue {
    Bool(bool),
    Str(String),
}

// ===========================================================================
// The overlay
// ===========================================================================

/// Where a structure member binds in the HTTP request/response.
///
/// ⚠ `Body` is the botocore DEFAULT (a member with no `location` key), and
/// it is NOT the same default `emit_rest.rs` applies to an unbound proto
/// field (query param). Do not reuse that partition for AWS.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
pub enum AwsLocation {
    /// No `location` key — the member is serialised into the body. This is
    /// botocore's own default, which is why it is `Default` here too.
    #[default]
    Body,
    /// `location: uri` — substituted into the `requestUri` template.
    Uri,
    /// `location: querystring` — a query parameter.
    QueryString,
    /// `location: header` — one header, named by `wire_name`.
    Header,
    /// `location: headers` — a `map<string,string>` splayed into headers
    /// each PREFIXED by `wire_name` (e.g. `x-amz-meta-`).
    HeaderPrefix,
    /// `location: statusCode` — response only; the HTTP status.
    StatusCode,
}

impl AwsLocation {
    pub fn token(self) -> &'static str {
        match self {
            AwsLocation::Body => "body",
            AwsLocation::Uri => "uri",
            AwsLocation::QueryString => "querystring",
            AwsLocation::Header => "header",
            AwsLocation::HeaderPrefix => "headers",
            AwsLocation::StatusCode => "statusCode",
        }
    }
}

/// A resolved timestamp wire format.
///
/// ⚠ THE RESOLUTION IS DERIVED, NOT READ. Only 8 of the 63 `timestamp`
/// shapes in the vendored corpus carry an explicit `timestampFormat`
/// (2 `iso8601`, 6 `rfc822`); the other 55 inherit botocore's
/// protocol-and-location default, which this file reproduces in
/// [`resolve_timestamp_format`]. That reproduction is stated in one place
/// so the conformance harness (`aws_conformance.rs`, 732 cases) can falsify
/// it rather than it being spread across an emitter.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AwsTimestampFormat {
    Iso8601,
    Rfc822,
    UnixTimestamp,
}

impl AwsTimestampFormat {
    pub fn token(self) -> &'static str {
        match self {
            AwsTimestampFormat::Iso8601 => "iso8601",
            AwsTimestampFormat::Rfc822 => "rfc822",
            AwsTimestampFormat::UnixTimestamp => "unixTimestamp",
        }
    }

    fn parse(s: &str) -> Option<Self> {
        match s {
            "iso8601" => Some(AwsTimestampFormat::Iso8601),
            "rfc822" => Some(AwsTimestampFormat::Rfc822),
            "unixTimestamp" => Some(AwsTimestampFormat::UnixTimestamp),
            _ => None,
        }
    }
}

/// Everything about one structure member that the IR cannot carry.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct AwsMemberFacts {
    pub member_name: String,
    pub wire_name: String,
    pub has_location_name: bool,
    /// `queryName`: the member's parameter name in an ec2Query request,
    /// ahead of its `locationName`.
    pub query_name: Option<String>,
    pub location: AwsLocation,
    /// Membership of the shape's `required` list.
    pub required: bool,
    /// 0-based position in the shape's DECLARED member order. This is the
    /// XML child-element order for `rest-xml`; `json.rs` keeps document
    /// order precisely so this is recoverable (42.2% of structures have a
    /// declared order that differs from sorted).
    pub declared_index: usize,
    /// `idempotencyToken: true` — the client must auto-fill a UUID.
    pub idempotency_token: bool,
    /// Member-level `flattened` (XML: no wrapper element around a list).
    pub flattened: bool,
    /// Member-level `xmlNamespace`.
    pub xml_namespace: Option<AwsXmlNamespace>,
    /// `xmlAttribute: true` — serialise as an attribute, not an element.
    pub xml_attribute: bool,
    /// `streaming: true` on the member.
    pub streaming: bool,
    /// `eventpayload: true`.
    pub event_payload: bool,
    /// `hostLabel: true` — the member is substituted into the endpoint's
    /// `hostPrefix`.
    pub host_label: bool,
    /// `jsonvalue: true` — a string holding a JSON document; bound to a
    /// header it travels base64-encoded.
    pub json_value: bool,
    pub boxed: bool,
    pub deprecated: bool,
    pub deprecated_message: Option<String>,
    /// `contextParam.name` — the endpoint-ruleset parameter this input
    /// member binds.
    pub context_param: Option<String>,
    /// True when this member is the shape's designated `payload`.
    pub is_payload: bool,
    /// The AWS shape name this member refers to (BEFORE any IR collapse).
    pub shape: String,
    /// The AWS shape name of the enclosing `list` / `map`, when the member
    /// referred to one. ⚠ The IR COLLAPSES list and map shapes (a list
    /// becomes `Label::Repeated`, a map becomes `IrType::Map`), so the
    /// container shape's own name — and therefore its `flattened` flag and
    /// its member/key/value `locationName`s, which are the XML element
    /// names — is otherwise unreachable from the IR. This is the link.
    pub container_shape: Option<String>,
    /// The resolved timestamp format, for a `timestamp`-shaped member and
    /// for a list or map whose elements (at any depth) are timestamps: a
    /// container has one scalar leaf, so the format belongs to it.
    pub timestamp_format: Option<AwsTimestampFormat>,
}

/// Everything about one AWS shape. Recorded for EVERY reached shape,
/// including the `list` / `map` / scalar shapes the IR collapses away.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct AwsShapeFacts {
    pub aws_name: String,
    /// `structure` / `list` / `map` / `string` / `integer` / `long` /
    /// `double` / `float` / `boolean` / `timestamp` / `blob`.
    pub aws_type: String,
    /// The IR name this shape became, when it became one. `None` for the
    /// shapes the IR collapses (list, map, plain scalars).
    pub ir_fq_name: Option<String>,
    pub exception: bool,
    pub fault: bool,
    /// `error.code` — the wire error code, when it differs from the shape
    /// name.
    pub error_code: Option<String>,
    pub http_status_code: Option<i64>,
    pub sender_fault: bool,
    pub retryable: bool,
    /// Shape-level `locationName`.
    pub location_name: Option<String>,
    /// Shape-level `xmlNamespace`.
    pub xml_namespace: Option<AwsXmlNamespace>,
    /// The `payload` member name, for a structure that designates one.
    pub payload: Option<String>,
    /// The `required` list, verbatim (member names, not IR field names).
    pub required: Vec<String>,
    /// Shape-level `flattened` — for a `list` or `map`, whether the
    /// container element is elided in XML.
    pub flattened: bool,
    pub list_member_location_name: Option<String>,
    /// For a `list`: the `xmlNamespace` on its `member` reference.
    pub list_member_xml_namespace: Option<AwsXmlNamespace>,
    /// For a `map`: the key / value `locationName`s.
    pub map_key_location_name: Option<String>,
    pub map_value_location_name: Option<String>,
    /// For a `map`: the key / value `queryName`s (ec2Query).
    pub map_key_query_name: Option<String>,
    pub map_value_query_name: Option<String>,
    /// For a `list` / `map`: the element / value AWS shape name.
    pub element_shape: Option<String>,
    pub map_key_shape: Option<String>,
    pub sensitive: bool,
    pub streaming: bool,
    pub event: bool,
    pub eventstream: bool,
    pub union: bool,
    pub synthetic: bool,
    pub deprecated: bool,
    pub deprecated_message: Option<String>,
    /// `enum` values, verbatim and in declaration order.
    pub enum_values: Vec<String>,
    /// Explicit `timestampFormat` on the shape, when present.
    pub timestamp_format: Option<AwsTimestampFormat>,
    pub min: Option<f64>,
    pub max: Option<f64>,
    pub pattern: Option<String>,
    pub boxed: bool,
}

/// One path parameter of an AWS `requestUri`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AwsPathParam {
    /// The member's WIRE name as it appears between the braces (minus the
    /// `+`) — matched against a member's `wire_name`, not its IR name.
    pub name: String,
    pub greedy: bool,
}

/// Everything about one operation that the IR cannot carry.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct AwsOperationFacts {
    /// The AWS operation name, e.g. `ChangeResourceRecordSets`. This is
    /// also the `Action=` value for `query`/`ec2` and the suffix of the
    /// `X-Amz-Target` header for the awsJson family.
    pub name: String,
    /// The IR method name (`change_resource_record_sets`).
    pub ir_method_name: String,
    pub http_method: String,
    /// The `requestUri` VERBATIM, including any `?query` suffix and any
    /// trailing `/`.
    ///
    /// ⚠ `path_template.rs` CANNOT parse this and is not used here. It
    /// rejects the greedy `{Key+}` form as "not a simple field
    /// identifier", drops empty segments (so a trailing `/` — which
    /// route53 requires on `/rrset/` — is lost), and has no notion of the
    /// `?` suffix that 101 of 850 operations carry. The AWS-shaped parse
    /// is `path` / `path_params` / `static_query` below.
    pub request_uri: String,
    /// The `requestUri` up to any `?`.
    pub path: String,
    pub path_params: Vec<AwsPathParam>,
    pub static_query: Vec<(String, Option<String>)>,
    pub response_code: Option<i64>,
    /// The AWS input shape name, or `None` when the operation declares no
    /// input (12 of 850 do not).
    pub input_shape: Option<String>,
    /// `input.locationName` — the XML root element name for `rest-xml`.
    pub input_location_name: Option<String>,
    /// `input.xmlNamespace`.
    pub input_xml_namespace: Option<AwsXmlNamespace>,
    /// The AWS output shape name, or `None` (165 of 850 declare none).
    pub output_shape: Option<String>,
    pub result_wrapper: Option<String>,
    /// The error shapes this operation declares, as IR fq_names. ⚠ The IR
    /// has no error dimension on `IrMethod`; this is the only place they
    /// are recorded, though each error shape IS lowered as an `IrMessage`.
    pub errors: Vec<String>,
    /// `true` when the IR method's `input` is a SYNTHESISED empty message
    /// (the operation declares no input shape). `IrMethod.input` is not an
    /// `Option`, so an empty message is the honest filler; the flag is
    /// what stops a reader mistaking it for a real one.
    pub synthesized_input: bool,
    pub synthesized_output: bool,
    pub idempotent: bool,
    pub readonly: bool,
    pub deprecated: bool,
    pub deprecated_message: Option<String>,
    pub auth_type: Option<String>,
    pub auth: Vec<String>,
    pub unsigned_payload: bool,
    pub endpoint_discovery: bool,
    pub endpoint_operation: bool,
    /// `endpoint.hostPrefix` — a per-operation host prefix.
    pub host_prefix: Option<String>,
    pub http_checksum: Option<AwsHttpChecksum>,
    /// `httpChecksumRequired`: the trait that predates `httpChecksum`, which
    /// requires a request checksum and names no algorithm member.
    pub http_checksum_required: bool,
    /// `staticContextParams`: ruleset parameters this operation always
    /// resolves its endpoint with, in declared order.
    pub static_context_params: Vec<(String, AwsStaticValue)>,
    /// `operationContextParams`: ruleset parameters taken from the input by
    /// a path (`{"path": "A.B"}`), as (parameter, path), in declared order.
    pub operation_context_params: Vec<(String, String)>,
}

impl AwsOperationFacts {
    /// Whether every request of this operation must carry a checksum:
    /// `httpChecksumRequired`, or `httpChecksum.requestChecksumRequired`
    /// (botocore's `request_checksum_required`). The emitter refuses such an
    /// operation where the generated client would send none
    /// (`checksum-required`).
    pub fn request_checksum_required(&self) -> bool {
        self.http_checksum_required
            || self
                .http_checksum
                .as_ref()
                .is_some_and(|c| c.request_checksum_required)
    }
}

/// The `httpChecksum` trait, flattened.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct AwsHttpChecksum {
    pub request_checksum_required: bool,
    pub request_algorithm_member: Option<String>,
    pub request_validation_mode_member: Option<String>,
    pub response_algorithms: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Default)]
pub struct AwsFacts {
    operations: BTreeMap<String, AwsOperationFacts>,
    /// (IR message `fq_name`, IR field `name`) -> facts.
    members: BTreeMap<(String, String), AwsMemberFacts>,
    /// AWS shape name -> facts. Covers EVERY reached shape, including the
    /// list/map/scalar shapes the IR collapses.
    shapes: BTreeMap<String, AwsShapeFacts>,
}

impl AwsFacts {
    /// Facts for an operation, by its AWS name.
    pub fn operation(&self, aws_name: &str) -> Result<&AwsOperationFacts, String> {
        self.operations.get(aws_name).ok_or_else(|| {
            format!("aws facts: no operation {aws_name:?} (the model was lowered without it)")
        })
    }

    /// Facts for an operation, by the IR method name the emitter has.
    pub fn operation_by_ir_method(&self, ir_method: &str) -> Result<&AwsOperationFacts, String> {
        self.operations
            .values()
            .find(|o| o.ir_method_name == ir_method)
            .ok_or_else(|| format!("aws facts: no operation whose IR method is {ir_method:?}"))
    }

    /// Facts for one field of one message.
    pub fn member(&self, msg_fq_name: &str, ir_field: &str) -> Result<&AwsMemberFacts, String> {
        self.members
            .get(&(msg_fq_name.to_string(), ir_field.to_string()))
            .ok_or_else(|| {
                format!("aws facts: no member facts for {msg_fq_name}.{ir_field} — the AWS \
                         overlay is TOTAL by construction, so this is a bug in aws_in.rs, \
                         not a case to default")
            })
    }

    /// Facts for one AWS shape, by its AWS name.
    pub fn shape(&self, aws_name: &str) -> Result<&AwsShapeFacts, String> {
        self.shapes
            .get(aws_name)
            .ok_or_else(|| format!("aws facts: no shape {aws_name:?} in the reached closure"))
    }

    pub fn operations(&self) -> impl Iterator<Item = (&String, &AwsOperationFacts)> {
        self.operations.iter()
    }

    pub fn shapes(&self) -> impl Iterator<Item = (&String, &AwsShapeFacts)> {
        self.shapes.iter()
    }

    pub fn members(&self) -> impl Iterator<Item = (&(String, String), &AwsMemberFacts)> {
        self.members.iter()
    }

    pub fn operation_count(&self) -> usize {
        self.operations.len()
    }

    pub fn shape_count(&self) -> usize {
        self.shapes.len()
    }

    pub fn member_count(&self) -> usize {
        self.members.len()
    }
}

impl AwsLowering {
    pub fn check_totality(&self) -> Result<(), String> {
        for file in &self.model.files {
            for msg in &file.messages {
                for field in &msg.fields {
                    self.facts.member(&msg.fq_name, &field.name)?;
                }
            }
            for svc in &file.services {
                for m in &svc.methods {
                    self.facts.operation_by_ir_method(&m.name)?;
                }
            }
        }
        let mut live: BTreeSet<(String, String)> = BTreeSet::new();
        for file in &self.model.files {
            for msg in &file.messages {
                for field in &msg.fields {
                    live.insert((msg.fq_name.clone(), field.name.clone()));
                }
            }
        }
        for key in self.facts.members.keys() {
            if !live.contains(key) {
                return Err(format!(
                    "aws facts: orphan member facts for {}.{} — no such field in the IR",
                    key.0, key.1
                ));
            }
        }
        Ok(())
    }
}

// ===========================================================================
// The entry point
// ===========================================================================

pub fn lower_aws_service(
    model: &Json,
    service: &str,
    operations: &[String],
    model_path: &str,
    package_prefix: &str,
) -> Result<AwsLowering, String> {
    let root = model
        .as_object()
        .ok_or("AWS service model root is not a JSON object")?;
    let meta = lower_metadata(root, service)?;
    let all_ops = root
        .get("operations")
        .and_then(Json::as_object)
        .ok_or("AWS service model has no `operations` object")?;
    let all_shapes = root
        .get("shapes")
        .and_then(Json::as_object)
        .ok_or("AWS service model has no `shapes` object")?;

    // --- the operation list: dedup + sort + validate --------------------
    let wanted: BTreeSet<String> = operations.iter().cloned().collect();
    if wanted.is_empty() {
        return Err(format!(
            "aws front-end: no operations requested for service `{service}` — this \
             front-end is OPERATION-SCOPED; an empty list would emit an empty client, \
             which is indistinguishable from a working one"
        ));
    }
    let unknown: Vec<&String> = wanted.iter().filter(|n| !all_ops.contains_key(n)).collect();
    if !unknown.is_empty() {
        let mut names: Vec<&str> = unknown.iter().map(|s| s.as_str()).collect();
        names.sort_unstable();
        return Err(format!(
            "aws front-end: service `{service}` declares no operation(s) {names:?} \
             (the model has {} operations). A typo must not silently generate a \
             smaller client.",
            all_ops.len()
        ));
    }

    let mut lowerer = AwsLowerer {
        meta,
        shapes: all_shapes,
        notes: Vec::new(),
        ir_names: BTreeMap::new(),
        enum_shapes: BTreeSet::new(),
        message_shapes: BTreeSet::new(),
        facts: AwsFacts::default(),
    };

    // --- reachability from the named operations only --------------------
    let reached = lowerer.reachable_shapes(all_ops, &wanted)?;

    // --- classify + register IR names (sorted: stable under list order) --
    let mut resolver = CollisionResolver::new();
    for name in &reached {
        let shape = lowerer.shape(name)?;
        let ty = shape_type(shape, name)?;
        // REFUSED, by name (aws_conformance::REFUSAL_MARKER): a document is
        // untyped JSON, and lowering it as the empty structure it is spelled
        // as would drop its contents on both the request and the response.
        if flag(shape, "document") {
            return Err(format!(
                "aws front-end: REFUSED document: shape `{name}` is a document type \
                 (untyped JSON), which the IR has no type for"
            ));
        }
        // REFUSED, by name: an event stream is a framed sequence of events
        // inside one HTTP body, and the generated code reads and writes a
        // body as one document, so a client of it would send or read the
        // frames as if they were that document.
        if flag(shape, "eventstream") {
            return Err(format!(
                "aws front-end: REFUSED eventstream: shape `{name}` is an event \
                 stream, and the generated code has no event-stream framing"
            ));
        }
        match ty {
            "structure" => {
                lowerer.message_shapes.insert(name.clone());
            }
            "string" if shape.get("enum").and_then(Json::as_array).is_some() => {
                lowerer.enum_shapes.insert(name.clone());
            }
            _ => continue,
        }
        let mojo = resolver.resolve(&flatten(&[name.clone()]));
        lowerer.ir_names.insert(name.clone(), mojo);
    }
    // Synthesised empty request/response messages, for the operations that
    // declare none. Registered in the SAME resolver so they cannot collide
    // with a real shape name.
    let mut synthesized: BTreeMap<String, String> = BTreeMap::new();
    for op_name in &wanted {
        let op = all_ops.get(op_name).expect("validated above");
        for (side, suffix) in [("input", "Request"), ("output", "Response")] {
            if op.get(side).and_then(|s| s.get("shape")).is_none() {
                let synth = format!("{op_name}{suffix}");
                if lowerer.ir_names.contains_key(&synth) {
                    return Err(format!(
                        "aws front-end: operation `{op_name}` declares no {side}, and the \
                         synthetic name `{synth}` collides with a real shape. Rename is \
                         not this front-end's call — report it."
                    ));
                }
                let mojo = resolver.resolve(&flatten(&[synth.clone()]));
                lowerer.ir_names.insert(synth.clone(), mojo);
                synthesized.insert(synth.clone(), side.to_string());
            }
        }
    }

    // --- record facts for EVERY reached shape ---------------------------
    for name in &reached {
        let facts = lowerer.shape_facts(name)?;
        lowerer.facts.shapes.insert(name.clone(), facts);
    }

    // --- lower messages + enums -----------------------------------------
    let mut messages = Vec::new();
    let mut enums = Vec::new();
    for name in &reached {
        if lowerer.enum_shapes.contains(name) {
            enums.push(lowerer.lower_enum(name)?);
        } else if lowerer.message_shapes.contains(name) {
            messages.push(lowerer.lower_structure(name)?);
        }
    }
    for (synth, _side) in &synthesized {
        messages.push(IrMessage {
            name: synth.clone(),
            mojo_name: lowerer.ir_names[synth].clone(),
            fq_name: aws_fq(service, synth),
            is_map_entry: false,
            fields: Vec::new(),
            oneofs: Vec::new(),
        });
        lowerer.facts.shapes.insert(
            synth.clone(),
            AwsShapeFacts {
                aws_name: synth.clone(),
                aws_type: "structure".to_string(),
                ir_fq_name: Some(aws_fq(service, synth)),
                synthetic: true,
                ..Default::default()
            },
        );
    }
    // Deterministic order regardless of the traversal: the reached set is a
    // BTreeSet and `synthesized` a BTreeMap, but the two are pushed
    // separately, so sort once at the end by AWS name.
    messages.sort_by(|a, b| a.name.cmp(&b.name));
    enums.sort_by(|a, b| a.name.cmp(&b.name));

    // --- lower operations ------------------------------------------------
    let mut methods = Vec::new();
    for op_name in &wanted {
        let op = all_ops.get(op_name).expect("validated above");
        methods.push(lowerer.lower_operation(op_name, op)?);
    }

    let services = if methods.is_empty() {
        Vec::new()
    } else {
        vec![IrService {
            name: service_struct_name(&lowerer.meta),
            default_host: None,
            host_from_service_config: false,
            methods,
        }]
    };

    let file = IrFile {
        proto_path: model_path.to_string(),
        proto_package: format!("aws.{}", lowerer.meta.service),
        mojo_package: package_prefix.to_string(),
        messages,
        enums,
        services,
        // One service model lowers into one generated file; there are no
        // cross-file references (an AWS model is self-contained).
        imports: Vec::new(),
    };

    let AwsLowerer { meta, notes, facts, .. } = lowerer;
    let lowering = AwsLowering {
        model: IrModel { files: vec![file] },
        service: meta,
        facts,
        notes,
    };
    lowering.check_totality()?;
    Ok(lowering)
}

/// The fully-qualified IR name of an AWS shape: `aws.<service>#<Shape>`.
///
/// Deliberately unlike both siblings (`.pkg.Name` for proto,
/// `#/components/schemas/X` for OpenAPI) so an IR dump makes its front-end
/// obvious at a glance.
pub fn aws_fq(service: &str, shape: &str) -> String {
    format!("aws.{service}#{shape}")
}

// ===========================================================================
// The lowerer
// ===========================================================================

struct AwsLowerer<'a> {
    meta: AwsServiceMeta,
    shapes: &'a JsonObject,
    notes: Vec<String>,
    /// AWS shape name -> resolved flat Mojo name (messages + enums only).
    ir_names: BTreeMap<String, String>,
    enum_shapes: BTreeSet<String>,
    message_shapes: BTreeSet<String>,
    facts: AwsFacts,
}

impl<'a> AwsLowerer<'a> {
    fn shape(&self, name: &str) -> Result<&'a JsonObject, String> {
        self.shapes
            .get(name)
            .and_then(Json::as_object)
            .ok_or_else(|| format!("aws front-end: shape reference `{name}` resolves to nothing"))
    }

    fn reachable_shapes(
        &self,
        all_ops: &JsonObject,
        wanted: &BTreeSet<String>,
    ) -> Result<BTreeSet<String>, String> {
        let mut seen: BTreeSet<String> = BTreeSet::new();
        let mut stack: Vec<String> = Vec::new();
        for op_name in wanted {
            let op = all_ops.get(op_name).expect("validated by the caller");
            for side in ["input", "output"] {
                if let Some(s) = op.get(side).and_then(|s| s.get("shape")).and_then(Json::as_str) {
                    stack.push(s.to_string());
                }
            }
            for e in op.get("errors").and_then(Json::as_array).unwrap_or(&[]) {
                let s = e.get("shape").and_then(Json::as_str).ok_or_else(|| {
                    format!("aws front-end: operation `{op_name}` has an error with no `shape`")
                })?;
                stack.push(s.to_string());
            }
        }
        while let Some(name) = stack.pop() {
            if !seen.insert(name.clone()) {
                continue;
            }
            let shape = self.shape(&name)?;
            match shape_type(shape, &name)? {
                "structure" => {
                    if let Some(members) = shape.get("members").and_then(Json::as_object) {
                        for (_, m) in members.iter_declared() {
                            stack.push(member_shape_name(m, &name)?);
                        }
                    }
                }
                "list" => {
                    let m = shape.get("member").ok_or_else(|| {
                        format!("aws front-end: list shape `{name}` has no `member`")
                    })?;
                    stack.push(member_shape_name(m, &name)?);
                }
                "map" => {
                    for k in ["key", "value"] {
                        let m = shape.get(k).ok_or_else(|| {
                            format!("aws front-end: map shape `{name}` has no `{k}`")
                        })?;
                        stack.push(member_shape_name(m, &name)?);
                    }
                }
                _ => {}
            }
        }
        Ok(seen)
    }

    // --- shapes ---------------------------------------------------------

    fn shape_facts(&self, name: &str) -> Result<AwsShapeFacts, String> {
        let s = self.shape(name)?;
        let ty = shape_type(s, name)?;
        let mut f = AwsShapeFacts {
            aws_name: name.to_string(),
            aws_type: ty.to_string(),
            ir_fq_name: self
                .ir_names
                .get(name)
                .map(|_| aws_fq(&self.meta.service, name)),
            exception: flag(s, "exception"),
            fault: flag(s, "fault"),
            retryable: s.get("retryable").is_some(),
            location_name: str_of(s, "locationName"),
            xml_namespace: xml_ns(s.get("xmlNamespace"), &format!("shape `{name}`"))?,
            payload: str_of(s, "payload"),
            required: s
                .get("required")
                .and_then(Json::as_array)
                .map(|a| a.iter().filter_map(Json::as_str).map(String::from).collect())
                .unwrap_or_default(),
            flattened: flag(s, "flattened"),
            sensitive: flag(s, "sensitive"),
            streaming: flag(s, "streaming"),
            event: flag(s, "event"),
            eventstream: flag(s, "eventstream"),
            union: flag(s, "union"),
            synthetic: flag(s, "synthetic"),
            deprecated: flag(s, "deprecated"),
            deprecated_message: str_of(s, "deprecatedMessage"),
            boxed: flag(s, "box"),
            min: num_of(s, "min"),
            max: num_of(s, "max"),
            pattern: str_of(s, "pattern"),
            ..Default::default()
        };
        if let Some(err) = s.get("error") {
            f.error_code = err.get("code").and_then(Json::as_str).map(String::from);
            f.http_status_code = err.get("httpStatusCode").and_then(as_i64);
            f.sender_fault = err.get("senderFault").and_then(Json::as_bool).unwrap_or(false);
        }
        if let Some(tf) = str_of(s, "timestampFormat") {
            f.timestamp_format = Some(AwsTimestampFormat::parse(&tf).ok_or_else(|| {
                format!("aws front-end: shape `{name}` has unknown timestampFormat {tf:?}")
            })?);
        }
        if let Some(vals) = s.get("enum").and_then(Json::as_array) {
            f.enum_values = vals
                .iter()
                .map(|v| {
                    v.as_str()
                        .map(String::from)
                        .ok_or_else(|| format!("aws front-end: enum `{name}` has a non-string value"))
                })
                .collect::<Result<Vec<_>, _>>()?;
        }
        if ty == "list" {
            let m = s.get("member").expect("checked in reachable_shapes");
            f.element_shape = Some(member_shape_name(m, name)?);
            f.list_member_location_name =
                m.get("locationName").and_then(Json::as_str).map(String::from);
            f.list_member_xml_namespace =
                xml_ns(m.get("xmlNamespace"), &format!("the member of list `{name}`"))?;
            // A member-level `flattened` on the list's own `member` node.
            if m.get("flattened").and_then(Json::as_bool) == Some(true) {
                f.flattened = true;
            }
        }
        if ty == "map" {
            let k = s.get("key").expect("checked in reachable_shapes");
            let v = s.get("value").expect("checked in reachable_shapes");
            f.map_key_shape = Some(member_shape_name(k, name)?);
            f.element_shape = Some(member_shape_name(v, name)?);
            f.map_key_location_name = k.get("locationName").and_then(Json::as_str).map(String::from);
            f.map_value_location_name =
                v.get("locationName").and_then(Json::as_str).map(String::from);
            f.map_key_query_name = k.get("queryName").and_then(Json::as_str).map(String::from);
            f.map_value_query_name = v.get("queryName").and_then(Json::as_str).map(String::from);
        }
        Ok(f)
    }

    fn lower_enum(&mut self, name: &str) -> Result<IrEnum, String> {
        let s = self.shape(name)?;
        let values = s
            .get("enum")
            .and_then(Json::as_array)
            .expect("classified as an enum shape");
        let mut resolver = CollisionResolver::new();
        let mut ir_values = Vec::new();
        for (idx, v) in values.iter().enumerate() {
            let wire = v
                .as_str()
                .ok_or_else(|| format!("aws front-end: enum `{name}` has a non-string value"))?;
            ir_values.push(IrEnumValue {
                // The WIRE STRING, verbatim. AWS enums are string-valued on
                // the wire; `number` below is an index this front-end
                // assigns for the IR's benefit and has NO wire meaning.
                name: wire.to_string(),
                mojo_name: resolver.resolve(&enum_ident(wire)),
                number: idx as i32,
            });
        }
        Ok(IrEnum {
            name: name.to_string(),
            mojo_name: self.ir_names[name].clone(),
            fq_name: aws_fq(&self.meta.service, name),
            values: ir_values,
        })
    }

    fn lower_structure(&mut self, name: &str) -> Result<IrMessage, String> {
        let s = self.shape(name)?;
        let fq = aws_fq(&self.meta.service, name);
        let required: BTreeSet<String> = s
            .get("required")
            .and_then(Json::as_array)
            .map(|a| a.iter().filter_map(Json::as_str).map(String::from).collect())
            .unwrap_or_default();
        let payload = str_of(s, "payload");

        let mut fields = Vec::new();
        let mut field_names = CollisionResolver::new();
        let mut pending: Vec<(AwsMemberFacts, IrField)> = Vec::new();
        if let Some(members) = s.get("members").and_then(Json::as_object) {
            // DECLARED order — the XML child-element order. `json.rs` keeps
            // it precisely for this (42.2% of structures differ from sorted).
            for (idx, (mname, m)) in members.iter_declared().enumerate() {
                let (ty, label, container) = self.lower_member_type(name, mname, m)?;
                let mfacts = self.member_facts(
                    name,
                    mname,
                    m,
                    idx,
                    required.contains(mname),
                    payload.as_deref() == Some(mname.as_str()),
                    container,
                )?;
                let ir_field = IrField {
                    name: field_names.resolve(&escape_member(&snake_case(mname))),
                    ty,
                    label,
                    // AWS has no wire field numbers. 1-based DECLARED order,
                    // so the number encodes the one ordering that IS
                    // meaningful here (XML element order) rather than an
                    // arbitrary one.
                    proto_field_number: (idx + 1) as u32,
                    // The WIRE name — `locationName` when present. For the
                    // awsJson family this IS the JSON key; for rest-xml it
                    // is the element name; for a header member it is the
                    // header name. `location` in the overlay says which.
                    json_name: mfacts.wire_name.clone(),
                    oneof_index: None,
                };
                pending.push((mfacts, ir_field));
            }
        }
        for (mfacts, ir_field) in pending {
            self.facts
                .members
                .insert((fq.clone(), ir_field.name.clone()), mfacts);
            fields.push(ir_field);
        }

        Ok(IrMessage {
            name: name.to_string(),
            mojo_name: self.ir_names[name].clone(),
            fq_name: fq,
            // AWS has no synthetic map-entry types — a map lowers straight
            // to `IrType::Map`, so no message is ever a map entry.
            is_map_entry: false,
            fields,
            // botocore models 2 `union` shapes across the vendored corpus
            // (see the `union` flag in `AwsShapeFacts`). They are ordinary
            // structures on the wire with at most one member set, NOT a
            // proto `oneof` with a discriminant, so lowering them to
            // `IrOneof` would invent a wire discriminant AWS does not send.
            // The flag is recorded; the arms stay plain optional fields.
            oneofs: Vec::new(),
        })
    }

    /// `(IrType, Label, container_shape)` for one structure member.
    fn lower_member_type(
        &mut self,
        owner: &str,
        mname: &str,
        m: &Json,
    ) -> Result<(IrType, Label, Option<String>), String> {
        let shape_name = member_shape_name(m, owner)?;
        let s = self.shape(&shape_name)?;
        let ty = shape_type(s, &shape_name)?;
        match ty {
            "list" => {
                // The OUTERMOST list is the field's `Label::Repeated` and the
                // field's type is its ELEMENT — protobuf's shape, kept so the
                // two front-ends spell a plain repeated field identically. Any
                // FURTHER nesting inside that element becomes `IrType::List` /
                // `IrType::Map`, which is what `lower_nested_type` builds.
                let elem_ref = s.get("member").expect("checked in reachable_shapes");
                let elem_name = member_shape_name(elem_ref, &shape_name)?;
                // The nested walk knows the SHAPE names but not the member
                // that reached them; a failure names both or a reader has to
                // grep the model to find out which member is at fault.
                let inner = self
                    .lower_nested_type(&elem_name)
                    .map_err(|e| format!("{owner}.{mname}: {e}"))?;
                Ok((inner, Label::Repeated, Some(shape_name)))
            }
            "map" => {
                let value_ty = self
                    .lower_map_value(&shape_name)
                    .map_err(|e| format!("{owner}.{mname}: {e}"))?;
                Ok((
                    IrType::Map(
                        Box::new(IrType::Scalar(ScalarKind::String)),
                        Box::new(value_ty),
                    ),
                    Label::Single,
                    Some(shape_name),
                ))
            }
            _ => {
                let (ir_ty, is_message) = self.scalar_or_ref(&shape_name)?;
                // A structure member is always presence-tracked: `required`
                // is preserved in the overlay, and the emitter needs the
                // indirection for the recursion edges anyway.
                let label = if is_message { Label::Optional } else { Label::Single };
                Ok((ir_ty, label, None))
            }
        }
    }

    fn lower_nested_type(&mut self, shape_name: &str) -> Result<IrType, String> {
        self.lower_nested_type_on(shape_name, &mut Vec::new())
    }

    /// [`Self::lower_nested_type`], carrying the CONTAINER shapes already on
    /// the path.
    ///
    /// ⚠ A CONTAINER CHAIN THAT RE-ENTERS ITSELF IS AN INFINITE TYPE, and
    /// without this it is an infinite RECURSION in the generator instead — a
    /// hang, which is the worst way for a malformed model to report itself. A
    /// structure member ends the walk (it lowers to a `Message` reference, and
    /// message cycles are what `lower::recursion_breaking_edges` is for), so
    /// only a list/map chain can loop. No vendored model has one; this says so
    /// rather than assuming it.
    fn lower_nested_type_on(
        &mut self,
        shape_name: &str,
        path: &mut Vec<String>,
    ) -> Result<IrType, String> {
        let s = self.shape(shape_name)?;
        let ty = shape_type(s, shape_name)?;
        if ty == "list" || ty == "map" {
            if path.iter().any(|p| p == shape_name) {
                return Err(format!(
                    "aws front-end: container shape `{shape_name}` contains itself through \
                     containers only ({} -> {shape_name}), which is an infinitely-sized \
                     type. A cycle must pass through a structure.",
                    path.join(" -> ")
                ));
            }
            path.push(shape_name.to_string());
        }
        let out = match ty {
            "list" => {
                let elem_name = member_shape_name(
                    s.get("member").expect("checked in reachable_shapes"),
                    shape_name,
                )?;
                IrType::List(Box::new(self.lower_nested_type_on(&elem_name, path)?))
            }
            "map" => IrType::Map(
                Box::new(IrType::Scalar(ScalarKind::String)),
                Box::new(self.lower_map_value_on(shape_name, path)?),
            ),
            _ => self.scalar_or_ref(shape_name)?.0,
        };
        if ty == "list" || ty == "map" {
            path.pop();
        }
        Ok(out)
    }

    /// A map shape's VALUE type, with the key restriction enforced once.
    fn lower_map_value(&mut self, shape_name: &str) -> Result<IrType, String> {
        self.lower_map_value_on(shape_name, &mut vec![shape_name.to_string()])
    }

    fn lower_map_value_on(
        &mut self,
        shape_name: &str,
        path: &mut Vec<String>,
    ) -> Result<IrType, String> {
        let s = self.shape(shape_name)?;
        let key_name =
            member_shape_name(s.get("key").expect("checked in reachable_shapes"), shape_name)?;
        let key_shape = self.shape(&key_name)?;
        if shape_type(key_shape, &key_name)? != "string" {
            return Err(format!(
                "aws front-end: map `{shape_name}` has a non-string key shape \
                 `{key_name}`; the IR's map key is restricted and every map key \
                 in the vendored corpus is a string (measured: 53 of 53)"
            ));
        }
        let val_name =
            member_shape_name(s.get("value").expect("checked in reachable_shapes"), shape_name)?;
        self.lower_nested_type_on(&val_name, path)
    }

    /// The `IrType` for a non-container shape, plus whether it is a
    /// message reference.
    fn scalar_or_ref(&mut self, shape_name: &str) -> Result<(IrType, bool), String> {
        let s = self.shape(shape_name)?;
        let ty = shape_type(s, shape_name)?;
        let tref = || TypeRef {
            fq_name: aws_fq(&self.meta.service, shape_name),
            mojo_name: self.ir_names[shape_name].clone(),
        };
        Ok(match ty {
            "structure" => (IrType::Message(tref()), true),
            "string" if s.get("enum").and_then(Json::as_array).is_some() => {
                (IrType::Enum(tref()), false)
            }
            "string" => (IrType::Scalar(ScalarKind::String), false),
            "integer" => (IrType::Scalar(ScalarKind::Int32), false),
            "long" => (IrType::Scalar(ScalarKind::Int64), false),
            "double" => (IrType::Scalar(ScalarKind::Double), false),
            "float" => (IrType::Scalar(ScalarKind::Float), false),
            "boolean" => (IrType::Scalar(ScalarKind::Bool), false),
            "blob" => (IrType::Scalar(ScalarKind::Bytes), false),
            "timestamp" => {
                // Carried as a STRING, with the resolved wire format in the
                // overlay. AWS timestamps are `iso8601` / `rfc822` text for
                // most protocol-and-location combinations and a NUMBER for
                // `unixTimestamp`; the IR has one scalar kind per field and
                // the format varies per MEMBER (it depends on `location`),
                // not per shape — so a single shape cannot be both. A string
                // is the one carrier that holds every case losslessly.
                self.note(format!(
                    "shape `{shape_name}`: AWS `timestamp` lowered to `string`; the \
                     resolved wire format is per-member in AwsMemberFacts.timestamp_format"
                ));
                (IrType::Scalar(ScalarKind::String), false)
            }
            "list" | "map" => {
                return Err(format!(
                    "aws front-end: internal — container shape `{shape_name}` reached \
                     scalar_or_ref"
                ))
            }
            other => {
                return Err(format!(
                    "aws front-end: shape `{shape_name}` has unknown AWS type {other:?}"
                ))
            }
        })
    }

    fn member_facts(
        &self,
        owner: &str,
        mname: &str,
        m: &Json,
        idx: usize,
        required: bool,
        is_payload: bool,
        container: Option<String>,
    ) -> Result<AwsMemberFacts, String> {
        let mo = m
            .as_object()
            .ok_or_else(|| format!("aws front-end: {owner}.{mname} is not an object"))?;
        let location = match mo.get("location").and_then(Json::as_str) {
            None => AwsLocation::Body,
            Some("uri") => AwsLocation::Uri,
            Some("querystring") => AwsLocation::QueryString,
            Some("header") => AwsLocation::Header,
            Some("headers") => AwsLocation::HeaderPrefix,
            Some("statusCode") => AwsLocation::StatusCode,
            Some(other) => {
                return Err(format!(
                    "aws front-end: {owner}.{mname} has unknown location {other:?} — \
                     a new binding needs a serializer, not a default"
                ))
            }
        };
        let location_name = str_of(mo, "locationName");
        let shape_name = member_shape_name(m, owner)?;
        let leaf_name = self.container_leaf(&shape_name)?;
        let leaf = self.shape(&leaf_name)?;
        let timestamp_format = if shape_type(leaf, &leaf_name)? == "timestamp" {
            Some(resolve_timestamp_format(
                str_of(leaf, "timestampFormat").as_deref(),
                &self.meta.protocol,
                location,
            )?)
        } else {
            None
        };
        Ok(AwsMemberFacts {
            member_name: mname.to_string(),
            wire_name: location_name.clone().unwrap_or_else(|| mname.to_string()),
            has_location_name: location_name.is_some(),
            query_name: str_of(mo, "queryName"),
            location,
            required,
            declared_index: idx,
            idempotency_token: flag(mo, "idempotencyToken"),
            flattened: flag(mo, "flattened"),
            xml_namespace: xml_ns(
                mo.get("xmlNamespace"),
                &format!("member `{owner}.{mname}`"),
            )?,
            xml_attribute: flag(mo, "xmlAttribute"),
            streaming: flag(mo, "streaming"),
            event_payload: flag(mo, "eventpayload"),
            host_label: flag(mo, "hostLabel"),
            json_value: flag(mo, "jsonvalue"),
            boxed: flag(mo, "box"),
            deprecated: flag(mo, "deprecated"),
            deprecated_message: str_of(mo, "deprecatedMessage"),
            context_param: mo
                .get("contextParam")
                .and_then(|c| c.get("name"))
                .and_then(Json::as_str)
                .map(String::from),
            is_payload,
            shape: shape_name,
            container_shape: container,
            timestamp_format,
        })
    }

    /// The shape a list's elements or a map's values end in, through any
    /// depth of containers: `shape_name` itself when it is not a list or a
    /// map. A container chain that re-enters itself is refused (see
    /// [`Self::lower_nested_type_on`]).
    fn container_leaf(&self, shape_name: &str) -> Result<String, String> {
        let mut name = shape_name.to_string();
        let mut seen: Vec<String> = Vec::new();
        loop {
            let s = self.shape(&name)?;
            let next = match shape_type(s, &name)? {
                "list" => s.get("member"),
                "map" => s.get("value"),
                _ => return Ok(name),
            };
            if seen.contains(&name) {
                return Err(format!(
                    "aws front-end: container shape `{name}` contains itself through \
                     containers only"
                ));
            }
            seen.push(name.clone());
            let next = next.ok_or_else(|| {
                format!("aws front-end: container shape `{name}` has no element shape")
            })?;
            name = member_shape_name(next, &name)?;
        }
    }

    // --- operations ------------------------------------------------------

    fn lower_operation(&mut self, op_name: &str, op: &Json) -> Result<IrMethod, String> {
        let http = op
            .get("http")
            .ok_or_else(|| format!("aws front-end: operation `{op_name}` has no `http`"))?;
        let method = http
            .get("method")
            .and_then(Json::as_str)
            .ok_or_else(|| format!("aws front-end: operation `{op_name}` has no `http.method`"))?;
        let request_uri = http.get("requestUri").and_then(Json::as_str).ok_or_else(|| {
            format!("aws front-end: operation `{op_name}` has no `http.requestUri`")
        })?;
        let (path, path_params, static_query) = parse_request_uri(request_uri, op_name)?;

        let input_shape = op.get("input").and_then(|s| s.get("shape")).and_then(Json::as_str);
        let output_shape = op.get("output").and_then(|s| s.get("shape")).and_then(Json::as_str);
        let synth_in = input_shape.is_none();
        let synth_out = output_shape.is_none();
        let in_name = input_shape
            .map(String::from)
            .unwrap_or_else(|| format!("{op_name}Request"));
        let out_name = output_shape
            .map(String::from)
            .unwrap_or_else(|| format!("{op_name}Response"));
        if synth_in {
            self.note(format!(
                "operation `{op_name}` declares no input shape; an EMPTY `{in_name}` \
                 message was synthesised (IrMethod.input is not optional). \
                 AwsOperationFacts.synthesized_input marks it."
            ));
        }
        if synth_out {
            self.note(format!(
                "operation `{op_name}` declares no output shape; an EMPTY `{out_name}` \
                 message was synthesised. AwsOperationFacts.synthesized_output marks it."
            ));
        }

        let ir_method_name = escape_member(&snake_case(op_name));
        let mut errors = Vec::new();
        for e in op.get("errors").and_then(Json::as_array).unwrap_or(&[]) {
            let s = e
                .get("shape")
                .and_then(Json::as_str)
                .ok_or_else(|| format!("aws front-end: `{op_name}` error has no `shape`"))?;
            // REFUSED, by name (aws_conformance::REFUSAL_MARKER): an error
            // of an awsQueryCompatible service whose `error.code` is not its
            // shape name. The service answers that error with the code in
            // the x-amzn-query-error header and the shape name in the body's
            // `__type`, and the generated error path reads the body only, so
            // the client would report the wrong code. An error without a
            // custom code carries the same code in both places, so the
            // operation is only refused when one of its errors has one.
            if self.meta.aws_query_compatible {
                let shape = self.shape(s)?;
                if let Some(code) = shape
                    .get("error")
                    .and_then(|e| e.get("code"))
                    .and_then(Json::as_str)
                    .filter(|c| *c != s)
                {
                    return Err(format!(
                        "aws front-end: REFUSED aws-query-compatible: operation \
                         `{op_name}` can return `{s}`, whose awsQueryCompatible code \
                         `{code}` arrives in the x-amzn-query-error header, which the \
                         generated error path does not read"
                    ));
                }
            }
            errors.push(aws_fq(&self.meta.service, s));
        }
        let facts = AwsOperationFacts {
            name: op_name.to_string(),
            ir_method_name: ir_method_name.clone(),
            http_method: method.to_string(),
            request_uri: request_uri.to_string(),
            path,
            path_params: path_params.clone(),
            static_query,
            response_code: http.get("responseCode").and_then(as_i64),
            input_shape: input_shape.map(String::from),
            input_location_name: op
                .get("input")
                .and_then(|i| i.get("locationName"))
                .and_then(Json::as_str)
                .map(String::from),
            input_xml_namespace: xml_ns(
                op.get("input").and_then(|i| i.get("xmlNamespace")),
                &format!("the input of operation `{op_name}`"),
            )?,
            output_shape: output_shape.map(String::from),
            result_wrapper: op
                .get("output")
                .and_then(|o| o.get("resultWrapper"))
                .and_then(Json::as_str)
                .map(String::from),
            errors,
            synthesized_input: synth_in,
            synthesized_output: synth_out,
            idempotent: op.get("idempotent").and_then(Json::as_bool).unwrap_or(false),
            readonly: op.get("readonly").and_then(Json::as_bool).unwrap_or(false),
            deprecated: op.get("deprecated").and_then(Json::as_bool).unwrap_or(false),
            deprecated_message: op
                .get("deprecatedMessage")
                .and_then(Json::as_str)
                .map(String::from),
            auth_type: op.get("authtype").and_then(Json::as_str).map(String::from),
            auth: op
                .get("auth")
                .and_then(Json::as_array)
                .map(|a| a.iter().filter_map(Json::as_str).map(String::from).collect())
                .unwrap_or_default(),
            unsigned_payload: op
                .get("unsignedPayload")
                .and_then(Json::as_bool)
                .unwrap_or(false),
            endpoint_discovery: op.get("endpointdiscovery").is_some(),
            endpoint_operation: op
                .get("endpointoperation")
                .and_then(Json::as_bool)
                .unwrap_or(false),
            host_prefix: op
                .get("endpoint")
                .and_then(|e| e.get("hostPrefix"))
                .and_then(Json::as_str)
                .map(String::from),
            http_checksum: op.get("httpChecksum").map(|c| AwsHttpChecksum {
                request_checksum_required: c
                    .get("requestChecksumRequired")
                    .and_then(Json::as_bool)
                    .unwrap_or(false),
                request_algorithm_member: c
                    .get("requestAlgorithmMember")
                    .and_then(Json::as_str)
                    .map(String::from),
                request_validation_mode_member: c
                    .get("requestValidationModeMember")
                    .and_then(Json::as_str)
                    .map(String::from),
                response_algorithms: c
                    .get("responseAlgorithms")
                    .and_then(Json::as_array)
                    .map(|a| a.iter().filter_map(Json::as_str).map(String::from).collect())
                    .unwrap_or_default(),
            }),
            http_checksum_required: op
                .get("httpChecksumRequired")
                .and_then(Json::as_bool)
                .unwrap_or(false),
            static_context_params: static_context_params(op, op_name)?,
            operation_context_params: operation_context_params(op, op_name)?,
        };
        let body = self.body_designator(op_name, input_shape, &path_params)?;
        self.facts.operations.insert(op_name.to_string(), facts);

        Ok(IrMethod {
            name: ir_method_name,
            input: TypeRef {
                fq_name: aws_fq(&self.meta.service, &in_name),
                mojo_name: self.ir_names[&in_name].clone(),
            },
            output: TypeRef {
                fq_name: aws_fq(&self.meta.service, &out_name),
                mojo_name: self.ir_names[&out_name].clone(),
            },
            // AWS's REST/RPC operations are unary. The 7 `event` /
            // 2 `eventstream` shapes in the corpus ARE a streaming
            // dimension, but they are a body ENCODING (a framed event
            // stream inside one HTTP response), not gRPC-style method
            // streaming — `AwsShapeFacts.eventstream` records them.
            client_streaming: false,
            server_streaming: false,
            idempotent: op.get("idempotent").and_then(Json::as_bool).unwrap_or(false),
            http_rule: Some(IrHttpRule {
                verb: method.to_ascii_lowercase(),
                // VERBATIM. See `AwsOperationFacts.request_uri`.
                path_template: request_uri.to_string(),
                body,
                additional_bindings: vec![],
            }),
            // `(google.api.routing)` is a gRPC concern; AWS has none.
            routing_rule: None,
        })
    }

    /// The `IrHttpRule.body` designator for an operation.
    ///
    /// ⚠ AWS's default is the OPPOSITE of `google.api.http`'s. A proto
    /// field not named in the template and not in `body` is a QUERY
    /// PARAM; an AWS member with no `location` is a BODY member. So this
    /// returns `"*"` whenever any input member is unbound, `""` when every
    /// member is bound to the uri / query / a header, and the member's IR
    /// field name when the shape designates a `payload`.
    fn body_designator(
        &self,
        op_name: &str,
        input_shape: Option<&str>,
        _path_params: &[AwsPathParam],
    ) -> Result<String, String> {
        let Some(shape_name) = input_shape else {
            return Ok(String::new());
        };
        let s = self.shape(shape_name)?;
        if let Some(payload) = str_of(s, "payload") {
            return Ok(escape_member(&snake_case(&payload)));
        }
        let Some(members) = s.get("members").and_then(Json::as_object) else {
            return Ok(String::new());
        };
        let any_body = members
            .iter()
            .any(|(_, m)| m.get("location").and_then(Json::as_str).is_none());
        if any_body {
            Ok("*".to_string())
        } else {
            let _ = op_name;
            Ok(String::new())
        }
    }

    fn note(&mut self, n: String) {
        if !self.notes.contains(&n) {
            self.notes.push(n);
        }
    }
}

// ===========================================================================
// Helpers
// ===========================================================================

fn lower_metadata(root: &JsonObject, service: &str) -> Result<AwsServiceMeta, String> {
    let m = root
        .get("metadata")
        .and_then(Json::as_object)
        .ok_or("AWS service model has no `metadata` object")?;
    let need = |k: &str| -> Result<String, String> {
        m.get(k)
            .and_then(Json::as_str)
            .map(String::from)
            .ok_or_else(|| format!("AWS service model `metadata` has no `{k}`"))
    };
    let endpoint_prefix = need("endpointPrefix")?;
    let declared_protocol = need("protocol")?;
    let protocols: Vec<String> = m
        .get("protocols")
        .and_then(Json::as_array)
        .map(|a| a.iter().filter_map(Json::as_str).map(String::from).collect())
        .unwrap_or_default();
    let protocol = protocols
        .iter()
        .find(|p| crate::emit_aws::SUPPORTED_PROTOCOLS.contains(&p.as_str()))
        .cloned()
        .unwrap_or_else(|| declared_protocol.clone());
    Ok(AwsServiceMeta {
        service: service.to_string(),
        api_version: need("apiVersion")?,
        protocol,
        declared_protocol,
        protocols,
        json_version: str_of(m, "jsonVersion"),
        target_prefix: str_of(m, "targetPrefix"),
        signing_name: str_of(m, "signingName").unwrap_or_else(|| endpoint_prefix.clone()),
        endpoint_prefix,
        signature_version: need("signatureVersion")?,
        auth: m
            .get("auth")
            .and_then(Json::as_array)
            .map(|a| a.iter().filter_map(Json::as_str).map(String::from).collect())
            .unwrap_or_default(),
        service_id: need("serviceId")?,
        service_full_name: need("serviceFullName")?,
        service_abbreviation: str_of(m, "serviceAbbreviation"),
        global_endpoint: str_of(m, "globalEndpoint"),
        xml_namespace: xml_ns(m.get("xmlNamespace"), "the service metadata")?,
        aws_query_compatible: m.get("awsQueryCompatible").is_some(),
        checksum_format: str_of(m, "checksumFormat"),
        uid: need("uid")?,
        client_context_params: client_context_params(root)?,
    })
}

/// The model's `clientContextParams` (a top-level object of the model, not
/// of `metadata`), in declared order.
fn client_context_params(root: &JsonObject) -> Result<Vec<AwsClientContextParam>, String> {
    let Some(v) = root.get("clientContextParams") else {
        return Ok(Vec::new());
    };
    let obj = v
        .as_object()
        .ok_or("AWS service model `clientContextParams` is not an object")?;
    let mut out = Vec::new();
    for (name, spec) in obj.iter_declared() {
        let ty = spec
            .get("type")
            .and_then(Json::as_str)
            .ok_or_else(|| format!("clientContextParams `{name}` has no `type`"))?;
        out.push(AwsClientContextParam {
            name: name.clone(),
            ty: ty.to_ascii_lowercase(),
        });
    }
    Ok(out)
}

/// An operation's `staticContextParams`, in declared order. A value that is
/// neither a boolean nor a string is refused: no other kind occurs in the
/// pinned models, and the emitter binds only these two.
fn static_context_params(
    op: &Json,
    op_name: &str,
) -> Result<Vec<(String, AwsStaticValue)>, String> {
    let Some(v) = op.get("staticContextParams") else {
        return Ok(Vec::new());
    };
    let obj = v.as_object().ok_or_else(|| {
        format!("operation `{op_name}`: `staticContextParams` is not an object")
    })?;
    let mut out = Vec::new();
    for (name, spec) in obj.iter_declared() {
        let value = match spec.get("value") {
            Some(Json::Bool(b)) => AwsStaticValue::Bool(*b),
            Some(Json::Str(s)) => AwsStaticValue::Str(s.clone()),
            _ => {
                return Err(format!(
                    "aws front-end: REFUSED static-context-param: operation `{op_name}` \
                     binds the endpoint parameter `{name}` to a value that is neither a \
                     boolean nor a string"
                ))
            }
        };
        out.push((name.clone(), value));
    }
    Ok(out)
}

/// An operation's `operationContextParams`, as (parameter, path), in
/// declared order. The path is kept as written; the emitter decides which
/// paths it can bind.
fn operation_context_params(op: &Json, op_name: &str) -> Result<Vec<(String, String)>, String> {
    let Some(v) = op.get("operationContextParams") else {
        return Ok(Vec::new());
    };
    let obj = v.as_object().ok_or_else(|| {
        format!("operation `{op_name}`: `operationContextParams` is not an object")
    })?;
    let mut out = Vec::new();
    for (name, spec) in obj.iter_declared() {
        let path = spec.get("path").and_then(Json::as_str).ok_or_else(|| {
            format!("operation `{op_name}`: operationContextParams `{name}` has no `path`")
        })?;
        out.push((name.clone(), path.to_string()));
    }
    Ok(out)
}

/// The generated client struct's name — `serviceId` with non-alphanumerics
/// removed (`"Route 53"` -> `Route53`, `"Secrets Manager"` ->
/// `SecretsManager`), then reserved-word-escaped.
fn service_struct_name(meta: &AwsServiceMeta) -> String {
    let cleaned: String = meta
        .service_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect();
    let base = if cleaned.is_empty() {
        meta.service.clone()
    } else {
        cleaned
    };
    flatten(&[base])
}

fn shape_type<'j>(s: &'j JsonObject, name: &str) -> Result<&'j str, String> {
    s.get("type")
        .and_then(Json::as_str)
        .ok_or_else(|| format!("aws front-end: shape `{name}` has no `type`"))
}

fn member_shape_name(m: &Json, owner: &str) -> Result<String, String> {
    m.get("shape")
        .and_then(Json::as_str)
        .map(String::from)
        .ok_or_else(|| format!("aws front-end: a member of `{owner}` has no `shape`"))
}

fn flag(o: &JsonObject, key: &str) -> bool {
    o.get(key).and_then(Json::as_bool).unwrap_or(false)
}

fn str_of(o: &JsonObject, key: &str) -> Option<String> {
    o.get(key).and_then(Json::as_str).map(String::from)
}

fn num_of(o: &JsonObject, key: &str) -> Option<f64> {
    match o.get(key) {
        Some(Json::Number(n)) => Some(*n),
        _ => None,
    }
}

fn as_i64(v: &Json) -> Option<i64> {
    match v {
        Json::Number(n) => Some(*n as i64),
        _ => None,
    }
}

/// The `xmlNamespace` trait `v` of `what` (`None` when absent): the bare
/// URI string, or an object with a string `uri` and an optional string
/// `prefix`. Any other spelling is an error naming `what`, so a namespace
/// is never dropped from a document without notice.
fn xml_ns(v: Option<&Json>, what: &str) -> Result<Option<AwsXmlNamespace>, String> {
    let malformed = || {
        format!(
            "aws front-end: the `xmlNamespace` of {what} is neither a URI string nor an \
             object with a string `uri` and an optional string `prefix`"
        )
    };
    match v {
        None => Ok(None),
        Some(Json::Str(uri)) => Ok(Some(AwsXmlNamespace {
            prefix: String::new(),
            uri: uri.clone(),
        })),
        Some(o @ Json::Object(_)) => {
            let uri = o.get("uri").and_then(Json::as_str).ok_or_else(malformed)?;
            let prefix = match o.get("prefix") {
                None => "",
                Some(p) => p.as_str().ok_or_else(malformed)?,
            };
            Ok(Some(AwsXmlNamespace {
                prefix: prefix.to_string(),
                uri: uri.to_string(),
            }))
        }
        Some(_) => Err(malformed()),
    }
}

pub fn resolve_timestamp_format(
    explicit: Option<&str>,
    protocol: &str,
    location: AwsLocation,
) -> Result<AwsTimestampFormat, String> {
    if let Some(e) = explicit {
        return AwsTimestampFormat::parse(e)
            .ok_or_else(|| format!("aws front-end: unknown timestampFormat {e:?}"));
    }
    Ok(match location {
        AwsLocation::Header | AwsLocation::HeaderPrefix => AwsTimestampFormat::Rfc822,
        AwsLocation::QueryString | AwsLocation::Uri => AwsTimestampFormat::Iso8601,
        AwsLocation::Body | AwsLocation::StatusCode => match protocol {
            "json" | "rest-json" | "smithy-rpc-v2-cbor" => AwsTimestampFormat::UnixTimestamp,
            "rest-xml" | "query" | "ec2" => AwsTimestampFormat::Iso8601,
            other => {
                return Err(format!(
                    "aws front-end: no timestamp default for protocol {other:?}"
                ))
            }
        },
    })
}

pub fn parse_request_uri(
    uri: &str,
    op_name: &str,
) -> Result<(String, Vec<AwsPathParam>, Vec<(String, Option<String>)>), String> {
    if !uri.starts_with('/') {
        return Err(format!(
            "aws front-end: operation `{op_name}` requestUri {uri:?} is not absolute"
        ));
    }
    let (path, query) = match uri.split_once('?') {
        Some((p, q)) => (p.to_string(), Some(q)),
        None => (uri.to_string(), None),
    };
    let mut params = Vec::new();
    let mut rest = path.as_str();
    while let Some(open) = rest.find('{') {
        let after = &rest[open + 1..];
        let close = after.find('}').ok_or_else(|| {
            format!("aws front-end: operation `{op_name}` requestUri {uri:?} has an unclosed `{{`")
        })?;
        let raw = &after[..close];
        if raw.is_empty() {
            return Err(format!(
                "aws front-end: operation `{op_name}` requestUri {uri:?} has an empty `{{}}`"
            ));
        }
        let greedy = raw.ends_with('+');
        params.push(AwsPathParam {
            name: raw.trim_end_matches('+').to_string(),
            greedy,
        });
        rest = &after[close + 1..];
    }
    let mut static_query = Vec::new();
    if let Some(q) = query {
        for pair in q.split('&') {
            if pair.is_empty() {
                continue;
            }
            match pair.split_once('=') {
                Some((k, v)) => static_query.push((k.to_string(), Some(v.to_string()))),
                None => static_query.push((pair.to_string(), None)),
            }
        }
    }
    Ok((path, params, static_query))
}

pub fn snake_case(ident: &str) -> String {
    let chars: Vec<char> = ident.chars().collect();
    let mut out = String::with_capacity(ident.len() + 4);
    for (i, &c) in chars.iter().enumerate() {
        if c == '-' || c == ' ' || c == '.' {
            if !out.ends_with('_') && !out.is_empty() {
                out.push('_');
            }
            continue;
        }
        if c.is_ascii_uppercase() && i != 0 {
            let prev = chars[i - 1];
            let next_is_lower = chars.get(i + 1).is_some_and(|n| n.is_ascii_lowercase());
            if (prev.is_ascii_lowercase() || prev.is_ascii_digit())
                || (prev.is_ascii_uppercase() && next_is_lower)
            {
                if !out.ends_with('_') && !out.is_empty() {
                    out.push('_');
                }
            }
        }
        out.push(c.to_ascii_lowercase());
    }
    if out.starts_with(|c: char| c.is_ascii_digit()) {
        out.insert(0, '_');
    }
    out
}

fn enum_ident(wire: &str) -> String {
    let mut out = String::with_capacity(wire.len() + 1);
    for c in wire.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c);
        } else if !out.ends_with('_') {
            out.push('_');
        }
    }
    let out = out.trim_end_matches('_').to_string();
    let out = if out.is_empty() {
        "VALUE".to_string()
    } else {
        out
    };
    let out = if out.starts_with(|c: char| c.is_ascii_digit()) {
        format!("_{out}")
    } else {
        out
    };
    escape_member(&out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A one-operation awsJson model: `extra_meta` is merged into its
    /// metadata, `extra_op` into its one operation, and `member_shape` is the
    /// type of the input's one member.
    fn tiny_model(extra_meta: &str, extra_op: &str, member_shape: &str) -> Json {
        crate::json::parse(&format!(
            r#"{{"version": "2.0",
                "metadata": {{"apiVersion": "2026-10-01", "endpointPrefix": "tiny",
                    "jsonVersion": "1.0", "protocol": "json", "serviceFullName": "Tiny",
                    "serviceId": "Tiny", "signatureVersion": "v4",
                    "targetPrefix": "Tiny", "uid": "tiny-2026-10-01"{extra_meta}}},
                "operations": {{"Op": {{"name": "Op",
                    "http": {{"method": "POST", "requestUri": "/"}},
                    "input": {{"shape": "In"}}{extra_op}}}}},
                "shapes": {{"In": {{"type": "structure",
                                   "members": {{"M": {{"shape": "{member_shape}"}}}}}},
                           "Str": {{"type": "string"}},
                           "Doc": {{"type": "structure", "members": {{}}, "document": true}},
                           "Events": {{"type": "structure", "members": {{}}, "eventstream": true}},
                           "Stamps": {{"type": "list", "member": {{"shape": "StampMap"}}}},
                           "StampMap": {{"type": "map", "key": {{"shape": "Str"}},
                                        "value": {{"shape": "Stamp"}}}},
                           "Stamp": {{"type": "timestamp", "timestampFormat": "rfc822"}},
                           "Plain": {{"type": "structure", "members": {{}}, "exception": true}},
                           "Coded": {{"type": "structure", "members": {{}}, "exception": true,
                                     "error": {{"code": "Customized", "httpStatusCode": 402}}}},
                           "SameCode": {{"type": "structure", "members": {{}}, "exception": true,
                                       "error": {{"code": "SameCode", "httpStatusCode": 400}}}}}}}}"#
        ))
        .unwrap()
    }

    fn lower_tiny(model: &Json) -> Result<AwsLowering, String> {
        lower_aws_service(model, "tiny", &["Op".to_string()], "tiny.json", "aws.tiny")
    }

    fn refusal_of(model: &Json) -> Option<String> {
        let e = lower_tiny(model).err().expect("the model lowered");
        crate::aws_conformance::refusal_name(&e)
    }

    const QUERY_COMPATIBLE: &str = r#", "awsQueryCompatible": {}"#;

    #[test]
    fn the_tiny_model_lowers() {
        lower_tiny(&tiny_model("", "", "Str")).unwrap();
    }

    #[test]
    fn xml_namespace_is_a_string_or_a_uri_object_with_an_optional_prefix() {
        let ns = |src: &str| xml_ns(Some(&crate::json::parse(src).unwrap()), "x");
        let want = |prefix: &str, uri: &str| {
            Some(AwsXmlNamespace {
                prefix: prefix.to_string(),
                uri: uri.to_string(),
            })
        };
        assert_eq!(xml_ns(None, "x").unwrap(), None);
        assert_eq!(ns(r#""urn:a""#).unwrap(), want("", "urn:a"));
        assert_eq!(ns(r#"{"uri": "urn:a"}"#).unwrap(), want("", "urn:a"));
        assert_eq!(ns(r#"{"prefix": "p", "uri": "urn:a"}"#).unwrap(), want("p", "urn:a"));
        for bad in [r#"{"prefix": "p"}"#, r#"{"uri": 5}"#, r#"{"uri": "u", "prefix": 1}"#, "7"] {
            let e = ns(bad).unwrap_err();
            assert!(e.contains("the `xmlNamespace` of x is neither"), "{bad}: {e}");
        }
    }

    #[test]
    fn a_malformed_xml_namespace_is_refused_naming_where_it_is() {
        let e = lower_tiny(&tiny_model(r#", "xmlNamespace": {"prefix": "p"}"#, "", "Str"))
            .unwrap_err();
        assert!(e.contains("the `xmlNamespace` of the service metadata"), "{e}");
    }

    #[test]
    fn a_document_shape_is_a_named_refusal() {
        assert_eq!(refusal_of(&tiny_model("", "", "Doc")).as_deref(), Some("document"));
    }

    #[test]
    fn a_host_prefix_lowers_and_is_recorded() {
        let op = r#", "endpoint": {"hostPrefix": "data-"}"#;
        let lowering = lower_tiny(&tiny_model("", op, "Str")).unwrap();
        let facts = lowering.facts.operation("Op").unwrap();
        assert_eq!(facts.host_prefix.as_deref(), Some("data-"));
    }

    #[test]
    fn a_required_checksum_lowers_and_is_recorded() {
        // The front-end lowers it; whether the client can send the checksum
        // is the emitter's question (emit_aws `checksum-required`).
        for (op, required) in [
            (r#", "httpChecksumRequired": true"#, true),
            (r#", "httpChecksum": {"requestChecksumRequired": true}"#, true),
            (r#", "httpChecksumRequired": false"#, false),
            (
                r#", "httpChecksum": {"requestChecksumRequired": false, "requestAlgorithmMember": "M"}"#,
                false,
            ),
            ("", false),
        ] {
            let l = lower_tiny(&tiny_model("", op, "Str")).unwrap();
            let facts = l.facts.operation("Op").unwrap();
            assert_eq!(facts.request_checksum_required(), required, "{op}");
        }
    }

    #[test]
    fn an_event_stream_is_a_named_refusal() {
        assert_eq!(refusal_of(&tiny_model("", "", "Events")).as_deref(), Some("eventstream"));
    }

    /// The timestamp format recorded for the tiny model's member `M`.
    fn member_m_format(member_shape: &str) -> Option<AwsTimestampFormat> {
        let l = lower_tiny(&tiny_model("", "", member_shape)).unwrap();
        let (_, m) = l
            .facts
            .members()
            .find(|(_, m)| m.member_name == "M")
            .expect("member M");
        m.timestamp_format
    }

    #[test]
    fn a_container_of_timestamps_carries_its_leaf_format() {
        // A list of maps of rfc822 timestamps: the leaf's format.
        assert_eq!(member_m_format("Stamps"), Some(AwsTimestampFormat::Rfc822));
        assert_eq!(member_m_format("Str"), None);
    }

    #[test]
    fn a_query_compatible_custom_error_code_is_a_named_refusal() {
        let op = r#", "errors": [{"shape": "Plain"}, {"shape": "Coded"}]"#;
        assert_eq!(
            refusal_of(&tiny_model(QUERY_COMPATIBLE, op, "Str")).as_deref(),
            Some("aws-query-compatible")
        );
    }

    #[test]
    fn a_query_compatible_service_without_custom_codes_lowers() {
        // No errors, a plain one, and one whose code is its shape name: the
        // header and the body name the same code, so nothing is refused, and
        // the service is still marked query-compatible for the request side.
        for op in [
            "",
            r#", "errors": [{"shape": "Plain"}]"#,
            r#", "errors": [{"shape": "SameCode"}]"#,
        ] {
            let l = lower_tiny(&tiny_model(QUERY_COMPATIBLE, op, "Str")).unwrap();
            assert!(l.service.aws_query_compatible, "{op}");
        }
    }

    #[test]
    fn a_custom_error_code_outside_query_compatible_lowers() {
        let op = r#", "errors": [{"shape": "Coded"}]"#;
        lower_tiny(&tiny_model("", op, "Str")).unwrap();
    }

    #[test]
    fn endpoint_context_params_are_carried() {
        let op = r#", "staticContextParams": {"A": {"value": true}, "B": {"value": "x"}},
                     "operationContextParams": {"C": {"path": "M"}}"#;
        let mut m = tiny_model("", op, "Str");
        if let Json::Object(root) = &mut m {
            let ccp = crate::json::parse(r#"{"D": {"type": "Boolean"}}"#).unwrap();
            root.insert("clientContextParams".to_string(), ccp);
        }
        let l = lower_tiny(&m).unwrap();
        let f = l.facts.operation("Op").unwrap();
        assert_eq!(
            f.static_context_params,
            vec![
                ("A".to_string(), AwsStaticValue::Bool(true)),
                ("B".to_string(), AwsStaticValue::Str("x".to_string())),
            ]
        );
        assert_eq!(f.operation_context_params, vec![("C".to_string(), "M".to_string())]);
        assert_eq!(
            l.service.client_context_params,
            vec![AwsClientContextParam { name: "D".into(), ty: "boolean".into() }]
        );
    }

    #[test]
    fn a_static_context_param_of_another_kind_is_a_named_refusal() {
        let op = r#", "staticContextParams": {"A": {"value": ["x"]}}"#;
        assert_eq!(
            refusal_of(&tiny_model("", op, "Str")).as_deref(),
            Some("static-context-param")
        );
    }

    #[test]
    fn snake_case_breaks_on_acronym_boundaries() {
        assert_eq!(snake_case("HostedZoneId"), "hosted_zone_id");
        assert_eq!(snake_case("ListMFADevices"), "list_mfa_devices");
        assert_eq!(snake_case("SSEKMSKeyId"), "ssekms_key_id");
        assert_eq!(snake_case("ETag"), "e_tag");
        assert_eq!(snake_case("TTL"), "ttl");
        assert_eq!(snake_case("S3Bucket"), "s3_bucket");
        assert_eq!(snake_case("already_snake"), "already_snake");
    }

    #[test]
    fn enum_idents_are_valid_mojo() {
        assert_eq!(enum_ident("us-east-1"), "us_east_1");
        assert_eq!(enum_ident("PriceClass_100"), "PriceClass_100");
        assert_eq!(enum_ident("s3:ObjectCreated:*"), "s3_ObjectCreated");
        assert_eq!(enum_ident("AAAA"), "AAAA");
        // A value that sanitises to a Mojo reserved word is escaped.
        assert_eq!(enum_ident("String"), "String_");
    }

    #[test]
    fn request_uri_parses_greedy_and_static_query() {
        let (path, params, q) =
            parse_request_uri("/2013-04-01/hostedzone/{Id}/rrset/", "X").unwrap();
        assert_eq!(path, "/2013-04-01/hostedzone/{Id}/rrset/");
        assert_eq!(params, vec![AwsPathParam { name: "Id".into(), greedy: false }]);
        assert!(q.is_empty());

        let (_, params, q) = parse_request_uri("/{Bucket}/{Key+}?versioning", "X").unwrap();
        assert_eq!(params[1], AwsPathParam { name: "Key".into(), greedy: true });
        assert_eq!(q, vec![("versioning".to_string(), None)]);

        let (_, _, q) = parse_request_uri("/{Bucket}?list-type=2&x", "X").unwrap();
        assert_eq!(
            q,
            vec![
                ("list-type".to_string(), Some("2".to_string())),
                ("x".to_string(), None)
            ]
        );
        assert!(parse_request_uri("2013/x", "X").is_err());
    }

    #[test]
    fn timestamp_defaults_follow_protocol_and_location() {
        use AwsTimestampFormat as T;
        assert_eq!(
            resolve_timestamp_format(None, "json", AwsLocation::Body).unwrap(),
            T::UnixTimestamp
        );
        assert_eq!(
            resolve_timestamp_format(None, "rest-xml", AwsLocation::Body).unwrap(),
            T::Iso8601
        );
        assert_eq!(
            resolve_timestamp_format(None, "rest-json", AwsLocation::Header).unwrap(),
            T::Rfc822
        );
        assert_eq!(
            resolve_timestamp_format(None, "rest-json", AwsLocation::QueryString).unwrap(),
            T::Iso8601
        );
        // An explicit shape-level format always wins.
        assert_eq!(
            resolve_timestamp_format(Some("rfc822"), "json", AwsLocation::Body).unwrap(),
            T::Rfc822
        );
        assert!(resolve_timestamp_format(Some("nope"), "json", AwsLocation::Body).is_err());
    }
}
