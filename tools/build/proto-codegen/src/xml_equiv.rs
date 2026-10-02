//! XML equivalence for the conformance harness: two documents are equal
//! when their namespace-resolved element trees are.
//!
//! ⚠ This is DELIBERATELY MORE LENIENT than botocore on namespace prefixes.
//! botocore compares canonical XML (`ET.canonicalize(strip_text=True)`),
//! which keeps each prefix, so `<p:a xmlns:p="urn:x"/>`, `<q:a
//! xmlns:q="urn:x"/>` and `<a xmlns="urn:x"/>` are three different documents
//! to it and one document here. A serializer that writes the wrong prefix
//! (or a prefix where the corpus has a default namespace) passes this
//! comparison and fails botocore's, and so do the verdicts
//! `xml-equiv-verdicts` writes from it. The tests that pin the leniency say
//! so; on whitespace, CDATA, attribute order and whitespace, and unused
//! namespace declarations the two agree.

use std::collections::BTreeMap;

/// A parsed XML document: the root element, with the declaration, comments
/// and any processing instructions already discarded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct XmlElement {
    /// Expanded name: the namespace URI (empty when in no namespace).
    pub ns: String,
    /// Expanded name: the local part, with any prefix stripped.
    pub local: String,
    /// Attributes keyed by expanded name. `xmlns` / `xmlns:p` declarations are
    /// NOT attributes — they are namespace bindings and are consumed by name
    /// expansion. A `BTreeMap` makes the set unordered by construction.
    pub attrs: BTreeMap<(String, String), String>,
    /// Children in document order. Text runs are already concatenated,
    /// trimmed, and dropped when empty.
    pub children: Vec<XmlNode>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum XmlNode {
    Element(XmlElement),
    Text(String),
}

/// Parse failure. The message is diagnostic only — callers branch on the
/// FACT of a failure (falling back to byte compare), never on the text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct XmlParseError(pub String);

impl std::fmt::Display for XmlParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// True when `a` and `b` are the same XML document under the relation this
/// module documents, or — when EITHER side fails to parse — when they are
/// byte-identical. The fallback mirrors botocore's `except ET.ParseError`
/// branch: 6 corpus bodies are raw non-XML payloads.
pub fn xml_bodies_equivalent(a: &str, b: &str) -> bool {
    match (parse(a), parse(b)) {
        (Ok(ta), Ok(tb)) => ta == tb,
        _ => a == b,
    }
}

/// Parse a document into its namespace-resolved root element.
pub fn parse(input: &str) -> Result<XmlElement, XmlParseError> {
    let mut p = Parser {
        b: input.as_bytes(),
        i: 0,
        src: input,
    };
    p.skip_prolog()?;
    let root = p.parse_element(&NsScope::root())?;
    p.skip_misc()?;
    if p.i < p.b.len() {
        return Err(XmlParseError(format!(
            "trailing content at byte {}",
            p.i
        )));
    }
    Ok(root)
}

/// A namespace scope: the in-scope prefix bindings, plus the default
/// namespace. Linked to the parent so a child sees its ancestors' bindings.
struct NsScope<'a> {
    parent: Option<&'a NsScope<'a>>,
    default_ns: Option<String>,
    prefixes: BTreeMap<String, String>,
}

impl<'a> NsScope<'a> {
    fn root() -> NsScope<'static> {
        NsScope {
            parent: None,
            default_ns: None,
            prefixes: BTreeMap::new(),
        }
    }

    fn child(parent: &'a NsScope<'a>) -> NsScope<'a> {
        NsScope {
            parent: Some(parent),
            default_ns: None,
            prefixes: BTreeMap::new(),
        }
    }

    fn resolve_default(&self) -> &str {
        if let Some(d) = &self.default_ns {
            return d;
        }
        match self.parent {
            Some(p) => p.resolve_default(),
            None => "",
        }
    }

    fn resolve_prefix(&self, prefix: &str) -> Option<&str> {
        if let Some(u) = self.prefixes.get(prefix) {
            return Some(u);
        }
        match self.parent {
            Some(p) => p.resolve_prefix(prefix),
            None => None,
        }
    }
}

struct Parser<'a> {
    b: &'a [u8],
    i: usize,
    src: &'a str,
}

impl<'a> Parser<'a> {
    fn eof(&self) -> bool {
        self.i >= self.b.len()
    }

    fn peek(&self) -> u8 {
        if self.eof() {
            0
        } else {
            self.b[self.i]
        }
    }

    fn starts_with(&self, s: &str) -> bool {
        self.b[self.i..].starts_with(s.as_bytes())
    }

    fn skip_ws(&mut self) {
        while !self.eof() && matches!(self.b[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }

    /// Skip the XML declaration, comments, processing instructions and any
    /// DOCTYPE that precede the root element.
    fn skip_prolog(&mut self) -> Result<(), XmlParseError> {
        self.skip_ws();
        if self.starts_with("<?") {
            self.skip_until("?>")?;
        }
        self.skip_misc()
    }

    /// Skip inter-element misc: whitespace, comments, processing instructions.
    fn skip_misc(&mut self) -> Result<(), XmlParseError> {
        loop {
            self.skip_ws();
            if self.starts_with("<!--") {
                self.skip_until("-->")?;
            } else if self.starts_with("<?") {
                self.skip_until("?>")?;
            } else if self.starts_with("<!DOCTYPE") {
                return Err(XmlParseError("DOCTYPE is not supported".into()));
            } else {
                return Ok(());
            }
        }
    }

    fn skip_until(&mut self, end: &str) -> Result<(), XmlParseError> {
        match self.src[self.i..].find(end) {
            Some(off) => {
                self.i += off + end.len();
                Ok(())
            }
            None => Err(XmlParseError(format!("unterminated `{end}`"))),
        }
    }

    fn parse_element(&mut self, parent: &NsScope) -> Result<XmlElement, XmlParseError> {
        if self.peek() != b'<' {
            return Err(XmlParseError(format!(
                "expected `<` at byte {}",
                self.i
            )));
        }
        self.i += 1;
        let raw_name = self.parse_name()?;

        // Collect the raw attributes first: a namespace declaration binds for
        // this element's OWN name too, and declarations may appear after the
        // attribute that uses the prefix.
        let mut scope = NsScope::child(parent);
        let mut raw_attrs: Vec<(String, String)> = Vec::new();
        loop {
            self.skip_ws();
            if self.eof() {
                return Err(XmlParseError("unterminated start tag".into()));
            }
            if self.peek() == b'>' || self.starts_with("/>") {
                break;
            }
            let aname = self.parse_name()?;
            self.skip_ws();
            if self.peek() != b'=' {
                return Err(XmlParseError(format!(
                    "expected `=` after attribute `{aname}`"
                )));
            }
            self.i += 1;
            self.skip_ws();
            let avalue = self.parse_attr_value()?;
            if aname == "xmlns" {
                scope.default_ns = Some(avalue);
            } else if let Some(prefix) = aname.strip_prefix("xmlns:") {
                scope.prefixes.insert(prefix.to_string(), avalue);
            } else {
                raw_attrs.push((aname, avalue));
            }
        }

        let (ns, local) = self.expand(&raw_name, &scope, true)?;
        let mut attrs = BTreeMap::new();
        for (aname, avalue) in raw_attrs {
            let key = self.expand(&aname, &scope, false)?;
            attrs.insert(key, avalue);
        }

        let self_closing = self.starts_with("/>");
        self.i += if self_closing { 2 } else { 1 };

        let mut children: Vec<XmlNode> = Vec::new();
        if !self_closing {
            let mut pending = String::new();
            loop {
                if self.eof() {
                    return Err(XmlParseError(format!("unclosed element `{local}`")));
                }
                if self.starts_with("</") {
                    self.i += 2;
                    let close = self.parse_name()?;
                    self.skip_ws();
                    if self.peek() != b'>' {
                        return Err(XmlParseError("malformed end tag".into()));
                    }
                    self.i += 1;
                    if close != raw_name {
                        return Err(XmlParseError(format!(
                            "end tag `{close}` does not match `{raw_name}`"
                        )));
                    }
                    break;
                }
                if self.starts_with("<!--") {
                    self.skip_until("-->")?;
                    continue;
                }
                if self.starts_with("<?") {
                    self.skip_until("?>")?;
                    continue;
                }
                if self.starts_with("<![CDATA[") {
                    self.i += "<![CDATA[".len();
                    let start = self.i;
                    match self.src[self.i..].find("]]>") {
                        Some(off) => {
                            pending.push_str(&self.src[start..start + off]);
                            self.i += off + 3;
                        }
                        None => return Err(XmlParseError("unterminated CDATA".into())),
                    }
                    continue;
                }
                if self.peek() == b'<' {
                    Self::flush_text(&mut pending, &mut children);
                    let child = self.parse_element(&scope)?;
                    children.push(XmlNode::Element(child));
                    continue;
                }
                let start = self.i;
                while !self.eof() && self.peek() != b'<' {
                    self.i += 1;
                }
                pending.push_str(&decode_entities(&self.src[start..self.i])?);
            }
            Self::flush_text(&mut pending, &mut children);
        }

        Ok(XmlElement {
            ns,
            local,
            attrs,
            children,
        })
    }

    fn flush_text(pending: &mut String, children: &mut Vec<XmlNode>) {
        let trimmed = pending.trim();
        if !trimmed.is_empty() {
            children.push(XmlNode::Text(trimmed.to_string()));
        }
        pending.clear();
    }

    /// Expand a possibly-prefixed name. `is_element` selects the XML rule that
    /// the default namespace applies to element names but NOT to attributes.
    fn expand(
        &self,
        raw: &str,
        scope: &NsScope,
        is_element: bool,
    ) -> Result<(String, String), XmlParseError> {
        match raw.split_once(':') {
            Some((prefix, local)) => match scope.resolve_prefix(prefix) {
                Some(uri) => Ok((uri.to_string(), local.to_string())),
                // `xml:` is bound by the spec and needs no declaration.
                None if prefix == "xml" => Ok((
                    "http://www.w3.org/XML/1998/namespace".to_string(),
                    local.to_string(),
                )),
                None => Err(XmlParseError(format!("unbound prefix `{prefix}`"))),
            },
            None => {
                let ns = if is_element {
                    scope.resolve_default().to_string()
                } else {
                    String::new()
                };
                Ok((ns, raw.to_string()))
            }
        }
    }

    fn parse_name(&mut self) -> Result<String, XmlParseError> {
        let start = self.i;
        while !self.eof() {
            let c = self.b[self.i];
            if c.is_ascii_alphanumeric()
                || matches!(c, b'_' | b'-' | b'.' | b':')
                || c >= 0x80
            {
                self.i += 1;
            } else {
                break;
            }
        }
        if self.i == start {
            return Err(XmlParseError(format!("expected a name at byte {start}")));
        }
        Ok(self.src[start..self.i].to_string())
    }

    fn parse_attr_value(&mut self) -> Result<String, XmlParseError> {
        let quote = self.peek();
        if quote != b'"' && quote != b'\'' {
            return Err(XmlParseError(format!(
                "expected a quoted attribute value at byte {}",
                self.i
            )));
        }
        self.i += 1;
        let start = self.i;
        while !self.eof() && self.peek() != quote {
            self.i += 1;
        }
        if self.eof() {
            return Err(XmlParseError("unterminated attribute value".into()));
        }
        let raw = &self.src[start..self.i];
        self.i += 1;
        let decoded = decode_entities(raw)?;
        // XML attribute-value normalisation: literal tab / LF / CR become a
        // space. Applied to BOTH sides of a comparison, so it cannot make two
        // different documents look equal — it makes a document equal to its
        // own re-serialisation, which is the point.
        Ok(decoded
            .chars()
            .map(|c| if matches!(c, '\t' | '\n' | '\r') { ' ' } else { c })
            .collect())
    }
}

fn decode_entities(s: &str) -> Result<String, XmlParseError> {
    if !s.contains('&') {
        return Ok(s.to_string());
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        let after = &rest[amp + 1..];
        let semi = after
            .find(';')
            .ok_or_else(|| XmlParseError("unterminated entity reference".into()))?;
        let name = &after[..semi];
        match name {
            "lt" => out.push('<'),
            "gt" => out.push('>'),
            "amp" => out.push('&'),
            "quot" => out.push('"'),
            "apos" => out.push('\''),
            _ => {
                let code = if let Some(hex) = name.strip_prefix("#x").or_else(|| name.strip_prefix("#X")) {
                    u32::from_str_radix(hex, 16).ok()
                } else if let Some(dec) = name.strip_prefix('#') {
                    dec.parse::<u32>().ok()
                } else {
                    None
                };
                match code.and_then(char::from_u32) {
                    Some(c) => out.push(c),
                    None => {
                        return Err(XmlParseError(format!("unknown entity `&{name};`")))
                    }
                }
            }
        }
        rest = &after[semi + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

// ---------------------------------------------------------------------------
// Unit tests. Each pair is written from the XML 1.0 and Namespaces in XML
// 1.0 recommendations (the section is named per test); none is taken from
// the botocore corpus. Four pin the prefix leniency the module doc states,
// and say so: there, botocore's canonical comparison disagrees.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn same(a: &str, b: &str) {
        assert!(xml_bodies_equivalent(a, b), "expected equivalent:\n  {a}\n  {b}");
        assert!(xml_bodies_equivalent(b, a), "not symmetric:\n  {a}\n  {b}");
    }

    fn differ(a: &str, b: &str) {
        assert!(!xml_bodies_equivalent(a, b), "expected different:\n  {a}\n  {b}");
        assert!(!xml_bodies_equivalent(b, a), "not symmetric:\n  {a}\n  {b}");
    }

    fn refused(doc: &str) {
        assert!(parse(doc).is_err(), "expected a parse error: {doc}");
    }

    // XML 1.0 §3.1: an empty-element tag and a start tag directly followed
    // by its end tag are the same element.
    #[test]
    fn empty_element_tag_equals_start_end_pair() {
        same("<a/>", "<a></a>");
    }

    // §2.8: the XML declaration is prolog, not content.
    #[test]
    fn xml_declaration_is_not_content() {
        same("<?xml version=\"1.0\" encoding=\"UTF-8\"?><a/>", "<a/>");
    }

    // §2.10 and the relation's own rule: whitespace-only text between
    // elements is dropped, and text is compared trimmed.
    #[test]
    fn whitespace_between_elements_is_dropped() {
        same("<a>\n  <b>1</b>\n</a>", "<a><b>1</b></a>");
    }

    #[test]
    fn surrounding_text_whitespace_is_trimmed() {
        same("<a>  x\t</a>", "<a>x</a>");
    }

    // §3.1: the order of attribute specifications is not significant.
    #[test]
    fn attribute_order_is_not_significant() {
        same("<a x=\"1\" y=\"2\"/>", "<a y=\"2\" x=\"1\"/>");
    }

    // §2.3 (AttValue): single and double quotes delimit the same value.
    #[test]
    fn attribute_quote_style_is_not_significant() {
        same("<a x='1'/>", "<a x=\"1\"/>");
    }

    // §3.1 (S? around Eq, trailing S in tags).
    #[test]
    fn whitespace_inside_tags_is_not_significant() {
        same("<a  x = \"1\" />", "<a x=\"1\"/>");
        same("<a></a >", "<a/>");
    }

    // Namespaces §3: a name is its namespace name plus local part; the
    // prefix is not part of it. DELIBERATE LENIENCY: botocore's canonical
    // comparison keeps the prefix and calls these different.
    #[test]
    fn prefix_choice_is_not_significant() {
        same("<p:a xmlns:p=\"urn:x\"/>", "<q:a xmlns:q=\"urn:x\"/>");
    }

    // Namespaces §6.2: a default namespace applies to unprefixed elements.
    // DELIBERATE LENIENCY: botocore's canonical comparison calls these
    // different.
    #[test]
    fn default_namespace_equals_a_prefixed_one() {
        same("<a xmlns=\"urn:x\"/>", "<p:a xmlns:p=\"urn:x\"/>");
    }

    // Namespaces §6.1: a declaration is in scope in the element's content.
    // DELIBERATE LENIENCY (one side is prefixed): botocore's canonical
    // comparison calls these different.
    #[test]
    fn default_namespace_is_inherited_by_children() {
        same("<a xmlns=\"urn:x\"><b/></a>", "<p:a xmlns:p=\"urn:x\"><p:b/></p:a>");
    }

    // Namespaces §6.1: an inner declaration overrides an outer one.
    // DELIBERATE LENIENCY (one side is prefixed): botocore's canonical
    // comparison calls these different.
    #[test]
    fn inner_declaration_overrides_outer() {
        same(
            "<a xmlns=\"urn:x\"><b xmlns=\"urn:y\"/></a>",
            "<p:a xmlns:p=\"urn:x\"><q:b xmlns:q=\"urn:y\"/></p:a>",
        );
    }

    // Namespaces §3: declarations are not attributes of the element.
    #[test]
    fn namespace_declarations_are_not_attributes() {
        same("<a xmlns:p=\"urn:x\"/>", "<a/>");
    }

    // §4.6: the predefined entities.
    #[test]
    fn predefined_entities_equal_their_characters() {
        same("<a>&lt;&amp;&gt;</a>", "<a><![CDATA[<&>]]></a>");
        same("<a x=\"&quot;&apos;\"/>", "<a x='\"&apos;'/>");
    }

    // §4.1: decimal and hexadecimal character references.
    #[test]
    fn character_references_equal_their_characters() {
        same("<a>&#65;&#x42;</a>", "<a>AB</a>");
    }

    // §2.7: a CDATA section is character data, and adjacent character data
    // is one text run.
    #[test]
    fn cdata_joins_adjacent_text() {
        same("<a>ab<![CDATA[c]]>d</a>", "<a>abcd</a>");
    }

    // §2.5, §2.6: comments and processing instructions are not character
    // data.
    #[test]
    fn comments_and_processing_instructions_are_not_content() {
        same("<a><!-- c --><b/></a>", "<a><b/></a>");
        same("<a><?pi x?><b/></a>", "<a><b/></a>");
        same("<!-- before --><a/><!-- after -->", "<a/>");
    }

    // §3.3.3: literal tab, LF and CR in an attribute value normalize to a
    // space.
    #[test]
    fn attribute_value_whitespace_normalizes_to_space() {
        same("<a x=\"1\t2\n3\"/>", "<a x=\"1 2 3\"/>");
    }

    // Namespaces §3: the `xml` prefix is bound without a declaration.
    #[test]
    fn xml_prefix_needs_no_declaration() {
        same("<a xml:lang=\"en\"/>", "<a xml:lang='en'></a>");
    }

    #[test]
    fn different_text_differs() {
        differ("<a>x</a>", "<a>y</a>");
    }

    // §3: element content is ordered.
    #[test]
    fn child_order_is_significant() {
        differ("<a><b/><c/></a>", "<a><c/><b/></a>");
    }

    #[test]
    fn different_namespace_names_differ() {
        differ("<a xmlns=\"urn:x\"/>", "<a xmlns=\"urn:y\"/>");
        differ("<a xmlns=\"urn:x\"/>", "<a/>");
    }

    // Namespaces §6.2: the default namespace does not apply to attributes.
    #[test]
    fn default_namespace_does_not_apply_to_attributes() {
        differ("<a xmlns=\"urn:x\" b=\"1\"/>", "<p:a xmlns:p=\"urn:x\" p:b=\"1\"/>");
    }

    #[test]
    fn attribute_values_and_sets_are_significant() {
        differ("<a x=\"1\"/>", "<a x=\"2\"/>");
        differ("<a x=\"1\"/>", "<a x=\"1\" y=\"1\"/>");
    }

    // §2.3: names are case-sensitive.
    #[test]
    fn names_are_case_sensitive() {
        differ("<a/>", "<A/>");
    }

    #[test]
    fn interior_text_whitespace_is_significant() {
        differ("<a>x y</a>", "<a>x  y</a>");
    }

    #[test]
    fn text_differs_from_an_element() {
        differ("<a>b</a>", "<a><b/></a>");
    }

    // §3 (WFC: Element Type Match).
    #[test]
    fn mismatched_end_tag_is_not_xml() {
        refused("<a></b>");
        refused("<p:a xmlns:p=\"urn:x\"></q:a>");
    }

    // Namespaces §5 (NSC: Prefix Declared).
    #[test]
    fn undeclared_prefix_is_not_namespace_well_formed() {
        refused("<p:a/>");
    }

    // §4.1 (WFC: Entity Declared): no DTD declares any other entity here.
    #[test]
    fn undeclared_entity_is_not_xml() {
        refused("<a>&nbsp;</a>");
    }

    #[test]
    fn unclosed_element_and_trailing_content_are_not_xml() {
        refused("<a><b></a>");
        refused("<a/><b/>");
    }

    // Not XML on either side: the bodies are compared byte for byte.
    #[test]
    fn non_xml_bodies_compare_as_bytes() {
        same("raw payload", "raw payload");
        differ("raw payload", "raw  payload");
        differ("<a></b>", "<a></a>");
    }
}
