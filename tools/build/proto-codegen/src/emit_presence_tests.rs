//! The generated `encode` and field presence (komira-ai/komira#349).
//!
//! The proto3 JSON mapping omits an implicit-presence field (a plain proto3
//! scalar or enum) holding its default; the generated `encode` guards each
//! such write with the encoder's `OMITS_IMPLICIT_DEFAULTS`, so the JSON
//! backend skips the default and the binary backend writes it as before. An
//! explicit-presence field (`optional`, a oneof member, a message) keeps its
//! own presence check and no default guard. A repeated or map field is
//! omitted when empty by the JSON encoder itself and takes no guard here.

use super::*;
use crate::ir::{IrField, IrFile, IrMessage, IrOneof, IrType, Label, ScalarKind, TypeRef};

fn field(name: &str, no: u32, ty: IrType, label: Label, oneof: Option<u32>) -> IrField {
    IrField {
        name: name.to_string(),
        ty,
        label,
        proto_field_number: no,
        json_name: name.to_string(),
        oneof_index: oneof,
    }
}

fn color() -> IrType {
    IrType::Enum(TypeRef { fq_name: ".p.Color".to_string(), mojo_name: "Color".to_string() })
}

fn file(fields: Vec<IrField>, oneofs: Vec<IrOneof>) -> IrFile {
    IrFile {
        proto_path: "p/p.proto".to_string(),
        proto_package: "p".to_string(),
        mojo_package: "p".to_string(),
        messages: vec![IrMessage {
            name: "M".to_string(),
            mojo_name: "M".to_string(),
            fq_name: ".p.M".to_string(),
            is_map_entry: false,
            fields,
            oneofs,
        }],
        enums: vec![],
        services: vec![],
        imports: vec![],
    }
}

/// The guard line and the write it guards, at `encode`'s body indent.
fn guarded(cond: &str, write: &str) -> String {
    format!(
        "        if not E.OMITS_IMPLICIT_DEFAULTS or {cond}:\n            {write}\n"
    )
}

#[test]
fn every_implicit_presence_scalar_and_enum_is_guarded_by_its_default() {
    use ScalarKind::*;
    // (kind, field, the default test, the write suffix)
    let kinds = [
        (String, "s", "self.s.byte_length() > 0", "string"),
        (Bytes, "by", "len(self.by) > 0", "bytes"),
        (Bool, "b", "self.b", "bool"),
        (Int32, "i32", "self.i32 != 0", "i32"),
        (Int64, "i64", "self.i64 != 0", "i64"),
        (Uint32, "u32", "self.u32 != 0", "u32"),
        (Uint64, "u64", "self.u64 != 0", "u64"),
        (Sint32, "si32", "self.si32 != 0", "sint32"),
        (Sint64, "si64", "self.si64 != 0", "sint64"),
        (Fixed32, "f32x", "self.f32x != 0", "fixed32"),
        (Fixed64, "f64x", "self.f64x != 0", "fixed64"),
        (Sfixed32, "sf32", "self.sf32 != 0", "sfixed32"),
        (Sfixed64, "sf64", "self.sf64 != 0", "sfixed64"),
        // A float's default is +0.0 alone: -0.0 carries a sign, NaN is data.
        (Float, "fl", "bitcast[DType.uint32](self.fl) != 0", "f32"),
        (Double, "db", "bitcast[DType.uint64](self.db) != 0", "f64"),
    ];
    let mut fields: Vec<IrField> = kinds
        .iter()
        .enumerate()
        .map(|(i, (k, n, _, _))| field(n, i as u32 + 1, IrType::Scalar(*k), Label::Single, None))
        .collect();
    fields.push(field("color", 99, color(), Label::Single, None));
    let out = Emitter::new(&file(fields, vec![])).emit();
    for (i, (_, n, cond, suf)) in kinds.iter().enumerate() {
        let write = format!("enc.write_{suf}_field({}, \"{n}\", self.{n})", i + 1);
        assert!(out.contains(&guarded(cond, &write)), "{n}; got:\n{out}");
    }
    assert!(
        out.contains(&guarded(
            "self.color.number() != 0",
            "enc.write_enum_field[Color](99, \"color\", self.color)"
        )),
        "got:\n{out}"
    );
    // The float guards read the bits; nothing else in the file needs them.
    assert!(out.contains("\nfrom std.memory import bitcast\n"), "got:\n{out}");
}

#[test]
fn explicit_presence_fields_take_no_default_guard() {
    let s = || IrType::Scalar(ScalarKind::String);
    let inner = IrType::Message(TypeRef { fq_name: ".p.M".to_string(), mojo_name: "M".to_string() });
    let fields = vec![
        field("opt_s", 1, s(), Label::Optional, None),
        field("opt_d", 2, IrType::Scalar(ScalarKind::Double), Label::Optional, None),
        field("opt_color", 3, color(), Label::Optional, None),
        field("inner", 4, inner, Label::Optional, None),
        field("names", 5, s(), Label::Repeated, None),
        field("arm_s", 6, s(), Label::Optional, Some(0)),
        field("arm_color", 7, color(), Label::Optional, Some(0)),
    ];
    let oneofs = vec![IrOneof {
        name: "arm".to_string(),
        arms: vec!["arm_s".to_string(), "arm_color".to_string()],
    }];
    let out = Emitter::new(&file(fields, oneofs)).emit();
    assert!(!out.contains("OMITS_IMPLICIT_DEFAULTS"), "got:\n{out}");
    assert!(!out.contains("bitcast"), "an optional double needs no bit test; got:\n{out}");
    for set in [
        "        if self.opt_s:\n            enc.write_string_field(1, \"opt_s\", self.opt_s.value())\n",
        "        if self.opt_d:\n            enc.write_f64_field(2, \"opt_d\", self.opt_d.value())\n",
        "        if self.opt_color:\n            enc.write_enum_field[Color](3, \"opt_color\", self.opt_color.value())\n",
        "        if self._oneof0_case == 1:\n            enc.write_string_field(6, \"arm_s\", self.arm_s.value())\n",
        "        elif self._oneof0_case == 2:\n            enc.write_enum_field[Color](7, \"arm_color\", self.arm_color.value())\n",
    ] {
        assert!(out.contains(set), "{set}; got:\n{out}");
    }
}
