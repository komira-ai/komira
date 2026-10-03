//! The awsJson body codec: a shape as a `JsonValue` and back, plus the
//! botocore MODEL convention the conformance corpus states values in.
//!
//! Every method here writes one method of a generated shape struct. The
//! JSON runtime is `komira_json` (`JsonValue`) and the scalar encoders are
//! the core's `aws_json_*` names; both arrive through the
//! [`super::AWS_IMPORTS`] rows scoped to [`super::JSON_BODY_PROTOCOLS`].

use super::proto::BodyCodec;
use super::{ts_const, AwsEmitter};
use crate::ir::{IrField, IrMessage, IrType, Label, ScalarKind};

/// The JSON body codec, shared by every protocol whose body is a JSON
/// document. Only awsJson (`json`) reaches it today.
pub(super) struct AwsJsonCodec;

impl BodyCodec for AwsJsonCodec {
    fn emit_shape_doc(&self, em: &mut AwsEmitter, is_union: bool, is_synthetic: bool) {
        if is_union {
            em.line("    ⛔ THIS IS AN AWS `union` SHAPE — EXACTLY ONE member may be set.");
            em.line("    awsJson serialises a union as an object with a single key, so");
            em.line("    `to_aws_json` REFUSES a value with zero or two set members rather");
            em.line("    than emitting a body the service will reject with an error that");
            em.line("    names neither member.");
            em.blank();
        }
        if is_synthetic {
            em.line("    SYNTHESISED: the operation declares no shape here. awsJson still");
            em.line("    requires `{}` on the wire, which is what this empty struct emits.");
            em.blank();
        }
        em.line("    Required members are plain fields taken by `__init__`; every other");
        em.line("    member is `Optional[...]` and is OMITTED from the body when unset.");
        em.line("    PRESENCE IS NOT EMPTINESS: an explicitly-set empty list serialises as");
        em.line("    `[]` and an unset one is absent, which the corpus distinguishes");
        em.line("    (`serializes_empty_list_shapes`).\"\"\"");
    }

    fn emit_encoder(&self, em: &mut AwsEmitter, msg: &IrMessage, is_union: bool) -> Result<(), String> {
        em.emit_to_json(msg, is_union)
    }

    fn emit_decoder(&self, em: &mut AwsEmitter, msg: &IrMessage) -> Result<(), String> {
        em.emit_from_json(msg)
    }

    fn emit_model_value(&self, em: &mut AwsEmitter, msg: &IrMessage) -> Result<(), String> {
        em.emit_model_json(msg)
    }
}

impl AwsEmitter<'_> {
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
}
