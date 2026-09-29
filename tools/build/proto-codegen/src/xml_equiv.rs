//! XML equivalence for the conformance harness: two documents are equal
//! when their namespace-resolved element trees are.

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
