//! The AWS client emitter: the IR plus the `aws_in` overlay, emitted as one
//! Mojo module per service.

use std::collections::{BTreeMap, BTreeSet};

use crate::aws_in::{AwsFacts, AwsLowering, AwsServiceMeta, AwsTimestampFormat};
use crate::ir::{IrEnum, IrField, IrMessage, IrType, Label, ScalarKind};
use crate::lower::{recursion_breaking_edges_under, ContainerInlining};
use crate::overrides::AwsOverrides;

/// Emitter options.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AwsEmitOptions {
    pub emit_model_json: bool,
    pub pure_only: bool,
    pub omit_preamble: bool,
}

/// The two protocols this emitter implements. Anything else is refused.
pub const SUPPORTED_PROTOCOLS: &[&str] = &["json"];

/// The `jsonVersion` values this emitter implements.
pub const SUPPORTED_JSON_VERSIONS: &[&str] = &["1.0", "1.1"];

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
    let meta = &lowering.service;
    if !SUPPORTED_PROTOCOLS.contains(&meta.protocol.as_str()) {
        return Err(format!(
            "emit_aws: service `{}` declares protocol `{}`, and this emitter \
             implements only {:?} (awsJson1_0 / awsJson1_1). It is REFUSED by name \
             rather than emitted half-right: a `{}` client emitted by a `json` \
             serializer produces requests that are syntactically valid and \
             semantically wrong, which is the failure mode a conformance corpus \
             catches late and a service catches never.",
            meta.service, meta.protocol, SUPPORTED_PROTOCOLS, meta.protocol
        ));
    }
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
    overrides.check_against(lowering)?;

    let mut em = AwsEmitter::new(lowering, overrides, module_name, json_version, options)?;
    let src = em.emit()?;
    Ok((format!("{module_name}.mojo"), src))
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
        json_version: String,
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
            json_version,
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
        if !self.options.omit_preamble {
            self.emit_header();
            self.emit_imports();
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
        if !self.options.pure_only {
            self.emit_client()?;
        }
        Ok(std::mem::take(&mut self.out))
    }

    fn emit_header(&mut self) {
        let proto_path = self.lowering.model.files[0].proto_path.clone();
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
        self.line(&format!(
            "#   protocol     : {} {} (targetPrefix `{}`)",
            self.meta.protocol,
            self.json_version,
            self.meta.target_prefix.clone().unwrap_or_default()
        ));
        self.line(&format!("#   model        : {}", proto_path));
        self.line(&format!("#   operations   : {}", ops.join(", ")));
        self.line(&format!(
            "#   shapes       : {} messages, {} enums",
            n_messages,
            n_enums
        ));
        self.line("#");
        self.line("# THE SIGNER AND THE CREDENTIAL CHAIN ARE NOT GENERATED. The transport");
        self.line("# call below goes to the shipped, AWS-test-vector-validated");
        self.line("# `komira_aws_relay.aws_relay_common.send_sigv4_signed_request`, which");
        self.line("# 14 hand-written clients already share. Nothing here signs.");
        self.line("#");
        if !self.validating.is_empty() {
            self.line("# ── §CONSTRAINTS — the model's `min` / `max`, checked ─────────────");
            self.line("#");
            self.line("# ⛔ `required` AND `non-empty` ARE DIFFERENT CLAIMS AND THE MODEL");
            self.line("# MAKES BOTH. A required member is taken positionally by `__init__`,");
            self.line("# which forces a caller to pass one and says nothing whatever about it");
            self.line("# being non-empty. `min` is where botocore says the second thing —");
            self.line("# `SecretIdType` is `{\"type\":\"string\",\"min\":1,\"max\":2048}` — and it");
            self.line("# was parsed by the front-end and read by nobody until the shapes");
            self.line("# below grew a `validate()`. Every bound here is READ FROM THE MODEL;");
            self.line("# none is a policy this generator invented.");
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
            self.line("# ⚠ `pattern` IS STILL DROPPED — 11 shapes across the six json");
            self.line("# clients carry one and this emitter has no regex. That is a stated");
            self.line("# gap, not an absence.");
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

    fn emit_imports(&mut self) {
        if !self.options.pure_only {
            self.line("from komira_aws_core.credentials import AwsCredential");
            self.line("from komira_aws_core.sigv4 import Header");
        }
        self.line("from komira_aws_wire.aws_wire import (");
        self.line("    AWS_TS_ISO8601,");
        self.line("    AWS_TS_RFC822,");
        self.line("    AWS_TS_UNIX,");
        self.line("    AwsRequest,");
        self.line("    aws_blob_from_json,");
        self.line("    aws_error_code,");
        self.line("    aws_error_code_from_body,");
        self.line("    aws_error_message_from_body,");
        self.line("    aws_is_error_status,");
        self.line("    aws_f64_from_json,");
        self.line("    aws_json_blob,");
        self.line("    aws_json_bool,");
        self.line("    aws_json_f32,");
        self.line("    aws_json_f64,");
        self.line("    aws_json_i32,");
        self.line("    aws_json_i64,");
        self.line("    aws_json_string,");
        self.line("    aws_ts_from_json,");
        self.line("    aws_ts_to_json,");
        self.line(")");
        self.line("from komira_serde.json_value import JsonValue, parse_json_value");
        if !self.options.pure_only {
            self.line("from komira_http.transport.io_stream import Connector");
            self.blank();
            self.line("from komira_aws_relay.aws_relay_common import (");
            self.line("    AwsEndpoint,");
            self.line("    HttpResult,");
            self.line("    resolve_endpoint,");
            self.line("    send_sigv4_signed_request,");
            self.line(")");
            self.line("from komira_aws_relay.aws_relay_creds import AwsCredsSource");
        }
        self.blank();
        self.blank();
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
        self.line(&format!(
            "comptime {p}_CONTENT_TYPE: String = \"application/x-amz-json-{}\"",
            self.json_version
        ));
        let target_prefix = self.meta.target_prefix.clone().unwrap_or_default();
        self.line(&format!(
            "comptime {p}_TARGET_PREFIX: String = \"{target_prefix}\""
        ));
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
        if is_union {
            self.line("    ⛔ THIS IS AN AWS `union` SHAPE — EXACTLY ONE member may be set.");
            self.line("    awsJson serialises a union as an object with a single key, so");
            self.line("    `to_aws_json` REFUSES a value with zero or two set members rather");
            self.line("    than emitting a body the service will reject with an error that");
            self.line("    names neither member.");
            self.blank();
        }
        if is_synthetic {
            self.line("    SYNTHESISED: the operation declares no shape here. awsJson still");
            self.line("    requires `{}` on the wire, which is what this empty struct emits.");
            self.blank();
        }
        self.line("    Required members are plain fields taken by `__init__`; every other");
        self.line("    member is `Optional[...]` and is OMITTED from the body when unset.");
        self.line("    PRESENCE IS NOT EMPTINESS: an explicitly-set empty list serialises as");
        self.line("    `[]` and an unset one is absent, which the corpus distinguishes");
        self.line("    (`serializes_empty_list_shapes`).\"\"\"");
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

        // -- to_aws_json ---------------------------------------------------
        self.emit_to_json(msg, is_union)?;
        self.blank();
        // -- from_aws_json -------------------------------------------------
        self.emit_from_json(msg)?;
        if self.options.emit_model_json {
            self.blank();
            self.emit_model_json(msg)?;
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

    fn emit_to_json(&mut self, msg: &IrMessage, is_union: bool) -> Result<(), String> {
        self.line("def to_aws_json(self) raises -> JsonValue:");
        self.push();
        self.line("\"\"\"This shape as an awsJson body fragment.\"\"\"");
        self.line("var obj = JsonValue.empty_object()");
        if is_union {
            self.line("var _set = 0");
            for f in &msg.fields {
                if self.required(msg, f) {
                    self.line("_set += 1");
                } else {
                    self.line(&format!("if {}:", self.presence_test(msg, f)));
                    self.push();
                    self.line("_set += 1");
                    self.pop();
                }
            }
            self.line("if _set != 1:");
            self.push();
            self.line("raise Error(");
            self.push();
            self.line(&format!(
                "String(\"{}.to_aws_json: an AWS `union` must have EXACTLY\")",
                self.ty_name(&msg.mojo_name)
            ));
            self.line("+ String(\" one member set; this value has \")");
            self.line("+ String(_set)");
            self.line("+ String(");
            self.push();
            self.line("\". awsJson renders a union as a single-key object, so a\"");
            self.line("\" zero- or two-member value has no wire form and the service\"");
            self.line("\" would answer with an error naming neither member.\"");
            self.pop();
            self.line(")");
            self.pop();
            self.line(")");
            self.pop();
        }
        for f in &msg.fields {
            let wire = self.wire_name(msg, f);
            if self.required(msg, f) {
                let access = if self.is_boxed(msg, f) {
                    format!("self.{}[0]", f.name)
                } else {
                    format!("self.{}", f.name)
                };
                let expr = self.to_json_expr(msg, f, &access, "obj", &wire)?;
                if let Some(e) = expr {
                    self.line(&format!(
                        "obj.set_member(String(\"{wire}\"), {e})"
                    ));
                }
            } else {
                self.line(&format!("if {}:", self.presence_test(msg, f)));
                self.push();
                let access = self.optional_access(msg, f);
                let expr = self.to_json_expr(msg, f, &access, "obj", &wire)?;
                if let Some(e) = expr {
                    self.line(&format!(
                        "obj.set_member(String(\"{wire}\"), {e})"
                    ));
                }
                self.pop();
            }
        }
        self.line("return obj^");
        self.pop();
        Ok(())
    }

    /// The expression that renders `access` as a `JsonValue`, or `None` when
    /// the emitter already wrote the statements (list / map need a loop).
    fn to_json_expr(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        access: &str,
        obj: &str,
        wire: &str,
    ) -> Result<Option<String>, String> {
        match (&f.label, &f.ty) {
            (Label::Repeated, ty) => {
                let tmp = format!("_a_{}", f.name);
                self.line(&format!("var {tmp} = JsonValue.empty_array()"));
                self.line(&format!("for _i in range(len({access})):"));
                self.push();
                let elem = self.value_to_json(msg, f, ty, &format!("{access}[_i]"), 1)?;
                self.line(&format!("{tmp}.push({elem})"));
                self.pop();
                self.line(&format!("{obj}.set_member(String(\"{wire}\"), {tmp}^)"));
                Ok(None)
            }
            (_, IrType::Map(_, v)) => {
                let tmp = format!("_m_{}", f.name);
                self.line(&format!("var {tmp} = JsonValue.empty_object()"));
                self.line(&format!("for _k in {access}.keys():"));
                self.push();
                let elem = self.value_to_json(msg, f, v, &format!("{access}[_k]"), 1)?;
                self.line(&format!("{tmp}.set_member(_k.copy(), {elem})"));
                self.pop();
                self.line(&format!("{obj}.set_member(String(\"{wire}\"), {tmp}^)"));
                Ok(None)
            }
            (_, ty) => Ok(Some(self.value_to_json(msg, f, ty, access, 1)?)),
        }
    }

    fn value_to_json(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        ty: &IrType,
        access: &str,
        depth: usize,
    ) -> Result<String, String> {
        match ty {
            IrType::List(e) => {
                let tmp = format!("_a{depth}_{}", f.name);
                let iv = format!("_i{depth}");
                self.line(&format!("var {tmp} = JsonValue.empty_array()"));
                self.line(&format!("for {iv} in range(len({access})):"));
                self.push();
                let elem =
                    self.value_to_json(msg, f, e, &format!("{access}[{iv}]"), depth + 1)?;
                self.line(&format!("{tmp}.push({elem})"));
                self.pop();
                Ok(format!("{tmp}^"))
            }
            IrType::Map(_, v) => {
                let tmp = format!("_m{depth}_{}", f.name);
                let kv = format!("_k{depth}");
                self.line(&format!("var {tmp} = JsonValue.empty_object()"));
                self.line(&format!("for {kv} in {access}.keys():"));
                self.push();
                let elem =
                    self.value_to_json(msg, f, v, &format!("{access}[{kv}]"), depth + 1)?;
                self.line(&format!("{tmp}.set_member({kv}.copy(), {elem})"));
                self.pop();
                Ok(format!("{tmp}^"))
            }
            other => self.scalar_to_json(msg, f, other, access),
        }
    }

    /// Render ONE value (not a container) as a `JsonValue` expression.
    fn scalar_to_json(
        &self,
        msg: &IrMessage,
        f: &IrField,
        ty: &IrType,
        access: &str,
    ) -> Result<String, String> {
        Ok(match ty {
            IrType::Message(_) => format!("{access}.to_aws_json()"),
            IrType::Enum(_) => format!("aws_json_string({access})"),
            // A container needs a LOOP, not an expression — `value_to_json`
            // takes those and calls back here for the leaf. Reaching this arm
            // means a caller bypassed it.
            IrType::Map(_, _) | IrType::List(_) => {
                return Err(format!(
                    "emit_aws: {}.{} reached `scalar_to_json` with a container type; \
                     `value_to_json` is the entry point that writes the loop.",
                    msg.name, f.name
                ))
            }
            IrType::Scalar(s) => match s {
                ScalarKind::String => {
                    if let Some(fmt) = self.timestamp_format(msg, f) {
                        format!("aws_ts_to_json({access}, {})", ts_const(fmt))
                    } else {
                        format!("aws_json_string({access})")
                    }
                }
                ScalarKind::Bytes => format!("aws_json_blob({access})"),
                ScalarKind::Bool => format!("aws_json_bool({access})"),
                ScalarKind::Double => format!("aws_json_f64({access})"),
                ScalarKind::Float => format!("aws_json_f32({access})"),
                ScalarKind::Int64 | ScalarKind::Sint64 | ScalarKind::Sfixed64 => {
                    format!("aws_json_i64({access})")
                }
                ScalarKind::Int32 | ScalarKind::Sint32 | ScalarKind::Sfixed32 => {
                    format!("aws_json_i32({access})")
                }
                ScalarKind::Uint64 | ScalarKind::Fixed64 => {
                    format!("aws_json_i64(Int64({access}))")
                }
                ScalarKind::Uint32 | ScalarKind::Fixed32 => {
                    format!("aws_json_i32(Int32({access}))")
                }
            },
        })
    }

    fn emit_from_json(&mut self, msg: &IrMessage) -> Result<(), String> {
        let ty = self.ty_name(&msg.mojo_name);
        self.line("@staticmethod");
        self.line(&format!("def from_aws_json(v: JsonValue) raises -> {ty}:"));
        self.push();
        self.line("\"\"\"Read this shape from an awsJson response fragment.");
        self.blank();
        self.line("    ⚠ AN UNKNOWN KEY IS IGNORED, AND SO IS AN EXPLICIT `null`. Both are");
        self.line("    corpus requirements, not tolerance for its own sake:");
        self.line("    `AwsJson11DeserializeIgnoreType` puts a `__type` discriminator inside");
        self.line("    a union body, and `AwsJson10DeserializeAllowNulls` sends every unset");
        self.line("    member as an explicit `null`. A decoder that treated either as a");
        self.line("    member would fail a response that is entirely valid.\"\"\"");

        // Required members are constructor arguments, so they are read first
        // into locals.
        let required: Vec<IrField> = msg
            .fields
            .iter()
            .filter(|f| self.required(msg, f))
            .cloned()
            .collect();
        for f in &required {
            let wire = self.wire_name(msg, f);
            let local = format!("_r_{}", f.name);
            if self.needs_no_nullary(f) {
                self.line(&format!(
                    "if not v.has(String(\"{wire}\")) or v.get(String(\"{wire}\")).is_null():"
                ));
                self.push();
                self.line(&format!(
                    "raise Error(\"{}.from_aws_json: required member `{wire}` is absent from the response.\")",
                    self.ty_name(&msg.mojo_name)
                ));
                self.pop();
                let expr = self.scalar_from_json(msg, f, &f.ty, &format!("v.get(String(\"{wire}\"))"))?;
                self.line(&format!("var {local} = {expr}"));
                continue;
            }
            self.line(&format!("var {local} = {}", self.default_expr(msg, f)?));
            self.line(&format!(
                "if v.has(String(\"{wire}\")) and not v.get(String(\"{wire}\")).is_null():"
            ));
            self.push();
            self.read_into(msg, f, &local, &wire)?;
            self.pop();
        }
        let args: Vec<String> = required
            .iter()
            .map(|f| format!("_r_{}^", f.name))
            .collect();
        self.line(&format!("var out = {ty}({})", args.join(", ")));
        for f in &msg.fields {
            if self.required(msg, f) {
                continue;
            }
            let wire = self.wire_name(msg, f);
            let local = format!("_v_{}", f.name);
            self.line(&format!(
                "if v.has(String(\"{wire}\")) and not v.get(String(\"{wire}\")).is_null():"
            ));
            self.push();
            if self.needs_no_nullary(f) {
                let expr = self.scalar_from_json(msg, f, &f.ty, &format!("v.get(String(\"{wire}\"))"))?;
                self.line(&format!("var {local} = {expr}"));
            } else {
                self.line(&format!("var {local} = {}", self.default_expr(msg, f)?));
                self.read_into(msg, f, &local, &wire)?;
            }
            self.line(&format!("out.set_{}({local}^)", f.name));
            self.pop();
        }
        self.line("return out^");
        self.pop();
        Ok(())
    }

    fn emit_model_json(&mut self, msg: &IrMessage) -> Result<(), String> {
        self.line("def to_model_json(self) raises -> JsonValue:");
        self.push();
        self.line("\"\"\"This shape in botocore's MODEL convention: a timestamp is epoch");
        self.line("    seconds as a NUMBER whatever its declared `timestampFormat`, and a");
        self.line("    blob is its decoded bytes rather than base64. This is the convention");
        self.line("    a protocol-test case states its `params` and its expected `result`");
        self.line("    in, and it is NOT the wire convention — see `to_aws_json`.\"\"\"");
        self.line("var obj = JsonValue.empty_object()");
        for f in &msg.fields {
            let wire = self.wire_name(msg, f);
            if self.required(msg, f) {
                let access = if self.is_boxed(msg, f) {
                    format!("self.{}[0]", f.name)
                } else {
                    format!("self.{}", f.name)
                };
                self.model_json_member(msg, f, &access, &wire)?;
            } else {
                self.line(&format!("if {}:", self.presence_test(msg, f)));
                self.push();
                let access = self.optional_access(msg, f);
                self.model_json_member(msg, f, &access, &wire)?;
                self.pop();
            }
        }
        self.line("return obj^");
        self.pop();
        Ok(())
    }

    fn model_json_member(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        access: &str,
        wire: &str,
    ) -> Result<(), String> {
        match (&f.label, &f.ty) {
            (Label::Repeated, ty) => {
                let tmp = format!("_ma_{}", f.name);
                self.line(&format!("var {tmp} = JsonValue.empty_array()"));
                self.line(&format!("for _i in range(len({access})):"));
                self.push();
                let e = self.value_to_model_json(msg, f, ty, &format!("{access}[_i]"), 1)?;
                self.line(&format!("{tmp}.push({e})"));
                self.pop();
                self.line(&format!("obj.set_member(String(\"{wire}\"), {tmp}^)"));
            }
            (_, IrType::Map(_, v)) => {
                let tmp = format!("_mm_{}", f.name);
                self.line(&format!("var {tmp} = JsonValue.empty_object()"));
                self.line(&format!("for _k in {access}.keys():"));
                self.push();
                let e = self.value_to_model_json(msg, f, v, &format!("{access}[_k]"), 1)?;
                self.line(&format!("{tmp}.set_member(_k.copy(), {e})"));
                self.pop();
                self.line(&format!("obj.set_member(String(\"{wire}\"), {tmp}^)"));
            }
            (_, ty) => {
                let e = self.value_to_model_json(msg, f, ty, access, 1)?;
                self.line(&format!("obj.set_member(String(\"{wire}\"), {e})"));
            }
        }
        Ok(())
    }

    /// [`Self::value_to_json`] for the MODEL convention — same recursion, same
    /// depth-naming rule, different leaf renderer.
    fn value_to_model_json(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        ty: &IrType,
        access: &str,
        depth: usize,
    ) -> Result<String, String> {
        match ty {
            IrType::List(e) => {
                let tmp = format!("_ma{depth}_{}", f.name);
                let iv = format!("_i{depth}");
                self.line(&format!("var {tmp} = JsonValue.empty_array()"));
                self.line(&format!("for {iv} in range(len({access})):"));
                self.push();
                let elem =
                    self.value_to_model_json(msg, f, e, &format!("{access}[{iv}]"), depth + 1)?;
                self.line(&format!("{tmp}.push({elem})"));
                self.pop();
                Ok(format!("{tmp}^"))
            }
            IrType::Map(_, v) => {
                let tmp = format!("_mm{depth}_{}", f.name);
                let kv = format!("_k{depth}");
                self.line(&format!("var {tmp} = JsonValue.empty_object()"));
                self.line(&format!("for {kv} in {access}.keys():"));
                self.push();
                let elem =
                    self.value_to_model_json(msg, f, v, &format!("{access}[{kv}]"), depth + 1)?;
                self.line(&format!("{tmp}.set_member({kv}.copy(), {elem})"));
                self.pop();
                Ok(format!("{tmp}^"))
            }
            other => self.scalar_to_model_json(msg, f, other, access),
        }
    }

    fn scalar_to_model_json(
        &self,
        msg: &IrMessage,
        f: &IrField,
        ty: &IrType,
        access: &str,
    ) -> Result<String, String> {
        Ok(match ty {
            IrType::Message(_) => format!("{access}.to_model_json()"),
            IrType::Scalar(ScalarKind::String) if self.timestamp_format(msg, f).is_some() => {
                // Epoch seconds as a NUMBER, whatever the declared format.
                format!("aws_json_f64({access})")
            }
            IrType::Scalar(ScalarKind::Bytes) => {
                // The DECODED bytes, not base64.
                format!("aws_json_string(_aws_bytes_to_string({access}))")
            }
            other => self.scalar_to_json(msg, f, other, access)?,
        })
    }

    /// Emit the statements that fill `local` from `v[wire]`.
    fn read_into(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        local: &str,
        wire: &str,
    ) -> Result<(), String> {
        let src = format!("v.get(String(\"{wire}\"))");
        match (&f.label, &f.ty) {
            (Label::Repeated, ty) => {
                let arr = format!("_arr_{}", f.name);
                self.line(&format!("var {arr} = {src}"));
                self.line(&format!("for _i in range({arr}.array_len()):"));
                self.push();
                let e = self.value_from_json(msg, f, ty, &format!("{arr}.element_at(_i)"), 1)?;
                self.line(&format!("{local}.append({e})"));
                self.pop();
            }
            (_, IrType::Map(_, vt)) => {
                let o = format!("_obj_{}", f.name);
                self.line(&format!("var {o} = {src}"));
                self.line(&format!("for _i in range({o}.num_members()):"));
                self.push();
                let e = self.value_from_json(msg, f, vt, &format!("{o}.value_at(_i)"), 1)?;
                self.line(&format!("{local}[{o}.key_at(_i)] = {e}"));
                self.pop();
            }
            (_, ty) => {
                let e = self.value_from_json(msg, f, ty, &src, 1)?;
                self.line(&format!("{local} = {e}"));
            }
        }
        Ok(())
    }

    fn value_from_json(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        ty: &IrType,
        src: &str,
        depth: usize,
    ) -> Result<String, String> {
        match ty {
            IrType::List(e) => {
                let j = format!("_arr{depth}_{}", f.name);
                let tmp = format!("_lst{depth}_{}", f.name);
                let iv = format!("_i{depth}");
                self.line(&format!("var {j} = {src}"));
                self.line(&format!("var {tmp} = List[{}]()", self.elem_type(msg, f, e)?));
                self.line(&format!("for {iv} in range({j}.array_len()):"));
                self.push();
                let elem =
                    self.value_from_json(msg, f, e, &format!("{j}.element_at({iv})"), depth + 1)?;
                self.line(&format!("{tmp}.append({elem})"));
                self.pop();
                Ok(format!("{tmp}^"))
            }
            IrType::Map(_, v) => {
                let j = format!("_obj{depth}_{}", f.name);
                let tmp = format!("_dct{depth}_{}", f.name);
                let iv = format!("_i{depth}");
                self.line(&format!("var {j} = {src}"));
                self.line(&format!(
                    "var {tmp} = Dict[String, {}]()",
                    self.elem_type(msg, f, v)?
                ));
                self.line(&format!("for {iv} in range({j}.num_members()):"));
                self.push();
                let elem =
                    self.value_from_json(msg, f, v, &format!("{j}.value_at({iv})"), depth + 1)?;
                self.line(&format!("{tmp}[{j}.key_at({iv})] = {elem}"));
                self.pop();
                Ok(format!("{tmp}^"))
            }
            other => self.scalar_from_json(msg, f, other, src),
        }
    }

    fn scalar_from_json(
        &self,
        msg: &IrMessage,
        f: &IrField,
        ty: &IrType,
        src: &str,
    ) -> Result<String, String> {
        Ok(match ty {
            IrType::Message(t) => {
                let n = self.by_fq.get(&t.fq_name).cloned().unwrap_or_else(|| t.mojo_name.clone());
                format!("{}.from_aws_json({src})", self.ty_name(&n))
            }
            IrType::Enum(_) => format!("{src}.as_string()"),
            IrType::Map(_, _) | IrType::List(_) => {
                return Err(format!(
                    "emit_aws: {}.{} reached `scalar_from_json` with a container type; \
                     `value_from_json` is the entry point that writes the loop.",
                    msg.name, f.name
                ))
            }
            IrType::Scalar(s) => match s {
                ScalarKind::String => {
                    if self.timestamp_format(msg, f).is_some() {
                        format!("aws_ts_from_json({src})")
                    } else {
                        format!("{src}.as_string()")
                    }
                }
                ScalarKind::Bytes => format!("aws_blob_from_json({src})"),
                ScalarKind::Bool => format!("{src}.as_bool()"),
                ScalarKind::Double => format!("aws_f64_from_json({src})"),
                ScalarKind::Float => format!("Float32(aws_f64_from_json({src}))"),
                ScalarKind::Int64 | ScalarKind::Sint64 | ScalarKind::Sfixed64 => {
                    format!("{src}.as_int64()")
                }
                ScalarKind::Int32 | ScalarKind::Sint32 | ScalarKind::Sfixed32 => {
                    format!("Int32({src}.as_int64())")
                }
                ScalarKind::Uint64 | ScalarKind::Fixed64 => format!("{src}.as_uint64()"),
                ScalarKind::Uint32 | ScalarKind::Fixed32 => {
                    format!("UInt32({src}.as_uint64())")
                }
            },
        })
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


    /// The model-stated constraint on one member, or `None`.
    fn member_constraint(&self, msg: &IrMessage, f: &IrField) -> Option<MemberConstraint> {
        if self.is_boxed(msg, f) {
            return None;
        }
        if self.timestamp_format(msg, f).is_some() {
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
        if self.is_boxed(msg, f) {
            format!("len(self.{}) > 0", f.name)
        } else {
            format!("self.{}", f.name)
        }
    }

    /// The Mojo expression that READS a present non-required member.
    fn optional_access(&self, msg: &IrMessage, f: &IrField) -> String {
        if self.is_boxed(msg, f) {
            format!("self.{}[0]", f.name)
        } else {
            format!("self.{}.value()", f.name)
        }
    }

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

        let methods: Vec<crate::ir::IrMethod> = {
            let svc = self.lowering.model.files[0]
                .services
                .first()
                .ok_or_else(|| "emit_aws: the lowering carries no IrService".to_string())?;
            svc.methods.clone()
        };
        let prefix = self.meta.target_prefix.clone().unwrap_or_default();

        for m in &methods {
            let facts = self.facts.operation_by_ir_method(&m.name)?.clone();
            let in_ty = self.ty_name(
                &self
                    .by_fq
                    .get(&m.input.fq_name)
                    .cloned()
                    .unwrap_or_else(|| m.input.mojo_name.clone()),
            );
            let out_ty = self.ty_name(
                &self
                    .by_fq
                    .get(&m.output.fq_name)
                    .cloned()
                    .unwrap_or_else(|| m.output.mojo_name.clone()),
            );
            let p = self.prefix.to_uppercase();

            let fp = self.fn_prefix();
            self.line(&format!(
                "def {fp}build_{}_request(input: {in_ty}) raises -> AwsRequest:",
                m.name
            ));
            self.push();
            self.line(&format!(
                "\"\"\"`{}` — the awsJson request, serialised and NOT signed.\"\"\"",
                facts.name
            ));
            // ⛔ THE CONSTRAINT CHECK IS ON THE PATH TO THE WIRE, NOT BESIDE IT.
            // A `validate()` a caller must remember to call is a convention;
            // this is the only entry point that produces an `AwsRequest`, so a
            // value that reaches AWS has been through it.
            {
                let input_mojo = self
                    .by_fq
                    .get(&m.input.fq_name)
                    .cloned()
                    .unwrap_or_else(|| m.input.mojo_name.clone());
                if self.validating.contains(&input_mojo) {
                    self.line("input.validate()");
                }
            }
            self.line(&format!(
                "var req = AwsRequest(String(\"{}\"), String(\"{}\"))",
                facts.http_method.to_uppercase(),
                escape(&facts.path)
            ));
            self.line(&format!(
                "req.set_header(String(\"X-Amz-Target\"), String(\"{}.{}\"))",
                escape(&prefix),
                escape(&facts.name)
            ));
            self.line(&format!(
                "req.set_header(String(\"Content-Type\"), String({p}_CONTENT_TYPE))"
            ));
            if self.meta.aws_query_compatible {
                self.line(
                    "req.set_header(String(\"x-amzn-query-mode\"), String(\"true\"))",
                );
            }
            // `endpoint.hostPrefix`, with its `hostLabel` members substituted.
            if let Some(hp) = &facts.host_prefix {
                let expr = self.host_prefix_expr(hp, &m.input.fq_name)?;
                self.line(&format!("req.host_prefix = {expr}"));
            }
            self.line("req.body = input.to_aws_json().serialize()");
            self.line("return req^");
            self.pop();
            self.blank();

            self.line(&format!(
                "def {fp}parse_{}_response(body: String) raises -> {out_ty}:",
                m.name
            ));
            self.push();
            self.line(&format!(
                "\"\"\"`{}` — the awsJson response. An EMPTY body is `{{}}`: awsJson",
                facts.name
            ));
            self.line("    operations with no output still answer 200 with no bytes, and");
            self.line("    `parses_operations_with_empty_json_bodies` states it.\"\"\"");
            self.line("if body.byte_length() == 0:");
            self.push();
            self.line(&format!(
                "return {out_ty}.from_aws_json(parse_json_value(String(\"{{}}\")))"
            ));
            self.pop();
            self.line(&format!(
                "return {out_ty}.from_aws_json(parse_json_value(body))"
            ));
            self.pop();
            self.blank();
        }
        self.blank();
        Ok(())
    }

    /// The Mojo expression for an `endpoint.hostPrefix`, substituting each
    /// `{member}` placeholder with the input's `hostLabel` member.
    ///
    /// ⚠ A HOST LABEL IS A MEMBER, NOT A CONSTANT. `AwsJson11EndpointTraitWithHostLabel`
    /// declares `hostPrefix: "{foo}.bar."`, and a generator that emitted the
    /// template verbatim would send a request to the literal host `{foo}.bar.…`
    /// — a DNS failure naming a brace.
    fn host_prefix_expr(&self, hp: &str, input_fq: &str) -> Result<String, String> {
        let mut parts: Vec<String> = Vec::new();
        let mut lit = String::new();
        let mut rest = hp;
        while let Some(i) = rest.find('{') {
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
                .find(|f| self.wire_name(msg, f) == member)
                .ok_or_else(|| {
                    format!(
                        "emit_aws: hostPrefix `{hp}` names `{{{member}}}`, and the input \
                         shape `{}` has no such member. A host label that resolves to \
                         nothing is a request to a host with a literal brace in it.",
                        msg.name
                    )
                })?;
            parts.push(if self.required(msg, field) {
                format!("input.{}.copy()", field.name)
            } else {
                format!("input.{}.value()", field.name)
            });
            rest = &rest[j + 1..];
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

    fn emit_client(&mut self) -> Result<(), String> {
        let (svc_name, methods) = {
            let svc = &self.lowering.model.files[0].services[0];
            (svc.name.clone(), svc.methods.clone())
        };
        let cls = format!("{}Client", self.ty_name(&svc_name));
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
        self.line("    and the credential source `T` — the same two parameters the 14");
        self.line("    hand-written clients in `komira_aws_relay` take.");
        self.blank();
        self.line("    gap6: a per-owner value. The connector factory is a");
        self.line("    `def () raises thin -> C` fn-ptr (FFI-POD, carve-out (a) — a code");
        self.line("    pointer, no heap, no wildcard origin); the credential source is");
        self.line("    moved in. No `UnsafePointer` field, no wildcard-origin field.\"\"\"");
        self.blank();
        self.line("var _mk_connector: def () raises thin -> Self.C");
        self.line("var _creds_source: Self.T");
        self.line("var _region: String");
        self.line("# WHERE this client sends. `None` = real AWS (the host derived from");
        self.line("# the region). A VALUE, never an ambient env var — see");
        self.line("# `aws_relay_common.AwsEndpoint`. This is what makes every verb this");
        self.line("# generator emits exercisable against a local emulator.");
        self.line("var _endpoint_override: Optional[AwsEndpoint]");
        self.blank();
        self.line("def __init__(");
        self.push();
        self.line("out self,");
        self.line("mk_connector: def () raises thin -> Self.C,");
        self.line("var creds_source: Self.T,");
        self.line("region: String,");
        self.line("endpoint_override: Optional[AwsEndpoint] = Optional[AwsEndpoint](),");
        self.pop();
        self.line("):");
        self.push();
        self.line("self._mk_connector = mk_connector");
        self.line("self._creds_source = creds_source^");
        self.line("self._region = region");
        self.line("self._endpoint_override = endpoint_override.copy()");
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
        self.line("def send(mut self, var req: AwsRequest) raises -> HttpResult:");
        self.push();
        self.line("\"\"\"Sign and send `req`. THE SIGNER IS NOT GENERATED — this is a call");
        self.line("    into the shipped `send_sigv4_signed_request`, which drives the");
        self.line("    AWS-test-vector-validated `komira_aws_core.sigv4`.");
        self.blank();
        self.line("    ⛔ `X-Amz-Target` MUST RIDE IN THE **SIGNED** SET, not merely on the");
        self.line("    wire: an awsJson service includes it in the canonical request, so an");
        self.line("    unsigned one comes back `SignatureDoesNotMatch` and sends every");
        self.line("    reader to the credential. It is passed as an extra SIGNED header for");
        self.line("    exactly that reason.\"\"\"");
        self.line("var cred = self._creds_source.credentials()");
        self.line("var extra = List[Header]()");
        self.line("var content_type = String(String(" );
        self.push();
        self.line(&format!("{p}_CONTENT_TYPE"));
        self.pop();
        self.line("))");
        self.line("for _i in range(len(req.header_names)):");
        self.push();
        self.line("var n = req.header_names[_i].copy()");
        self.line("if n == String(\"Content-Type\"):");
        self.push();
        self.line("# The substrate takes the content type as its own argument and");
        self.line("# puts it in BOTH the signed set and the wire headers. Passing it");
        self.line("# again here would emit it twice and break the signature.");
        self.line("content_type = req.header_values[_i].copy()");
        self.pop();
        self.line("else:");
        self.push();
        self.line("extra.append(Header(n^, req.header_values[_i].copy()))");
        self.pop();
        self.pop();
        self.line("return send_sigv4_signed_request[Self.C](");
        self.push();
        self.line("self._mk_connector,");
        self.line("req.method.copy(),");
        self.line("cred,");
        self.line("self._region.copy(),");
        self.line(&format!("String({p}_SERVICE),"));
        self.line(&format!(
            "resolve_endpoint(self._endpoint_override, {}_host(self._region.copy())),",
            self.module_name
        ));
        self.line("req.uri.copy(),");
        self.line("content_type^,");
        self.line("req.body.copy(),");
        self.line("extra^,");
        self.pop();
        self.line(")");
        self.pop();
        self.blank();

        // -- per-operation verbs ------------------------------------------
        for m in &methods {
            let facts = self.facts.operation_by_ir_method(&m.name)?.clone();
            let overridden = self.overrides.get(&facts.name);
            let verb = if overridden.is_some() {
                format!("{}_raw", m.name)
            } else {
                m.name.clone()
            };
            let in_ty = self.ty_name(
                &self
                    .by_fq
                    .get(&m.input.fq_name)
                    .cloned()
                    .unwrap_or_else(|| m.input.mojo_name.clone()),
            );
            let out_ty = self.ty_name(
                &self
                    .by_fq
                    .get(&m.output.fq_name)
                    .cloned()
                    .unwrap_or_else(|| m.output.mojo_name.clone()),
            );
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
            self.line(&format!("var req = {fp}build_{}_request(input)", m.name));
            self.line("var res = self.send(req^)");
            self.line("if not aws_is_error_status(res.status):");
            self.push();
            self.line(&format!("return {fp}parse_{}_response(res.body)", m.name));
            self.pop();
            self.line(&format!(
                "raise _{}_error(String(\"{}\"), res)",
                self.module_name,
                escape(&facts.name)
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
        self.line("    parsed short `__type` token and message ride out. A generated client");
        self.line("    cannot know which of its shapes carry a secret, so the discipline is");
        self.line("    unconditional — the `secrets_manager_client._sm_error` rule, applied");
        self.line("    everywhere because the generator has no way to make the exception.\"\"\"");
        self.line("var code = aws_error_code_from_body(res.body)");
        self.line("var msg = aws_error_message_from_body(res.body)");
        self.line("return Error(");
        self.push();
        self.line(&format!("String(\"{}.\")", self.ty_name(&svc_name)));
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

/// The import block + shared helper every generated PURE module needs. The
/// conformance driver emits this ONCE ahead of 44 concatenated suites.
pub fn pure_preamble(with_model_json: bool) -> String {
    let mut em = String::new();
    em.push_str("from komira_aws_wire.aws_wire import (\n");
    for n in [
        "AWS_TS_ISO8601",
        "AWS_TS_RFC822",
        "AWS_TS_UNIX",
        "AwsRequest",
        "aws_blob_from_json",
        "aws_error_code",
        "aws_error_code_from_body",
        "aws_error_message_from_body",
        "aws_is_error_status",
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
    ] {
        em.push_str(&format!("    {n},\n"));
    }
    em.push_str(")\n");
    em.push_str("from komira_serde.json_value import JsonValue, parse_json_value\n\n\n");
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
