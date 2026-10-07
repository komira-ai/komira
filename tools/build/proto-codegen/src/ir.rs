//! The protocol-neutral intermediate representation: what every front-end
//! (`.proto`, OpenAPI, AWS) produces and every emitter consumes.

use std::fmt::{self, Write as _};

/// The whole generated artifact — one model per plugin invocation.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct IrModel {
    pub files: Vec<IrFile>,
}

/// One generated `.mojo` file, lowered from one input `.proto`.
#[derive(Clone, Debug, PartialEq)]
pub struct IrFile {
    pub proto_path: String,
    /// The proto `package` declaration, e.g. `komira.cp.v1`.
    pub proto_package: String,
    /// The generated Mojo package namespace (the `package_prefix` opt).
    pub mojo_package: String,
    pub messages: Vec<IrMessage>,
    pub enums: Vec<IrEnum>,
    pub services: Vec<IrService>,
    pub imports: Vec<IrImport>,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct IrImport {
    /// The Mojo module to import from, e.g. `komira_wkt`.
    pub module: String,
    /// The symbol to import, e.g. `Timestamp`.
    pub symbol: String,
}

/// A message type — a struct in the generated Mojo.
#[derive(Clone, Debug, PartialEq)]
pub struct IrMessage {
    /// The proto-local simple name, e.g. `SupervisorHeartbeat`.
    pub name: String,
    pub mojo_name: String,
    pub fq_name: String,
    pub is_map_entry: bool,
    pub fields: Vec<IrField>,
    /// `oneof` declarations on this message.
    pub oneofs: Vec<IrOneof>,
}

/// One field of a message.
#[derive(Clone, Debug, PartialEq)]
pub struct IrField {
    /// The proto field name (snake_case), e.g. `job_id`.
    pub name: String,
    pub ty: IrType,
    pub label: Label,
    /// The protobuf wire field number. The protobuf-binary backend keys
    /// by this; the JSON backend ignores it.
    pub proto_field_number: u32,
    /// The proto3 JSON name (lowerCamelCase), e.g. `jobId`. The JSON
    /// backend keys by this; the protobuf-binary backend ignores it.
    pub json_name: String,
    /// `Some(index)` when this field is an arm of the message's
    /// `oneofs[index]`; `None` for a plain field. A `proto3_optional`
    /// field's synthetic single-field oneof is collapsed in LOWER, so a
    /// field with `Label::Optional` reports `oneof_index = None`.
    pub oneof_index: Option<u32>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Label {
    /// Implicit-presence scalar / message — a plain field.
    Single,
    /// `repeated T` — a `List[T]` in the generated struct.
    Repeated,
    /// proto3 `optional T` — an `Optional[T]` in the generated struct.
    Optional,
}

/// A field's type.
#[derive(Clone, Debug, PartialEq)]
pub enum IrType {
    Scalar(ScalarKind),
    /// A reference to a message type, by fully-qualified proto name.
    Message(TypeRef),
    /// A reference to an enum type, by fully-qualified proto name.
    Enum(TypeRef),
    Map(Box<IrType>, Box<IrType>),
    List(Box<IrType>),
}

pub const LIST_IS_AWS_FRONT_END_ONLY: &str =
    "IrType::List is constructed only by the AWS front-end (aws_in.rs), for a container \
     NESTED inside another container. The protobuf/OpenAPI/db emitters spell a repeated \
     field as Label::Repeated + the element type and never see this variant";

/// A reference to a named type, resolved during LOWER.
#[derive(Clone, Debug, PartialEq)]
pub struct TypeRef {
    pub fq_name: String,
    /// The resolved flat Mojo struct/enum name the emitter writes.
    pub mojo_name: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScalarKind {
    Double,
    Float,
    /// proto `int64` -> Mojo `Int64`, wire VARINT (plain 2's-complement).
    Int64,
    /// proto `uint64` -> Mojo `UInt64`, wire VARINT.
    Uint64,
    /// proto `int32` -> Mojo `Int32`, wire VARINT (plain, sign-extended).
    Int32,
    /// proto `uint32` -> Mojo `UInt32`, wire VARINT.
    Uint32,
    /// proto `sint64` -> Mojo `Int64`, wire VARINT (ZIGZAG-encoded).
    Sint64,
    /// proto `sint32` -> Mojo `Int32`, wire VARINT (ZIGZAG-encoded).
    Sint32,
    Fixed64,
    Fixed32,
    Sfixed64,
    Sfixed32,
    /// proto `bool` -> Mojo `Bool`.
    Bool,
    /// proto `string` -> Mojo `String`.
    String,
    /// proto `bytes` -> Mojo `List[UInt8]`.
    Bytes,
}

impl ScalarKind {
    /// The Mojo type name this scalar lowers to.
    pub fn mojo_type(self) -> &'static str {
        match self {
            ScalarKind::Double => "Float64",
            ScalarKind::Float => "Float32",
            ScalarKind::Int64 => "Int64",
            ScalarKind::Uint64 => "UInt64",
            ScalarKind::Int32 => "Int32",
            ScalarKind::Uint32 => "UInt32",
            ScalarKind::Sint64 => "Int64",
            ScalarKind::Sint32 => "Int32",
            ScalarKind::Fixed64 => "UInt64",
            ScalarKind::Fixed32 => "UInt32",
            ScalarKind::Sfixed64 => "Int64",
            ScalarKind::Sfixed32 => "Int32",
            ScalarKind::Bool => "Bool",
            ScalarKind::String => "String",
            ScalarKind::Bytes => "List[UInt8]",
        }
    }

    /// The `WireEncoder` primitive suffix — `write_<suffix>_field`.
    pub fn write_suffix(self) -> &'static str {
        match self {
            ScalarKind::Double => "f64",
            ScalarKind::Float => "f32",
            ScalarKind::Int64 => "i64",
            ScalarKind::Uint64 => "u64",
            ScalarKind::Int32 => "i32",
            ScalarKind::Uint32 => "u32",
            ScalarKind::Sint64 => "sint64",
            ScalarKind::Sint32 => "sint32",
            ScalarKind::Fixed64 => "fixed64",
            ScalarKind::Fixed32 => "fixed32",
            ScalarKind::Sfixed64 => "sfixed64",
            ScalarKind::Sfixed32 => "sfixed32",
            ScalarKind::Bool => "bool",
            ScalarKind::String => "string",
            ScalarKind::Bytes => "bytes",
        }
    }

    /// The `WireDecoder` accessor suffix — `read_<suffix>`.
    pub fn read_suffix(self) -> &'static str {
        // The read/write suffixes coincide for every scalar kind.
        self.write_suffix()
    }

    pub fn ir_token(self) -> &'static str {
        match self {
            ScalarKind::Double => "double",
            ScalarKind::Float => "float",
            ScalarKind::Int64 => "int64",
            ScalarKind::Uint64 => "uint64",
            ScalarKind::Int32 => "int32",
            ScalarKind::Uint32 => "uint32",
            ScalarKind::Sint64 => "sint64",
            ScalarKind::Sint32 => "sint32",
            ScalarKind::Fixed64 => "fixed64",
            ScalarKind::Fixed32 => "fixed32",
            ScalarKind::Sfixed64 => "sfixed64",
            ScalarKind::Sfixed32 => "sfixed32",
            ScalarKind::Bool => "bool",
            ScalarKind::String => "string",
            ScalarKind::Bytes => "bytes",
        }
    }
}

/// An enum type.
#[derive(Clone, Debug, PartialEq)]
pub struct IrEnum {
    /// The proto-local simple name.
    pub name: String,
    pub mojo_name: String,
    /// The fully-qualified proto name.
    pub fq_name: String,
    pub values: Vec<IrEnumValue>,
}

/// One `name = number` of an enum.
#[derive(Clone, Debug, PartialEq)]
pub struct IrEnumValue {
    /// The proto value name, e.g. `JOB_PHASE_PENDING`.
    pub name: String,
    /// The resolved Mojo alias name (reserved-word-escaped).
    pub mojo_name: String,
    pub number: i32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct IrOneof {
    /// The proto oneof name, e.g. `kind`.
    pub name: String,
    /// The arm field names, in declaration order. The discriminant value
    /// for arm `i` is `i + 1` (0 = unset).
    pub arms: Vec<String>,
}

/// A service — a set of RPC methods.
#[derive(Clone, Debug, PartialEq)]
pub struct IrService {
    pub name: String,
    pub methods: Vec<IrMethod>,
    /// The service's `(google.api.default_host)` option (`logging.googleapis.com`),
    /// recovered from the descriptor bytes (`service_options.rs`). `None` when
    /// the service declares none, and on every path that does not recover it
    /// (gRPC, db, OpenAPI, AWS). Read by the REST emitter: the generated
    /// client starts at this host, and with `None` it refuses to send until
    /// its caller names one.
    pub default_host: Option<String>,
    /// True when `default_host` is a service configuration's `name` that
    /// replaced a different (or absent) `(google.api.default_host)`
    /// ([`crate::service_config::ServiceConfig::apply`]); the REST emitter
    /// then names the configuration as the host's source.
    pub host_from_service_config: bool,
}

/// One RPC method.
#[derive(Clone, Debug, PartialEq)]
pub struct IrMethod {
    pub name: String,
    pub input: TypeRef,
    pub output: TypeRef,
    pub client_streaming: bool,
    pub server_streaming: bool,
    /// From the proto `idempotency_level` option — drives retry-safety.
    pub idempotent: bool,
    pub http_rule: Option<IrHttpRule>,
    /// The `(google.api.routing)` gRPC routing-header annotation — `Some`
    /// ONLY for methods that carry the extension; `None` otherwise.
    /// Populated in LOWER from the descriptor-set re-decode
    /// (`routing_options.rs`); read by the gRPC emitter (`emit.rs`) to emit
    /// the `x-goog-request-params` header build from the request message.
    pub routing_rule: Option<IrRoutingRule>,
}

/// A `(google.api.routing)` rule attached to a method — the ordered set of
/// routing parameters the gRPC emitter turns into an `x-goog-request-params`
/// header build. Each parameter reads a (possibly dotted) request field and
/// matches a path template against its value to extract one `key=value` pair;
/// the pairs join with `&` into the single header.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IrRoutingRule {
    pub parameters: Vec<IrRoutingParameter>,
}

/// One routing parameter — a (request field, path template) pair.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IrRoutingParameter {
    /// The request field to read, possibly dotted (`service.name`,
    /// `write_object_spec.resource.bucket`).
    pub field: String,
    /// The path template applied to the field's string value
    /// (`{bucket=**}`, `projects/*/locations/{location=*}`). Empty string
    /// means the whole field is the value and the key is the field name.
    pub path_template: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IrHttpRule {
    pub verb: String,
    /// The path template, e.g. `/v1/shelves/{shelf}/books/{book}`.
    pub path_template: String,
    /// The `body` designator: `"*"` (whole request is the JSON body),
    /// `""` (no body — every leaf field is path or query), or a single
    /// field name (that field is the body).
    pub body: String,
    /// The annotation's `additional_bindings`: further path forms of the
    /// same method, in declaration order, each with no bindings of its own.
    /// Empty for a rule with one form.
    pub additional_bindings: Vec<IrHttpRule>,
}


impl fmt::Display for IrModel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for file in &self.files {
            write!(f, "{file}")?;
        }
        Ok(())
    }
}

impl fmt::Display for IrFile {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "file {}", self.proto_path)?;
        writeln!(f, "  proto_package {}", self.proto_package)?;
        writeln!(f, "  mojo_package {}", self.mojo_package)?;
        for imp in &self.imports {
            writeln!(f, "  import {} from {}", imp.symbol, imp.module)?;
        }
        for e in &self.enums {
            write!(f, "{e}")?;
        }
        for m in &self.messages {
            write!(f, "{m}")?;
        }
        for s in &self.services {
            write!(f, "{s}")?;
        }
        Ok(())
    }
}

impl fmt::Display for IrEnum {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "  enum {} -> {}", self.name, self.mojo_name)?;
        for v in &self.values {
            writeln!(f, "    value {} = {} -> {}", v.name, v.number, v.mojo_name)?;
        }
        Ok(())
    }
}

impl fmt::Display for IrMessage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let kind = if self.is_map_entry { "map-entry message" } else { "message" };
        writeln!(f, "  {} {} -> {}", kind, self.name, self.mojo_name)?;
        for o in &self.oneofs {
            writeln!(f, "    oneof {} [{}]", o.name, o.arms.join(", "))?;
        }
        for fld in &self.fields {
            let mut line = String::new();
            let _ = write!(
                line,
                "    field {} #{} json={} {} {}",
                fld.name,
                fld.proto_field_number,
                fld.json_name,
                label_token(fld.label),
                type_token(&fld.ty),
            );
            if let Some(idx) = fld.oneof_index {
                let _ = write!(line, " oneof_index={idx}");
            }
            writeln!(f, "{line}")?;
        }
        Ok(())
    }
}

impl fmt::Display for IrService {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "  service {}", self.name)?;
        for m in &self.methods {
            writeln!(
                f,
                "    rpc {} ({}) -> ({}) client_stream={} server_stream={} idempotent={}",
                m.name,
                m.input.fq_name,
                m.output.fq_name,
                m.client_streaming,
                m.server_streaming,
                m.idempotent,
            )?;
            if let Some(h) = &m.http_rule {
                writeln!(
                    f,
                    "      http_rule {} {} body={}",
                    h.verb,
                    h.path_template,
                    if h.body.is_empty() { "<none>" } else { &h.body },
                )?;
                for b in &h.additional_bindings {
                    writeln!(
                        f,
                        "      additional_binding {} {} body={}",
                        b.verb,
                        b.path_template,
                        if b.body.is_empty() { "<none>" } else { &b.body },
                    )?;
                }
            }
            if let Some(r) = &m.routing_rule {
                for p in &r.parameters {
                    writeln!(
                        f,
                        "      routing_param {} template={}",
                        p.field,
                        if p.path_template.is_empty() {
                            "<whole-field>"
                        } else {
                            &p.path_template
                        },
                    )?;
                }
            }
        }
        Ok(())
    }
}

fn label_token(label: Label) -> &'static str {
    match label {
        Label::Single => "single",
        Label::Repeated => "repeated",
        Label::Optional => "optional",
    }
}

fn type_token(ty: &IrType) -> String {
    match ty {
        IrType::Scalar(s) => s.ir_token().to_string(),
        IrType::Message(r) => format!("message:{}", r.fq_name),
        IrType::Enum(r) => format!("enum:{}", r.fq_name),
        IrType::Map(k, v) => format!("map<{},{}>", type_token(k), type_token(v)),
        IrType::List(e) => format!("list<{}>", type_token(e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_dump_shows_every_additional_binding() {
        let rule = |verb: &str, path: &str, body: &str| IrHttpRule {
            verb: verb.into(),
            path_template: path.into(),
            body: body.into(),
            additional_bindings: vec![],
        };
        let mut main = rule("get", "/v1/{name=roles/*}", "");
        main.additional_bindings.push(rule("get", "/v1/{name=projects/*/roles/*}", ""));
        main.additional_bindings.push(rule("post", "/v1/{name=orgs/*}:x", "*"));
        let ty = TypeRef { fq_name: ".t.Req".into(), mojo_name: "Req".into() };
        let svc = IrService {
            name: "S".into(),
            default_host: None,
            host_from_service_config: false,
            methods: vec![IrMethod {
                name: "M".into(),
                input: ty.clone(),
                output: ty,
                client_streaming: false,
                server_streaming: false,
                idempotent: false,
                http_rule: Some(main),
                routing_rule: None,
            }],
        };
        let dump = svc.to_string();
        assert!(dump.contains(
            "      http_rule get /v1/{name=roles/*} body=<none>\n\
             \x20     additional_binding get /v1/{name=projects/*/roles/*} body=<none>\n\
             \x20     additional_binding post /v1/{name=orgs/*}:x body=*\n"
        ), "{dump}");
    }
}
