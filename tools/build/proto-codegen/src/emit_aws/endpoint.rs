//! Endpoint resolution in a generated module: the service's endpoint
//! ruleset (`endpoint-rule-set-1.json`) and the partition table
//! (`partitions.json`) are embedded in the module, and each operation gets a
//! `resolve_<op>_endpoint` that binds the ruleset's parameters and asks
//! `komira_aws_core.EndpointRuleSet` for the endpoint.
//!
//! The parameters a call resolves with, from the lowest precedence to the
//! highest (Smithy's endpoint parameter binding order; a later binding
//! replaces an earlier one, and an unbound parameter takes the ruleset's
//! default):
//!
//! 1. the client's `<Prefix>EndpointConfig`: one field per ruleset parameter
//!    that is a built-in (`AWS::Region`, `SDK::Endpoint`, ...) or one of the
//!    model's `clientContextParams`;
//! 2. the operation's `operationContextParams`, read from the input by a
//!    member path;
//! 3. the input members carrying a `contextParam`;
//! 4. the operation's `staticContextParams`.
//!
//! Every binding is checked against the ruleset when the module is
//! generated: a parameter the ruleset does not declare, or one of another
//! type, is refused, as is an `operationContextParams` path that is not a
//! plain member path. Nothing here names a service: the bindings are the
//! model's and the endpoints the ruleset's.

use std::collections::BTreeSet;

use crate::aws_in::{snake_case, AwsStaticValue};
use crate::ir::{IrMessage, IrMethod, IrType, Label};
use crate::json::{parse, Json};

use super::{escape, AwsEmitter};

/// The type of a ruleset parameter.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RulesetParamType {
    Str,
    Bool,
    StrArray,
}

impl RulesetParamType {
    fn parse(ty: &str) -> Option<Self> {
        match ty.to_ascii_lowercase().as_str() {
            "string" => Some(Self::Str),
            "boolean" => Some(Self::Bool),
            "stringarray" => Some(Self::StrArray),
            _ => None,
        }
    }

    /// The ruleset's own name for the type.
    pub fn name(self) -> &'static str {
        match self {
            Self::Str => "string",
            Self::Bool => "boolean",
            Self::StrArray => "stringArray",
        }
    }

    /// The Mojo type of a value of this type.
    fn mojo(self) -> &'static str {
        match self {
            Self::Str => "String",
            Self::Bool => "Bool",
            Self::StrArray => "List[String]",
        }
    }

    /// The `EndpointParams` setter for this type.
    fn setter(self) -> &'static str {
        match self {
            Self::Str => "set_string",
            Self::Bool => "set_bool",
            Self::StrArray => "set_string_array",
        }
    }
}

/// One parameter the ruleset declares.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RulesetParam {
    pub name: String,
    pub ty: RulesetParamType,
    /// `builtIn`, e.g. `AWS::Region`.
    pub built_in: Option<String>,
    pub required: bool,
    pub has_default: bool,
}

/// A service's endpoint ruleset and the partition table, checked and
/// minified for embedding.
#[derive(Clone, Debug)]
pub struct AwsEndpointRules {
    /// The ruleset document with the whitespace between its tokens removed.
    pub ruleset: String,
    /// The partition table, likewise.
    pub partitions: String,
    /// The sha256 of each file as read, for the generated header.
    pub ruleset_sha256: String,
    pub partitions_sha256: String,
    /// The parameters the ruleset declares, in document order.
    pub params: Vec<RulesetParam>,
}

impl AwsEndpointRules {
    /// Reads a ruleset and a partition table. Refuses a document that is not
    /// JSON, a ruleset whose `version` is not 1.x or whose `parameters` are
    /// malformed, and a partition table with no `partitions` array. The
    /// rules themselves are checked by the interpreter when the generated
    /// module loads them, and by its test over the published cases.
    pub fn parse(
        ruleset_text: &str,
        ruleset_sha256: &str,
        partitions_text: &str,
        partitions_sha256: &str,
    ) -> Result<Self, String> {
        let doc = parse(ruleset_text).map_err(|e| format!("the endpoint ruleset: {e}"))?;
        let version = doc
            .get("version")
            .and_then(Json::as_str)
            .ok_or("the endpoint ruleset has no `version` string")?;
        if !version.starts_with("1.") {
            return Err(format!(
                "the endpoint ruleset has version `{version}`, and only 1.x is interpreted"
            ));
        }
        let declared = doc
            .get("parameters")
            .and_then(Json::as_object)
            .ok_or("the endpoint ruleset has no `parameters` object")?;
        let mut params = Vec::new();
        for (name, spec) in declared.iter_declared() {
            let ty_text = spec
                .get("type")
                .and_then(Json::as_str)
                .ok_or_else(|| format!("endpoint ruleset parameter `{name}` has no `type`"))?;
            let ty = RulesetParamType::parse(ty_text).ok_or_else(|| {
                format!("endpoint ruleset parameter `{name}` has the unknown type `{ty_text}`")
            })?;
            params.push(RulesetParam {
                name: name.clone(),
                ty,
                built_in: spec.get("builtIn").and_then(Json::as_str).map(String::from),
                required: spec.get("required").and_then(Json::as_bool).unwrap_or(false),
                has_default: spec.get("default").is_some(),
            });
        }
        let parts = parse(partitions_text).map_err(|e| format!("the partition table: {e}"))?;
        if parts.get("partitions").and_then(Json::as_array).is_none() {
            return Err("the partition table has no `partitions` array".into());
        }
        let ruleset = minify(ruleset_text)?;
        let partitions = minify(partitions_text)?;
        // The embedded text must be the same document.
        if parse(&ruleset)? != doc || parse(&partitions)? != parts {
            return Err("minifying a JSON document changed it".into());
        }
        Ok(AwsEndpointRules {
            ruleset,
            partitions,
            ruleset_sha256: ruleset_sha256.to_string(),
            partitions_sha256: partitions_sha256.to_string(),
            params,
        })
    }

    pub fn param(&self, name: &str) -> Option<&RulesetParam> {
        self.params.iter().find(|p| p.name == name)
    }
}

/// `text` with the whitespace between JSON tokens removed; string literals
/// are kept byte for byte, escapes included.
pub fn minify(text: &str) -> Result<String, String> {
    let mut out = String::with_capacity(text.len());
    let mut in_string = false;
    let mut escaped = false;
    for c in text.chars() {
        if in_string {
            out.push(c);
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                in_string = false;
            }
        } else if c == '"' {
            in_string = true;
            out.push(c);
        } else if !matches!(c, ' ' | '\t' | '\n' | '\r') {
            out.push(c);
        }
    }
    if in_string {
        return Err("a JSON document ends inside a string".into());
    }
    Ok(out)
}

/// One step of an `operationContextParams` path: the IR field, and whether
/// it is `Optional` in the generated struct.
struct PathStep {
    field: String,
    optional: bool,
}

/// How one ruleset parameter is bound from an operation's input.
struct InputBinding {
    param: String,
    ty: RulesetParamType,
    steps: Vec<PathStep>,
}

impl<'a> AwsEmitter<'a> {
    /// The ruleset parameters the client configures: the built-ins and the
    /// model's `clientContextParams`, in ruleset order, each with its field
    /// name in `<Prefix>EndpointConfig`.
    fn endpoint_config_fields(
        &self,
        rules: &AwsEndpointRules,
    ) -> Result<Vec<(RulesetParam, String)>, String> {
        let ccp: BTreeSet<&str> = self
            .meta
            .client_context_params
            .iter()
            .map(|p| p.name.as_str())
            .collect();
        let mut out = Vec::new();
        let mut names = BTreeSet::new();
        for p in &rules.params {
            if p.built_in.is_none() && !ccp.contains(p.name.as_str()) {
                continue;
            }
            let field = snake_case(&p.name);
            if !names.insert(field.clone()) {
                return Err(format!(
                    "aws endpoint rules: two ruleset parameters are both the config field `{field}`"
                ));
            }
            out.push((p.clone(), field));
        }
        Ok(out)
    }

    /// Checks every binding of the model against the ruleset: each
    /// `clientContextParams` entry, and for every emitted operation its
    /// `contextParam` members, `staticContextParams` and
    /// `operationContextParams`.
    pub(super) fn check_endpoint_bindings(&self, rules: &AwsEndpointRules) -> Result<(), String> {
        for c in &self.meta.client_context_params {
            let p = declared(rules, &c.name, "the model's clientContextParams")?;
            let want = RulesetParamType::parse(&c.ty).ok_or_else(|| {
                format!(
                    "aws endpoint rules: clientContextParams `{}` has the type `{}`, which \
                     no ruleset parameter has",
                    c.name, c.ty
                )
            })?;
            same_type(p, want, "the model's clientContextParams")?;
        }
        self.endpoint_config_fields(rules)?;
        for m in self.service_methods()? {
            self.input_bindings(rules, &m)?;
            let facts = self.facts.operation_by_ir_method(&m.name)?;
            for (name, value) in &facts.static_context_params {
                let what = format!("the staticContextParams of `{}`", facts.name);
                let p = declared(rules, name, &what)?;
                same_type(
                    p,
                    match value {
                        AwsStaticValue::Bool(_) => RulesetParamType::Bool,
                        AwsStaticValue::Str(_) => RulesetParamType::Str,
                    },
                    &what,
                )?;
            }
        }
        Ok(())
    }

    /// What the model binds into an endpoint ruleset, for a module
    /// generated WITHOUT one: the `clientContextParams`, and per emitted
    /// operation its `contextParam` members, `operationContextParams` and
    /// `staticContextParams`, one line each. Empty when the model binds
    /// nothing.
    pub(super) fn unapplied_endpoint_bindings(&self) -> Result<Vec<String>, String> {
        let mut out = Vec::new();
        if !self.meta.client_context_params.is_empty() {
            let names: Vec<&str> =
                self.meta.client_context_params.iter().map(|p| p.name.as_str()).collect();
            out.push(format!("clientContextParams: {}", names.join(", ")));
        }
        let Some(service) = self.file().services.first() else {
            return Ok(out);
        };
        for m in &service.methods {
            let facts = self.facts.operation_by_ir_method(&m.name)?;
            let mut parts = Vec::new();
            if let Some(input) = self.messages.get(&self.op_input_mojo(m)) {
                let members: Vec<String> = input
                    .fields
                    .iter()
                    .filter_map(|f| self.facts.member(&input.fq_name, &f.name).ok())
                    .filter_map(|mf| {
                        mf.context_param.as_ref().map(|p| format!("{} -> {p}", mf.member_name))
                    })
                    .collect();
                if !members.is_empty() {
                    parts.push(format!("contextParam {}", members.join(", ")));
                }
            }
            if !facts.operation_context_params.is_empty() {
                let v: Vec<String> = facts
                    .operation_context_params
                    .iter()
                    .map(|(p, path)| format!("{path} -> {p}"))
                    .collect();
                parts.push(format!("operationContextParams {}", v.join(", ")));
            }
            if !facts.static_context_params.is_empty() {
                let v: Vec<&str> =
                    facts.static_context_params.iter().map(|(p, _)| p.as_str()).collect();
                parts.push(format!("staticContextParams {}", v.join(", ")));
            }
            if !parts.is_empty() {
                out.push(format!("{}: {}", facts.name, parts.join("; ")));
            }
        }
        Ok(out)
    }

    fn service_methods(&self) -> Result<Vec<IrMethod>, String> {
        Ok(self
            .file()
            .services
            .first()
            .ok_or_else(|| "emit_aws: the lowering carries no IrService".to_string())?
            .methods
            .clone())
    }

    /// The bindings from an operation's input: its `operationContextParams`
    /// first, then its `contextParam` members, so a member's binding wins.
    fn input_bindings(
        &self,
        rules: &AwsEndpointRules,
        m: &IrMethod,
    ) -> Result<Vec<InputBinding>, String> {
        let facts = self.facts.operation_by_ir_method(&m.name)?.clone();
        let input = self.messages[&self.op_input_mojo(m)];
        let mut out = Vec::new();
        for (name, path) in &facts.operation_context_params {
            let what = format!("the operationContextParams of `{}`", facts.name);
            let p = declared(rules, name, &what)?;
            let (steps, ty) = self.member_path(input, path, &facts.name)?;
            same_type(p, ty, &format!("{what} (path `{path}`)"))?;
            out.push(InputBinding { param: name.clone(), ty, steps });
        }
        for f in &input.fields {
            let Ok(mf) = self.facts.member(&input.fq_name, &f.name) else {
                continue;
            };
            let Some(name) = &mf.context_param else {
                continue;
            };
            let what = format!("the contextParam of `{}.{}`", input.name, mf.member_name);
            let p = declared(rules, name, &what)?;
            let ty = self.binding_type(input, f.name.as_str()).ok_or_else(|| {
                format!(
                    "aws endpoint rules: {what} binds `{name}` from a member that is not a \
                     string, a boolean or a list of strings"
                )
            })?;
            same_type(p, ty, &what)?;
            out.push(InputBinding {
                param: name.clone(),
                ty,
                steps: vec![PathStep {
                    field: f.name.clone(),
                    optional: !self.required(input, f),
                }],
            });
        }
        Ok(out)
    }

    /// The ruleset type a field of `msg` can bind, when it is a plain
    /// (unboxed) string, boolean or list of strings.
    fn binding_type(&self, msg: &IrMessage, field: &str) -> Option<RulesetParamType> {
        let f = msg.fields.iter().find(|f| f.name == field)?;
        if self.is_boxed(msg, f) || self.timestamp_format(msg, f).is_some() {
            return None;
        }
        match self.value_type(msg, f).ok()?.as_str() {
            "String" => Some(RulesetParamType::Str),
            "Bool" => Some(RulesetParamType::Bool),
            "List[String]" => Some(RulesetParamType::StrArray),
            _ => None,
        }
    }

    /// Resolves an `operationContextParams` path over the input. Only a
    /// member path is bound (`Member` or `Member.Member...`, through
    /// structures); any other JMESPath form is refused, naming the path.
    fn member_path(
        &self,
        input: &IrMessage,
        path: &str,
        op: &str,
    ) -> Result<(Vec<PathStep>, RulesetParamType), String> {
        let refuse = |why: &str| {
            format!(
                "aws front-end: REFUSED operation-context-param: operation `{op}` binds an \
                 endpoint parameter from the path `{path}`, {why}"
            )
        };
        let parts: Vec<&str> = path.split('.').collect();
        if parts
            .iter()
            .any(|p| p.is_empty() || !p.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'))
        {
            return Err(refuse(
                "and only a member path (`A` or `A.B`) is bound, not another JMESPath form",
            ));
        }
        let mut msg = input;
        let mut steps = Vec::new();
        for (i, part) in parts.iter().enumerate() {
            let f = msg
                .fields
                .iter()
                .find(|f| {
                    self.facts
                        .member(&msg.fq_name, &f.name)
                        .map(|m| m.member_name == *part)
                        .unwrap_or(false)
                })
                .ok_or_else(|| refuse(&format!("and `{}` declares no member `{part}`", msg.name)))?;
            if self.is_boxed(msg, f) {
                return Err(refuse(&format!("and `{part}` is a recursive member")));
            }
            steps.push(PathStep {
                field: f.name.clone(),
                optional: !self.required(msg, f),
            });
            if i + 1 == parts.len() {
                let ty = self.binding_type(msg, &f.name).ok_or_else(|| {
                    refuse("whose value is not a string, a boolean or a list of strings")
                })?;
                return Ok((steps, ty));
            }
            let next = match (&f.label, &f.ty) {
                (Label::Repeated, _) => None,
                (_, IrType::Message(t)) => {
                    self.by_fq.get(&t.fq_name).and_then(|n| self.messages.get(n).copied())
                }
                _ => None,
            }
            .ok_or_else(|| refuse(&format!("and `{part}` is not a structure")))?;
            msg = next;
        }
        unreachable!("a path has at least one part")
    }

    // ======================================================================
    // emission
    // ======================================================================

    pub(super) fn emit_endpoint_section(&mut self, rules: &AwsEndpointRules) -> Result<(), String> {
        let p = self.prefix.to_uppercase();
        let mn = self.module_name.clone();
        let cfg = format!("{}EndpointConfig", self.prefix);
        let fields = self.endpoint_config_fields(rules)?;

        self.line(&format!("# {}", "=".repeat(75)));
        self.line("# §E — endpoint resolution: the service's endpoint ruleset, interpreted.");
        self.line("#");
        self.line("# The ruleset and the partition table are botocore's published data,");
        self.line("# embedded from the pinned archive when this module was generated (their");
        self.line("# sha256 are in the header). `komira_aws_core.EndpointRuleSet` evaluates");
        self.line("# them: nothing below chooses a host, an addressing style or a signer.");
        self.line("#");
        self.line("# A call's parameters, lowest precedence first: the client's endpoint");
        self.line("# config, the operation's operationContextParams, its contextParam");
        self.line("# members, and its staticContextParams. An unset parameter takes the");
        self.line("# ruleset's default.");
        self.line(&format!("# {}", "=".repeat(75)));
        self.line(&format!(
            "comptime {p}_ENDPOINT_RULESET: StaticString = \"{}\"",
            escape(&rules.ruleset)
        ));
        self.line(&format!(
            "comptime {p}_PARTITIONS: StaticString = \"{}\"",
            escape(&rules.partitions)
        ));
        self.blank();
        self.blank();
        self.line(&format!("def {mn}_endpoint_rules() raises -> EndpointRuleSet:"));
        self.push();
        self.line("\"\"\"The service's endpoint ruleset over the partition table, loaded and");
        self.line("    checked. Loading parses both documents: load once, resolve many.\"\"\"");
        self.line("return EndpointRuleSet(");
        self.push();
        self.line(&format!("String({p}_ENDPOINT_RULESET), AwsPartitionSet(String({p}_PARTITIONS))"));
        self.pop();
        self.line(")");
        self.pop();
        self.blank();
        self.blank();

        // -- the client's configuration ------------------------------------
        self.structs.push(cfg.clone());
        let region = fields
            .iter()
            .find(|(rp, _)| rp.built_in.as_deref() == Some("AWS::Region"))
            .map(|(_, f)| f.clone());
        let sdk_defaults: Vec<(&RulesetParam, &String, &'static str)> = fields
            .iter()
            .filter_map(|(rp, f)| sdk_built_in_default(rp).map(|d| (rp, f, d)))
            .collect();
        self.line(&format!("struct {cfg}(Copyable, Movable):"));
        self.push();
        self.line("\"\"\"The endpoint ruleset's client-level parameters: its built-ins and the");
        if sdk_defaults.is_empty() {
            self.line("    model's clientContextParams. Every field is unset until a caller sets it,");
            self.line("    and an unset one takes the ruleset's default. Nothing here reads the");
            self.line("    environment.");
        } else {
            self.line("    model's clientContextParams. Every field is unset until a caller sets it,");
            self.line("    but for a built-in the AWS SDKs give a value the ruleset does not:");
            for (rp, f, d) in &sdk_defaults {
                self.line(&format!(
                    "    `{f}` starts as `{d}` ({});",
                    rp.built_in.as_deref().unwrap_or_default()
                ));
                self.line("    a caller that wants it unset assigns it an empty Optional.");
            }
            self.line("    An unset field takes the ruleset's default. Nothing here reads the");
            self.line("    environment.");
        }
        if let Some((_, f)) = fields.iter().find(|(rp, _)| rp.name == "ForcePathStyle") {
            self.blank();
            self.line(&format!(
                "    A custom `endpoint` keeps the ruleset's addressing: with `{f}`"
            ));
            self.line("    unset, a bucket that can be a host name is addressed by virtual host on");
            self.line("    the custom endpoint too, as the AWS SDKs for Rust and Java v2 do. A");
            self.line(&format!(
                "    caller that needs path-style addressing sets `{f} = True`."
            ));
        }
        self.line("    \"\"\"");
        self.blank();
        for (rp, f) in &fields {
            let source = match (&rp.built_in, self.is_client_context_param(&rp.name)) {
                (Some(b), true) => format!("built-in {b}; clientContextParams"),
                (Some(b), false) => format!("built-in {b}"),
                (None, _) => "clientContextParams".to_string(),
            };
            self.line(&format!("# `{}` ({source})", rp.name));
            self.line(&format!("var {f}: Optional[{}]", rp.ty.mojo()));
        }
        if !fields.is_empty() {
            self.blank();
        }
        self.line("def __init__(out self):");
        self.push();
        if sdk_defaults.is_empty() {
            self.line("\"\"\"Every parameter unset.\"\"\"");
        } else {
            self.line("\"\"\"Every parameter unset but those the AWS SDKs default.\"\"\"");
        }
        for (rp, f) in &fields {
            match sdk_built_in_default(rp) {
                Some(d) => self.line(&format!(
                    "self.{f} = Optional[{}](String(\"{}\"))",
                    rp.ty.mojo(),
                    escape(d)
                )),
                None => self.line(&format!("self.{f} = Optional[{}]()", rp.ty.mojo())),
            }
        }
        self.pop();
        self.blank();
        if let Some(r) = &region {
            self.line(&format!("def __init__(out self, {r}: String):"));
            self.push();
            self.line(&format!(
                "\"\"\"Every parameter unset but `{r}`, which \"\" leaves unset too.\"\"\""
            ));
            self.line("self = Self()");
            self.line(&format!("if {r}.byte_length() > 0:"));
            self.push();
            self.line(&format!("self.{r} = Optional[String]({r})"));
            self.pop();
            self.pop();
            self.blank();
        }
        self.line("def endpoint_params(self) -> EndpointParams:");
        self.push();
        self.line("\"\"\"The ruleset parameters this configuration sets.\"\"\"");
        self.line("var params = EndpointParams()");
        for (rp, f) in &fields {
            self.line(&format!("if self.{f}:"));
            self.push();
            self.line(&format!(
                "params.{}(String(\"{}\"), self.{f}.value())",
                rp.ty.setter(),
                escape(&rp.name)
            ));
            self.pop();
        }
        self.line("return params^");
        self.pop();
        self.pop();
        self.blank();
        self.blank();

        // -- per operation --------------------------------------------------
        let fp = self.fn_prefix();
        for m in self.service_methods()? {
            let facts = self.facts.operation_by_ir_method(&m.name)?.clone();
            let bindings = self.input_bindings(rules, &m)?;
            let in_ty = self.op_input_type(&m);
            self.line(&format!(
                "def {fp}resolve_{}_endpoint(rules: EndpointRuleSet, config: {cfg}, input: {in_ty}) raises -> ResolvedEndpoint:",
                m.name
            ));
            self.push();
            self.line(&format!(
                "\"\"\"`{}` — the endpoint the ruleset chooses for this call: its URL,",
                facts.name
            ));
            self.line("    headers and properties (`authSchemes` says how to sign). An `error`");
            self.line("    rule's answer is raised with the ruleset's message.\"\"\"");
            self.line("var params = config.endpoint_params()");
            for b in &bindings {
                self.emit_input_binding(b);
            }
            for (name, value) in &facts.static_context_params {
                match value {
                    AwsStaticValue::Bool(v) => self.line(&format!(
                        "params.set_bool(String(\"{}\"), {})",
                        escape(name),
                        if *v { "True" } else { "False" }
                    )),
                    AwsStaticValue::Str(v) => self.line(&format!(
                        "params.set_string(String(\"{}\"), String(\"{}\"))",
                        escape(name),
                        escape(v)
                    )),
                }
            }
            self.line("var outcome = rules.resolve(params)");
            self.line("if outcome.is_error:");
            self.push();
            self.line("raise Error(");
            self.push();
            self.line(&format!(
                "String(\"{mn}: the endpoint ruleset chose no endpoint for {}: \") + outcome.error",
                escape(&facts.name)
            ));
            self.pop();
            self.line(")");
            self.pop();
            self.line("return outcome.endpoint.copy()");
            self.pop();
            self.blank();
        }
        self.blank();
        Ok(())
    }

    fn is_client_context_param(&self, name: &str) -> bool {
        self.meta.client_context_params.iter().any(|c| c.name == name)
    }

    /// `params.<setter>("<param>", input.a.b)`, inside one `if` per optional
    /// step of the path.
    fn emit_input_binding(&mut self, b: &InputBinding) {
        let mut expr = "input".to_string();
        let mut opened = 0;
        for (i, s) in b.steps.iter().enumerate() {
            let last = i + 1 == b.steps.len();
            let access = format!("{expr}.{}", s.field);
            if s.optional {
                self.line(&format!("if {access}:"));
                self.push();
                opened += 1;
                if last {
                    expr = format!("{access}.value()");
                } else {
                    let name = format!("_ep{i}");
                    self.line(&format!("ref {name} = {access}.value()"));
                    expr = name;
                }
            } else {
                expr = access;
            }
        }
        self.line(&format!(
            "params.{}(String(\"{}\"), {expr})",
            b.ty.setter(),
            escape(&b.param)
        ));
        for _ in 0..opened {
            self.pop();
        }
    }
}

fn declared<'r>(
    rules: &'r AwsEndpointRules,
    name: &str,
    what: &str,
) -> Result<&'r RulesetParam, String> {
    rules.param(name).ok_or_else(|| {
        format!(
            "aws endpoint rules: {what} binds `{name}`, which the endpoint ruleset does not \
             declare (is it this service's ruleset?)"
        )
    })
}

fn same_type(p: &RulesetParam, ty: RulesetParamType, what: &str) -> Result<(), String> {
    if p.ty != ty {
        return Err(format!(
            "aws endpoint rules: {what} binds `{}` to a {}, and the ruleset declares it a {}",
            p.name,
            ty.name(),
            p.ty.name()
        ));
    }
    Ok(())
}

/// The value the AWS SDKs give built-in `rp` when their caller sets none,
/// for a built-in whose ruleset parameter declares no default. One today:
/// `AWS::Auth::AccountIdEndpointMode`, whose SDK setting
/// (`account_id_endpoint_mode`) defaults to `preferred`, so an account id
/// the caller supplies picks the account-based endpoint where the ruleset
/// has one.
fn sdk_built_in_default(rp: &RulesetParam) -> Option<&'static str> {
    if rp.has_default || rp.ty != RulesetParamType::Str {
        return None;
    }
    match rp.built_in.as_deref() {
        Some("AWS::Auth::AccountIdEndpointMode") => Some("preferred"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::aws_in::lower_aws_service;
    use crate::emit_aws::{emit_aws_module_with_endpoints, AwsEmitOptions, AwsProvenance};
    use crate::overrides::AwsOverrides;

    /// A ruleset declaring `params` (JSON members of `parameters`), with one
    /// unconditional endpoint rule.
    fn ruleset(params: &str) -> String {
        format!(
            r#"{{"version": "1.0", "parameters": {{{params}}},
                "rules": [{{"conditions": [], "type": "endpoint",
                            "endpoint": {{"url": "https://example.com"}}}}]}}"#
        )
    }

    const PARTITIONS: &str = r#"{"partitions": [{"id": "aws", "outputs": {}}]}"#;

    const S3_LIKE: &str = r#"
        "Region": {"builtIn": "AWS::Region", "type": "String", "required": false},
        "UseFIPS": {"builtIn": "AWS::UseFIPS", "type": "Boolean", "required": true, "default": false},
        "Endpoint": {"builtIn": "SDK::Endpoint", "type": "string"},
        "ForcePathStyle": {"builtIn": "AWS::S3::ForcePathStyle", "type": "boolean", "default": false},
        "Bucket": {"type": "string"},
        "Key": {"type": "string"},
        "Arns": {"type": "stringArray"},
        "DisableSession": {"type": "boolean"},
        "Mode": {"type": "string"}"#;

    fn rules(params: &str) -> AwsEndpointRules {
        AwsEndpointRules::parse(&ruleset(params), "r".repeat(64).as_str(), PARTITIONS, "p".repeat(64).as_str())
            .unwrap()
    }

    /// A one-operation awsJson model: `op` is merged into the operation,
    /// `members` are the input's members, and `extra` into the model root.
    fn model(op: &str, members: &str, extra: &str) -> Json {
        parse(&format!(
            r#"{{"version": "2.0",
                "metadata": {{"apiVersion": "2026-10-02", "endpointPrefix": "tiny",
                    "jsonVersion": "1.1", "protocol": "json", "serviceFullName": "Tiny",
                    "serviceId": "Tiny", "signatureVersion": "v4",
                    "targetPrefix": "Tiny", "uid": "tiny-2026-10-02"}},
                "operations": {{"Op": {{"name": "Op",
                    "http": {{"method": "POST", "requestUri": "/"}},
                    "input": {{"shape": "In"}}{op}}}}},
                "shapes": {{"In": {{"type": "structure", "required": ["Bucket"],
                                   "members": {{{members}}}}},
                           "Inner": {{"type": "structure",
                                      "members": {{"Name": {{"shape": "Str"}},
                                                  "Flag": {{"shape": "Bool"}}}}}},
                           "Str": {{"type": "string"}},
                           "Bool": {{"type": "boolean"}},
                           "Strs": {{"type": "list", "member": {{"shape": "Str"}}}}}}{extra}}}"#
        ))
        .unwrap()
    }

    const MEMBERS: &str = r#""Bucket": {"shape": "Str", "contextParam": {"name": "Bucket"}},
                             "Key": {"shape": "Str", "contextParam": {"name": "Key"}},
                             "Inner": {"shape": "Inner"},
                             "Arns": {"shape": "Strs"}"#;

    fn emit(m: &Json, r: &AwsEndpointRules) -> Result<String, String> {
        let lowering = lower_aws_service(m, "tiny", &["Op".to_string()], "tiny.json", "aws.tiny")?;
        let options = AwsEmitOptions { pure_only: true, ..Default::default() };
        let prov = AwsProvenance { model_key: "tiny/2026-10-02", model_sha256: "m" };
        emit_aws_module_with_endpoints(
            &lowering,
            &AwsOverrides::empty(),
            "tiny",
            options,
            Some(prov),
            Some(r),
        )
        .map(|e| e.source)
    }

    #[test]
    fn minify_removes_whitespace_between_tokens_only() {
        assert_eq!(
            minify("{ \"a b\" : [ 1 ,\n\t\"x\\\" y\" ] }").unwrap(),
            "{\"a b\":[1,\"x\\\" y\"]}"
        );
        assert!(minify("{\"a").is_err());
    }

    #[test]
    fn parse_reads_parameters_and_refuses_malformed_documents() {
        let r = rules(S3_LIKE);
        assert_eq!(r.params.len(), 9);
        let region = r.param("Region").unwrap();
        assert_eq!(region.ty, RulesetParamType::Str);
        assert_eq!(region.built_in.as_deref(), Some("AWS::Region"));
        assert!(r.param("UseFIPS").unwrap().required);
        assert!(r.param("UseFIPS").unwrap().has_default);
        assert_eq!(r.param("Arns").unwrap().ty, RulesetParamType::StrArray);
        assert!(r.ruleset.starts_with("{\"version\":\"1.0\",\"parameters\":{\"Region\":{"));
        let refuse = |text: &str, parts: &str| {
            AwsEndpointRules::parse(text, "r", parts, "p").unwrap_err()
        };
        assert!(refuse(r#"{"version": "2.0", "parameters": {}, "rules": []}"#, PARTITIONS)
            .contains("only 1.x is interpreted"));
        assert!(refuse(&ruleset(r#""X": {"type": "integer"}"#), PARTITIONS)
            .contains("unknown type `integer`"));
        assert!(refuse(&ruleset(""), "{}").contains("no `partitions` array"));
    }

    #[test]
    fn bindings_are_emitted_in_precedence_order() {
        let op = r#", "staticContextParams": {"DisableSession": {"value": true},
                                              "Mode": {"value": "fixed"}},
                     "operationContextParams": {"Key": {"path": "Inner.Name"},
                                                "Arns": {"path": "Arns"}}"#;
        let extra = r#", "clientContextParams": {"ForcePathStyle": {"type": "boolean"},
                                                  "DisableSession": {"type": "boolean"}}"#;
        let src = emit(&model(op, MEMBERS, extra), &rules(S3_LIKE)).unwrap();
        // The header records both digests, and the interpreter is imported.
        assert!(src.contains(&format!("#   endpoints    : ruleset sha256 {}", "r".repeat(64))));
        assert!(src.contains("    EndpointRuleSet,\n"));
        // The config: built-ins and clientContextParams, in ruleset order;
        // Bucket, Key, Arns and Mode are none of those.
        let cfg = &src[src.find("struct TinyEndpointConfig").unwrap()..];
        let fields: Vec<&str> = cfg
            .lines()
            .filter(|l| l.starts_with("    var "))
            .collect();
        assert_eq!(
            &fields[..5],
            &[
                "    var region: Optional[String]",
                "    var use_fips: Optional[Bool]",
                "    var endpoint: Optional[String]",
                "    var force_path_style: Optional[Bool]",
                "    var disable_session: Optional[Bool]",
            ]
        );
        // Two constructors: every parameter unset, and Region set unless "".
        assert!(cfg.contains("def __init__(out self):"));
        assert!(cfg.contains("def __init__(out self, region: String):"));
        assert!(cfg.contains("if region.byte_length() > 0:\n            self.region = Optional[String](region)"));
        assert!(cfg.contains("A custom `endpoint` keeps the ruleset's addressing"));
        // One resolver, binding: the config, then operationContextParams,
        // then contextParam members, then staticContextParams.
        let body = &src[src.find("def resolve_op_endpoint(").unwrap()..];
        let order = [
            "var params = config.endpoint_params()",
            "if input.inner:",
            "ref _ep0 = input.inner.value()",
            "if _ep0.name:",
            "params.set_string(String(\"Key\"), _ep0.name.value())",
            "if input.arns:",
            "params.set_string_array(String(\"Arns\"), input.arns.value())",
            "params.set_string(String(\"Bucket\"), input.bucket)",
            "if input.key:",
            "params.set_string(String(\"Key\"), input.key.value())",
            "params.set_bool(String(\"DisableSession\"), True)",
            "params.set_string(String(\"Mode\"), String(\"fixed\"))",
            "var outcome = rules.resolve(params)",
            "return outcome.endpoint.copy()",
        ];
        let mut at = 0;
        for want in order {
            let i = body[at..].find(want).unwrap_or_else(|| panic!("`{want}` missing or out of order"));
            at += i + want.len();
        }
    }

    #[test]
    fn the_account_id_endpoint_mode_built_in_starts_as_the_sdk_default() {
        let params = r#""Region": {"builtIn": "AWS::Region", "type": "String"},
            "AccountId": {"builtIn": "AWS::Auth::AccountId", "type": "String"},
            "AccountIdEndpointMode": {"builtIn": "AWS::Auth::AccountIdEndpointMode",
                                      "type": "String"}"#;
        let plain = r#""Bucket": {"shape": "Str"}"#;
        let src = emit(&model("", plain, ""), &rules(params)).unwrap();
        let cfg = &src[src.find("struct TinyEndpointConfig").unwrap()..];
        assert!(cfg.contains("Every parameter unset but those the AWS SDKs default."));
        assert!(cfg.contains(
            "self.account_id_endpoint_mode = Optional[String](String(\"preferred\"))"
        ));
        assert!(cfg.contains("self.account_id = Optional[String]()"));
        assert!(cfg.contains(
            "`account_id_endpoint_mode` starts as `preferred` (AWS::Auth::AccountIdEndpointMode);"
        ));
        // A ruleset default of its own wins: the field stays unset.
        let declared = params.replace(
            r#""AWS::Auth::AccountIdEndpointMode","#,
            r#""AWS::Auth::AccountIdEndpointMode", "default": "disabled","#,
        );
        let src = emit(&model("", plain, ""), &rules(&declared)).unwrap();
        assert!(src.contains("self.account_id_endpoint_mode = Optional[String]()"));
        assert!(!src.contains("preferred"));
        // Without the built-in nothing changes.
        let s3_like = emit(&model("", MEMBERS, ""), &rules(S3_LIKE)).unwrap();
        assert!(s3_like.contains("\"\"\"Every parameter unset.\"\"\""));
    }

    fn emit_without_ruleset(m: &Json) -> String {
        let lowering = lower_aws_service(m, "tiny", &["Op".to_string()], "tiny.json", "aws.tiny").unwrap();
        let options = AwsEmitOptions { pure_only: true, ..Default::default() };
        let prov = AwsProvenance { model_key: "tiny/2026-10-02", model_sha256: "m" };
        crate::emit_aws::emit_aws_module(&lowering, &AwsOverrides::empty(), "tiny", options, Some(prov))
            .unwrap()
            .source
    }

    #[test]
    fn a_module_without_a_ruleset_has_no_endpoint_section() {
        let plain = r#""Bucket": {"shape": "Str"}, "Inner": {"shape": "Inner"}, "Arns": {"shape": "Strs"}"#;
        let src = emit_without_ruleset(&model("", plain, ""));
        for absent in ["EndpointRuleSet", "EndpointConfig", "§E", "endpoints    :"] {
            assert!(!src.contains(absent), "{absent}");
        }
    }

    #[test]
    fn a_module_without_a_ruleset_names_the_bindings_it_does_not_apply() {
        let op = r#", "staticContextParams": {"DisableSession": {"value": true}},
                     "operationContextParams": {"Key": {"path": "Inner.Name"}}"#;
        let extra = r#", "clientContextParams": {"ForcePathStyle": {"type": "boolean"}}"#;
        let src = emit_without_ruleset(&model(op, MEMBERS, extra));
        for absent in ["EndpointRuleSet", "EndpointConfig", "§E"] {
            assert!(!src.contains(absent), "{absent}");
        }
        let header = &src[..src.find("\n\n").unwrap()];
        for want in [
            "#   endpoints    : NO RULESET. Requests go to the static service host,",
            "#                  - clientContextParams: ForcePathStyle",
            "#                  - Op: contextParam Bucket -> Bucket, Key -> Key;",
            "#                    operationContextParams Inner.Name -> Key;",
            "#                    staticContextParams DisableSession",
        ] {
            assert!(header.contains(want), "`{want}` missing from\n{header}");
        }
    }

    #[test]
    fn a_binding_the_ruleset_does_not_declare_is_refused() {
        let members = r#""Bucket": {"shape": "Str", "contextParam": {"name": "Buckett"}}"#;
        let e = emit(&model("", members, ""), &rules(S3_LIKE)).unwrap_err();
        assert!(e.contains("binds `Buckett`, which the endpoint ruleset does not declare"), "{e}");
        let op = r#", "staticContextParams": {"Nope": {"value": true}}"#;
        let e = emit(&model(op, MEMBERS, ""), &rules(S3_LIKE)).unwrap_err();
        assert!(e.contains("the staticContextParams of `Op` binds `Nope`"), "{e}");
        let extra = r#", "clientContextParams": {"Nope": {"type": "boolean"}}"#;
        let e = emit(&model("", MEMBERS, extra), &rules(S3_LIKE)).unwrap_err();
        assert!(e.contains("the model's clientContextParams binds `Nope`"), "{e}");
    }

    #[test]
    fn a_binding_of_another_type_is_refused() {
        let op = r#", "staticContextParams": {"Mode": {"value": true}}"#;
        let e = emit(&model(op, MEMBERS, ""), &rules(S3_LIKE)).unwrap_err();
        assert!(e.contains("binds `Mode` to a boolean, and the ruleset declares it a string"), "{e}");
        let members = r#""Bucket": {"shape": "Str"},
                         "Flag": {"shape": "Bool", "contextParam": {"name": "Key"}}"#;
        let e = emit(&model("", members, ""), &rules(S3_LIKE)).unwrap_err();
        assert!(e.contains("binds `Key` to a boolean, and the ruleset declares it a string"), "{e}");
        let op = r#", "operationContextParams": {"Bucket": {"path": "Arns"}}"#;
        let e = emit(&model(op, MEMBERS, ""), &rules(S3_LIKE)).unwrap_err();
        assert!(e.contains("binds `Bucket` to a stringArray"), "{e}");
    }

    #[test]
    fn an_operation_context_path_beyond_a_member_path_is_refused() {
        for (path, why) in [
            ("keys(Inner)", "only a member path"),
            ("Arns[*]", "only a member path"),
            ("Inner.Missing", "declares no member `Missing`"),
            ("Bucket.Name", "`Bucket` is not a structure"),
            ("Inner", "is not a string, a boolean or a list of strings"),
        ] {
            let op = format!(r#", "operationContextParams": {{"Key": {{"path": "{path}"}}}}"#);
            let e = emit(&model(&op, MEMBERS, ""), &rules(S3_LIKE)).unwrap_err();
            assert!(e.contains("REFUSED operation-context-param"), "{path}: {e}");
            assert!(e.contains(why), "{path}: {e}");
        }
    }

    /// A one-operation restJson1 client module whose label `{Bucket}` is
    /// also the ruleset's `Bucket`, emitted with `r` or without a ruleset.
    fn emit_rest_json(r: Option<&AwsEndpointRules>) -> String {
        let m = parse(
            r#"{"version": "2.0",
                "metadata": {"apiVersion": "2026-10-02", "endpointPrefix": "tiny",
                    "protocol": "rest-json", "serviceFullName": "Tiny",
                    "serviceId": "Tiny", "signatureVersion": "v4",
                    "uid": "tiny-2026-10-02"},
                "operations": {"Op": {"name": "Op",
                    "http": {"method": "GET", "requestUri": "/{Bucket}"},
                    "input": {"shape": "In"},
                    "staticContextParams": {"DisableSession": {"value": true}}}},
                "shapes": {"In": {"type": "structure", "required": ["Bucket"],
                                  "members": {"Bucket": {"shape": "Str",
                                      "location": "uri", "locationName": "Bucket",
                                      "contextParam": {"name": "Bucket"}}}},
                           "Str": {"type": "string"}}}"#,
        )
        .unwrap();
        let lowering = lower_aws_service(&m, "tiny", &["Op".to_string()], "tiny.json", "aws.tiny").unwrap();
        let prov = AwsProvenance { model_key: "tiny/2026-10-02", model_sha256: "m" };
        emit_aws_module_with_endpoints(
            &lowering,
            &AwsOverrides::empty(),
            "tiny",
            AwsEmitOptions::default(),
            Some(prov),
            r,
        )
        .unwrap()
        .source
    }

    #[test]
    fn a_rest_json_client_resolves_through_its_ruleset() {
        let src = emit_rest_json(Some(&rules(S3_LIKE)));
        // The REST binding's client import and the interpreter, side by side.
        assert!(src.contains("    aws_rest_json_error,\n"));
        assert!(src.contains("    EndpointRuleSet,\n"));
        assert!(src.contains(&format!("#   endpoints    : ruleset sha256 {}", "r".repeat(64))));
        // The REST request builder is there, and so is the resolver, binding
        // the label member and the operation's static parameter.
        assert!(src.contains("AwsRestUri"));
        let body = &src[src.find("def resolve_op_endpoint(").unwrap()..];
        let mut at = 0;
        for want in [
            "var params = config.endpoint_params()",
            "params.set_string(String(\"Bucket\"), input.bucket)",
            "params.set_bool(String(\"DisableSession\"), True)",
            "var outcome = rules.resolve(params)",
        ] {
            let i = body[at..].find(want).unwrap_or_else(|| panic!("`{want}` missing or out of order"));
            at += i + want.len();
        }
    }

    #[test]
    fn a_ruleset_client_sends_where_the_ruleset_resolves_each_call() {
        let src = emit_rest_json(Some(&rules(S3_LIKE)));
        // The client holds the ruleset and its configuration, not a static
        // host, and imports what turns a resolved endpoint into a target.
        for want in [
            "    AwsSigningTarget,\n    aws_signing_target,\n",
            "    var _endpoint_config: TinyEndpointConfig\n",
            "    var _rules: EndpointRuleSet\n",
            "        var endpoint_config: TinyEndpointConfig = TinyEndpointConfig(),\n    ) raises:\n",
            "        var rules = tiny_endpoint_rules()\n",
            "    def send(mut self, var req: AwsRequest, target: AwsSigningTarget) raises -> HttpResult:\n",
            "            target.signing_region.copy(),\n            target.signing_name.copy(),\n            target.endpoint.with_host_prefix(req.host_prefix),\n",
        ] {
            assert!(src.contains(want), "`{want}` missing");
        }
        assert!(!src.contains("_endpoint_override"));
        assert!(!src.contains("resolve_endpoint(self._endpoint_override"));
        // Each verb resolves its own endpoint, from its own input.
        let verb = &src[src.find("    def op(mut self").unwrap()..];
        let mut at = 0;
        for want in [
            "var req = build_op_request(input)",
            "var target = aws_signing_target(",
            "resolve_op_endpoint(self._rules, self._endpoint_config, input),",
            "self._region.copy(),",
            "String(TINY_SERVICE),",
            "var res = self.send(req^, target)",
        ] {
            let i = verb[at..].find(want).unwrap_or_else(|| panic!("`{want}` missing or out of order"));
            at += i + want.len();
        }
    }

    #[test]
    fn a_rest_json_client_without_a_ruleset_keeps_the_static_host() {
        let src = emit_rest_json(None);
        for absent in ["EndpointRuleSet", "EndpointConfig", "§E", "resolve_op_endpoint"] {
            assert!(!src.contains(absent), "{absent}");
        }
        let header = &src[..src.find("\n\n").unwrap()];
        for want in [
            "#   endpoints    : NO RULESET. Requests go to the static service host,",
            "#                  - Op: contextParam Bucket -> Bucket; staticContextParams",
        ] {
            assert!(header.contains(want), "`{want}` missing from\n{header}");
        }
        assert!(src.contains("resolve_endpoint(self._endpoint_override, tiny_host("));
    }

    /// A restXml S3 model (serviceId `S3`) of three operations whose
    /// requestUri starts with `/{Bucket}`, emitted with the `s3`
    /// customization, with `r` or without a ruleset. `context` is the
    /// Bucket member's `contextParam` clause (with its leading comma).
    fn emit_s3_paths(r: Option<&AwsEndpointRules>, context: &str) -> Result<String, String> {
        let m = parse(&format!(
            r#"{{"version": "2.0",
                "metadata": {{"apiVersion": "2026-10-02", "endpointPrefix": "s3",
                    "protocol": "rest-xml", "serviceFullName": "Tiny S3",
                    "serviceId": "S3", "signatureVersion": "s3",
                    "auth": ["aws.auth#sigv4"], "uid": "s3-2026-10-02"}},
                "operations": {{
                    "GetKey": {{"name": "GetKey",
                        "http": {{"method": "GET", "requestUri": "/{{Bucket}}/{{Key+}}"}},
                        "input": {{"shape": "KeyIn"}}}},
                    "List": {{"name": "List",
                        "http": {{"method": "GET", "requestUri": "/{{Bucket}}?list-type=2"}},
                        "input": {{"shape": "In"}}}},
                    "HeadIt": {{"name": "HeadIt",
                        "http": {{"method": "HEAD", "requestUri": "/{{Bucket}}"}},
                        "input": {{"shape": "In"}}}}}},
                "shapes": {{
                    "In": {{"type": "structure", "required": ["Bucket"], "members": {{
                        "Bucket": {{"shape": "Str", "location": "uri",
                                   "locationName": "Bucket"{context}}}}}}},
                    "KeyIn": {{"type": "structure", "required": ["Bucket", "Key"], "members": {{
                        "Bucket": {{"shape": "Str", "location": "uri",
                                   "locationName": "Bucket"{context}}},
                        "Key": {{"shape": "Str", "location": "uri", "locationName": "Key"}}}}}},
                    "Str": {{"type": "string"}}}}}}"#
        ))
        .unwrap();
        let ops: Vec<String> = ["GetKey", "HeadIt", "List"].iter().map(|s| s.to_string()).collect();
        let lowering = lower_aws_service(&m, "s3", &ops, "s3.json", "aws.s3").unwrap();
        let prov = AwsProvenance { model_key: "s3/2026-10-02", model_sha256: "m" };
        let options = AwsEmitOptions { pure_only: true, s3: true, ..Default::default() };
        emit_aws_module_with_endpoints(&lowering, &AwsOverrides::empty(), "s3", options, Some(prov), r)
            .map(|e| e.source)
    }

    const BUCKET_CONTEXT: &str = r#", "contextParam": {"name": "Bucket"}"#;

    #[test]
    fn s3_with_a_ruleset_leaves_the_bucket_to_the_ruleset() {
        let src = emit_s3_paths(Some(&rules(S3_LIKE)), BUCKET_CONTEXT).unwrap();
        // The bucket is dropped from the path, and a path left empty is the
        // root; the query stays.
        for want in [
            "AwsRestUri.expand(String(\"/{Key+}\"), _ln, _lv)",
            "AwsRestUri.expand(String(\"/?list-type=2\"), _ln, _lv)",
            "AwsRestUri.expand(String(\"/\"), _ln, _lv)",
        ] {
            assert!(src.contains(want), "`{want}` missing from\n{src}");
        }
        assert!(!src.contains("_ln.append(String(\"Bucket\"))"), "{src}");
        assert!(src.contains("#                  and a leading /{Bucket} dropped from each path:"), "{src}");
        assert!(src.contains("_ln.append(String(\"Key\"))"), "{src}");
        // The ruleset is given the bucket.
        assert!(src.contains("params.set_string(String(\"Bucket\"), input.bucket)"), "{src}");
    }

    #[test]
    fn s3_without_a_ruleset_keeps_the_bucket_in_the_path() {
        let src = emit_s3_paths(None, BUCKET_CONTEXT).unwrap();
        for want in [
            "AwsRestUri.expand(String(\"/{Bucket}/{Key+}\"), _ln, _lv)",
            "AwsRestUri.expand(String(\"/{Bucket}?list-type=2\"), _ln, _lv)",
            "AwsRestUri.expand(String(\"/{Bucket}\"), _ln, _lv)",
        ] {
            assert!(src.contains(want), "`{want}` missing from\n{src}");
        }
        assert!(!src.contains("dropped from each path"), "{src}");
    }

    #[test]
    fn s3_refuses_to_drop_a_bucket_the_ruleset_is_not_given() {
        let e = emit_s3_paths(Some(&rules(S3_LIKE)), "").unwrap_err();
        assert!(e.contains("the bucket would be sent nowhere"), "{e}");
        assert!(e.contains("{Bucket}"), "{e}");
    }

    #[test]
    fn omit_preamble_mode_refuses_a_ruleset() {
        let m = model("", MEMBERS, "");
        let lowering = lower_aws_service(&m, "tiny", &["Op".to_string()], "tiny.json", "aws.tiny").unwrap();
        let options = AwsEmitOptions { pure_only: true, omit_preamble: true, ..Default::default() };
        let r = rules(S3_LIKE);
        let e = emit_aws_module_with_endpoints(&lowering, &AwsOverrides::empty(), "tiny", options, None, Some(&r))
            .unwrap_err();
        assert!(e.contains("omit_preamble"), "{e}");
    }
}
