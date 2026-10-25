//! Splitting a generated Mojo module that reaches the line limit.
//!
//! A source file is held to fewer than [`MAX_FILE_LINES`] lines (Mojo hangs
//! on very large files), and a generated file has no exemption.
//! [`split_file`] is how every generator keeps to it: a module under the
//! limit is written as it is; a module at or over it is written as
//! a FACADE, `<stem>.mojo`, beside a directory of PARTS,
//! `_parts/<stem>_pNN.mojo`.
//!
//! * The parts hold the module's top-level declarations, in the order the
//!   emitter wrote them, cut between two declarations (a declaration is never
//!   cut), each part under the limit. A part starts with the module's own
//!   `# @generated` header, then the imports it uses: the module's own
//!   imports, and the names it uses that another part declares (parts import
//!   one another; Mojo allows modules to import one another in a cycle). The
//!   cuts are found by packing the declarations into parts of about
//!   [`BODY_PERCENT`] of the limit and then halving every part that does not
//!   fit once its imports are counted, until all do.
//! * The facade keeps what is not a declaration: the module's leading
//!   comments (its documentation) and its closing comments. It then imports
//!   every name the module declares from its part, so that
//!   `from <package>.<stem> import <name>` names the same things as before
//!   the split. (A name the module only imported from elsewhere is not
//!   re-exported: it never was the module's.) The facade lists every name,
//!   so a module of about four thousand names or more cannot be split, and
//!   is refused.
//!
//! The split depends on nothing but the text: the same text gives the same
//! files, byte for byte. A module that cannot be split (a declaration that
//! does not fit in a file by itself, a top-level line that is not a
//! declaration or an import, a name declared twice) is an error: the text is
//! not cut where it cannot be cut.
//!
//! The parts directory exists whether or not a module needed it: the rules
//! that compile a generated package name their sources before the generator
//! has run, so `_parts` is a fixed name, and the rule actions write its
//! `__init__.mojo`.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use crate::header::{DO_NOT_EDIT, GENERATED_TOKEN};

/// A generated file holds fewer lines than this.
pub const MAX_FILE_LINES: usize = 1000;

/// The directory, beside a split module, that holds its parts.
pub const PARTS_DIR: &str = "_parts";

/// The lines of declarations a part is first given, as a percentage of the
/// limit: the rest is its header and imports. A part that still does not fit
/// is halved.
const BODY_PERCENT: usize = 88;

/// The widest an import line the splitter writes is, but for a single name.
const IMPORT_WIDTH: usize = 100;

/// Why a module cannot be split.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SplitError {
    /// The text does not start with a generated-file header
    /// ([`crate::header::render`]): a part could not carry one.
    NoHeader,
    /// A top-level line that is neither an import nor a declaration the
    /// splitter knows.
    Unrecognised { line: usize, text: String },
    /// One top-level name is declared twice.
    DuplicateName(String),
    /// The module imports relatively (`from .x import y`): in a part, which
    /// lives one package down in `_parts`, the dot would name another module.
    RelativeImport(String),
    /// A declaration that does not fit in a file with its header and imports.
    DeclarationTooLarge { name: String, lines: usize },
    /// The facade (documentation and the re-export of every name) reaches the
    /// limit.
    FacadeTooLarge { lines: usize },
}

impl fmt::Display for SplitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SplitError::NoHeader => write!(
                f,
                "the module does not start with a `# {GENERATED_TOKEN}` header, so its parts \
                 could not carry one"
            ),
            SplitError::Unrecognised { line, text } => write!(
                f,
                "line {line} of the module is `{text}`, which is neither an import nor a \
                 declaration (struct, trait, def, fn, comptime, alias, var) the splitter can \
                 move to its own file"
            ),
            SplitError::DuplicateName(n) => write!(
                f,
                "`{n}` is declared twice at the top level of the module, so the file it \
                 belongs to cannot be told"
            ),
            SplitError::RelativeImport(m) => write!(
                f,
                "the module imports `{m}`, a relative import, which would name another module \
                 once moved into `{PARTS_DIR}/`"
            ),
            SplitError::DeclarationTooLarge { name, lines } => write!(
                f,
                "`{name}` is {lines} lines, which with a header and its imports does not fit \
                 in a file under {MAX_FILE_LINES} lines; a declaration is never cut"
            ),
            SplitError::FacadeTooLarge { lines } => write!(
                f,
                "the module's documentation and the re-export of its names are {lines} lines, \
                 which does not fit in a file under {MAX_FILE_LINES} lines"
            ),
        }
    }
}

impl std::error::Error for SplitError {}

/// A file to write: its path (the facade's path for the facade, `_parts/...`
/// beside it for a part) and its text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Emitted {
    pub path: String,
    pub text: String,
}

/// `text`, the module to be written at `path`, as the files to write: one
/// (the module itself) when it holds fewer than [`MAX_FILE_LINES`] lines,
/// else the facade at `path` and its parts. The facade comes first, the parts
/// follow in order.
pub fn split_file(path: &str, text: &str) -> Result<Vec<Emitted>, SplitError> {
    split_with(path, text, MAX_FILE_LINES)
}

/// [`split_file`] with the limit as an argument.
pub fn split_with(path: &str, text: &str, max_lines: usize) -> Result<Vec<Emitted>, SplitError> {
    if line_count(text) < max_lines {
        return Ok(vec![Emitted { path: path.to_string(), text: text.to_string() }]);
    }
    let module = Module::parse(text)?;
    let (dir, stem) = split_path(path);
    module.assemble(&dir, &stem, max_lines)
}

/// The number of lines of `text`.
pub fn line_count(text: &str) -> usize {
    text.lines().count()
}

/// `path` as its directory (with the trailing `/`, or empty) and file stem.
fn split_path(path: &str) -> (String, String) {
    let (dir, file) = match path.rfind('/') {
        Some(i) => (&path[..=i], &path[i + 1..]),
        None => ("", path),
    };
    let stem = file.strip_suffix(".mojo").unwrap_or(file);
    (dir.to_string(), stem.to_string())
}

// ---------------------------------------------------------------------------
// Reading the module
// ---------------------------------------------------------------------------

/// What a line is, to the reader of top-level structure.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Class {
    /// Empty, or only white space, outside any string or bracket.
    Blank,
    /// A comment from column 0, outside any string or bracket.
    Comment,
    /// Starts a top-level statement: column 0, outside any string or
    /// bracket, not a comment.
    Head,
    /// Anything else: indented, or inside a string, a bracket or a
    /// backslash-continued line.
    Body,
}

/// The class of each line of `text`. Strings (single, triple-quoted, with
/// backslash escapes), comments, backtick names, brackets and backslash
/// continuations are followed, so that a line inside a docstring or a
/// parenthesised import is never taken for a statement.
fn classify(lines: &[&str]) -> Vec<Class> {
    let mut out = Vec::with_capacity(lines.len());
    let mut depth: i64 = 0;
    let mut triple: Option<u8> = None;
    let mut cont = false;
    for line in lines {
        let class = if triple.is_some() || depth > 0 || cont {
            Class::Body
        } else if line.trim().is_empty() {
            Class::Blank
        } else if line.starts_with(' ') || line.starts_with('\t') {
            Class::Body
        } else if line.starts_with('#') {
            Class::Comment
        } else {
            Class::Head
        };
        out.push(class);
        cont = false;
        let b = line.as_bytes();
        let n = b.len();
        let mut i = 0;
        while i < n {
            if let Some(q) = triple {
                if b[i] == b'\\' {
                    i += 2;
                } else if b[i] == q && i + 2 < n && b[i + 1] == q && b[i + 2] == q {
                    triple = None;
                    i += 3;
                } else {
                    i += 1;
                }
                continue;
            }
            match b[i] {
                b'#' => break,
                b'"' | b'\'' => {
                    let q = b[i];
                    if i + 2 < n && b[i + 1] == q && b[i + 2] == q {
                        triple = Some(q);
                        i += 3;
                    } else {
                        i += 1;
                        while i < n {
                            if b[i] == b'\\' {
                                i += 2;
                            } else if b[i] == q {
                                i += 1;
                                break;
                            } else {
                                i += 1;
                            }
                        }
                    }
                }
                b'`' => {
                    i += 1;
                    while i < n && b[i] != b'`' {
                        i += 1;
                    }
                    i += 1;
                }
                b'(' | b'[' | b'{' => {
                    depth += 1;
                    i += 1;
                }
                b')' | b']' | b'}' => {
                    depth = (depth - 1).max(0);
                    i += 1;
                }
                b'\\' if i + 1 == n => {
                    cont = true;
                    i += 1;
                }
                _ => i += 1,
            }
        }
    }
    out
}

/// The identifiers of `lines` outside comments and string literals.
fn identifiers(lines: &[&str]) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    let mut triple: Option<u8> = None;
    for line in lines {
        let b = line.as_bytes();
        let n = b.len();
        let mut i = 0;
        while i < n {
            if let Some(q) = triple {
                if b[i] == b'\\' {
                    i += 2;
                } else if b[i] == q && i + 2 < n && b[i + 1] == q && b[i + 2] == q {
                    triple = None;
                    i += 3;
                } else {
                    i += 1;
                }
                continue;
            }
            let c = b[i];
            if c == b'#' {
                break;
            } else if c == b'"' || c == b'\'' {
                if i + 2 < n && b[i + 1] == c && b[i + 2] == c {
                    triple = Some(c);
                    i += 3;
                } else {
                    i += 1;
                    while i < n {
                        if b[i] == b'\\' {
                            i += 2;
                        } else if b[i] == c {
                            i += 1;
                            break;
                        } else {
                            i += 1;
                        }
                    }
                }
            } else if c == b'`' {
                i += 1;
                while i < n && b[i] != b'`' {
                    i += 1;
                }
                i += 1;
            } else if c == b'_' || c.is_ascii_alphabetic() {
                let s = i;
                while i < n && (b[i] == b'_' || b[i].is_ascii_alphanumeric()) {
                    i += 1;
                }
                out.insert(line[s..i].to_string());
            } else {
                i += 1;
            }
        }
    }
    out
}

/// What a top-level statement starts with.
enum Head {
    Import,
    Decorator,
    Decl(String),
}

fn ident_at(s: &str) -> String {
    s.chars().take_while(|c| *c == '_' || c.is_ascii_alphanumeric()).collect()
}

fn parse_head(line: &str) -> Option<Head> {
    if line.starts_with('@') {
        return Some(Head::Decorator);
    }
    if line.starts_with("from ") || line.starts_with("import ") {
        return Some(Head::Import);
    }
    for kw in ["struct ", "trait ", "def ", "fn ", "comptime ", "alias ", "var "] {
        if let Some(rest) = line.strip_prefix(kw) {
            let name = ident_at(rest.trim_start());
            return if name.is_empty() { None } else { Some(Head::Decl(name)) };
        }
    }
    None
}

/// One import statement of the module, read for the names it binds.
struct Import {
    /// `from <module> import ...`: the module; `None` for `import a, b`.
    module: Option<String>,
    /// What each item binds: (the item as written, the name it binds).
    items: Vec<(String, String)>,
}

impl Import {
    fn parse(core: Vec<String>) -> Import {
        // The statement without its comments or brackets.
        let flat: String = core
            .iter()
            .map(|l| l.split('#').next().unwrap_or(""))
            .collect::<Vec<_>>()
            .join(" ")
            .replace(['(', ')'], " ");
        let flat = flat.trim();
        let (module, rest) = if let Some(r) = flat.strip_prefix("from ") {
            let r = r.trim_start();
            let at = r.find(" import ").unwrap_or(r.len());
            let module = r[..at].trim().to_string();
            let items = if at < r.len() { &r[at + " import ".len()..] } else { "" };
            (Some(module), items.to_string())
        } else {
            (None, flat.strip_prefix("import ").unwrap_or(flat).to_string())
        };
        let mut items = Vec::new();
        for item in rest.split(',') {
            let item = item.trim();
            if item.is_empty() {
                continue;
            }
            let bound = match item.split_once(" as ") {
                Some((_, alias)) => alias.trim().to_string(),
                None if module.is_none() => item.split('.').next().unwrap_or(item).to_string(),
                None => item.to_string(),
            };
            items.push((item.to_string(), bound));
        }
        Import { module, items }
    }
}

/// One top-level declaration with the comments before it.
struct Unit {
    lead: Vec<String>,
    core: Vec<String>,
    name: String,
    refs: BTreeSet<String>,
}

impl Unit {
    fn lines(&self) -> usize {
        self.lead.len() + self.core.len()
    }
}

struct Module {
    /// The generated-file header lines.
    header: Vec<String>,
    /// Everything before the first top-level statement.
    prelude: Vec<String>,
    imports: Vec<Import>,
    units: Vec<Unit>,
    /// Comment and blank lines after the last statement.
    epilogue: Vec<String>,
}

impl Module {
    fn parse(text: &str) -> Result<Module, SplitError> {
        let lines: Vec<&str> = text.lines().collect();
        let header = header_of(&lines).ok_or(SplitError::NoHeader)?;
        let class = classify(&lines);

        let mut prelude: Vec<String> = Vec::new();
        let mut imports: Vec<Import> = Vec::new();
        let mut units: Vec<Unit> = Vec::new();
        let mut epilogue: Vec<String> = Vec::new();

        // The statement being read: its lead (comments before it), its core,
        // what it is, and whether its last head line was a decorator (so that
        // the next head is the same statement).
        struct Open {
            lead: Vec<String>,
            core: Vec<String>,
            kind: Option<Head>,
            decorated: bool,
        }
        let mut open: Option<Open> = None;
        let mut pending: Vec<String> = Vec::new();

        fn close(open: &mut Option<Open>, imports: &mut Vec<Import>, units: &mut Vec<Unit>) {
            if let Some(o) = open.take() {
                match o.kind {
                    Some(Head::Import) => imports.push(Import::parse(o.core)),
                    Some(Head::Decl(name)) => {
                        let refs = {
                            let core: Vec<&str> = o.core.iter().map(String::as_str).collect();
                            identifiers(&core)
                        };
                        units.push(Unit { lead: o.lead, core: o.core, name, refs });
                    }
                    _ => unreachable!("a decorator alone is refused when it is read"),
                }
            }
        }

        for (n, (line, class)) in lines.iter().zip(class.iter()).enumerate() {
            match class {
                Class::Blank | Class::Comment => pending.push(line.to_string()),
                Class::Body => match open.as_mut() {
                    Some(o) => {
                        o.core.append(&mut pending);
                        o.core.push(line.to_string());
                    }
                    None => pending.push(line.to_string()),
                },
                Class::Head => {
                    let head = parse_head(line).ok_or_else(|| SplitError::Unrecognised {
                        line: n + 1,
                        text: line.to_string(),
                    })?;
                    let joins = matches!(&open, Some(o) if o.decorated);
                    if joins {
                        let o = open.as_mut().expect("joins implies open");
                        o.core.append(&mut pending);
                        o.core.push(line.to_string());
                        o.decorated = matches!(head, Head::Decorator);
                        if !o.decorated {
                            o.kind = Some(head);
                        }
                    } else {
                        close(&mut open, &mut imports, &mut units);
                        let lead = if open.is_none() && units.is_empty() && imports.is_empty() {
                            // Everything before the first statement is the
                            // module's own prelude.
                            prelude.append(&mut pending);
                            Vec::new()
                        } else {
                            std::mem::take(&mut pending)
                        };
                        let decorated = matches!(head, Head::Decorator);
                        open = Some(Open {
                            lead,
                            core: vec![line.to_string()],
                            kind: if decorated { None } else { Some(head) },
                            decorated,
                        });
                    }
                }
            }
        }
        if matches!(&open, Some(o) if o.decorated) {
            return Err(SplitError::Unrecognised {
                line: lines.len(),
                text: lines.last().map(|l| l.to_string()).unwrap_or_default(),
            });
        }
        close(&mut open, &mut imports, &mut units);
        epilogue.append(&mut pending);
        if prelude.is_empty() && units.is_empty() && imports.is_empty() {
            prelude = epilogue.drain(..).collect();
        }

        for imp in &imports {
            if let Some(m) = imp.module.as_deref().filter(|m| m.starts_with('.')) {
                return Err(SplitError::RelativeImport(m.to_string()));
            }
        }
        let mut seen = BTreeSet::new();
        for u in &units {
            if !seen.insert(u.name.clone()) {
                return Err(SplitError::DuplicateName(u.name.clone()));
            }
        }
        Ok(Module {
            header: header.iter().map(|s| s.to_string()).collect(),
            prelude,
            imports,
            units,
            epilogue,
        })
    }

    /// The facade and parts, or why they do not fit.
    fn assemble(&self, dir: &str, stem: &str, max_lines: usize) -> Result<Vec<Emitted>, SplitError> {
        let mut groups = self.pack((max_lines * BODY_PERCENT / 100).max(1));
        let (module_of, texts) = loop {
            let total = groups.len();
            let width = total.to_string().len().max(2);
            let module_of: Vec<String> =
                (0..total).map(|i| format!("{stem}_p{:0width$}", i + 1)).collect();
            // Which part declares each name.
            let mut owner: BTreeMap<&str, usize> = BTreeMap::new();
            for (p, g) in groups.iter().enumerate() {
                for u in g {
                    owner.insert(u.name.as_str(), p);
                }
            }
            let texts: Vec<String> = (0..total)
                .map(|p| self.render_part(stem, p, &groups, &owner, &module_of, max_lines))
                .collect();
            match texts.iter().position(|t| line_count(t) >= max_lines) {
                None => break (module_of, texts),
                Some(p) if groups[p].len() == 1 => {
                    return Err(SplitError::DeclarationTooLarge {
                        name: groups[p][0].name.clone(),
                        lines: groups[p][0].lines(),
                    })
                }
                Some(p) => {
                    // Halve it, by lines, and look again: the imports of
                    // every part depend on where the names fall.
                    let g = groups.remove(p);
                    let total: usize = g.iter().map(|u| u.lines()).sum();
                    let mut seen = 0;
                    let mut at = 1;
                    for (i, u) in g.iter().enumerate() {
                        seen += u.lines();
                        if seen * 2 >= total {
                            at = (i + 1).clamp(1, g.len() - 1);
                            break;
                        }
                    }
                    let (head, tail) = g.split_at(at);
                    groups.insert(p, tail.to_vec());
                    groups.insert(p, head.to_vec());
                }
            }
        };

        // The facade: the module's own prelude, every name re-exported from
        // its part, the closing comments.
        let mut out: Vec<String> = self.prelude.clone();
        out.push(String::new());
        out.push(format!(
            "# Every declaration of `{stem}` is in a part under `{PARTS_DIR}/`; this module"
        ));
        out.push("# re-exports each, so an import from this module names what it always did.".to_string());
        for (p, g) in groups.iter().enumerate() {
            let names: Vec<&str> = g.iter().map(|u| u.name.as_str()).collect();
            out.extend(render_from(&format!(".{PARTS_DIR}.{}", module_of[p]), &names));
        }
        out.extend(self.epilogue.iter().cloned());
        let facade = join(&out);
        if line_count(&facade) >= max_lines {
            return Err(SplitError::FacadeTooLarge { lines: line_count(&facade) });
        }
        let mut files = Vec::with_capacity(texts.len() + 1);
        files.push(Emitted { path: format!("{dir}{stem}.mojo"), text: facade });
        for (p, text) in texts.into_iter().enumerate() {
            files.push(Emitted { path: format!("{dir}{PARTS_DIR}/{}.mojo", module_of[p]), text });
        }
        Ok(files)
    }

    /// The text of part `p` of `groups`.
    fn render_part(
        &self,
        stem: &str,
        p: usize,
        groups: &[Vec<&Unit>],
        owner: &BTreeMap<&str, usize>,
        module_of: &[String],
        max_lines: usize,
    ) -> String {
        let total = groups.len();
        let g = &groups[p];
        let refs: BTreeSet<&str> = g.iter().flat_map(|u| u.refs.iter().map(String::as_str)).collect();
        let mut out: Vec<String> = self.header.clone();
        out.push(format!(
            "# Part {} of {total} of `{stem}`: declarations of `{stem}.mojo`, which is split so",
            p + 1
        ));
        out.push(format!(
            "# that no generated file reaches {max_lines} lines. Import them from `{stem}`; it re-exports all."
        ));
        out.push(String::new());
        let before = out.len();
        for imp in &self.imports {
            out.extend(render_import(imp, &refs));
        }
        // The names this part uses that another part declares, by part.
        let mut wanted: BTreeMap<usize, Vec<&str>> = BTreeMap::new();
        for u in groups.iter().flatten() {
            if refs.contains(u.name.as_str()) && owner[u.name.as_str()] != p {
                wanted.entry(owner[u.name.as_str()]).or_default().push(u.name.as_str());
            }
        }
        for (q, names) in &wanted {
            out.extend(render_from(&format!(".{}", module_of[*q]), names));
        }
        if out.len() > before {
            out.push(String::new());
        }
        out.push(String::new());
        let mut first = true;
        for u in g {
            let mut lead: &[String] = &u.lead;
            if first {
                let skip = lead.iter().take_while(|l| l.trim().is_empty()).count();
                lead = &lead[skip..];
                first = false;
            }
            out.extend(lead.iter().cloned());
            out.extend(u.core.iter().cloned());
        }
        join(&out)
    }

    /// The declarations in order, grouped into runs of at most `budget`
    /// lines (a declaration over `budget` is a run of its own).
    fn pack(&self, budget: usize) -> Vec<Vec<&Unit>> {
        let mut groups: Vec<Vec<&Unit>> = Vec::new();
        let mut size = 0;
        for u in &self.units {
            let fits = groups.last().is_some() && size + u.lines() <= budget;
            if fits {
                groups.last_mut().expect("fits implies a group").push(u);
                size += u.lines();
            } else {
                groups.push(vec![u]);
                size = u.lines();
            }
        }
        groups
    }
}

/// The header of `lines`: from the first line, which holds the generated-file
/// token, to the line that says not to edit.
fn header_of<'a>(lines: &[&'a str]) -> Option<Vec<&'a str>> {
    let first = lines.first()?;
    if !first.starts_with(&format!("# {GENERATED_TOKEN} ")) {
        return None;
    }
    let end = lines.iter().take(64).position(|l| l.starts_with(&format!("# {DO_NOT_EDIT}")))?;
    Some(lines[..=end].to_vec())
}

fn join(lines: &[String]) -> String {
    let mut s = lines.join("\n");
    s.push('\n');
    s
}

/// The statement `imp` restricted to the names in `refs`, none if it binds
/// none of them.
fn render_import(imp: &Import, refs: &BTreeSet<&str>) -> Vec<String> {
    let kept: Vec<&(String, String)> =
        imp.items.iter().filter(|(_, bound)| bound == "*" || refs.contains(bound.as_str())).collect();
    if kept.is_empty() {
        return Vec::new();
    }
    match &imp.module {
        Some(m) => {
            let names: Vec<&str> = kept.iter().map(|(item, _)| item.as_str()).collect();
            render_from(m, &names)
        }
        None => kept.iter().map(|(item, _)| format!("import {item}")).collect(),
    }
}

/// `from <module> import <names>`: one line when it fits, else the names
/// wrapped in brackets.
fn render_from(module: &str, names: &[&str]) -> Vec<String> {
    let one = format!("from {module} import {}", names.join(", "));
    if one.len() <= IMPORT_WIDTH {
        return vec![one];
    }
    let mut out = vec![format!("from {module} import (")];
    let mut row = String::from("   ");
    for n in names {
        if row.len() > 3 && row.len() + 1 + n.len() + 1 > IMPORT_WIDTH {
            out.push(row);
            row = String::from("   ");
        }
        row.push(' ');
        row.push_str(n);
        row.push(',');
    }
    if row.len() > 3 {
        out.push(row);
    }
    out.push(")".to_string());
    out
}

#[cfg(test)]
mod tests;
