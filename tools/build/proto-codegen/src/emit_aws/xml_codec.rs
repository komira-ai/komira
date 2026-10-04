//! The restXml body codec: a shape as XML elements and back, plus the
//! botocore MODEL convention the conformance corpus states values in (the
//! JSON codec's, shared).
//!
//! Every structure gets two methods. `write_aws_xml(self, mut w)` writes the
//! structure's CHILD elements; its own element (name and namespace) is the
//! caller's, because the name is the referring member's (`locationName`) and
//! the namespace may be too. `from_aws_xml(node)` reads a structure from its
//! element. The element and namespace rules are the Smithy restXml
//! protocol's and botocore's (`serialize.py` `RestXMLSerializer`,
//! `parsers.py` `RestXMLParser`):
//!
//! - A member is an element named by its `locationName` (the member name
//!   when it has none), in declared member order. Only body members are
//!   elements: a member bound to the URI, the query, a header or the status
//!   is not in the document.
//! - A member's element carries the `xmlNamespace` of the member, else of
//!   the shape it targets.
//! - A list is wrapped (an element named for the member holding one element
//!   per item, named by the list member's `locationName`, `member` by
//!   default) or `flattened` (one element per item, each named for the
//!   member). An item carries the `xmlNamespace` of the list's member
//!   reference, else of the item shape. A list nested in a list is wrapped.
//! - A scalar is `komira_aws_core`'s XML scalar text; a timestamp is in the
//!   member's resolved format (date-time in a body by default).
//! - Reading matches elements by local name, takes the last occurrence of a
//!   non-list member and ignores elements the shape does not name
//!   (`komira_aws_core.aws_xml`).
//! - A map is read, never written: wrapped (an element named for the member
//!   holding one `<entry>` per entry) or `flattened` (one element per entry,
//!   each named for the member), each entry holding the key and value
//!   elements its `locationName`s name (`key` and `value` by default). The
//!   awsQuery and ec2Query responses (`query`) read maps through it; their
//!   requests are not XML.
//!
//! What this codec does not write or read is REFUSED by name before any
//! text is emitted ([`check_rest_xml_features`]): a union (`union`), a
//! member bound to an XML attribute (`xml-attribute`), and, in restXml, a
//! map in a body (`xml-map`). A map bound to prefixed headers, or to the query of a
//! request, is the REST binding's and is not refused; a response has no
//! URI or query, so a map bound to either in an output shape is a body map
//! and is refused too.

use super::proto::BodyCodec;
use super::{escape, ts_const, AwsEmitter};
use crate::aws_in::{
    AwsFacts, AwsLocation, AwsMemberFacts, AwsTimestampFormat, AwsXmlNamespace,
};
use crate::ir::{IrField, IrMessage, IrType, Label, ScalarKind};

/// The restXml body codec.
pub(super) struct AwsXmlCodec;

impl BodyCodec for AwsXmlCodec {
    fn emit_shape_doc(&self, em: &mut AwsEmitter, _is_union: bool, is_synthetic: bool) {
        if is_synthetic {
            em.line("    SYNTHESISED: the operation declares no shape here, so its request");
            em.line("    or response binds nothing and has no body.");
            em.blank();
        }
        em.line("    Required members are plain fields taken by `__init__`; every other");
        em.line("    member is `Optional[...]` and is OMITTED from the document when");
        em.line("    unset. PRESENCE IS NOT EMPTINESS: an explicitly-set empty list is");
        em.line("    written as its empty wrapper element and an unset one is absent.\"\"\"");
    }

    fn emit_encoder(&self, em: &mut AwsEmitter, msg: &IrMessage, _is_union: bool) -> Result<(), String> {
        em.emit_to_xml(msg)
    }

    fn emit_decoder(&self, em: &mut AwsEmitter, msg: &IrMessage) -> Result<(), String> {
        em.emit_from_xml(msg)
    }

    fn emit_model_value(&self, em: &mut AwsEmitter, msg: &IrMessage) -> Result<(), String> {
        em.emit_model_json(msg)
    }
}

/// The restXml features this codec refuses, checked over every shape and
/// member a lowering reaches. The error carries the refusal marker the
/// conformance harness reads (`REFUSED <name>:`).
pub(super) fn check_rest_xml_features(facts: &AwsFacts) -> Result<(), String> {
    for (name, s) in facts.shapes() {
        if s.union {
            return Err(format!(
                "emit_aws: REFUSED union: shape `{name}` is a `union`, and the restXml \
                 codec writes and reads structures only. A union has exactly one member \
                 element, which a structure codec would neither enforce on write nor \
                 check on read."
            ));
        }
    }
    for ((owner, field), m) in facts.members() {
        if m.xml_attribute {
            return Err(format!(
                "emit_aws: REFUSED xml-attribute: member `{}` of `{owner}` (`{field}`) is \
                 bound to an XML attribute (`xmlAttribute`), and the restXml codec writes \
                 and reads members as elements only. Written as an element, it would be \
                 a document the service reads without that value.",
                m.member_name
            ));
        }
    }
    for ((owner, field), m) in facts.members() {
        if m.location == AwsLocation::Body && reaches_map(facts, &m.shape)? {
            return Err(format!(
                "emit_aws: REFUSED xml-map: member `{}` of `{owner}` (`{field}`) is a map \
                 in an XML body (shape `{}`), and the restXml codec does not write or \
                 read maps. A map bound to the query or to prefixed headers is not \
                 refused.",
                m.member_name, m.shape
            ));
        }
    }
    // A response has no URI or query: a member of an output shape bound to
    // either is read from the body (`xml_read_from_body`), so a map there is
    // a body map.
    for (op, o) in facts.operations() {
        let Some(out) = &o.output_shape else { continue };
        let Some(fq) = &facts.shape(out)?.ir_fq_name else { continue };
        for ((owner, field), m) in facts.members() {
            if owner == fq
                && matches!(m.location, AwsLocation::Uri | AwsLocation::QueryString)
                && reaches_map(facts, &m.shape)?
            {
                return Err(format!(
                    "emit_aws: REFUSED xml-map: member `{}` of `{owner}` (`{field}`), the \
                     output of `{op}`, is a map bound to the URI or the query (shape `{}`). \
                     A response has neither, so it is read from the XML body, and the \
                     restXml codec does not read maps.",
                    m.member_name, m.shape
                ));
            }
        }
    }
    Ok(())
}

/// Whether the shape `name` is a map, or a list whose items are one at any
/// depth. A structure ends the walk: its own members are checked as members.
fn reaches_map(facts: &AwsFacts, name: &str) -> Result<bool, String> {
    let mut at = name.to_string();
    loop {
        let s = facts.shape(&at)?;
        match s.aws_type.as_str() {
            "map" => return Ok(true),
            "list" => match &s.element_shape {
                Some(e) => at = e.clone(),
                None => return Ok(false),
            },
            _ => return Ok(false),
        }
    }
}

/// Whether a member bound to `location` is read from the document: a body
/// member always, and in an operation's `response` a member bound to the URI
/// or the query too, since a response has neither (Smithy restXml, the
/// corpus's `IgnoreQueryParamsInResponse`). A header or the status never.
pub(super) fn xml_read_from_body(location: AwsLocation, response: bool) -> bool {
    match location {
        AwsLocation::Body => true,
        AwsLocation::Uri | AwsLocation::QueryString => response,
        _ => false,
    }
}

/// How one list is written and read: the item element's name and
/// namespace, whether the items are flattened into the parent, and the
/// item shape.
struct XmlList {
    item: String,
    item_ns: Option<AwsXmlNamespace>,
    flattened: bool,
    elem_shape: String,
}

/// How one map is read: the key and value element names, whether the
/// entries are flattened into the parent, and the value shape.
struct XmlMap {
    key: String,
    value: String,
    flattened: bool,
    value_shape: String,
}

impl AwsEmitter<'_> {
    /// The namespace on member `mf`'s element: the member's own, else the
    /// one of the shape it targets.
    fn xml_member_ns(&self, mf: &AwsMemberFacts) -> Option<AwsXmlNamespace> {
        mf.xml_namespace.clone().or_else(|| {
            self.facts
                .shape(&mf.shape)
                .ok()
                .and_then(|s| s.xml_namespace.clone())
        })
    }

    /// The list shape `list_shape`, reached by a member that is `flattened`
    /// itself when `member_flattened`.
    fn xml_list_of(&self, list_shape: &str, member_flattened: bool) -> Result<XmlList, String> {
        let s = self.facts.shape(list_shape)?;
        let elem_shape = s.element_shape.clone().ok_or_else(|| {
            format!("emit_aws: list shape `{list_shape}` has no member shape")
        })?;
        let item_ns = s.list_member_xml_namespace.clone().or_else(|| {
            self.facts
                .shape(&elem_shape)
                .ok()
                .and_then(|e| e.xml_namespace.clone())
        });
        Ok(XmlList {
            item: s
                .list_member_location_name
                .clone()
                .unwrap_or_else(|| "member".to_string()),
            item_ns,
            flattened: member_flattened || s.flattened,
            elem_shape,
        })
    }

    /// The map shape `map_shape`, reached by a member that is `flattened`
    /// itself when `member_flattened`.
    fn xml_map_of(&self, map_shape: &str, member_flattened: bool) -> Result<XmlMap, String> {
        let s = self.facts.shape(map_shape)?;
        let value_shape = s.element_shape.clone().ok_or_else(|| {
            format!("emit_aws: map shape `{map_shape}` has no value shape")
        })?;
        Ok(XmlMap {
            key: s
                .map_key_location_name
                .clone()
                .unwrap_or_else(|| "key".to_string()),
            value: s
                .map_value_location_name
                .clone()
                .unwrap_or_else(|| "value".to_string()),
            flattened: member_flattened || s.flattened,
            value_shape,
        })
    }

    /// Insert each entry element of `{entries}` (a `List[XmlNode]`) into
    /// the map `local`: its key's text, and its value read as `value_ty`. A
    /// later entry for a key replaces an earlier one.
    #[allow(clippy::too_many_arguments)]
    fn xml_read_entries(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        value_ty: &IrType,
        map: &XmlMap,
        entries: &str,
        local: &str,
        depth: usize,
    ) -> Result<(), String> {
        let iv = format!("_xk{depth}");
        let ev = format!("_xv{depth}_{}", f.name);
        let (k, v) = (escape(&map.key), escape(&map.value));
        self.line(&format!("for {iv} in range(len({entries})):"));
        self.push();
        self.line(&format!(
            "var {ev} = aws_xml_entry_value({entries}[{iv}], String(\"{k}\"), String(\"{v}\"))"
        ));
        let value = self.xml_read_value(msg, f, value_ty, &map.value_shape, &ev, depth + 1)?;
        self.line(&format!(
            "{local}[aws_xml_entry_key({entries}[{iv}], String(\"{k}\"), String(\"{v}\"))] = {value}"
        ));
        self.pop();
        Ok(())
    }

    /// `aws_xml_namespace` on the element just started, when there is one.
    fn xml_namespace_line(&mut self, w: &str, ns: &Option<AwsXmlNamespace>) {
        if let Some(ns) = ns {
            self.line(&format!(
                "aws_xml_namespace({w}, String(\"{}\"), String(\"{}\"))",
                escape(&ns.prefix),
                escape(&ns.uri)
            ));
        }
    }

    // ======================================================================
    // Writing
    // ======================================================================

    fn emit_to_xml(&mut self, msg: &IrMessage) -> Result<(), String> {
        self.line("def write_aws_xml(self, mut w: XmlWriter) raises:");
        self.push();
        self.line("\"\"\"This shape's member elements, into the element the caller opened.\"\"\"");
        let mut fields: Vec<IrField> = msg.fields.clone();
        self.sort_by_declared(msg, &mut fields);
        let mut wrote = false;
        for f in &fields {
            if self.facts.member(&msg.fq_name, &f.name)?.location != AwsLocation::Body {
                continue;
            }
            self.emit_xml_member_write(msg, f, "self", "w")?;
            wrote = true;
        }
        if !wrote {
            self.line("pass");
        }
        self.pop();
        Ok(())
    }

    /// `fields` in the shape's declared member order, which is the element
    /// order of a restXml document.
    pub(super) fn sort_by_declared(&self, msg: &IrMessage, fields: &mut [IrField]) {
        fields.sort_by_key(|f| {
            self.facts
                .member(&msg.fq_name, &f.name)
                .map(|m| m.declared_index)
                .unwrap_or(usize::MAX)
        });
    }

    /// The statements that write member `f` of `{base}` (a value of `msg`)
    /// as its element into the writer `{w}`: unconditionally for a required
    /// member, behind its presence test otherwise.
    pub(super) fn emit_xml_member_write(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        base: &str,
        w: &str,
    ) -> Result<(), String> {
        let mf = self.facts.member(&msg.fq_name, &f.name)?.clone();
        if self.required(msg, f) {
            let access = if self.is_boxed(msg, f) {
                format!("{base}.{}[0]", f.name)
            } else {
                format!("{base}.{}", f.name)
            };
            self.xml_write_field(msg, f, &mf, &access, w)
        } else {
            self.line(&format!("if {}:", self.presence_test_on(base, msg, f)));
            self.push();
            let access = self.optional_access_on(base, msg, f);
            self.xml_write_field(msg, f, &mf, &access, w)?;
            self.pop();
            Ok(())
        }
    }

    fn xml_write_field(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        mf: &AwsMemberFacts,
        access: &str,
        w: &str,
    ) -> Result<(), String> {
        let ns = self.xml_member_ns(mf);
        match (&f.label, &f.ty) {
            (Label::Repeated, ty) => {
                let list = self.xml_list_of(&mf.shape, mf.flattened)?;
                self.xml_write_list(msg, f, ty, &list, &mf.wire_name, &ns, access, w, 1)
            }
            (_, ty) => {
                self.xml_write_value(msg, f, ty, &mf.shape, &mf.wire_name, &ns, access, w, 1)
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn xml_write_list(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        elem_ty: &IrType,
        list: &XmlList,
        name: &str,
        ns: &Option<AwsXmlNamespace>,
        access: &str,
        w: &str,
        depth: usize,
    ) -> Result<(), String> {
        if !list.flattened {
            self.line(&format!("aws_xml_start({w}, String(\"{}\"))", escape(name)));
            self.xml_namespace_line(w, ns);
        }
        let iv = format!("_xi{depth}");
        self.line(&format!("for {iv} in range(len({access})):"));
        self.push();
        let item = if list.flattened { name.to_string() } else { list.item.clone() };
        let elem_shape = list.elem_shape.clone();
        let item_ns = list.item_ns.clone();
        self.xml_write_value(
            msg,
            f,
            elem_ty,
            &elem_shape,
            &item,
            &item_ns,
            &format!("{access}[{iv}]"),
            w,
            depth + 1,
        )?;
        self.pop();
        if !list.flattened {
            self.line(&format!("aws_xml_end({w})"));
        }
        Ok(())
    }

    /// The statements that write ONE value of type `ty` (AWS shape `shape`)
    /// as the element `name`.
    #[allow(clippy::too_many_arguments)]
    fn xml_write_value(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        ty: &IrType,
        shape: &str,
        name: &str,
        ns: &Option<AwsXmlNamespace>,
        access: &str,
        w: &str,
        depth: usize,
    ) -> Result<(), String> {
        let n = format!("String(\"{}\")", escape(name));
        match ty {
            IrType::List(e) => {
                let list = self.xml_list_of(shape, false)?;
                // A list nested in a list is always wrapped.
                let list = XmlList {
                    flattened: false,
                    ..list
                };
                self.xml_write_list(msg, f, e, &list, name, ns, access, w, depth)
            }
            IrType::Map(_, _) => Err(format!(
                "emit_aws: REFUSED xml-map: {}.{} holds a map in an XML body",
                msg.name, f.name
            )),
            IrType::Message(_) => {
                self.line(&format!("aws_xml_start({w}, {n})"));
                self.xml_namespace_line(w, ns);
                self.line(&format!("{access}.write_aws_xml({w})"));
                self.line(&format!("aws_xml_end({w})"));
                Ok(())
            }
            scalar => {
                let ts = self.timestamp_format(msg, f);
                if ns.is_none() {
                    let call = xml_scalar_write(scalar, ts, w, &n, access)?;
                    self.line(&call);
                } else {
                    let text = xml_scalar_text(scalar, ts, access)?;
                    self.line(&format!("aws_xml_start({w}, {n})"));
                    self.xml_namespace_line(w, ns);
                    self.line(&format!("{w}.text({text})"));
                    self.line(&format!("aws_xml_end({w})"));
                }
                Ok(())
            }
        }
    }

    // ======================================================================
    // Reading
    // ======================================================================

    pub(super) fn emit_from_xml(&mut self, msg: &IrMessage) -> Result<(), String> {
        let ty = self.ty_name(&msg.mojo_name);
        self.line("@staticmethod");
        self.line(&format!("def from_aws_xml(node: XmlNode) raises -> {ty}:"));
        self.push();
        self.line("\"\"\"Read this shape from its element. An element the shape does not");
        self.line("    name is ignored; a non-list member that occurs twice takes the last.\"\"\"");
        let required: Vec<IrField> = msg
            .fields
            .iter()
            .filter(|f| self.required(msg, f))
            .cloned()
            .collect();
        let what = format!("{ty}.from_aws_xml");
        for f in &required {
            self.emit_xml_read_required(msg, f, &what, false)?;
        }
        let args: Vec<String> = required.iter().map(|f| format!("_r_{}^", f.name)).collect();
        self.line(&format!("var out = {ty}({})", args.join(", ")));
        for f in &msg.fields {
            if self.required(msg, f) {
                continue;
            }
            self.emit_xml_read_optional(msg, f, false)?;
        }
        self.line("return out^");
        self.pop();
        Ok(())
    }

    /// The statements that read required member `f` of `msg` from the
    /// element `node` into the local `_r_<field>`, a constructor argument. A
    /// structure member that is absent is raised, naming `what`; any other
    /// absent member keeps its default. A member that is not in the body
    /// keeps its default.
    pub(super) fn emit_xml_read_required(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        what: &str,
        response: bool,
    ) -> Result<(), String> {
        let mf = self.facts.member(&msg.fq_name, &f.name)?.clone();
        let local = format!("_r_{}", f.name);
        if !xml_read_from_body(mf.location, response) {
            self.line(&format!("var {local} = {}", self.default_expr(msg, f)?));
            return Ok(());
        }
        let n = format!("String(\"{}\")", escape(&mf.wire_name));
        match (&f.label, &f.ty) {
            (Label::Repeated, ty) => {
                self.line(&format!("var {local} = {}", self.default_expr(msg, f)?));
                self.xml_read_list_into(msg, f, &mf, ty, &local)?;
            }
            (_, IrType::Map(_, v)) => {
                self.line(&format!("var {local} = {}", self.default_expr(msg, f)?));
                let entries = format!("_xs_{}", f.name);
                let map = self.xml_map_of(&mf.shape, mf.flattened)?;
                self.line(&format!(
                    "var {entries} = aws_xml_map_entries(node, {n}, {})",
                    if map.flattened { "True" } else { "False" }
                ));
                self.line(&format!("if {entries}:"));
                self.push();
                self.xml_read_entries(msg, f, v, &map, &format!("{entries}.value()"), &local, 1)?;
                self.pop();
            }
            (_, IrType::Message(_)) if self.needs_no_nullary(f) => {
                let idx = format!("_xc_{}", f.name);
                self.line(&format!("var {idx} = aws_xml_child(node, {n})"));
                self.line(&format!("if {idx} < 0:"));
                self.push();
                self.line(&format!(
                    "raise Error(\"{what}: required member `{}` is absent from the response.\")",
                    escape(&mf.wire_name)
                ));
                self.pop();
                let e = self.xml_read_value(
                    msg,
                    f,
                    &f.ty,
                    &mf.shape,
                    &format!("node.children[{idx}]"),
                    1,
                )?;
                self.line(&format!("var {local} = {e}"));
            }
            (_, ty) => {
                self.line(&format!("var {local} = {}", self.default_expr(msg, f)?));
                let idx = format!("_xc_{}", f.name);
                self.line(&format!("var {idx} = aws_xml_child(node, {n})"));
                self.line(&format!("if {idx} >= 0:"));
                self.push();
                let e =
                    self.xml_read_value(msg, f, ty, &mf.shape, &format!("node.children[{idx}]"), 1)?;
                self.line(&format!("{local} = {e}"));
                self.pop();
            }
        }
        Ok(())
    }

    /// The statements that read optional member `f` of `msg` from the
    /// element `node` and set it on `out` when its element is present.
    pub(super) fn emit_xml_read_optional(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        response: bool,
    ) -> Result<(), String> {
        let mf = self.facts.member(&msg.fq_name, &f.name)?.clone();
        if !xml_read_from_body(mf.location, response) {
            return Ok(());
        }
        let n = format!("String(\"{}\")", escape(&mf.wire_name));
        match (&f.label, &f.ty) {
            (Label::Repeated, ty) => {
                let local = format!("_v_{}", f.name);
                let items = format!("_xs_{}", f.name);
                let list = self.xml_list_of(&mf.shape, mf.flattened)?;
                self.line(&format!(
                    "var {items} = aws_xml_list_items(node, {n}, String(\"{}\"), {})",
                    escape(&list.item),
                    if list.flattened { "True" } else { "False" }
                ));
                self.line(&format!("if {items}:"));
                self.push();
                self.line(&format!("var {local} = {}", self.default_expr(msg, f)?));
                self.xml_read_items(msg, f, ty, &list, &items, &local)?;
                self.line(&format!("out.set_{}({local}^)", f.name));
                self.pop();
            }
            (_, IrType::Map(_, v)) => {
                let local = format!("_v_{}", f.name);
                let entries = format!("_xs_{}", f.name);
                let map = self.xml_map_of(&mf.shape, mf.flattened)?;
                self.line(&format!(
                    "var {entries} = aws_xml_map_entries(node, {n}, {})",
                    if map.flattened { "True" } else { "False" }
                ));
                self.line(&format!("if {entries}:"));
                self.push();
                self.line(&format!("var {local} = {}", self.default_expr(msg, f)?));
                self.xml_read_entries(msg, f, v, &map, &format!("{entries}.value()"), &local, 1)?;
                self.line(&format!("out.set_{}({local}^)", f.name));
                self.pop();
            }
            (_, ty) => {
                let idx = format!("_xc_{}", f.name);
                self.line(&format!("var {idx} = aws_xml_child(node, {n})"));
                self.line(&format!("if {idx} >= 0:"));
                self.push();
                let e =
                    self.xml_read_value(msg, f, ty, &mf.shape, &format!("node.children[{idx}]"), 1)?;
                self.line(&format!("out.set_{}({e})", f.name));
                self.pop();
            }
        }
        Ok(())
    }

    /// Fill the (declared, empty) list `local` with list member `f`'s items,
    /// when its element is present.
    fn xml_read_list_into(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        mf: &AwsMemberFacts,
        elem_ty: &IrType,
        local: &str,
    ) -> Result<(), String> {
        let items = format!("_xs_{}", f.name);
        let list = self.xml_list_of(&mf.shape, mf.flattened)?;
        self.line(&format!(
            "var {items} = aws_xml_list_items(node, String(\"{}\"), String(\"{}\"), {})",
            escape(&mf.wire_name),
            escape(&list.item),
            if list.flattened { "True" } else { "False" }
        ));
        self.line(&format!("if {items}:"));
        self.push();
        self.xml_read_items(msg, f, elem_ty, &list, &items, local)?;
        self.pop();
        Ok(())
    }

    /// Append each item element of `{items}` (an `Optional[List[XmlNode]]`
    /// known to be set) to the list `local`.
    fn xml_read_items(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        elem_ty: &IrType,
        list: &XmlList,
        items: &str,
        local: &str,
    ) -> Result<(), String> {
        self.line(&format!("for _xi1 in range(len({items}.value())):"));
        self.push();
        let e = self.xml_read_value(
            msg,
            f,
            elem_ty,
            &list.elem_shape,
            &format!("{items}.value()[_xi1]"),
            2,
        )?;
        self.line(&format!("{local}.append({e})"));
        self.pop();
        Ok(())
    }

    /// The expression reading ONE value of type `ty` (AWS shape `shape`)
    /// from the element `src`, after any statements it needs.
    fn xml_read_value(
        &mut self,
        msg: &IrMessage,
        f: &IrField,
        ty: &IrType,
        shape: &str,
        src: &str,
        depth: usize,
    ) -> Result<String, String> {
        match ty {
            IrType::List(e) => {
                let list = self.xml_list_of(shape, false)?;
                let node = format!("_xn{depth}_{}", f.name);
                let tmp = format!("_xl{depth}_{}", f.name);
                let jv = format!("_xj{depth}");
                self.line(&format!("ref {node} = {src}"));
                self.line(&format!("var {tmp} = List[{}]()", self.elem_type(msg, f, e)?));
                self.line(&format!("for {jv} in range(len({node}.children)):"));
                self.push();
                self.line(&format!(
                    "if {node}.children[{jv}].local == String(\"{}\"):",
                    escape(&list.item)
                ));
                self.push();
                let v = self.xml_read_value(
                    msg,
                    f,
                    e,
                    &list.elem_shape,
                    &format!("{node}.children[{jv}]"),
                    depth + 1,
                )?;
                self.line(&format!("{tmp}.append({v})"));
                self.pop();
                self.pop();
                Ok(format!("{tmp}^"))
            }
            IrType::Map(_, v) => {
                // A map nested in a list or a map: its element `src` is
                // the wrapper of its <entry> elements, or, for a map shape
                // that is flattened, the one entry (botocore's
                // `_handle_map`).
                let map = self.xml_map_of(shape, false)?;
                let node = format!("_xn{depth}_{}", f.name);
                let tmp = format!("_xm{depth}_{}", f.name);
                let entries = format!("_xe{depth}_{}", f.name);
                let jv = format!("_xj{depth}");
                self.line(&format!("ref {node} = {src}"));
                self.line(&format!("var {tmp} = Dict[String, {}]()", self.elem_type(msg, f, v)?));
                self.line(&format!("var {entries} = List[XmlNode]()"));
                if map.flattened {
                    self.line(&format!("{entries}.append({node}.copy())"));
                } else {
                    self.line(&format!("for {jv} in range(len({node}.children)):"));
                    self.push();
                    self.line(&format!("if {node}.children[{jv}].local == String(\"entry\"):"));
                    self.push();
                    self.line(&format!("{entries}.append({node}.children[{jv}].copy())"));
                    self.pop();
                    self.pop();
                }
                self.xml_read_entries(msg, f, v, &map, &entries, &tmp, depth + 1)?;
                Ok(format!("{tmp}^"))
            }
            IrType::Message(t) => {
                let n = self
                    .by_fq
                    .get(&t.fq_name)
                    .cloned()
                    .unwrap_or_else(|| t.mojo_name.clone());
                Ok(format!("{}.from_aws_xml({src})", self.ty_name(&n)))
            }
            scalar => xml_scalar_read(scalar, self.timestamp_format(msg, f), src),
        }
    }
}

/// The `aws_xml_write_*` call writing one scalar `access` as the element
/// named by the expression `n`.
fn xml_scalar_write(
    ty: &IrType,
    ts: Option<AwsTimestampFormat>,
    w: &str,
    n: &str,
    access: &str,
) -> Result<String, String> {
    Ok(match ty {
        IrType::Enum(_) => format!("aws_xml_write_string({w}, {n}, {access})"),
        IrType::Scalar(ScalarKind::String) => match ts {
            Some(fmt) => format!("aws_xml_write_ts({w}, {n}, {access}, {})", ts_const(fmt)),
            None => format!("aws_xml_write_string({w}, {n}, {access})"),
        },
        IrType::Scalar(ScalarKind::Bool) => format!("aws_xml_write_bool({w}, {n}, {access})"),
        IrType::Scalar(ScalarKind::Double) => format!("aws_xml_write_f64({w}, {n}, {access})"),
        IrType::Scalar(ScalarKind::Float) => format!("aws_xml_write_f32({w}, {n}, {access})"),
        IrType::Scalar(ScalarKind::Bytes) => {
            format!("aws_xml_write_blob({w}, {n}, Span({access}))")
        }
        IrType::Scalar(_) => format!("aws_xml_write_int({w}, {n}, Int64({access}))"),
        other => return Err(format!("emit_aws: {other:?} is not an XML scalar")),
    })
}

/// The text of one scalar `access`, for an element written by hand (one
/// that carries a namespace).
fn xml_scalar_text(ty: &IrType, ts: Option<AwsTimestampFormat>, access: &str) -> Result<String, String> {
    Ok(match ty {
        IrType::Enum(_) => access.to_string(),
        IrType::Scalar(ScalarKind::String) => match ts {
            Some(fmt) => format!("aws_text_ts({access}, {})", ts_const(fmt)),
            None => access.to_string(),
        },
        IrType::Scalar(ScalarKind::Bool) => format!("aws_text_bool({access})"),
        IrType::Scalar(ScalarKind::Double) => format!("aws_text_f64({access})"),
        IrType::Scalar(ScalarKind::Float) => format!("aws_text_f32({access})"),
        IrType::Scalar(ScalarKind::Bytes) => format!("aws_text_blob(Span({access}))"),
        IrType::Scalar(_) => format!("aws_text_int(Int64({access}))"),
        other => return Err(format!("emit_aws: {other:?} is not an XML scalar")),
    })
}

/// The expression reading one scalar from the element `src`.
fn xml_scalar_read(ty: &IrType, ts: Option<AwsTimestampFormat>, src: &str) -> Result<String, String> {
    Ok(match ty {
        IrType::Enum(_) => format!("aws_xml_string_of({src})"),
        IrType::Scalar(ScalarKind::String) => match ts {
            Some(fmt) => format!("aws_xml_ts_of({src}, {})", ts_const(fmt)),
            None => format!("aws_xml_string_of({src})"),
        },
        IrType::Scalar(ScalarKind::Bool) => format!("aws_xml_bool_of({src})"),
        IrType::Scalar(ScalarKind::Double) => format!("aws_xml_f64_of({src})"),
        IrType::Scalar(ScalarKind::Float) => format!("aws_xml_f32_of({src})"),
        IrType::Scalar(ScalarKind::Bytes) => format!("aws_xml_blob_of({src})"),
        IrType::Scalar(ScalarKind::Int64 | ScalarKind::Sint64 | ScalarKind::Sfixed64) => {
            format!("aws_xml_int_of({src}, 64)")
        }
        IrType::Scalar(ScalarKind::Int32 | ScalarKind::Sint32 | ScalarKind::Sfixed32) => {
            format!("Int32(aws_xml_int_of({src}, 32))")
        }
        IrType::Scalar(ScalarKind::Uint64 | ScalarKind::Fixed64) => {
            format!("UInt64(aws_xml_int_of({src}, 64))")
        }
        IrType::Scalar(ScalarKind::Uint32 | ScalarKind::Fixed32) => {
            format!("UInt32(aws_xml_int_of({src}, 32))")
        }
        other => return Err(format!("emit_aws: {other:?} is not an XML scalar")),
    })
}

#[cfg(test)]
mod tests {
    use crate::aws_in::lower_aws_service;
    use crate::emit_aws::{emit_aws_client, AwsEmitOptions};
    use crate::json::parse;
    use crate::overrides::AwsOverrides;

    /// A one-operation restXml model: `input` is the operation's input
    /// reference, `shapes` the model's shapes.
    fn emit(input: &str, shapes: &str) -> Result<String, String> {
        emit_with_output(input, r#"{"shape": "In"}"#, shapes)
    }

    /// [`emit`], with `output` the operation's output reference.
    fn emit_with_output(input: &str, output: &str, shapes: &str) -> Result<String, String> {
        let model = parse(&format!(
            r#"{{"version": "2.0",
                "metadata": {{"apiVersion": "2026-10-02", "endpointPrefix": "tiny",
                    "protocol": "rest-xml", "serviceFullName": "Tiny",
                    "serviceId": "Tiny", "signatureVersion": "v4",
                    "uid": "tiny-2026-10-02"}},
                "operations": {{"Op": {{"name": "Op",
                    "http": {{"method": "PUT", "requestUri": "/op"}},
                    "input": {input}, "output": {output}}}}},
                "shapes": {{{shapes}}}}}"#
        ))
        .map_err(|e| e.to_string())?;
        let lowering =
            lower_aws_service(&model, "tiny", &["Op".to_string()], "tiny.json", "aws.tiny")?;
        let options = AwsEmitOptions {
            pure_only: true,
            omit_preamble: true,
            ..AwsEmitOptions::default()
        };
        emit_aws_client(&lowering, &AwsOverrides::empty(), "tiny", options).map(|(_, s)| s)
    }

    const STR: &str = r#""Str": {"type": "string"}"#;

    #[test]
    fn a_union_is_refused_by_name() {
        let shapes = format!(
            r#""In": {{"type": "structure", "members": {{"U": {{"shape": "U"}}}}}},
               "U": {{"type": "structure", "union": true,
                      "members": {{"A": {{"shape": "Str"}}}}}}, {STR}"#
        );
        let e = emit(r#"{"shape": "In"}"#, &shapes).unwrap_err();
        assert!(e.contains("REFUSED union:"), "{e}");
    }

    #[test]
    fn an_xml_attribute_is_refused_by_name() {
        let shapes = format!(
            r#""In": {{"type": "structure", "members": {{
                   "A": {{"shape": "Str", "xmlAttribute": true, "locationName": "a"}}}}}},
               {STR}"#
        );
        let e = emit(r#"{"shape": "In"}"#, &shapes).unwrap_err();
        assert!(e.contains("REFUSED xml-attribute:"), "{e}");
    }

    #[test]
    fn a_map_in_the_body_is_refused_and_one_in_the_query_or_headers_is_not() {
        let map = r#""M": {"type": "map", "key": {"shape": "Str"}, "value": {"shape": "Str"}}"#;
        let body = format!(
            r#""In": {{"type": "structure", "members": {{"M": {{"shape": "M"}}}}}}, {map}, {STR}"#
        );
        let e = emit(r#"{"shape": "In"}"#, &body).unwrap_err();
        assert!(e.contains("REFUSED xml-map:"), "{e}");
        // A list of maps is a map in the body too.
        let listed = format!(
            r#""In": {{"type": "structure", "members": {{"L": {{"shape": "L"}}}}}},
               "L": {{"type": "list", "member": {{"shape": "M"}}}}, {map}, {STR}"#
        );
        let e = emit(r#"{"shape": "In"}"#, &listed).unwrap_err();
        assert!(e.contains("REFUSED xml-map:"), "{e}");
        let bound = format!(
            r#""In": {{"type": "structure", "members": {{
                   "Q": {{"shape": "M", "location": "querystring"}},
                   "H": {{"shape": "M", "location": "headers", "locationName": "x-h-"}}}}}},
               {map}, {STR}"#
        );
        // (A response has no query: a member bound to one is read from the
        // body, so the output here is another shape.)
        let bound = format!(r#"{bound}, "Out": {{"type": "structure", "members": {{}}}}"#);
        emit_with_output(r#"{"shape": "In"}"#, r#"{"shape": "Out"}"#, &bound).unwrap();
    }

    #[test]
    fn a_query_bound_map_in_an_output_shape_is_refused_before_emission() {
        let shapes = format!(
            r#""In": {{"type": "structure", "members": {{}}}},
               "Out": {{"type": "structure", "members": {{
                   "Q": {{"shape": "M", "location": "querystring"}}}}}},
               "M": {{"type": "map", "key": {{"shape": "Str"}}, "value": {{"shape": "Str"}}}},
               {STR}"#
        );
        let model = parse(&format!(
            r#"{{"version": "2.0",
                "metadata": {{"apiVersion": "2026-10-02", "endpointPrefix": "tiny",
                    "protocol": "rest-xml", "serviceFullName": "Tiny",
                    "serviceId": "Tiny", "signatureVersion": "v4",
                    "uid": "tiny-2026-10-02"}},
                "operations": {{"Op": {{"name": "Op",
                    "http": {{"method": "PUT", "requestUri": "/op"}},
                    "input": {{"shape": "In"}}, "output": {{"shape": "Out"}}}}}},
                "shapes": {{{shapes}}}}}"#
        ))
        .unwrap();
        let lowering =
            lower_aws_service(&model, "tiny", &["Op".to_string()], "tiny.json", "aws.tiny")
                .unwrap();
        let e = super::check_rest_xml_features(&lowering.facts).unwrap_err();
        assert!(e.contains("REFUSED xml-map:"), "{e}");
        assert!(e.contains("the output of `Op`"), "{e}");
    }

    #[test]
    fn the_body_is_the_input_root_with_members_in_declared_order() {
        let shapes = format!(
            r#""In": {{"type": "structure", "members": {{
                   "Zed": {{"shape": "Str"}},
                   "Alpha": {{"shape": "Str", "locationName": "alpha"}},
                   "H": {{"shape": "Str", "location": "header", "locationName": "X-H"}}}}}},
               {STR}"#
        );
        let src = emit(
            r#"{"shape": "In", "locationName": "OpRequest",
                "xmlNamespace": {"uri": "https://example.com/ns"}}"#,
            &shapes,
        )
        .unwrap();
        assert!(src.contains("aws_xml_start(_w, String(\"OpRequest\"))"), "{src}");
        assert!(
            src.contains("aws_xml_namespace(_w, String(\"\"), String(\"https://example.com/ns\"))"),
            "{src}"
        );
        let zed = src.find("aws_xml_write_string(_w, String(\"Zed\")").expect("Zed");
        let alpha = src.find("aws_xml_write_string(_w, String(\"alpha\")").expect("alpha");
        assert!(zed < alpha, "{src}");
        // The header member is a header, not an element.
        assert!(!src.contains("aws_xml_write_string(_w, String(\"X-H\")"), "{src}");
        assert!(!src.contains("aws_xml_write_string(w, String(\"X-H\")"), "{src}");
        assert!(src.contains("req.set_header(String(\"X-H\"), "), "{src}");
        // Nothing set is no body.
        assert!(src.contains("var _xb = False"), "{src}");
        // The response reads the root's children.
        assert!(src.contains("var node = aws_xml_parse(resp.body)"), "{src}");
        assert!(src.contains("aws_xml_child(node, String(\"alpha\"))"), "{src}");
    }

    #[test]
    fn lists_are_wrapped_or_flattened_and_items_take_the_member_name() {
        let shapes = format!(
            r#""In": {{"type": "structure", "members": {{
                   "W": {{"shape": "L"}},
                   "F": {{"shape": "L", "flattened": true, "locationName": "f"}},
                   "N": {{"shape": "LL"}}}}}},
               "L": {{"type": "list", "member": {{"shape": "Str", "locationName": "item"}}}},
               "LL": {{"type": "list", "member": {{"shape": "L"}}}},
               {STR}"#
        );
        let src = emit(r#"{"shape": "In", "locationName": "OpRequest"}"#, &shapes).unwrap();
        // Wrapped: the wrapper, then each item named by the list member.
        assert!(src.contains("aws_xml_start(_w, String(\"W\"))"), "{src}");
        assert!(src.contains("aws_xml_write_string(_w, String(\"item\"), "), "{src}");
        // Flattened: each item is named for the member.
        assert!(src.contains("aws_xml_write_string(_w, String(\"f\"), "), "{src}");
        assert!(!src.contains("aws_xml_start(_w, String(\"f\"))"), "{src}");
        // Nested: the inner list is wrapped in a `member` element.
        assert!(src.contains("aws_xml_start(_w, String(\"member\"))"), "{src}");
        // Read back by the same names.
        assert!(
            src.contains("aws_xml_list_items(node, String(\"W\"), String(\"item\"), False)"),
            "{src}"
        );
        assert!(
            src.contains("aws_xml_list_items(node, String(\"f\"), String(\"item\"), True)"),
            "{src}"
        );
    }

    #[test]
    fn a_namespaced_scalar_is_written_by_hand_with_its_prefix() {
        let shapes = format!(
            r#""In": {{"type": "structure", "members": {{
                   "A": {{"shape": "Str", "xmlNamespace": {{"prefix": "p", "uri": "urn:p"}}}}}}}},
               {STR}"#
        );
        let src = emit(r#"{"shape": "In", "locationName": "OpRequest"}"#, &shapes).unwrap();
        assert!(src.contains("aws_xml_namespace(_w, String(\"p\"), String(\"urn:p\"))"), "{src}");
        assert!(src.contains("_w.text("), "{src}");
    }

    #[test]
    fn a_structure_payload_is_its_own_document_and_absent_when_unset() {
        let shapes = format!(
            r#""In": {{"type": "structure", "payload": "P", "members": {{
                   "P": {{"shape": "Nested", "locationName": "Root"}}}}}},
               "Nested": {{"type": "structure", "members": {{"A": {{"shape": "Str"}}}}}},
               {STR}"#
        );
        let src = emit(r#"{"shape": "In"}"#, &shapes).unwrap();
        assert!(src.contains("aws_xml_start(_w, String(\"Root\"))"), "{src}");
        assert!(src.contains(".write_aws_xml(_w)"), "{src}");
        assert!(!src.contains("req.set_body_text(String(\"{}\"))"), "{src}");
        assert!(src.contains("from_aws_xml(aws_xml_parse(resp.body))"), "{src}");
        assert!(src.contains("(restXml)") || src.contains("restXml request"), "{src}");
    }

    /// A two-operation restXml model with serviceId `service_id`, emitted
    /// with the `s3` customization.
    fn emit_s3(service_id: &str) -> Result<String, String> {
        emit_s3_in(service_id, true)
    }

    fn emit_s3_in(service_id: &str, pure_only: bool) -> Result<String, String> {
        let model = parse(&format!(
            r#"{{"version": "2.0",
                "metadata": {{"apiVersion": "2026-10-02", "endpointPrefix": "s3",
                    "protocol": "rest-xml", "serviceFullName": "Tiny S3",
                    "serviceId": "{service_id}", "signatureVersion": "s3",
                    "auth": ["aws.auth#sigv4"], "uid": "s3-2026-10-02"}},
                "operations": {{
                    "Head": {{"name": "Head", "http": {{"method": "HEAD", "requestUri": "/h"}},
                        "input": {{"shape": "In"}}, "output": {{"shape": "HeadOut"}}}},
                    "Get": {{"name": "Get", "http": {{"method": "GET", "requestUri": "/g"}},
                        "input": {{"shape": "In"}}, "output": {{"shape": "GetOut"}}}},
                    "GetBytes": {{"name": "GetBytes",
                        "http": {{"method": "GET", "requestUri": "/b"}},
                        "input": {{"shape": "In"}}, "output": {{"shape": "BytesOut"}}}},
                    "GetText": {{"name": "GetText",
                        "http": {{"method": "GET", "requestUri": "/t"}},
                        "input": {{"shape": "In"}}, "output": {{"shape": "TextOut"}}}},
                    "Drop": {{"name": "Drop", "http": {{"method": "DELETE", "requestUri": "/d"}},
                        "input": {{"shape": "In"}}}},
                    "Put": {{"name": "Put", "http": {{"method": "PUT", "requestUri": "/p"}},
                        "input": {{"shape": "PutIn"}},
                        "httpChecksum": {{"requestAlgorithmMember": "ChecksumAlgorithm",
                            "requestChecksumRequired": false}}}},
                    "Purge": {{"name": "Purge",
                        "http": {{"method": "POST", "requestUri": "/p?purge"}},
                        "input": {{"shape": "PurgeIn"}},
                        "httpChecksum": {{"requestAlgorithmMember": "ChecksumAlgorithm",
                            "requestChecksumRequired": true}}}}}},
                "shapes": {{
                    "In": {{"type": "structure", "members": {{}}}},
                    "PurgeIn": {{"type": "structure", "payload": "Purge", "members": {{
                        "ChecksumAlgorithm": {{"shape": "Str", "location": "header",
                            "locationName": "x-amz-sdk-checksum-algorithm"}},
                        "Purge": {{"shape": "PurgeDoc", "locationName": "Purge"}}}}}},
                    "PurgeDoc": {{"type": "structure", "members": {{
                        "Key": {{"shape": "Str"}}}}}},
                    "PutIn": {{"type": "structure", "payload": "Body", "members": {{
                        "ChecksumAlgorithm": {{"shape": "Str", "location": "header",
                            "locationName": "x-amz-sdk-checksum-algorithm"}},
                        "ChecksumSHA256": {{"shape": "Str", "location": "header",
                            "locationName": "x-amz-checksum-sha256"}},
                        "Body": {{"shape": "Bytes"}}}}}},
                    "HeadOut": {{"type": "structure", "members": {{
                        "Expires": {{"shape": "Ts", "location": "header", "locationName": "Expires"}},
                        "Size": {{"shape": "Str"}}}}}},
                    "GetOut": {{"type": "structure", "payload": "Body", "members": {{
                        "Body": {{"shape": "Blob", "streaming": true}}}}}},
                    "BytesOut": {{"type": "structure", "payload": "Body", "members": {{
                        "Body": {{"shape": "Bytes"}}}}}},
                    "TextOut": {{"type": "structure", "payload": "Text", "members": {{
                        "Text": {{"shape": "Str"}}}}}},
                    "Ts": {{"type": "timestamp"}},
                    "Blob": {{"type": "blob", "streaming": true}},
                    "Bytes": {{"type": "blob"}},
                    {STR}}}}}"#
        ))
        .map_err(|e| e.to_string())?;
        let lowering = lower_aws_service(
            &model,
            "s3",
            &["Head", "Get", "GetBytes", "GetText", "Drop", "Put", "Purge"].map(String::from),
            "s3.json",
            "aws.s3",
        )?;
        let options = AwsEmitOptions {
            pure_only,
            omit_preamble: true,
            s3: true,
            ..AwsEmitOptions::default()
        };
        emit_aws_client(&lowering, &AwsOverrides::empty(), "s3", options).map(|(_, s)| s)
    }

    #[test]
    fn the_s3_customization_is_refused_for_another_service() {
        let e = emit_s3("Tiny").unwrap_err();
        assert!(e.contains("is refused unless the model's serviceId is `S3`"), "{e}");
    }

    /// The text of the parser `name` in `src`, up to the next definition.
    fn parser<'a>(src: &'a str, name: &str) -> &'a str {
        let at = src.find(&format!("def {name}(")).expect(name);
        let rest = &src[at..];
        let end = rest[1..].find("\ndef ").map_or(rest.len(), |e| e + 1);
        &rest[..end]
    }

    #[test]
    fn s3_raises_a_200_error_body_unless_the_payload_is_a_blob_or_a_string() {
        let src = emit_s3("S3").unwrap();
        // In the Head parser, before its body is read, raised as the error
        // an HTTP 500 is.
        let head = parser(&src, "s3_parse_head_response");
        let check = head.find("if aws_xml_body_is_error(resp):").expect("the 200 check");
        assert!(check < head.find("aws_xml_parse(resp.body)").expect("body"), "{src}");
        // Named as the client's error builder names the service: the type
        // prefix, then the service name.
        assert!(head.contains("String(\"S3S3.Head failed: HTTP 500 \")"), "{head}");
        // Not where the payload is a blob, streaming (`Get`, read by its head
        // parser) or not (`GetBytes`), or a string (`GetText`).
        for name in ["s3_parse_get_bytes_response", "s3_parse_get_text_response"] {
            assert!(!parser(&src, name).contains("aws_xml_body_is_error"), "{src}");
        }
        assert!(!parser(&src, "s3_parse_get_head").contains("aws_xml_body_is_error"), "{src}");
        // Nor for an operation with no output shape (`Drop`).
        assert!(!parser(&src, "s3_parse_drop_response").contains("aws_xml_body_is_error"), "{src}");
        assert_eq!(src.matches("if aws_xml_body_is_error(resp):").count(), 1, "{src}");
    }

    #[test]
    fn an_s3_client_tells_the_send_which_operations_answer_a_200_error() {
        let src = emit_s3_in("S3", false).unwrap();
        // The send takes the flag and hands it to komira_aws_core.
        assert!(
            src.contains(
                "    def send(mut self, var req: AwsRequest, s3_200_error: Bool = False) raises -> HttpResult:\n"
            ),
            "{src}"
        );
        assert!(src.contains("            s3_200_error=s3_200_error,\n"), "{src}");
        // Each verb, up to the next method of the client.
        let verb = |name: &str| -> &str {
            let at = src.find(&format!("    def {name}(mut self")).expect(name);
            let rest = &src[at..];
            let end = rest[1..].find("\n    def ").map_or(rest.len(), |e| e + 1);
            &rest[..end]
        };
        // botocore's `_should_handle_200_error`: an output shape whose
        // payload is not a blob or a string (`Head`) ...
        assert!(verb("head").contains("var res = self.send(req^, s3_200_error=True)\n"), "{src}");
        // ... and not a payload that is a blob, streaming or not, or a
        // string, nor an operation with no output shape.
        for name in ["get", "get_bytes", "get_text", "drop", "put", "purge"] {
            assert!(verb(name).contains("var res = self.send(req^)\n"), "{name}: {src}");
        }
        // The verb over injected seams says the same.
        let with = |name: &str| -> &str {
            let at = src.find(&format!("    def {name}_with[")).expect(name);
            let rest = &src[at..];
            let end = rest[1..].find("\n    def ").map_or(rest.len(), |e| e + 1);
            &rest[..end]
        };
        assert!(with("head").contains("budget, s3_200_error=True)\n"), "{src}");
        for name in ["get", "get_bytes", "get_text", "drop", "put", "purge"] {
            assert!(with(name).contains("budget)\n"), "{name}: {src}");
        }
        assert_eq!(src.matches("s3_200_error=True").count(), 2, "{src}");
        // A pure module has no send.
        assert!(!emit_s3("S3").unwrap().contains("s3_200_error"));
    }

    /// The text of the request builder `name` in `src`.
    fn builder<'a>(src: &'a str, name: &str) -> &'a str {
        parser(src, name)
    }

    #[test]
    fn s3_sends_the_request_checksum_where_the_model_names_its_algorithm_member() {
        let src = emit_s3("S3").unwrap();
        // After the body is set, with the header the member is bound to,
        // and saying that the input has a member for a checksum value
        // (`ChecksumSHA256`).
        let put = builder(&src, "s3_build_put_request");
        let body = put.find("req.body = ").expect("the body");
        let sum = put
            .find(
                "s3_apply_request_checksum(req, \
                 String(\"x-amz-sdk-checksum-algorithm\"), value_members=True)",
            )
            .expect("the checksum");
        assert!(body < sum && sum < put.find("return req^").expect("return"), "{put}");
        // A required checksum (`Purge`) is the same call, after its XML
        // document is set; its input has no member for a value.
        let purge = builder(&src, "s3_build_purge_request");
        let body = purge.find("aws_xml_set_body(req, _w)").expect("the body");
        let sum = purge
            .find(
                "s3_apply_request_checksum(req, \
                 String(\"x-amz-sdk-checksum-algorithm\"), value_members=False)",
            )
            .expect("the checksum");
        assert!(body < sum && sum < purge.find("return req^").expect("return"), "{purge}");
        // Nowhere else: no other operation names an algorithm member.
        assert_eq!(src.matches("s3_apply_request_checksum(").count(), 2, "{src}");
    }

    #[test]
    fn s3_leaves_an_unparseable_expires_unset() {
        let src = emit_s3("S3").unwrap();
        let at = src.find("if resp.has_header(String(\"Expires\")):").expect("Expires");
        let rest = &src[at..];
        let tried = rest.find("try:").expect("try");
        let set = rest.find("out.set_expires(aws_ts_from_text(").expect("set");
        let except = rest.find("except:").expect("except");
        assert!(tried < set && set < except, "{src}");
    }

    #[test]
    fn without_the_customization_neither_is_emitted() {
        let shapes = format!(
            r#""In": {{"type": "structure", "members": {{
                   "Expires": {{"shape": "Ts", "location": "header", "locationName": "Expires"}},
                   "A": {{"shape": "Str"}}}}}},
               "Ts": {{"type": "timestamp"}}, {STR}"#
        );
        let src = emit(r#"{"shape": "In"}"#, &shapes).unwrap();
        assert!(!src.contains("aws_xml_body_is_error"), "{src}");
        assert!(!src.contains("try:"), "{src}");
    }
}
