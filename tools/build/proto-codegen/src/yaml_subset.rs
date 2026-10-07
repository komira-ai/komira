//! A reader for the block-style YAML subset a googleapis service
//! configuration (`<api>_<version>.yaml`) is written in, for
//! [`crate::service_config`].
//!
//! Read: block mappings with plain keys (`[A-Za-z_][A-Za-z0-9_]*`), block
//! sequences (an item's mapping may start on its `- ` line, and a key's
//! sequence may sit at the key's own indentation), and scalars that are
//! plain, single-quoted (`''` is a quote) or double-quoted (escapes `\\`,
//! `\"`, `\/`, `\n`, `\t`), each on one line, with `#` comments. A scalar is
//! kept as its text: nothing is typed.
//!
//! Refused, naming the line: a tab in the indentation of a line that is read,
//! a flow collection (`[`, `{`), a block scalar (`|`, `>`), an anchor, alias,
//! tag or directive (`&`, `*`, `!`, `%`, `@`, a backquote), a document
//! marker, a plain scalar holding `: `, a key given twice in one mapping, and
//! indentation that fits no enclosing node.
//!
//! [`parse_top_level`] reads only the top-level keys it is asked for: the
//! body of any other top-level key (its indented lines, and a sequence at
//! column 0 under it) is skipped unread, so a feature of the subset's
//! refusals in a section nobody reads (a `documentation` block scalar) is
//! not an error.

use std::collections::BTreeMap;

/// A YAML value of the subset.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Yaml {
    /// A scalar's text, quotes removed and escapes applied. A key with no
    /// value is the empty scalar.
    Scalar(String),
    Seq(Vec<Node>),
    /// The entries in document order (keys are distinct).
    Map(Vec<(String, Node)>),
}

/// A value and the 1-based line it starts on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Node {
    pub line: usize,
    pub value: Yaml,
}

impl Node {
    /// The value under `key` of a mapping, if it holds one.
    pub fn get(&self, key: &str) -> Option<&Node> {
        match &self.value {
            Yaml::Map(entries) => entries.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }
}

#[derive(Clone, Debug)]
struct Line<'a> {
    no: usize,
    indent: usize,
    text: &'a str,
    tab_in_indent: bool,
}

fn err(line: usize, msg: impl std::fmt::Display) -> String {
    format!("line {line}: {msg}")
}

/// The lines that hold content: blank lines and whole-line comments dropped.
fn lines(text: &str) -> Vec<Line<'_>> {
    let mut out = Vec::new();
    for (i, raw) in text.lines().enumerate() {
        let raw = raw.strip_suffix('\r').unwrap_or(raw);
        let body = raw.trim_start_matches([' ', '\t']);
        let lead = &raw[..raw.len() - body.len()];
        let body = body.trim_end_matches([' ', '\t']);
        if body.is_empty() || body.starts_with('#') {
            continue;
        }
        out.push(Line {
            no: i + 1,
            indent: lead.len(),
            text: body,
            tab_in_indent: lead.contains('\t'),
        });
    }
    out
}

fn is_dash(l: &Line<'_>) -> bool {
    l.text == "-" || l.text.starts_with("- ")
}

/// `key: rest` or `key:`, the key a plain identifier. `None` when the text
/// is not a mapping entry.
fn split_key(text: &str) -> Option<(&str, &str)> {
    let colon = text.find(':')?;
    let (key, after) = (&text[..colon], &text[colon + 1..]);
    let ident = key
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
    if !ident {
        return None;
    }
    if after.is_empty() {
        return Some((key, ""));
    }
    after.strip_prefix(' ').map(|rest| (key, rest.trim_start_matches(' ')))
}

/// The text after a closing quote must be nothing or a comment.
fn only_comment_after(rest: &str, line: usize) -> Result<(), String> {
    let rest = rest.trim_start_matches(' ');
    if rest.is_empty() || rest.starts_with('#') {
        Ok(())
    } else {
        Err(err(line, format!("text `{rest}` after a quoted scalar")))
    }
}

fn scalar(text: &str, line: usize) -> Result<String, String> {
    if let Some(body) = text.strip_prefix('\'') {
        let mut out = String::new();
        let mut chars = body.char_indices().peekable();
        while let Some((i, c)) = chars.next() {
            if c == '\'' {
                if let Some(&(_, '\'')) = chars.peek() {
                    chars.next();
                    out.push('\'');
                    continue;
                }
                only_comment_after(&body[i + 1..], line)?;
                return Ok(out);
            }
            out.push(c);
        }
        return Err(err(line, "a single-quoted scalar is not closed on its line"));
    }
    if let Some(body) = text.strip_prefix('"') {
        let mut out = String::new();
        let mut chars = body.char_indices();
        while let Some((i, c)) = chars.next() {
            match c {
                '"' => {
                    only_comment_after(&body[i + 1..], line)?;
                    return Ok(out);
                }
                '\\' => match chars.next().map(|(_, e)| e) {
                    Some('\\') => out.push('\\'),
                    Some('"') => out.push('"'),
                    Some('/') => out.push('/'),
                    Some('n') => out.push('\n'),
                    Some('t') => out.push('\t'),
                    Some(e) => {
                        return Err(err(line, format!("escape `\\{e}` is not read")))
                    }
                    None => break,
                },
                _ => out.push(c),
            }
        }
        return Err(err(line, "a double-quoted scalar is not closed on its line"));
    }
    if let Some(c) = text.chars().next() {
        if "[{|>&*!%@`".contains(c) {
            return Err(err(
                line,
                format!(
                    "`{c}` starts a flow collection, block scalar, anchor, alias, tag or \
                     directive, which this reader does not read"
                ),
            ));
        }
    }
    let plain = match text.find(" #") {
        Some(at) => text[..at].trim_end_matches(' '),
        None => text,
    };
    if plain.contains(": ") || plain.ends_with(':') {
        return Err(err(line, format!("plain scalar `{plain}` holds `: `")));
    }
    Ok(plain.to_string())
}

struct Reader<'a> {
    lines: Vec<Line<'a>>,
    i: usize,
}

impl<'a> Reader<'a> {
    fn peek(&self) -> Option<&Line<'a>> {
        self.lines.get(self.i)
    }

    fn check_tabs(&self) -> Result<(), String> {
        match self.peek() {
            Some(l) if l.tab_in_indent => Err(err(l.no, "a tab in the indentation")),
            _ => Ok(()),
        }
    }

    /// The node whose first line is the current one, at `indent`.
    fn block(&mut self, indent: usize) -> Result<Node, String> {
        self.check_tabs()?;
        let l = self.peek().expect("block called at a line");
        if is_dash(l) {
            self.seq(indent)
        } else {
            self.map(indent)
        }
    }

    /// The value of a mapping entry whose `rest` (text after `key:`) is on
    /// the line just consumed, at `indent`.
    fn entry_value(&mut self, rest: &str, indent: usize, line: usize) -> Result<Node, String> {
        if !rest.is_empty() {
            return Ok(Node { line, value: Yaml::Scalar(scalar(rest, line)?) });
        }
        match self.peek() {
            Some(n) if n.indent > indent => {
                let ind = n.indent;
                self.block(ind)
            }
            Some(n) if n.indent == indent && is_dash(n) => self.seq(indent),
            _ => Ok(Node { line, value: Yaml::Scalar(String::new()) }),
        }
    }

    fn map(&mut self, indent: usize) -> Result<Node, String> {
        let start = self.peek().map_or(0, |l| l.no);
        let mut entries: Vec<(String, Node)> = Vec::new();
        while let Some(l) = self.peek() {
            if l.indent != indent || is_dash(l) {
                break;
            }
            self.check_tabs()?;
            let (no, text) = (l.no, l.text);
            if text == "---" || text == "..." {
                return Err(err(no, "a document marker"));
            }
            let (key, rest) = split_key(text)
                .ok_or_else(|| err(no, format!("`{text}` is not a `key: value` entry")))?;
            if entries.iter().any(|(k, _)| k == key) {
                return Err(err(no, format!("key `{key}` is given twice in one mapping")));
            }
            self.i += 1;
            let value = self.entry_value(rest, indent, no)?;
            entries.push((key.to_string(), value));
        }
        Ok(Node { line: start, value: Yaml::Map(entries) })
    }

    fn seq(&mut self, indent: usize) -> Result<Node, String> {
        let start = self.peek().map_or(0, |l| l.no);
        let mut items = Vec::new();
        while let Some(l) = self.peek() {
            if l.indent != indent || !is_dash(l) {
                break;
            }
            self.check_tabs()?;
            let no = l.no;
            let after = &l.text[1..];
            let rest = after.trim_start_matches(' ');
            if rest.is_empty() {
                self.i += 1;
                match self.peek() {
                    Some(n) if n.indent > indent => {
                        let ind = n.indent;
                        items.push(self.block(ind)?);
                    }
                    _ => items.push(Node { line: no, value: Yaml::Scalar(String::new()) }),
                }
            } else if split_key(rest).is_some() || rest == "-" || rest.starts_with("- ") {
                // The item's node starts on the dash line, at the column of
                // its first character.
                let col = indent + 1 + (after.len() - rest.len());
                self.lines[self.i].indent = col;
                self.lines[self.i].text = rest;
                items.push(self.block(col)?);
            } else {
                self.i += 1;
                items.push(Node { line: no, value: Yaml::Scalar(scalar(rest, no)?) });
            }
        }
        Ok(Node { line: start, value: Yaml::Seq(items) })
    }
}

/// Read the top-level keys of `text` named in `wanted`, each parsed in full;
/// the bodies of the other top-level keys are skipped unread. A wanted key
/// the document does not hold is absent from the result.
pub fn parse_top_level(text: &str, wanted: &[&str]) -> Result<BTreeMap<String, Node>, String> {
    let mut r = Reader { lines: lines(text), i: 0 };
    let mut out = BTreeMap::new();
    let mut seen: Vec<String> = Vec::new();
    while let Some(l) = r.peek() {
        let (no, text) = (l.no, l.text);
        // A node ends at the first line it cannot hold, which then ends
        // every node enclosing it: a line left over here, indented, fits none.
        if l.indent != 0 {
            return Err(err(no, "indentation that fits no enclosing node"));
        }
        if is_dash(l) {
            return Err(err(no, "the top level is not a mapping of keys at column 0"));
        }
        if text == "---" || text == "..." {
            return Err(err(no, "a document marker"));
        }
        let (key, rest) = split_key(text)
            .ok_or_else(|| err(no, format!("`{text}` is not a `key: value` entry")))?;
        if seen.iter().any(|k| k == key) {
            return Err(err(no, format!("top-level key `{key}` is given twice")));
        }
        seen.push(key.to_string());
        r.i += 1;
        if wanted.contains(&key) {
            let value = r.entry_value(rest, 0, no)?;
            out.insert(key.to_string(), value);
        } else {
            while let Some(n) = r.peek() {
                if n.indent > 0 || is_dash(n) {
                    r.i += 1;
                } else {
                    break;
                }
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(n: &Node) -> &str {
        match &n.value {
            Yaml::Scalar(v) => v,
            other => panic!("not a scalar: {other:?}"),
        }
    }

    fn items(n: &Node) -> &[Node] {
        match &n.value {
            Yaml::Seq(v) => v,
            other => panic!("not a sequence: {other:?}"),
        }
    }

    const DOC: &str = "\
type: google.api.Service
config_version: 3
name: run.googleapis.com

apis:
- name: google.cloud.location.Locations
- name: google.longrunning.Operations   # a mixin

documentation:
  summary: |-
    Text: with a colon, [brackets] and *stars*.
\tand a tab
  rules:
  - selector: x
    description: y

http:
  rules:
  - selector: google.longrunning.Operations.GetOperation
    get: '/v2/{name=projects/*/locations/*/operations/*}'
  - selector: google.longrunning.Operations.WaitOperation
    post: \"/v2/{name=projects/*/locations/*/operations/*}:wait\"
    body: '*'
    additional_bindings:
    -   get: '/v2/it''s'
";

    #[test]
    fn reads_the_wanted_keys_and_skips_the_rest() {
        let top = parse_top_level(DOC, &["name", "apis", "http"]).unwrap();
        assert_eq!(top.keys().collect::<Vec<_>>(), ["apis", "http", "name"]);
        assert_eq!(s(&top["name"]), "run.googleapis.com");
        let apis = items(&top["apis"]);
        assert_eq!(s(apis[1].get("name").unwrap()), "google.longrunning.Operations");
        let rules = items(top["http"].get("rules").unwrap());
        assert_eq!(rules.len(), 2);
        assert_eq!(rules[0].line, 19);
        assert_eq!(
            s(rules[0].get("get").unwrap()),
            "/v2/{name=projects/*/locations/*/operations/*}"
        );
        assert_eq!(
            s(rules[1].get("post").unwrap()),
            "/v2/{name=projects/*/locations/*/operations/*}:wait"
        );
        assert_eq!(s(rules[1].get("body").unwrap()), "*");
        let extra = items(rules[1].get("additional_bindings").unwrap());
        assert_eq!(s(extra[0].get("get").unwrap()), "/v2/it's");
    }

    #[test]
    fn a_skipped_section_may_hold_what_a_read_one_may_not() {
        // The documentation block scalar and its tab are never read.
        parse_top_level(DOC, &["name"]).unwrap();
        let err = parse_top_level(DOC, &["documentation"]).unwrap_err();
        assert_eq!(
            err,
            "line 10: `|` starts a flow collection, block scalar, anchor, alias, tag or \
             directive, which this reader does not read"
        );
    }

    #[test]
    fn refusals_name_the_line() {
        for (doc, want) in [
            ("a:\n\tb: c\n", "line 2: a tab in the indentation"),
            ("a: [x]\n", "line 1: `[` starts a flow collection"),
            ("a: *x\n", "line 1: `*` starts a flow collection"),
            ("a: b\na: c\n", "line 2: top-level key `a` is given twice"),
            ("a:\n  b: 1\n  b: 2\n", "line 3: key `b` is given twice in one mapping"),
            ("a:\n    b: 1\n  c: 2\n", "line 3: indentation that fits no enclosing node"),
            ("a: 'x\n", "line 1: a single-quoted scalar is not closed on its line"),
            ("a: \"x\\q\"\n", "line 1: escape `\\q` is not read"),
            ("a: 'x' y\n", "line 1: text `y` after a quoted scalar"),
            ("a: b: c\n", "line 1: plain scalar `b: c` holds `: `"),
            ("  a: b\n", "line 1: indentation that fits no enclosing node"),
            ("- a\n", "line 1: the top level is not a mapping of keys at column 0"),
            ("---\n", "line 1: a document marker"),
            ("a:\n  - x\n  y: z\n", "line 3: indentation that fits no enclosing node"),
            ("a:\n  b: 1\n  - x\n", "line 3: indentation that fits no enclosing node"),
            ("a:\n  b:\n    x: 1\n   y: 2\n", "line 4: indentation that fits no enclosing node"),
        ] {
            let got = parse_top_level(doc, &["a"]).unwrap_err();
            assert!(got.starts_with(want), "{doc:?}: {got}");
        }
    }

    #[test]
    fn a_key_with_no_value_is_the_empty_scalar_and_comments_are_dropped() {
        let top = parse_top_level("a:\nb: x # note\nc: 'y' # q\n", &["a", "b", "c"]).unwrap();
        assert_eq!(s(&top["a"]), "");
        assert_eq!(s(&top["b"]), "x");
        assert_eq!(s(&top["c"]), "y");
    }
}
