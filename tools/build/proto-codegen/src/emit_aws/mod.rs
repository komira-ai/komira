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

use std::collections::{BTreeMap, BTreeSet};

use crate::aws_in::{AwsFacts, AwsLowering, AwsServiceMeta, AwsTimestampFormat};
use crate::ir::{IrEnum, IrField, IrMessage, IrMethod, IrType, Label, ScalarKind};
use crate::lower::{recursion_breaking_edges_under, ContainerInlining};
use crate::overrides::AwsOverrides;

mod json_codec;
pub mod proto;
mod rpc;

pub use proto::{AwsProtocol, ALL_PROTOCOLS, JSON_BODY_PROTOCOLS};
use proto::{select_protocol, Binding, BodyCodec};

/// Emitter options.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AwsEmitOptions {
    pub emit_model_json: bool,
    pub pure_only: bool,
    pub omit_preamble: bool,
}

/// The protocols this emitter implements, by botocore name. Anything else is
/// refused.
pub const SUPPORTED_PROTOCOLS: &[&str] = &["json"];

/// The `jsonVersion` values this emitter implements.
pub const SUPPORTED_JSON_VERSIONS: &[&str] = &["1.0", "1.1"];

/// The generator version written into every generated header. Bump it when
/// the emitted text changes for the same model, operation list and options.
pub const AWS_GENERATOR_VERSION: &str = "3";

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
        mode: AwsImportMode::Always,
        protocols: JSON_BODY_PROTOCOLS,
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
            "AwsCredential",
            "AwsCredsSource",
            "AwsEndpoint",
            "Header",
            "HttpResult",
            "resolve_endpoint",
            "send_sigv4_signed_request",
        ],
        mode: AwsImportMode::ClientOnly,
        protocols: ALL_PROTOCOLS,
    },
    AwsImport {
        module: "komira_json",
        names: &["JsonValue", "parse_json_bytes", "parse_json_value"],
        mode: AwsImportMode::Always,
        protocols: JSON_BODY_PROTOCOLS,
    },
    AwsImport {
        module: "komira_http.transport.io_stream",
        names: &["Connector"],
        mode: AwsImportMode::ClientOnly,
        protocols: ALL_PROTOCOLS,
    },
];

/// The import section of a `protocol` module: one `from` statement per
/// module of the [`AWS_IMPORTS`] rows that apply to `protocol`, in table
/// order, holding every name that `pure_only` needs. Rows that share a
/// module merge into one statement.
pub fn aws_import_section(protocol: AwsProtocol, pure_only: bool) -> String {
    let mut groups: Vec<(&str, Vec<&str>)> = Vec::new();
    for row in AWS_IMPORTS {
        if pure_only && row.mode == AwsImportMode::ClientOnly {
            continue;
        }
        if !row.protocols.contains(&protocol) {
            continue;
        }
        match groups.iter_mut().find(|(m, _)| *m == row.module) {
            Some((_, names)) => names.extend_from_slice(row.names),
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
    if provenance.is_none() && !options.omit_preamble {
        return Err(format!(
            "emit_aws: module `{module_name}` has a header but no provenance; the \
             header must name the model key and its sha256"
        ));
    }
    let selected = select_protocol(&lowering.service)?;
    overrides.check_against(lowering)?;

    let mut em = AwsEmitter::new(lowering, overrides, module_name, selected, options)?;
    em.provenance = provenance.map(|p| (p.model_key.to_string(), p.model_sha256.to_string()));
    let source = em.emit()?;
    Ok(AwsEmitted {
        path: format!("{module_name}.mojo"),
        source,
        structs: em.structs,
        parameterised: em.parameterised,
    })
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
        let (model_key, model_sha256) = self.provenance.clone().unwrap_or_default();
        self.line(&format!("#   model key    : {model_key}"));
        self.line(&format!("#   model sha256 : {model_sha256}"));
        self.line(&format!("#   operations   : {}", ops.join(", ")));
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

    fn emit_imports(&mut self) {
        let section = aws_import_section(self.protocol, self.options.pure_only);
        self.out.push_str(&section);
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
        for m in &methods {
            let facts = self.facts.operation_by_ir_method(&m.name)?.clone();
            binding.emit_request_builder(self, m, &facts)?;
            binding.emit_response_parser(self, m, &facts)?;
        }
        self.blank();
        Ok(())
    }

    fn emit_client(&mut self) -> Result<(), String> {
        let (svc_name, methods) = {
            let svc = &self.lowering.model.files[0].services[0];
            (svc.name.clone(), svc.methods.clone())
        };
        let cls = format!("{}Client", self.ty_name(&svc_name));
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
        self.line("    in. No field is an `UnsafePointer`.\"\"\"");
        self.blank();
        self.line("var _mk_connector: def () raises thin -> Self.C");
        self.line("var _creds_source: Self.T");
        self.line("var _region: String");
        self.line("# WHERE this client sends. `None` = real AWS (the host derived from");
        self.line("# the region). A VALUE, never an ambient env var — see");
        self.line(&format!(
            "# `{}.AwsEndpoint`. This is what makes every verb this",
            AWS_CORE
        ));
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
        if let Some(last) = doc.last_mut() {
            last.push_str("\"\"\"");
        }
        for l in &doc {
            self.line(l);
        }
        self.line("var cred = self._creds_source.credentials()");
        self.line("var extra = List[Header]()");
        self.line("var content_type = String(String(" );
        self.push();
        let default_content_type = self.binding.default_content_type(self);
        self.line(&default_content_type);
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
            self.line(&format!("var req = {fp}build_{}_request(input)", m.name));
            self.line("var res = self.send(req^)");
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
        let (code_expr, msg_expr) = self.binding.error_code_and_message();
        self.line(&format!("var code = {code_expr}"));
        self.line(&format!("var msg = {msg_expr}"));
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
pub fn pure_preamble(protocol: AwsProtocol, with_model_json: bool) -> String {
    let mut em = aws_import_section(protocol, true);
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
        for p in ALL_PROTOCOLS.iter().filter(|p| !JSON_BODY_PROTOCOLS.contains(p)) {
            for row in rows_for(*p) {
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

    #[test]
    fn every_protocol_gets_the_transport_in_client_mode_only() {
        for p in ALL_PROTOCOLS {
            assert!(!aws_import_section(*p, true).contains("Connector"), "{p:?}");
            assert!(aws_import_section(*p, false).contains("Connector"), "{p:?}");
            assert!(aws_import_section(*p, true).contains("    AwsRequest,"), "{p:?}");
        }
    }
}
