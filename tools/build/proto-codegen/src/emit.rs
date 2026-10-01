//! The Mojo emitter: one `Emitter` per generated `.mojo` file, writing
//! messages, enums, their encode/decode bodies and the service clients
//! programmatically. The same inputs produce byte-identical output.

use std::collections::BTreeSet;
use std::fmt::Write as _;

use crate::ir::*;
use crate::lower::recursion_breaking_edges;
use crate::ProtocolMode;

const TRIVIAL_REGISTER_STORAGE_TYPES: &[&str] = &[
    "Bool", "Float32", "Float64", "Int32", "Int64", "UInt32", "UInt64",
];

/// The `write_<suffix>_field` / element suffix for a map key/value `IrType`.
/// proto map keys are integral/bool/string; values may be scalar, enum, OR a
/// message (`map<string, M>` — common in googleapis surfaces, e.g. GCS
/// `ObjectCustomContextPayload`). The suffix names the typed
/// `write_*`/`read_into_*` primitive the generated map body routes through
/// (see `komira_serde` `WireEncoder`/`WireDecoder`). A message value routes
/// through `write_message_field[V]` / `read_into_*_message_map[V]`, which are
/// PARAMETRIC on the value type — `map_scalar_write_suffix` is only called for
/// the suffix-keyed scalar/enum primitives, so a message value returns the
/// `"message"` token and the emit body special-cases it (never calling a
/// nonexistent `write_message_field` suffix form).
fn map_scalar_write_suffix(t: &IrType) -> &'static str {
    match t {
        IrType::Scalar(s) => s.write_suffix(),
        // A proto enum map value encodes as its int32 — route via i32.
        IrType::Enum(_) => "i32",
        // A message map value routes through the parametric
        // `write_message_field[V]` / `read_into_*_message_map[V]`.
        IrType::Message(_) => "message",
        IrType::Map(_, _) => unreachable!("a map cannot key/value into a map"),
        IrType::List(_) => unreachable!("{}", crate::ir::LIST_IS_AWS_FRONT_END_ONLY),
    }
}

/// The `read_into_<suffix>_<suffix>_map` component suffix for a map key/value.
fn map_scalar_read_suffix(t: &IrType) -> &'static str {
    // read/write suffixes coincide for every scalar kind.
    map_scalar_write_suffix(t)
}

/// How a routing field path resolves to a Mojo access expression.
enum FieldAccess {
    /// A flat scalar field — `req.<field>`, read unconditionally.
    Direct(String),
    /// A dotted path through Optional message intermediates. `guards` are the
    /// presence expressions (`req.service`, `req.service.value().resource`,
    /// ...) checked in order; `leaf` is the final scalar access read only when
    /// every guard is present.
    Guarded { guards: Vec<String>, leaf: String },
}

/// The `x-goog-request-params` header KEY for a routing parameter. When the
/// template carries a `{key=subpattern}` named capture, the key is `key`.
/// When the template is empty (the whole-field fallback) OR carries no named
/// capture, the key defaults to the LEAF field name (the last dotted
/// component) — the `google.api.routing` spec's `{field=**}` shorthand.
fn routing_param_key(field: &str, path_template: &str) -> String {
    if let Some(name) = named_capture_key(path_template) {
        return name;
    }
    // Fallback: the leaf component of the (possibly dotted) field name.
    field.rsplit('.').next().unwrap_or(field).to_string()
}

/// Extract the `key` from a template's single `{key=subpattern}` named
/// capture, or `None` if the template has no `{...=...}` binding.
fn named_capture_key(path_template: &str) -> Option<String> {
    let open = path_template.find('{')?;
    let close = path_template[open..].find('}')? + open;
    let inner = &path_template[open + 1..close];
    let eq = inner.find('=')?;
    Some(inner[..eq].to_string())
}

/// A Mojo `String(...)` string literal for `s`, escaping `\` and `"`. Routing
/// templates contain only `/ * { } = _ a-z`-class characters, so this is a
/// minimal-but-correct escaper.
fn mojo_str_lit(s: &str) -> String {
    let mut out = String::from("String(\"");
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            _ => out.push(c),
        }
    }
    out.push_str("\")");
    out
}

/// The programmatic Mojo emitter — one per generated `.mojo` file.
pub struct Emitter<'a> {
    file: &'a IrFile,
    buf: String,
    /// The current indentation depth, in 4-space units.
    indent: usize,
    boxed: BTreeSet<(String, String)>,
    protocol: ProtocolMode,
}

impl<'a> Emitter<'a> {
    /// Construct an emitter for `file` with the default (`Grpc`) protocol
    /// mode — the convenience form for the OpenAPI front-end and tests that
    /// do not vary the protocol. The `.proto` plugin path uses
    /// [`Emitter::with_protocol`] to thread the parsed `default_protocol`.
    pub fn new(file: &'a IrFile) -> Self {
        Self::with_protocol(file, ProtocolMode::default())
    }

    /// Construct an emitter for `file` emitting service clients for the
    /// given protocol `mode`.
    pub fn with_protocol(file: &'a IrFile, protocol: ProtocolMode) -> Self {
        Self {
            boxed: recursion_breaking_edges(file),
            file,
            buf: String::new(),
            indent: 0,
            protocol,
        }
    }

    /// Emit the whole file and return the generated Mojo source.
    pub fn emit(mut self) -> String {
        self.emit_header();
        for en in &self.file.enums {
            self.emit_enum(en);
        }
        for msg in &self.file.messages {
            if msg.is_map_entry {
                continue;
            }
            self.emit_message(msg);
        }
        if self.protocol == ProtocolMode::Rest && !self.file.services.is_empty() {
            // The module-level percent-encode / stringify helpers the REST
            // client bodies call.
            self.buf.push('\n');
            self.buf.push_str(crate::emit_rest::rest_helper_functions());
            for svc in &self.file.services {
                self.emit_rest_service_or_panic(svc);
            }
        } else {
            for svc in &self.file.services {
                self.emit_service(svc);
            }
        }
        self.buf
    }

    fn emit_rest_service_or_panic(&mut self, svc: &IrService) {
        match crate::emit_rest::emit_rest_service(self.file, svc) {
            Ok(emit) => {
                self.buf.push_str(&emit.source);
                // Validation notes (streaming methods skipped) — emitted as a
                // trailing comment block so they are visible in the output.
                for note in &emit.notes {
                    self.buf.push_str(&format!("# REST-NOTE: {note}\n"));
                }
            }
            Err(e) => panic!("REST emit failed for service `{}`: {e}", svc.name),
        }
    }

    // -- buffer primitives ---------------------------------------------

    /// Append one indented line (or a blank line for `""`).
    fn line(&mut self, text: &str) {
        if text.is_empty() {
            self.buf.push('\n');
            return;
        }
        for _ in 0..self.indent {
            self.buf.push_str("    ");
        }
        self.buf.push_str(text);
        self.buf.push('\n');
    }

    fn blank(&mut self) {
        self.buf.push('\n');
    }

    fn push_indent(&mut self) {
        self.indent += 1;
    }

    fn pop_indent(&mut self) {
        self.indent = self.indent.saturating_sub(1);
    }

    // -- file header ----------------------------------------------------

    fn emit_header(&mut self) {
        self.line("# GENERATED by protoc-gen-mojo — do not hand-edit.");
        self.line(&format!("# Source: {}", self.file.proto_path));
        self.line(&format!("# proto package: {}", self.file.proto_package));
        self.line(&format!("# Mojo package:  {}", self.file.mojo_package));
        self.line("#");
        self.line(
            "# Generated message structs conform to the komira_serde",
        );
        self.line(
            "# `Serializable` trait: encode[E: WireEncoder] / decode[D: WireDecoder].",
        );
        self.blank();
        if self.file.enums.is_empty() {
            self.line(
                "from komira_serde import Serializable, WireEncoder, WireDecoder",
            );
        } else {
            self.line(
                "from komira_serde import (",
            );
            self.line("    ProtoEnum,");
            self.line("    Serializable,");
            self.line("    WireEncoder,");
            self.line("    WireDecoder,");
            self.line(")");
        }
        if !self.file.services.is_empty() {
            if self.protocol == ProtocolMode::Rest {
                for imp in crate::emit_rest::rest_imports() {
                    self.line(imp);
                }
            } else {
                self.line(
                    "from komira_grpc import (",
                );
                self.line("    Protocol,");
                self.line("    CallOptions,");
                self.line("    GrpcClient,");
                self.line("    RetryPolicy,");
                self.line("    UnaryResult,");
                self.line("    ServerStreamDecoder,");
                self.line("    ClientStreamEncoder,");
                self.line("    BidiStreamCodec,");
                self.line(")");
                self.line(
                    "from komira_serde.proto_binary import PbEncoder, PbDecoder",
                );
                self.line(
                    "from komira_http.transport.io_stream import Connector",
                );
                self.line("from komira_async.reactor.reactor import Reactor");
                self.line(
                    "from komira_async.runtime.runtime_trait import Runtime",
                );
                self.line(
                    "from komira_async.cancellation.token import CancellationToken",
                );
                if self.file_has_routing_rule() {
                    self.line(
                        "from komira_grpc import build_routing_params, match_path_template",
                    );
                }
            }
        }
        for imp in &self.file.imports {
            self.buf.push_str(&format!(
                "from {} import {}\n",
                imp.module, imp.symbol
            ));
        }
        self.blank();
        self.blank();
    }

    // -- enum emission --------------------------------------------------

    fn emit_enum(&mut self, en: &IrEnum) {
        self.line(&format!("# proto enum {} ({})", en.name, en.fq_name));
        self.line("@fieldwise_init");
        self.line(&format!(
            "struct {}(ProtoEnum, Copyable, Movable, ImplicitlyCopyable):",
            en.mojo_name
        ));
        self.push_indent();
        self.line(&format!(
            "\"\"\"Generated enum wrapper for proto `{}`.\"\"\"",
            en.name
        ));
        self.blank();
        self.line("var value: Int");
        self.blank();
        for v in &en.values {
            self.line(&format!(
                "comptime {}: Int = {}",
                v.mojo_name, v.number
            ));
        }
        self.blank();
        self.line("def __eq__(self, other: Self) -> Bool:");
        self.push_indent();
        self.line("return self.value == other.value");
        self.pop_indent();
        self.blank();
        self.line("def __ne__(self, other: Self) -> Bool:");
        self.push_indent();
        self.line("return self.value != other.value");
        self.pop_indent();
        self.blank();
        // -- ProtoEnum: binary-wire number <-> JSON-wire NAME mapping ------
        self.line("def number(self) -> Int:");
        self.push_indent();
        self.line("\"\"\"The proto int32 value — the binary wire form.\"\"\"");
        self.line("return self.value");
        self.pop_indent();
        self.blank();
        self.line("def json_name(self) -> String:");
        self.push_indent();
        self.line(
            "\"\"\"The proto value NAME — the proto3-canonical-JSON form.\"\"\"",
        );
        // value -> NAME (the proto3-JSON canonical spelling is the proto
        // value name verbatim). An unmapped value renders as its decimal
        // number text (proto3-JSON renders an unknown enum value as the
        // number — the spec's "value not in the enum" fallback).
        let mut first = true;
        for v in &en.values {
            let kw = if first { "if" } else { "elif" };
            first = false;
            self.line(&format!("{kw} self.value == {}:", v.number));
            self.push_indent();
            self.line(&format!("return String(\"{}\")", v.name));
            self.pop_indent();
        }
        if first {
            // A proto enum always has at least one value (the zero value), so
            // this is unreachable in practice; keep the body valid.
            self.line("return String(self.value)");
        } else {
            self.line("return String(self.value)");
        }
        self.pop_indent();
        self.blank();
        self.line("@staticmethod");
        self.line("def from_number(n: Int) -> Self:");
        self.push_indent();
        self.line("\"\"\"Construct from the proto int32 value.\"\"\"");
        self.line("return Self(n)");
        self.pop_indent();
        self.blank();
        self.line("@staticmethod");
        self.line("def from_json_name(s: String) -> Self:");
        self.push_indent();
        self.line(
            "\"\"\"Construct from the proto value NAME (proto3-JSON input); an",
        );
        self.line(
            "unknown name maps to the zero value (proto3 unknown-enum contract).",
        );
        self.line("\"\"\"");
        // NAME -> value. proto3-JSON also permits the integer form as a
        // STRING on input (rare), but the canonical input is the NAME; an
        // unknown name falls through to the zero value.
        for v in &en.values {
            self.line(&format!("if s == \"{}\":", v.name));
            self.push_indent();
            self.line(&format!("return Self({})", v.number));
            self.pop_indent();
        }
        self.line("return Self(0)");
        self.pop_indent();
        self.blank();
        self.line("@staticmethod");
        self.line("def is_known_json_name(s: String) -> Bool:");
        self.push_indent();
        self.line(
            "\"\"\"True iff `s` is a DECLARED value name of this enum.\"\"\"",
        );
        for v in &en.values {
            self.line(&format!("if s == \"{}\":", v.name));
            self.push_indent();
            self.line("return True");
            self.pop_indent();
        }
        self.line("return False");
        self.pop_indent();
        self.blank();
        self.line("@staticmethod");
        self.line("def known_json_names() -> String:");
        self.push_indent();
        self.line(
            "\"\"\"The declared value names, comma-separated — the accepted",
        );
        self.line(
            "vocabulary, for a refusal that says what IS accepted. ERROR PATH",
        );
        self.line("ONLY: it allocates.");
        self.line("\"\"\"");
        self.line(&format!(
            "return String(\"{}\")",
            en.values
                .iter()
                .map(|v| v.name.clone())
                .collect::<Vec<_>>()
                .join(","),
        ));
        self.pop_indent();
        self.pop_indent();
        self.blank();
        self.blank();
    }

    // -- message emission -----------------------------------------------

    fn emit_message(&mut self, msg: &IrMessage) {
        self.line(&format!("# proto message {} ({})", msg.name, msg.fq_name));
        self.line("@fieldwise_init");
        self.line(&format!(
            "struct {}(Serializable, Copyable, Movable):",
            msg.mojo_name
        ));
        self.push_indent();
        self.line(&format!(
            "\"\"\"Generated message struct for proto `{}`.\"\"\"",
            msg.name
        ));
        self.blank();

        // -- fields ----------------------------------------------------
        for field in &msg.fields {
            // A field that is an arm of a real oneof is emitted by the
            // oneof block below, not here.
            if field.oneof_index.is_some() {
                continue;
            }
            let comment = format!("# field #{} `{}`", field.proto_field_number, field.name);
            self.line(&comment);
            self.line(&format!(
                "var {}: {}",
                field.name,
                self.field_storage_type(msg, field)
            ));
        }

        // -- oneof arms + discriminant ---------------------------------
        for (oi, oneof) in msg.oneofs.iter().enumerate() {
            self.line(&format!(
                "# oneof `{}`: 0 = unset, 1..N = the set arm",
                oneof.name
            ));
            self.line(&format!("var _oneof{oi}_case: Int"));
            for arm_name in &oneof.arms {
                if let Some(field) = msg.fields.iter().find(|f| &f.name == arm_name) {
                    self.line(&format!(
                        "var {}: {}",
                        field.name,
                        self.oneof_arm_storage_type(msg, field)
                    ));
                }
            }
        }

        self.blank();
        self.emit_explicit_deinit();
        self.blank();
        self.emit_encode(msg);
        self.blank();
        self.emit_decode(msg);
        self.pop_indent();
        self.blank();
        self.blank();
    }

    fn emit_explicit_deinit(&mut self) {
        self.line("# PORT(1.0.0): explicit destructor — 1.0.0's `Deinitable`");
        self.line("# synthesis is not co-inductive and its cycle guard caches a");
        self.line("# negative, so a recursive message cannot prove itself. Field");
        self.line("# destructors still run; ownership is unchanged.");
        self.line("def __deinit__(deinit self):");
        self.push_indent();
        self.line("pass");
        self.pop_indent();
    }

    fn is_boxed_edge(&self, msg: &IrMessage, field: &IrField) -> bool {
        matches!(field.ty, IrType::Message(_))
            && field.label != Label::Repeated
            && self
                .boxed
                .contains(&(msg.mojo_name.clone(), field.name.clone()))
    }

    /// The Mojo storage type of a ONEOF ARM.
    ///
    /// An arm carries no proto label — presence lives in the oneof's
    /// `_oneofN_case` discriminant — so the ordinary storage is
    /// `Optional[T]`. The ONE exception is a recursion-breaking edge, which
    /// must be the same `List[T]` box `field_storage_type` applies, or the
    /// struct is infinitely sized and cannot be laid out at all.
    ///
    /// This exists as its own function rather than as a call to
    /// `field_storage_type` because the two disagree on the non-boxed case:
    /// an arm's `Label` is `Single`, and `field_storage_type` would return a
    /// BARE `T` for it, dropping the presence wrapper every other site
    /// (`emit_encode_oneof_arm`, the decode accumulator) is written against.
    fn oneof_arm_storage_type(&self, msg: &IrMessage, field: &IrField) -> String {
        let base = self.scalar_or_named_type(msg, field);
        if self.is_boxed_edge(msg, field) {
            format!("List[{base}]")
        } else {
            format!("Optional[{base}]")
        }
    }

    fn field_storage_type(&self, msg: &IrMessage, field: &IrField) -> String {
        match &field.ty {
            IrType::Map(k, v) => {
                format!("Dict[{}, {}]", self.ir_type_name(k), self.ir_type_name(v))
            }
            _ => {
                let base = self.scalar_or_named_type(msg, field);
                if self.is_boxed_edge(msg, field) {
                    // Recursion-breaking edge — a `List[T]` (0 or 1 set).
                    return format!("List[{base}]");
                }
                match field.label {
                    Label::Single => base,
                    Label::Optional => format!("Optional[{base}]"),
                    Label::Repeated => format!("List[{base}]"),
                }
            }
        }
    }

    /// True if this field's decode ACCUMULATOR is a trivial register type,
    /// i.e. `<name>^` in the `return Self(...)` would be a no-op transfer the
    /// Mojo compiler warns about. Keyed on the full storage type — see
    /// `TRIVIAL_REGISTER_STORAGE_TYPES`.
    fn is_trivial_register_storage(&self, msg: &IrMessage, field: &IrField) -> bool {
        TRIVIAL_REGISTER_STORAGE_TYPES.contains(&self.field_storage_type(msg, field).as_str())
    }

    /// The base (label-stripped, map-stripped, box-stripped) Mojo type of
    /// a field — a scalar's Mojo type or an enum / message struct name.
    /// The `OwnedPointer` box is applied by `field_storage_type`, not here.
    fn scalar_or_named_type(&self, _msg: &IrMessage, field: &IrField) -> String {
        match &field.ty {
            IrType::Scalar(s) => s.mojo_type().to_string(),
            IrType::Enum(r) => r.mojo_name.clone(),
            IrType::Message(r) => r.mojo_name.clone(),
            IrType::Map(_, _) => unreachable!("map handled by field_storage_type"),
            IrType::List(_) => unreachable!("{}", crate::ir::LIST_IS_AWS_FRONT_END_ONLY),
        }
    }

    /// The Mojo type name of an `IrType` standing alone (a map key/value).
    fn ir_type_name(&self, ty: &IrType) -> String {
        match ty {
            IrType::Scalar(s) => s.mojo_type().to_string(),
            IrType::Enum(r) => r.mojo_name.clone(),
            IrType::Message(r) => r.mojo_name.clone(),
            IrType::Map(_, _) => "Dict".to_string(),
            IrType::List(_) => unreachable!("{}", crate::ir::LIST_IS_AWS_FRONT_END_ONLY),
        }
    }

    // -- the `encode` body ---------------------------------------------

    fn emit_encode(&mut self, msg: &IrMessage) {
        self.line("def encode[E: WireEncoder](self, mut enc: E) raises:");
        self.push_indent();
        self.line("\"\"\"Encode this message's fields into `enc`.\"\"\"");

        let mut emitted_any = false;

        for field in &msg.fields {
            if field.oneof_index.is_some() {
                continue;
            }
            emitted_any = true;
            let boxed = self.is_boxed_edge(msg, field);
            self.emit_encode_field(field, &format!("self.{}", field.name), boxed);
        }

        for (oi, oneof) in msg.oneofs.iter().enumerate() {
            emitted_any = true;
            for (arm_idx, arm_name) in oneof.arms.iter().enumerate() {
                let case = arm_idx + 1;
                let kw = if arm_idx == 0 { "if" } else { "elif" };
                self.line(&format!("{kw} self._oneof{oi}_case == {case}:"));
                self.push_indent();
                if let Some(field) = msg.fields.iter().find(|f| &f.name == arm_name) {
                    let boxed = self.is_boxed_edge(msg, field);
                    self.emit_encode_oneof_arm(field, boxed);
                }
                self.pop_indent();
            }
        }

        if !emitted_any {
            // An empty message — `encode` writes nothing. `pass` keeps the
            // body syntactically valid.
            self.line("pass");
        }
        self.pop_indent();
    }

    /// Emit the `enc.write_*` call(s) for one non-oneof field.
    /// `boxed` is true when the field is an `Optional[OwnedPointer[T]]`
    /// recursion edge.
    fn emit_encode_field(&mut self, field: &IrField, value_expr: &str, boxed: bool) {
        match &field.ty {
            IrType::Scalar(s) => {
                if field.label == Label::Repeated {
                    self.line(&format!(
                        "enc.begin_list_field({}, \"{}\")",
                        field.proto_field_number, field.json_name
                    ));
                    self.line(&format!("for i in range(len(self.{})):", field.name));
                    self.push_indent();
                    self.line(&format!(
                        "enc.write_{}_element({}, self.{}[i])",
                        s.write_suffix(),
                        field.proto_field_number,
                        field.name,
                    ));
                    self.pop_indent();
                    self.line("enc.end_list_field()");
                } else if field.label == Label::Optional {
                    self.line(&format!("if self.{}:", field.name));
                    self.push_indent();
                    self.line(&self.write_call(
                        s,
                        field,
                        &format!("self.{}.value()", field.name),
                    ));
                    self.pop_indent();
                } else {
                    self.line(&self.write_call(s, field, value_expr));
                }
            }
            IrType::Enum(r) => {
                let en = &r.mojo_name;
                if field.label == Label::Repeated {
                    self.line(&format!(
                        "enc.begin_list_field({}, \"{}\")",
                        field.proto_field_number, field.json_name
                    ));
                    self.line(&format!("for i in range(len(self.{})):", field.name));
                    self.push_indent();
                    self.line(&format!(
                        "enc.write_enum_element[{}]({}, self.{}[i])",
                        en, field.proto_field_number, field.name
                    ));
                    self.pop_indent();
                    self.line("enc.end_list_field()");
                } else if field.label == Label::Optional {
                    self.line(&format!("if self.{}:", field.name));
                    self.push_indent();
                    self.line(&format!(
                        "enc.write_enum_field[{}]({}, \"{}\", self.{}.value())",
                        en, field.proto_field_number, field.json_name, field.name
                    ));
                    self.pop_indent();
                } else {
                    self.line(&format!(
                        "enc.write_enum_field[{}]({}, \"{}\", {})",
                        en, field.proto_field_number, field.json_name, value_expr
                    ));
                }
            }
            IrType::Message(r) => {
                if boxed {
                    // Recursion edge — a `List[T]` holding 0 or 1. Iterate
                    // it (the 0-element case writes nothing — an unset
                    // recursive child).
                    self.line(&format!("for i in range(len(self.{})):", field.name));
                    self.push_indent();
                    self.line(&format!(
                        "enc.write_message_field[{}]({}, \"{}\", self.{}[i])",
                        r.mojo_name,
                        field.proto_field_number,
                        field.json_name,
                        field.name
                    ));
                    self.pop_indent();
                } else if field.label == Label::Repeated {
                    self.line(&format!(
                        "enc.begin_list_field({}, \"{}\")",
                        field.proto_field_number, field.json_name
                    ));
                    self.line(&format!("for i in range(len(self.{})):", field.name));
                    self.push_indent();
                    self.line(&format!(
                        "enc.write_message_element[{}]({}, self.{}[i])",
                        r.mojo_name,
                        field.proto_field_number,
                        field.name
                    ));
                    self.pop_indent();
                    self.line("enc.end_list_field()");
                } else if field.label == Label::Optional {
                    self.line(&format!("if self.{}:", field.name));
                    self.push_indent();
                    self.line(&format!(
                        "enc.write_message_field[{}]({}, \"{}\", self.{}.value())",
                        r.mojo_name,
                        field.proto_field_number,
                        field.json_name,
                        field.name
                    ));
                    self.pop_indent();
                } else {
                    self.line(&format!(
                        "enc.write_message_field[{}]({}, \"{}\", {})",
                        r.mojo_name,
                        field.proto_field_number,
                        field.json_name,
                        value_expr
                    ));
                }
            }
            IrType::Map(k, v) => {
                let ksuf = map_scalar_write_suffix(k);
                self.line(&format!(
                    "enc.begin_map_field({}, \"{}\")",
                    field.proto_field_number, field.json_name
                ));
                self.line(&format!("for entry in self.{}.items():", field.name));
                self.push_indent();
                self.line("enc.begin_map_entry()");
                self.line(&format!(
                    "enc.write_{ksuf}_field(1, \"key\", entry.key)"
                ));
                // The value primitive depends on the value type. A message
                // value routes through the parametric `write_message_field[V]`
                // (the map entry's value field number is 2); a scalar / enum
                // value routes through the suffix-keyed `write_<suf>_field`.
                match v.as_ref() {
                    IrType::Message(r) => self.line(&format!(
                        "enc.write_message_field[{}](2, \"value\", entry.value)",
                        r.mojo_name
                    )),
                    _ => {
                        let vsuf = map_scalar_write_suffix(v);
                        self.line(&format!(
                            "enc.write_{vsuf}_field(2, \"value\", entry.value)"
                        ));
                    }
                }
                self.line("enc.end_map_entry()");
                self.pop_indent();
                self.line("enc.end_map_field()");
            }
            IrType::List(_) => unreachable!("{}", crate::ir::LIST_IS_AWS_FRONT_END_ONLY),
        }
    }

    /// Emit the `enc.write_*` call for one oneof arm, guarded by the caller's
    /// `_oneofN_case` check.
    ///
    /// The arm value is `self.<arm>.value()` for the ordinary `Optional[T]`
    /// arm and `self.<arm>[0]` for a recursion-breaking arm, whose storage is
    /// the `List[T]` box. `_oneofN_case` being set is what guarantees the box
    /// is non-empty, exactly as it guarantees the `Optional` is populated.
    fn emit_encode_oneof_arm(&mut self, field: &IrField, boxed: bool) {
        let v = if boxed {
            format!("self.{}[0]", field.name)
        } else {
            format!("self.{}.value()", field.name)
        };
        match &field.ty {
            IrType::Scalar(s) => {
                self.line(&self.write_call(s, field, &v));
            }
            IrType::Enum(r) => {
                self.line(&format!(
                    "enc.write_enum_field[{}]({}, \"{}\", {})",
                    r.mojo_name, field.proto_field_number, field.json_name, v
                ));
            }
            IrType::Message(r) => {
                self.line(&format!(
                    "enc.write_message_field[{}]({}, \"{}\", {})",
                    r.mojo_name, field.proto_field_number, field.json_name, v
                ));
            }
            IrType::Map(_, _) => {
                // proto disallows a `map` arm of a oneof — unreachable.
                self.line("pass  # map oneof arm is not valid proto");
            }
            IrType::List(_) => unreachable!("{}", crate::ir::LIST_IS_AWS_FRONT_END_ONLY),
        }
    }

    /// Build a scalar `enc.write_<suffix>_field(...)` call expression.
    fn write_call(&self, s: &ScalarKind, field: &IrField, value_expr: &str) -> String {
        format!(
            "enc.write_{}_field({}, \"{}\", {})",
            s.write_suffix(),
            field.proto_field_number,
            field.json_name,
            value_expr
        )
    }

    // -- the accepted-key vocabulary ------------------------------------

    fn accepted_field_spellings(msg: &IrMessage) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for field in &msg.fields {
            if field.name != field.json_name {
                out.push(format!("{}|{}", field.json_name, field.name));
            } else {
                // A field already spelled lowerCamel is a ONE-member group.
                out.push(field.json_name.clone());
            }
        }
        out
    }

    /// One field's decode-loop match condition, covering both backends and
    /// both accepted JSON spellings.
    fn field_match_condition(field: &IrField) -> String {
        let mut cond = format!(
            "_pb_field.field_no == {} or _pb_field.json_name == \"{}\"",
            field.proto_field_number, field.json_name
        );
        if field.name != field.json_name {
            let _ = write!(cond, " or _pb_field.json_name == \"{}\"", field.name);
        }
        cond
    }

    fn assert_field_spellings_are_injective(msg: &IrMessage) {
        let mut seen: Vec<(String, String)> = Vec::new();
        for field in &msg.fields {
            let mut spellings = vec![field.json_name.clone()];
            if field.name != field.json_name {
                spellings.push(field.name.clone());
            }
            for sp in spellings {
                if let Some((owner, _)) =
                    seen.iter().find(|(_, s)| *s == sp)
                {
                    if owner != &field.name {
                        panic!(
                            "proto3-JSON key collision in message {}: the \
                             spelling {sp:?} is accepted for BOTH field {:?} \
                             and field {:?}. One JSON key cannot mean two \
                             fields; rename one or give it an explicit \
                             json_name.",
                            msg.fq_name, owner, field.name
                        );
                    }
                }
                seen.push((field.name.clone(), sp));
            }
        }
    }

    // -- the `decode` body ---------------------------------------------

    fn emit_decode(&mut self, msg: &IrMessage) {
        Self::assert_field_spellings_are_injective(msg);
        self.line("@staticmethod");
        self.line("def decode[D: WireDecoder](mut dec: D) raises -> Self:");
        self.push_indent();
        self.line("\"\"\"Decode a fresh Self from `dec`.\"\"\"");
        // Declare the accepted key vocabulary BEFORE the loop. The JSON
        // backend validates every key of the object against it — including
        // a `null`-valued one, which `next_field()` legitimately skips and
        // the loop below therefore never sees. The binary backend ignores
        // it (a wire that transmits no names has no use for a name list).
        self.line(&format!(
            "dec.expect_fields(\"{}\", \"{}\")",
            // `fq_name` carries protoc's leading dot (`.pkg.Msg`); a
            // diagnostic reads better without it and the dot means nothing
            // to the person holding the document.
            msg.fq_name.trim_start_matches('.'),
            Self::accepted_field_spellings(msg).join(","),
        ));

        // Local accumulators, default-initialised. The struct is built
        // from these once the field loop is exhausted.
        for field in &msg.fields {
            if field.oneof_index.is_some() {
                continue;
            }
            self.line(&format!(
                "var {}: {} = {}",
                field.name,
                self.field_storage_type(msg, field),
                self.default_expr(msg, field),
            ));
        }
        for (oi, oneof) in msg.oneofs.iter().enumerate() {
            self.line(&format!("var _oneof{oi}_case: Int = 0"));
            for arm_name in &oneof.arms {
                if let Some(field) = msg.fields.iter().find(|f| &f.name == arm_name) {
                    // The accumulator's type must match the field's DECLARED
                    // storage: a recursion-breaking arm accumulates into the
                    // same `List[T]` box it is stored in.
                    let init = if self.is_boxed_edge(msg, field) {
                        format!("List[{}]()", self.scalar_or_named_type(msg, field))
                    } else {
                        "None".to_string()
                    };
                    self.line(&format!(
                        "var {}: {} = {}",
                        field.name,
                        self.oneof_arm_storage_type(msg, field),
                        init
                    ));
                }
            }
        }

        self.line("while True:");
        self.push_indent();
        self.line("var _pb_field = dec.next_field()");
        self.line("if _pb_field.end:");
        self.push_indent();
        self.line("break");
        self.pop_indent();

        let mut first = true;
        // non-oneof fields
        for field in &msg.fields {
            if field.oneof_index.is_some() {
                continue;
            }
            let kw = if first { "if" } else { "elif" };
            first = false;
            self.line(&format!(
                "{} {}:",
                kw,
                Self::field_match_condition(field)
            ));
            self.push_indent();
            self.emit_decode_field(msg, field, &field.name);
            self.pop_indent();
        }
        // oneof arms
        for (oi, oneof) in msg.oneofs.iter().enumerate() {
            for (arm_idx, arm_name) in oneof.arms.iter().enumerate() {
                if let Some(field) = msg.fields.iter().find(|f| &f.name == arm_name) {
                    let kw = if first { "if" } else { "elif" };
                    first = false;
                    self.line(&format!(
                        "{} {}:",
                        kw,
                        Self::field_match_condition(field)
                    ));
                    self.push_indent();
                    let boxed = self.is_boxed_edge(msg, field);
                    self.emit_decode_oneof_arm(field, msg, oi, arm_idx + 1, boxed);
                    self.pop_indent();
                }
            }
        }
        // unknown field — skip-and-keep (proto3 forward-compat contract).
        if first {
            // No fields at all — every field is unknown.
            self.line("dec.skip()");
        } else {
            self.line("else:");
            self.push_indent();
            self.line("dec.skip()");
            self.pop_indent();
        }
        self.pop_indent(); // while

        // Build the struct from the accumulators.
        let mut ctor_args: Vec<String> = Vec::new();
        for field in &msg.fields {
            if field.oneof_index.is_some() {
                continue;
            }
            // A trivial-register accumulator (`Int32`, `Bool`, ...) is passed
            // BARE: `^` on it is a no-op the compiler warns about. Everything
            // else — `String`, `List`, `Dict`, `Optional`, enum/message structs
            // — keeps `^` so the accumulator is MOVED into the struct rather
            // than copied.
            if self.is_trivial_register_storage(msg, field) {
                ctor_args.push(field.name.clone());
            } else {
                ctor_args.push(format!("{}^", field.name));
            }
        }
        for (oi, oneof) in msg.oneofs.iter().enumerate() {
            ctor_args.push(format!("_oneof{oi}_case"));
            for arm_name in &oneof.arms {
                if msg.fields.iter().any(|f| &f.name == arm_name) {
                    ctor_args.push(format!("{arm_name}^"));
                }
            }
        }
        let mut ctor = String::new();
        let _ = write!(ctor, "return Self({})", ctor_args.join(", "));
        self.line(&ctor);
        self.pop_indent();
    }

    /// The default initialiser expression for a field's accumulator local.
    fn default_expr(&self, msg: &IrMessage, field: &IrField) -> String {
        // A recursion edge is a `List[T]` (0 or 1 elements) — its
        // accumulator default is an empty `List`, regardless of the label.
        if self.is_boxed_edge(msg, field) {
            return format!("List[{}]()", self.scalar_or_named_type(msg, field));
        }
        match &field.ty {
            IrType::Map(k, v) => {
                format!("Dict[{}, {}]()", self.ir_type_name(k), self.ir_type_name(v))
            }
            _ => match field.label {
                Label::Optional => "None".to_string(),
                Label::Repeated => {
                    format!("List[{}]()", self.scalar_or_named_type(msg, field))
                }
                Label::Single => self.scalar_default(msg, field),
            },
        }
    }

    /// The zero value of a `Single` field's base type.
    fn scalar_default(&self, msg: &IrMessage, field: &IrField) -> String {
        match &field.ty {
            IrType::Scalar(s) => match s {
                ScalarKind::Double | ScalarKind::Float => format!("{}(0.0)", s.mojo_type()),
                ScalarKind::Bool => "False".to_string(),
                ScalarKind::String => "String(\"\")".to_string(),
                ScalarKind::Bytes => "List[UInt8]()".to_string(),
                _ => format!("{}(0)", s.mojo_type()),
            },
            IrType::Enum(r) => format!("{}(0)", r.mojo_name),
            IrType::Message(_) => {
                // Unreachable: LOWER lowers every singular message field
                // to `Label::Optional` (proto3 message presence), so a
                // message field never reaches the `Single` default path.
                let _ = msg;
                unreachable!("singular message field is lowered to Optional")
            }
            IrType::Map(_, _) => unreachable!(),
            IrType::List(_) => unreachable!("{}", crate::ir::LIST_IS_AWS_FRONT_END_ONLY),
        }
    }

    /// Emit the read for one non-oneof field inside the decode loop.
    fn emit_decode_field(&mut self, msg: &IrMessage, field: &IrField, local: &str) {
        match &field.ty {
            IrType::Scalar(s) => {
                match field.label {
                    Label::Repeated => {
                        self.line(&format!(
                            "dec.read_into_repeated_{}({local})",
                            s.read_suffix(),
                        ));
                    }
                    Label::Optional => {
                        self.line(&format!("{local} = dec.read_{}()", s.read_suffix()));
                    }
                    Label::Single => {
                        self.line(&format!("{local} = dec.read_{}()", s.read_suffix()));
                    }
                }
            }
            IrType::Enum(r) => {
                // An enum decodes via the format-neutral `read_enum[En]`: the
                // binary backend reads the int32 varint and maps via
                // `from_number`; the proto3-JSON backend reads the value
                // (canonical NAME string -> `from_json_name`, integer ->
                // `from_number`). Symmetric with the `write_enum_*` encode.
                let en = &r.mojo_name;
                match field.label {
                    Label::Repeated => {
                        self.line(&format!(
                            "dec.read_into_repeated_enum[{en}]({local})"
                        ));
                    }
                    _ => self.line(&format!("{local} = dec.read_enum[{en}]()")),
                }
            }
            IrType::Message(r) => {
                let read = format!("dec.read_message[{}]()", r.mojo_name);
                if self.is_boxed_edge(msg, field) {
                    self.emit_singular_box_arity_guard(msg, field);
                    self.line(&format!("{local}.append({read})"));
                } else {
                    match field.label {
                        Label::Repeated => {
                            self.line(&format!(
                                "dec.read_into_repeated_message[{}]({local})",
                                r.mojo_name
                            ))
                        }
                        Label::Optional | Label::Single => {
                            self.line(&format!("{local} = {read}"))
                        }
                    }
                }
            }
            IrType::Map(k, v) => {
                let ksuf = map_scalar_read_suffix(k);
                // A message value routes through the parametric
                // `read_into_<ksuf>_message_map[V]`; a scalar / enum value
                // routes through the suffix-keyed `read_into_<ksuf>_<vsuf>_map`.
                match v.as_ref() {
                    IrType::Message(r) => self.line(&format!(
                        "dec.read_into_{ksuf}_message_map[{}]({local})",
                        r.mojo_name
                    )),
                    _ => {
                        let vsuf = map_scalar_read_suffix(v);
                        self.line(&format!(
                            "dec.read_into_{ksuf}_{vsuf}_map({local})"
                        ));
                    }
                }
            }
            IrType::List(_) => unreachable!("{}", crate::ir::LIST_IS_AWS_FRONT_END_ONLY),
        }
    }

    fn emit_decode_oneof_arm(
        &mut self,
        field: &IrField,
        msg: &IrMessage,
        oneof_idx: usize,
        case: usize,
        boxed: bool,
    ) {
        let read = match &field.ty {
            IrType::Scalar(s) => format!("dec.read_{}()", s.read_suffix()),
            IrType::Enum(r) => format!("dec.read_enum[{}]()", r.mojo_name),
            IrType::Message(r) => format!("dec.read_message[{}]()", r.mojo_name),
            IrType::Map(_, _) => "dec.read_string()".to_string(),
            IrType::List(_) => unreachable!("{}", crate::ir::LIST_IS_AWS_FRONT_END_ONLY),
        };
        if boxed {
            self.emit_singular_box_arity_guard(msg, field);
            self.line(&format!("{}.append({})", field.name, read));
        } else {
            self.line(&format!("{} = {}", field.name, read));
        }
        self.line(&format!("_oneof{oneof_idx}_case = {case}"));
    }

    /// Emit the arity guard for a recursion-boxed SINGULAR field: a second
    /// occurrence of the tag on the wire is a malformed message, not a second
    /// child. See `emit_decode_oneof_arm` for why this raises rather than
    /// picking a winner.
    fn emit_singular_box_arity_guard(&mut self, msg: &IrMessage, field: &IrField) {
        self.line(&format!("if len({}) != 0:", field.name));
        self.push_indent();
        self.line(&format!(
            "raise Error(\"{}.{}: a singular recursive field appeared more than\"",
            msg.mojo_name, field.name
        ));
        self.line("    + \" once on the wire; the message is malformed\")");
        self.pop_indent();
    }


    fn file_has_routing_rule(&self) -> bool {
        self.file.services.iter().any(|svc| {
            svc.methods
                .iter()
                .any(|m| m.routing_rule.is_some() && !m.client_streaming)
        })
    }

    fn message_by_fq(&self, fq_name: &str) -> Option<&'a IrMessage> {
        self.file.messages.iter().find(|m| m.fq_name == fq_name)
    }

    /// Emit the `(google.api.routing)` preamble: build the
    /// `x-goog-request-params` header from `req` and set it on `opts`.
    ///
    /// For each routing parameter, the generated code reads the (possibly
    /// dotted) request field, matches its value against the path template via
    /// the `match_path_template` runtime helper, and on a match pushes the
    /// `(key, captured)` pair. The pairs join + percent-encode via
    /// `build_routing_params`; the result, if non-empty, is set under
    /// `x-goog-request-params` on `opts.raw_metadata` (the RAW — un-prefixed —
    /// header path GCP's frontend matches).
    fn emit_routing_preamble(&mut self, m: &IrMethod) {
        let rule = m
            .routing_rule
            .as_ref()
            .expect("emit_routing_preamble called without a routing_rule");
        self.line(
            "# (google.api.routing) -> x-goog-request-params header build.",
        );
        self.line("var _routing_pairs = List[Tuple[StaticString, String]]()");
        let req_msg = self.message_by_fq(&m.input.fq_name);
        for (i, param) in rule.parameters.iter().enumerate() {
            self.emit_routing_param(i, param, req_msg);
        }
        self.line("var _routing_hdr = build_routing_params(_routing_pairs)");
        self.line("if _routing_hdr.byte_length() > 0:");
        self.push_indent();
        self.line(
            "opts.raw_metadata.set(String(\"x-goog-request-params\"), _routing_hdr)",
        );
        self.pop_indent();
    }

    /// Emit the code for ONE routing parameter — resolve its (possibly dotted)
    /// field access against the request message (None-guarding every Optional
    /// message intermediate), run the template match, and append the pair.
    fn emit_routing_param(
        &mut self,
        idx: usize,
        param: &IrRoutingParameter,
        req_msg: Option<&IrMessage>,
    ) {
        // The header key: the template's `{key=...}` named-capture name, or
        // the (leaf) field name for the whole-field fallback (empty template).
        let key = routing_param_key(&param.field, &param.path_template);
        // Mojo string literal for the template (escaped). Empty template = the
        // whole-field fallback (match_path_template returns the whole value).
        let template_lit = mojo_str_lit(&param.path_template);
        self.line(&format!(
            "# routing_param: field={} template={}",
            param.field,
            if param.path_template.is_empty() {
                "<whole-field>"
            } else {
                &param.path_template
            },
        ));
        // Resolve the field access expression + the presence guards.
        let access = self.resolve_field_access(&param.field, req_msg);
        let val = format!("_rv{idx}");
        let ok = format!("_rok{idx}");
        match access {
            FieldAccess::Direct(expr) => {
                // A flat scalar field — no None-guard needed; read directly.
                self.line(&format!("var {val} = {expr}"));
                self.line(&format!("var _rm{idx} = match_path_template({val}, {template_lit})"));
                self.line(&format!("if _rm{idx}:"));
                self.push_indent();
                self.line(&format!(
                    "_routing_pairs.append((StaticString(\"{key}\"), _rm{idx}.value()))"
                ));
                self.pop_indent();
            }
            FieldAccess::Guarded { guards, leaf } => {
                // A dotted path through Optional message intermediates. Emit a
                // nested presence check; the value is read only when every
                // intermediate is present.
                self.line(&format!("var {val} = String(\"\")"));
                self.line(&format!("var {ok} = False"));
                // Open the nested `if guard:` blocks.
                for guard in &guards {
                    self.line(&format!("if {guard}:"));
                    self.push_indent();
                }
                self.line(&format!("{val} = {leaf}"));
                self.line(&format!("{ok} = True"));
                for _ in &guards {
                    self.pop_indent();
                }
                self.line(&format!("if {ok}:"));
                self.push_indent();
                self.line(&format!(
                    "var _rm{idx} = match_path_template({val}, {template_lit})"
                ));
                self.line(&format!("if _rm{idx}:"));
                self.push_indent();
                self.line(&format!(
                    "_routing_pairs.append((StaticString(\"{key}\"), _rm{idx}.value()))"
                ));
                self.pop_indent();
                self.pop_indent();
            }
        }
    }

    /// Resolve a (possibly dotted) routing field path against the request
    /// message into a Mojo access expression. A flat scalar field is a
    /// `Direct` read (`req.<field>`); a dotted path walks Optional message
    /// intermediates, emitting a presence guard per `.value()` hop
    /// (`Guarded`). When the message type is not in this file (cross-file
    /// request type), the resolver falls back to a best-effort guarded access
    /// assuming each intermediate is an `Optional` message field.
    fn resolve_field_access(
        &self,
        field: &str,
        req_msg: Option<&IrMessage>,
    ) -> FieldAccess {
        let parts: Vec<&str> = field.split('.').collect();
        if parts.len() == 1 {
            // Flat field — `req.<field>`.
            return FieldAccess::Direct(format!("req.{}", parts[0]));
        }
        // Dotted — walk the message types. Each non-leaf hop is a singular
        // message field stored as `Optional[T]` (lower.rs), accessed via
        // `.value()` and guarded by its presence.
        let mut guards = Vec::new();
        let mut expr = String::from("req");
        let mut cur_msg = req_msg;
        for (i, part) in parts.iter().enumerate() {
            let is_leaf = i == parts.len() - 1;
            if is_leaf {
                // The leaf scalar — read straight off the (guarded) parent.
                expr = format!("{expr}.{part}");
            } else {
                // An intermediate message field: guard presence, then unwrap.
                guards.push(format!("{expr}.{part}"));
                expr = format!("{expr}.{part}.value()");
                // Advance the message cursor so the next hop resolves against
                // the right type (best-effort; cross-file types yield None and
                // the resolver keeps the same Optional-message assumption).
                cur_msg = cur_msg.and_then(|msg| {
                    msg.fields
                        .iter()
                        .find(|f| &f.name == part)
                        .and_then(|f| match &f.ty {
                            IrType::Message(r) => self.message_by_fq(&r.fq_name),
                            _ => None,
                        })
                });
            }
        }
        let _ = cur_msg;
        FieldAccess::Guarded { guards, leaf: expr }
    }

    fn emit_service(&mut self, svc: &IrService) {
        let struct_name = format!("{}Client", svc.name);
        self.blank();
        self.line(&format!(
            "# Service client for `{}.{}`. (PROTO-CODEGEN-M5)",
            self.file.proto_package, svc.name
        ));
        self.line(&format!(
            "struct {struct_name}[C: Connector, P: Protocol](",
        ));
        self.push_indent();
        self.line("Movable, Deinitable");
        self.pop_indent();
        self.line("):");
        self.push_indent();
        self.line(&format!("\"\"\"Generated gRPC client for service `{}`.\n", svc.name));
        self.line(&format!(
            "    Per proto_codegen_v04.md §5 + §9.1 PC-M5.",
        ));
        self.line(&format!(
            "    The full path for each method is `/{}.{}/<MethodName>`.",
            self.file.proto_package, svc.name,
        ));
        self.line("    \"\"\"");
        self.blank();
        self.line("var _client: GrpcClient[Self.C]");
        self.line("\"\"\"The gRPC transport substrate (wraps HttpClient[C] via OwnedPointer).\"\"\"");
        self.blank();
        self.line("def __init__(out self, var client: GrpcClient[Self.C]):");
        self.push_indent();
        self.line("self._client = client^");
        self.pop_indent();
        self.blank();
        for method in &svc.methods {
            self.emit_service_method(svc, method);
        }
        self.pop_indent();
    }

    fn emit_service_method(&mut self, svc: &IrService, m: &IrMethod) {
        debug_assert!(
            self.protocol != ProtocolMode::Rest,
            "REST methods are emitted by emit_rest_service, not emit_service_method"
        );
        // Method name in snake_case per `mojo_names::rpc_method_name`.
        let method_name = crate::mojo_names::rpc_method_name(&m.name);
        // The full RPC path the client sets on the HTTP request.
        let rpc_path = format!(
            "/{}.{}/{}",
            self.file.proto_package, svc.name, m.name
        );
        let req_ty = m.input.mojo_name.clone();
        let resp_ty = m.output.mojo_name.clone();
        let rt_args = "now_us: Int, mut reactor: Reactor[RT.Sink], \
                       ref token: CancellationToken";
        // The `(google.api.routing)` header is built from the typed `req`
        // message — so it can only be emitted for methods that HAVE a `req`
        // parameter: unary (false,false) and server-streaming (false,true).
        // A client-streaming / bidi method buffers its request into an
        // encoder (no `req` param), so codegen cannot read the routing field;
        // the caller hand-sets the header on those (e.g. the GCS WriteObject
        // wrapper). When routing IS emitted, `opts` is taken `var` (owned) so
        // the body can mutate it — callers already pass `opts^`.
        let emits_routing =
            m.routing_rule.is_some() && !m.client_streaming;
        let opts_decl = if emits_routing {
            "var opts: CallOptions"
        } else {
            "opts: CallOptions"
        };
        match (m.client_streaming, m.server_streaming) {
            (false, false) => {
                // ----- unary: 1 req -> 1 resp -----
                self.line(&format!(
                    "def {method_name}[RT: Runtime](mut self, req: {req_ty}, \
                     {opts_decl}, {rt_args}) raises -> {resp_ty}:"
                ));
                self.push_indent();
                self.line(&format!(
                    "\"\"\"Unary RPC — `{rpc_path}`.\"\"\""
                ));
                if emits_routing {
                    self.emit_routing_preamble(m);
                }
                // Encode the request message via the protobuf-binary wire.
                self.line("var enc = PbEncoder()");
                self.line("req.encode(enc)");
                self.line("var req_bytes = enc.into_buf()");
                let (retry_class, retry_reason) =
                    crate::retry_policy::derive_retry_class(m);
                self.line(&retry_class.rationale(retry_reason));
                self.line(&format!(
                    "var result = self._client.unary_call_retrying[RT, Self.P]("
                ));
                self.line(&format!("    String(\"{rpc_path}\"),"));
                self.line("    Span(req_bytes),");
                self.line("    opts,");
                self.line("    now_us,");
                self.line("    reactor,");
                self.line("    token,");
                self.line(&format!("    {},", retry_class.mojo_expr()));
                self.line(")");
                self.line("var resp_bytes = List[UInt8]()");
                self.line("swap(resp_bytes, result.message_bytes)");
                self.line("var dec = PbDecoder(resp_bytes^)");
                self.line(&format!("return {resp_ty}.decode(dec)"));
                self.pop_indent();
            }
            (false, true) => {
                // ----- server-streaming: 1 req -> N resp -----
                // Returns the loaded decoder; the caller drives
                // `decoder.try_next_message()` + decodes each message via
                // `{resp_ty}.decode(PbDecoder(bytes^))`.
                self.line(&format!(
                    "def {method_name}[RT: Runtime](mut self, req: {req_ty}, \
                     {opts_decl}, {rt_args}) raises \
                     -> ServerStreamDecoder[Self.P]:"
                ));
                self.push_indent();
                self.line(&format!(
                    "\"\"\"Server-streaming RPC — `{rpc_path}`.\n"
                ));
                self.line(&format!(
                    "    Returns a loaded ServerStreamDecoder[P]; drive \
                     `try_next_message()` and"
                ));
                self.line(&format!(
                    "    decode each message via `{resp_ty}.decode(PbDecoder(bytes^))`."
                ));
                self.line("    \"\"\"");
                if emits_routing {
                    self.emit_routing_preamble(m);
                }
                self.line("var enc = PbEncoder()");
                self.line("req.encode(enc)");
                self.line("var req_bytes = enc.into_buf()");
                self.line(
                    "return self._client.server_stream[RT, Self.P](",
                );
                self.line(&format!("    String(\"{rpc_path}\"),"));
                self.line("    Span(req_bytes),");
                self.line("    opts,");
                self.line("    now_us,");
                self.line("    reactor,");
                self.line("    token,");
                self.line(")");
                self.pop_indent();
            }
            (true, false) => {
                // ----- client-streaming: N req -> 1 resp -----
                // The caller buffers N requests into the encoder (via
                // `encoder.encode_message({resp_ty}-or-req bytes)` +
                // `encoder.mark_close()`) and passes it in.
                self.line(&format!(
                    "def {method_name}[RT: Runtime](mut self, \
                     var encoder: ClientStreamEncoder[Self.P], \
                     opts: CallOptions, {rt_args}) raises -> {resp_ty}:"
                ));
                self.push_indent();
                self.line(&format!(
                    "\"\"\"Client-streaming RPC — `{rpc_path}`.\n"
                ));
                self.line(
                    "    The caller buffers N request messages into \
                     `encoder` (each via",
                );
                self.line(&format!(
                    "    `enc = PbEncoder(); req.encode(enc); \
                     encoder.encode_message(Span(enc.into_buf()))`) then"
                ));
                self.line(
                    "    `encoder.mark_close()` before calling. Returns the \
                     single response.",
                );
                self.line("    \"\"\"");
                self.line(
                    "var result = self._client.client_stream[RT, Self.P](",
                );
                self.line(&format!("    String(\"{rpc_path}\"),"));
                self.line("    encoder^,");
                self.line("    opts,");
                self.line("    now_us,");
                self.line("    reactor,");
                self.line("    token,");
                self.line(")");
                self.line("var resp_bytes = List[UInt8]()");
                self.line("swap(resp_bytes, result.message_bytes)");
                self.line("var dec = PbDecoder(resp_bytes^)");
                self.line(&format!("return {resp_ty}.decode(dec)"));
                self.pop_indent();
            }
            (true, true) => {
                // ----- bidi: N req <-> N resp -----
                // The caller buffers N requests into `codec.encoder` +
                // `mark_close()`; returns the loaded response decoder.
                self.line(&format!(
                    "def {method_name}[RT: Runtime](mut self, \
                     var codec: BidiStreamCodec[Self.P], \
                     opts: CallOptions, {rt_args}) raises \
                     -> ServerStreamDecoder[Self.P]:"
                ));
                self.push_indent();
                self.line(&format!(
                    "\"\"\"Bidirectional RPC — `{rpc_path}`.\n"
                ));
                self.line(
                    "    The caller buffers N request messages into \
                     `codec.encoder` + `mark_close()`",
                );
                self.line(&format!(
                    "    before calling; returns the response decoder \
                     (decode each via `{resp_ty}.decode`)."
                ));
                self.line("    \"\"\"");
                self.line(
                    "return self._client.bidi_stream[RT, Self.P](",
                );
                self.line(&format!("    String(\"{rpc_path}\"),"));
                self.line("    codec^,");
                self.line("    opts,");
                self.line("    now_us,");
                self.line("    reactor,");
                self.line("    token,");
                self.line(")");
                self.pop_indent();
            }
        }
        self.blank();
    }
}

pub fn emit_model(model: &IrModel) -> Vec<(String, String)> {
    emit_model_with_protocol(model, ProtocolMode::default())
}

/// Emit the whole `IrModel`, emitting service clients for the given
/// protocol `mode` — one `CodeGeneratorResponse.File` per IR file.
pub fn emit_model_with_protocol(
    model: &IrModel,
    protocol: ProtocolMode,
) -> Vec<(String, String)> {
    model
        .files
        .iter()
        .map(|file| {
            let mojo_path = proto_to_mojo_path(&file.proto_path);
            let source = Emitter::with_protocol(file, protocol).emit();
            (mojo_path, source)
        })
        .collect()
}

pub fn proto_to_mojo_path(proto_path: &str) -> String {
    let basename = proto_path.rsplit('/').next().unwrap_or(proto_path);
    let stem = basename.rsplit_once('.').map(|(s, _)| s).unwrap_or(basename);
    format!("{stem}.mojo")
}

/// The module [`emit_layout_probe`] writes, beside the generated modules.
pub const LAYOUT_PROBE_FILE: &str = "_layout_probe.mojo";

/// The layout probe of `model`: a program that names every struct the
/// generated modules declare (each message and enum) in one `size_of`, and
/// prints the sizes. A generator that accepts a `.proto` does not prove the
/// emitted code lays out; compiling and running this does.
pub fn emit_layout_probe(model: &IrModel) -> (String, String) {
    let mut imports = String::new();
    let mut body = String::new();
    for file in &model.files {
        let stem = proto_to_mojo_path(&file.proto_path);
        let stem = stem.strip_suffix(".mojo").unwrap_or(&stem);
        imports.push_str(&format!("from {} import {stem}\n", file.mojo_package));
        let names = file
            .enums
            .iter()
            .map(|e| &e.mojo_name)
            .chain(file.messages.iter().filter(|m| !m.is_map_entry).map(|m| &m.mojo_name));
        for name in names {
            body.push_str(&format!(
                "    print(\"{stem}.{name}\", size_of[{stem}.{name}]())\n"
            ));
        }
    }
    if body.is_empty() {
        body.push_str("    pass\n");
    }
    let source = format!(
        "# GENERATED by protoc-gen-mojo — do not hand-edit.\n\
         # The layout probe: one size_of per struct of the generated modules.\n\
         \n\
         from std.sys import size_of\n\
         \n\
         {imports}\
         \n\
         \n\
         def main():\n\
         {body}"
    );
    (LAYOUT_PROBE_FILE.to_string(), source)
}

#[cfg(test)]
mod oneof_recursion_box_tests {
    use super::*;
    use crate::ir::{IrField, IrFile, IrMessage, IrOneof, IrType, Label, TypeRef};

    fn tref(name: &str) -> TypeRef {
        TypeRef {
            fq_name: format!(".ab.v1.{name}"),
            mojo_name: name.to_string(),
        }
    }

    fn msg_field(name: &str, target: &str, num: u32, oneof: Option<u32>) -> IrField {
        IrField {
            name: name.to_string(),
            ty: IrType::Message(tref(target)),
            label: Label::Optional,
            proto_field_number: num,
            json_name: name.to_string(),
            oneof_index: oneof,
        }
    }

    fn message(name: &str, fields: Vec<IrField>, oneofs: Vec<IrOneof>) -> IrMessage {
        IrMessage {
            name: name.to_string(),
            mojo_name: name.to_string(),
            fq_name: format!(".ab.v1.{name}"),
            is_map_entry: false,
            fields,
            oneofs,
        }
    }

    fn file(messages: Vec<IrMessage>) -> IrFile {
        IrFile {
            proto_path: "ab/v1/ab.proto".to_string(),
            proto_package: "ab.v1".to_string(),
            mojo_package: "ab".to_string(),
            messages,
            enums: vec![],
            services: vec![],
            imports: vec![],
        }
    }

    #[test]
    fn plain_field_recursion_edge_is_boxed() {
        let f = file(vec![
            message("Inner2", vec![msg_field("o", "Outer2", 1, None)], vec![]),
            message("Outer2", vec![msg_field("i", "Inner2", 1, None)], vec![]),
        ]);
        let out = Emitter::new(&f).emit();
        assert!(
            out.contains("var i: List[Inner2]"),
            "the plain-field break point must be boxed as List[T]; got:\n{out}"
        );
    }

    #[test]
    fn oneof_arm_recursion_edge_is_boxed() {
        let f = file(vec![
            message("Inner", vec![msg_field("o", "Outer", 1, None)], vec![]),
            message(
                "Outer",
                vec![msg_field("i", "Inner", 1, Some(0))],
                vec![IrOneof {
                    name: "n".to_string(),
                    arms: vec!["i".to_string()],
                }],
            ),
        ]);
        let out = Emitter::new(&f).emit();
        assert!(
            !out.contains("var i: Optional[Inner]"),
            "a recursion-breaking ONEOF ARM emitted as Optional[T] keeps the \
             size cycle alive — the struct cannot be laid out. Got:\n{out}"
        );
        assert!(
            out.contains("var i: List[Inner]"),
            "the oneof-arm break point must take the same List[T] box a plain \
             field takes; got:\n{out}"
        );
    }

    #[test]
    fn non_recursive_oneof_arm_stays_optional() {
        let f = file(vec![
            message("Leaf", vec![], vec![]),
            message("Inner", vec![msg_field("o", "Outer", 1, None)], vec![]),
            message(
                "Outer",
                vec![
                    msg_field("i", "Inner", 1, Some(0)),
                    msg_field("l", "Leaf", 2, Some(0)),
                ],
                vec![IrOneof {
                    name: "n".to_string(),
                    arms: vec!["i".to_string(), "l".to_string()],
                }],
            ),
        ]);
        let out = Emitter::new(&f).emit();
        assert!(
            out.contains("var l: Optional[Leaf]"),
            "a non-recursive oneof arm must stay Optional[T]; got:\n{out}"
        );
        assert!(
            out.contains("var i: List[Inner]"),
            "the recursive arm in the SAME oneof must still be boxed; got:\n{out}"
        );
    }

    #[test]
    fn boxed_oneof_arm_encode_and_decode_match_its_storage() {
        let f = file(vec![
            message("Inner", vec![msg_field("o", "Outer", 1, None)], vec![]),
            message(
                "Outer",
                vec![msg_field("i", "Inner", 1, Some(0))],
                vec![IrOneof {
                    name: "n".to_string(),
                    arms: vec!["i".to_string()],
                }],
            ),
        ]);
        let out = Emitter::new(&f).emit();
        assert!(
            out.contains("enc.write_message_field[Inner](1, \"i\", self.i[0])"),
            "a boxed arm encodes `self.<arm>[0]`, not `.value()`; got:\n{out}"
        );
        assert!(
            out.contains("var i: List[Inner] = List[Inner]()"),
            "the decode accumulator must be the box, not an Optional; got:\n{out}"
        );
        assert!(
            out.contains("i.append(dec.read_message[Inner]())"),
            "a boxed arm decodes by appending into the box; got:\n{out}"
        );
    }

    #[test]
    fn a_boxed_singular_field_refuses_a_second_occurrence() {
        let f = file(vec![
            message("Inner", vec![msg_field("o", "Outer", 1, None)], vec![]),
            message(
                "Outer",
                vec![msg_field("i", "Inner", 1, Some(0))],
                vec![IrOneof {
                    name: "n".to_string(),
                    arms: vec!["i".to_string()],
                }],
            ),
        ]);
        let out = Emitter::new(&f).emit();
        assert!(
            out.contains("if len(i) != 0:"),
            "a boxed singular field must guard against a second wire \
             occurrence; got:\n{out}"
        );
        assert!(
            out.contains("appeared more than"),
            "the guard must RAISE, naming the malformation; got:\n{out}"
        );

        let g = file(vec![
            message("Inner2", vec![msg_field("o", "Outer2", 1, None)], vec![]),
            message("Outer2", vec![msg_field("i", "Inner2", 1, None)], vec![]),
        ]);
        let out2 = Emitter::new(&g).emit();
        assert!(
            out2.contains("if len(i) != 0:"),
            "the plain-field box needs the same arity guard; got:\n{out2}"
        );
    }
}

#[cfg(test)]
mod mojo_100_service_client_tests {
    use super::*;
    use crate::ir::{IrFile, IrMessage, IrMethod, IrService, TypeRef};

    fn tref(name: &str) -> TypeRef {
        TypeRef {
            fq_name: format!(".svc.v1.{name}"),
            mojo_name: name.to_string(),
        }
    }

    fn empty_msg(name: &str) -> IrMessage {
        IrMessage {
            name: name.to_string(),
            mojo_name: name.to_string(),
            fq_name: format!(".svc.v1.{name}"),
            is_map_entry: false,
            fields: vec![],
            oneofs: vec![],
        }
    }

    /// One unary method — the minimum that makes `emit_service` run.
    fn file_with_service() -> IrFile {
        IrFile {
            proto_path: "svc/v1/svc.proto".to_string(),
            proto_package: "svc.v1".to_string(),
            mojo_package: "komira_rpc_storage".to_string(),
            messages: vec![empty_msg("Req"), empty_msg("Resp")],
            enums: vec![],
            services: vec![IrService {
                name: "Thing".to_string(),
                methods: vec![IrMethod {
                    name: "DoThing".to_string(),
                    input: tref("Req"),
                    output: tref("Resp"),
                    client_streaming: false,
                    server_streaming: false,
                    idempotent: false,
                    http_rule: None,
                    routing_rule: None,
                }],
            }],
            imports: vec![],
        }
    }

    #[test]
    fn the_service_client_conforms_to_deinitable_not_the_b2_name() {
        let out = Emitter::new(&file_with_service()).emit();
        assert!(
            out.contains("struct ThingClient[C: Connector, P: Protocol]("),
            "fixture must actually reach emit_service; got:\n{out}"
        );
        assert!(
            out.contains("Movable, Deinitable"),
            "the generated gRPC client must conform to 1.0.0's `Deinitable`; got:\n{out}"
        );
        assert!(
            !out.contains("ImplicitlyDestructible"),
            "`ImplicitlyDestructible` is the Mojo b2 spelling — 1.0.0 renamed it \
             `Deinitable` (76108ca55d, 5878 hand-written sites); got:\n{out}"
        );
    }

    #[test]
    fn every_message_struct_carries_the_explicit_destructor() {
        let out = Emitter::new(&file_with_service()).emit();
        let structs = out.matches("\nstruct ").count();
        let deinits = out.matches("def __deinit__(deinit self):").count();
        assert_eq!(
            structs, 3,
            "fixture shape changed (2 messages + 1 client); got:\n{out}"
        );
        assert_eq!(
            deinits, 2,
            "one destructor per MESSAGE struct, none on the client; got:\n{out}"
        );
    }
}
