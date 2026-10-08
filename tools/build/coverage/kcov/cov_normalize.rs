//! cov_normalize: one kcov Cobertura report, rewritten to repository paths
//! with bytes that do not depend on the run.
//!
//! usage: cov_normalize --in <report.xml> --out <file>
//!            --map <ABS>=<REPO>...          (at least one)
//!            [--exclude <PREFIX>]...
//!            --must-contain <REPO_PATH>...  (at least one)
//!            [--forbid <S>]...
//!
//! The report is kcov's, written with `--configure=cobertura-full-paths=1`, so
//! every `<class filename=...>` is an absolute path. Each is, in this order:
//!   1. dropped when it starts with an --exclude PREFIX (counted on stderr);
//!   2. rewritten by the longest --map ABS it starts with: ABS is replaced by
//!      REPO, giving a path relative to the repository root;
//!   3. otherwise refused: an unmapped file is a report the caller did not
//!      expect, and passing it through would hand covcheck a path that names
//!      nothing.
//! ABS and PREFIX are absolute and end with '/', so a prefix matches whole
//! directory names only; REPO is empty (the repository root) or a relative
//! directory ending with '/'.
//!
//! The output is canonical Cobertura, the subset covcheck reads
//! (tools/build/coverage): the XML declaration, `<coverage timestamp="0">`
//! with no rate attributes, `<sources><source>.</source></sources>`, one
//! `<package name="">`, one `<class>` per repository path sorted bytewise
//! (classes that map to the same path are merged), and `<line number hits>`
//! sorted by number. Hits are clamped to 0 or 1, so the bytes do not depend on
//! how often a line ran. A line's `branch` attribute is kept: `true` with its
//! `condition-coverage` "NN% (k/n)", or `false`. Merging two lines: hits 1 if
//! either is 1; `true` wins over `false` over none; two `true` with the same n
//! keep the larger k, and two with different n are refused.
//!
//! Refused, exit 1, with no output written: a malformed report (the same
//! refusals as covcheck's reader: text outside the root, an unclosed or
//! mismatched tag, an unquoted, valueless or repeated attribute, an unknown
//! entity, `<!` markup other than a comment or a DOCTYPE without an internal
//! subset, a root other than <coverage>, a second root, a <class> inside a
//! <class> or without a filename, a <line> without number or hits, a value
//! that is not a decimal number, a line number of 0 or above 10^9, a bad
//! branch or condition-coverage), an unmapped file name, a mapped path that is
//! not a clean relative path (an empty, '.' or '..' segment) or holds a
//! control byte or is not UTF-8, a --must-contain path with no class in the
//! output or whose class has no line, and an output holding any --forbid
//! string, as given or escaped as the output writes it. Every output path is
//! relative and clean (the mapping and the check above), so an absolute
//! sandbox path cannot be one; --forbid (the caller passes its own working
//! directory) is the backstop against one appearing inside a path.
//!
//! The output is written through a temporary file renamed over <file>, so a
//! failed write leaves no file.
//!
//! Exit status: 0 written; 1 refused; 2 bad usage.
//!
//! Paths, file names and messages are bytes: a file name that is not UTF-8 is
//! named on stderr as it is. An I/O error is named the way the tool's earlier
//! Zig version named it (`FileNotFound`, `FileTooBig`, ...).
//!
//! It uses only the standard library: no shell, no PATH and no network.

use std::collections::hash_map::RandomState;
use std::collections::HashMap;
use std::fs;
use std::hash::{BuildHasher, Hasher};
use std::io::{self, Read, Write};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::Path;
use std::process;

const USAGE: &str = "usage: cov_normalize --in <report.xml> --out <file> --map <ABS>=<REPO>...\n           [--exclude <PREFIX>]... --must-contain <REPO_PATH>... [--forbid <S>]...\n";

const MAX_REPORT: u64 = 1 << 30;
const MAX_LINE: u64 = 1_000_000_000;
const MAX_BRANCHES: u64 = 4096;

// ---- messages ----------------------------------------------------------------

/// One piece of a message: bytes as they are, a number in decimal.
trait Piece {
    fn put(&self, out: &mut Vec<u8>);
}

impl Piece for str {
    fn put(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(self.as_bytes());
    }
}

impl Piece for [u8] {
    fn put(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(self);
    }
}

impl Piece for u64 {
    fn put(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(self.to_string().as_bytes());
    }
}

impl Piece for usize {
    fn put(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(self.to_string().as_bytes());
    }
}

/// The bytes of its pieces, concatenated.
macro_rules! cat {
    ($($p:expr),* $(,)?) => {{
        let mut v: Vec<u8> = Vec::new();
        $( ($p).put(&mut v); )*
        v
    }};
}

fn eprint_bytes(b: &[u8]) {
    let _ = io::stderr().write_all(b);
}

fn usage_fail(msg: Vec<u8>) -> ! {
    eprint_bytes(&cat!("cov_normalize: ", &msg, "\n", USAGE));
    process::exit(2);
}

fn fail(msg: Vec<u8>) -> ! {
    eprint_bytes(&cat!("cov_normalize: ", &msg, "\n"));
    process::exit(1);
}

// ---- I/O error names -----------------------------------------------------------

#[derive(Clone, Copy)]
enum Op {
    Open,
    Read,
    Write,
    Rename,
}

/// The name the earlier Zig version gave an errno from `op` (Linux numbers).
fn err_name(op: Op, e: &io::Error) -> &'static str {
    let Some(n) = e.raw_os_error() else {
        return "Unexpected";
    };
    match (op, n) {
        (_, 2) => "FileNotFound",
        (_, 5) => "InputOutput",
        (_, 12) | (_, 105) => "SystemResources",
        (_, 13) => "AccessDenied",
        (Op::Rename, 16) => "FileBusy",
        (_, 16) => "DeviceBusy",
        (_, 17) | (Op::Rename, 39) => "PathAlreadyExists",
        (Op::Rename, 18) => "RenameAcrossMountPoints",
        (Op::Open, 19) | (Op::Open, 6) => "NoDevice",
        (_, 20) => "NotDir",
        (_, 21) => "IsDir",
        (Op::Open, 22) => "BadPathName",
        (Op::Write, 22) => "InvalidArgument",
        (_, 23) => "SystemFdQuotaExceeded",
        (_, 24) => "ProcessFdQuotaExceeded",
        (Op::Open, 26) => "FileBusy",
        (_, 27) | (Op::Open, 75) => "FileTooBig",
        (_, 28) => "NoSpaceLeft",
        (_, 30) => "ReadOnlyFileSystem",
        (Op::Rename, 31) => "LinkQuotaExceeded",
        (Op::Write, 32) => "BrokenPipe",
        (_, 36) => "NameTooLong",
        (_, 40) => "SymLinkLoop",
        (_, 1) => "AccessDenied",
        (_, 11) => "WouldBlock",
        (Op::Read, 9) => "NotOpenForReading",
        (Op::Write, 9) => "NotOpenForWriting",
        (_, 104) => "ConnectionResetByPeer",
        (_, 122) => "DiskQuota",
        _ => "Unexpected",
    }
}

fn read_report(path: &[u8]) -> Result<Vec<u8>, &'static str> {
    let p = Path::new(std::ffi::OsStr::from_bytes(path));
    let f = fs::File::open(p).map_err(|e| err_name(Op::Open, &e))?;
    let mut out = Vec::new();
    // One byte past the limit tells a file that is too big.
    f.take(MAX_REPORT + 1)
        .read_to_end(&mut out)
        .map_err(|e| err_name(Op::Read, &e))?;
    if out.len() as u64 > MAX_REPORT {
        return Err("FileTooBig");
    }
    Ok(out)
}

// ---- the report ----------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Debug)]
enum Branch {
    None,
    False,
    True { k: u64, n: u64 },
}

#[derive(Clone, Copy, Debug)]
struct Line {
    number: u64,
    hits: u8,
    branch: Branch,
}

struct Class {
    filename: Vec<u8>,
    lines: Vec<Line>,
}

struct Attr<'a> {
    name: &'a [u8],
    value: Vec<u8>,
}

fn attr_value<'b>(attrs: &'b [Attr], name: &[u8]) -> Option<&'b [u8]> {
    attrs.iter().find(|a| a.name == name).map(|a| a.value.as_slice())
}

fn index_of(hay: &[u8], at: usize, needle: &[u8]) -> Option<usize> {
    if at > hay.len() || needle.len() > hay.len() - at {
        return None;
    }
    hay[at..]
        .windows(needle.len())
        .position(|w| w == needle)
        .map(|p| p + at)
}

fn index_of_byte(hay: &[u8], at: usize, c: u8) -> Option<usize> {
    if at > hay.len() {
        return None;
    }
    hay[at..].iter().position(|&x| x == c).map(|p| p + at)
}

fn is_space(c: u8) -> bool {
    c == b' ' || c == b'\t' || c == b'\n' || c == b'\r'
}

fn is_name_end(c: u8) -> bool {
    is_space(c) || c == b'>' || c == b'/' || c == b'=' || c == b'<'
}

/// The byte an XML predefined entity names; numeric references are not read.
fn entity(name: &[u8]) -> Option<u8> {
    match name {
        b"amp" => Some(b'&'),
        b"lt" => Some(b'<'),
        b"gt" => Some(b'>'),
        b"quot" => Some(b'"'),
        b"apos" => Some(b'\''),
        _ => None,
    }
}

struct Reader<'a> {
    path: &'a [u8],
    b: &'a [u8],
}

impl<'a> Reader<'a> {
    fn line_of(&self, at: usize) -> usize {
        1 + self.b[..at.min(self.b.len())].iter().filter(|&&c| c == b'\n').count()
    }

    fn bad(&self, at: usize, msg: Vec<u8>) -> ! {
        eprint_bytes(&cat!("cov_normalize: ", self.path, ":", &self.line_of(at), ": ", &msg, "\n"));
        process::exit(1);
    }

    fn starts_at(&self, at: usize, s: &[u8]) -> bool {
        self.b[at..].starts_with(s)
    }

    fn unescape(&self, at: usize, v: &[u8]) -> Vec<u8> {
        if !v.contains(&b'&') {
            return v.to_vec();
        }
        let mut out = Vec::with_capacity(v.len());
        let mut i = 0;
        while i < v.len() {
            if v[i] != b'&' {
                out.push(v[i]);
                i += 1;
                continue;
            }
            let semi = index_of_byte(v, i, b';')
                .unwrap_or_else(|| self.bad(at, cat!("an '&' with no ';' in an attribute value")));
            let ent = &v[i + 1..semi];
            let c = entity(ent).unwrap_or_else(|| self.bad(at, cat!("unknown entity '&", ent, ";'")));
            out.push(c);
            i = semi + 1;
        }
        out
    }

    fn number(&self, at: usize, attrs: &[Attr], name: &str, tag: &[u8]) -> u64 {
        let v = attr_value(attrs, name.as_bytes())
            .unwrap_or_else(|| self.bad(at, cat!("<", tag, "> has no ", name)));
        self.decimal(at, v, name)
    }

    fn decimal(&self, at: usize, v: &[u8], what: &str) -> u64 {
        if v.is_empty() || v.len() > 18 {
            self.not_decimal(at, v, what);
        }
        let mut x: u64 = 0;
        for &c in v {
            if !c.is_ascii_digit() {
                self.not_decimal(at, v, what);
            }
            x = x * 10 + u64::from(c - b'0');
        }
        x
    }

    fn not_decimal(&self, at: usize, v: &[u8], what: &str) -> ! {
        self.bad(at, cat!(what, " '", v, "' is not a decimal number"))
    }

    fn not_condition(&self, at: usize, v: &[u8]) -> ! {
        self.bad(at, cat!("condition-coverage '", v, "' is not 'NN% (k/n)'"))
    }

    /// "NN% (k/n)" as k and n.
    fn condition(&self, at: usize, v: &[u8]) -> Branch {
        let pct = index_of_byte(v, 0, b'%').unwrap_or_else(|| self.not_condition(at, v));
        self.decimal(at, &v[..pct], "condition-coverage");
        let rest = &v[pct + 1..];
        if !rest.starts_with(b" (") || !rest.ends_with(b")") {
            self.not_condition(at, v);
        }
        let inner = &rest[2..rest.len() - 1];
        let slash = index_of_byte(inner, 0, b'/').unwrap_or_else(|| self.not_condition(at, v));
        let k = self.decimal(at, &inner[..slash], "condition-coverage");
        let n = self.decimal(at, &inner[slash + 1..], "condition-coverage");
        if n == 0 || k > n {
            self.bad(
                at,
                cat!("condition-coverage '", v, "' is not 'NN% (k/n)' with 0 <= k <= n, n > 0"),
            );
        }
        if n > MAX_BRANCHES {
            self.bad(
                at,
                cat!("condition-coverage '", v, "' claims more than ", &MAX_BRANCHES, " branches on one line"),
            );
        }
        Branch::True { k, n }
    }

    /// The classes of the report, in document order.
    fn read(&self) -> Vec<Class> {
        let b = self.b;
        let n = b.len();
        let mut stack: Vec<&[u8]> = Vec::new();
        let mut classes: Vec<Class> = Vec::new();
        let mut current: Option<Class> = None;
        let mut saw_root = false;
        let mut i = 0;
        while i < n {
            if b[i] != b'<' {
                if stack.is_empty() && !is_space(b[i]) {
                    self.bad(i, cat!("text outside the root element"));
                }
                i += 1;
                continue;
            }
            let start = i;
            if self.starts_at(i, b"<?") {
                let e = index_of(b, i + 2, b"?>").unwrap_or_else(|| self.bad(start, cat!("unterminated <?")));
                i = e + 2;
                continue;
            }
            if self.starts_at(i, b"<!--") {
                let e = index_of(b, i + 4, b"-->").unwrap_or_else(|| self.bad(start, cat!("unterminated comment")));
                i = e + 3;
                continue;
            }
            if self.starts_at(i, b"<!DOCTYPE") {
                let e = index_of(b, i, b">").unwrap_or_else(|| self.bad(start, cat!("unterminated DOCTYPE")));
                if b[i..e].contains(&b'[') {
                    self.bad(start, cat!("a DOCTYPE with an internal subset"));
                }
                i = e + 1;
                continue;
            }
            if i + 1 < n && b[i + 1] == b'!' {
                self.bad(start, cat!("unsupported markup '<!' (CDATA is not read)"));
            }
            if i + 1 < n && b[i + 1] == b'/' {
                let mut j = i + 2;
                while j < n && !is_name_end(b[j]) {
                    j += 1;
                }
                let name = &b[i + 2..j];
                while j < n && is_space(b[j]) {
                    j += 1;
                }
                if j >= n || b[j] != b'>' {
                    self.bad(start, cat!("unterminated end tag </", name));
                }
                let Some(&top) = stack.last() else {
                    self.bad(start, cat!("</", name, "> closes nothing"));
                };
                if top != name {
                    self.bad(start, cat!("</", name, "> closes <", top, ">"));
                }
                stack.pop();
                if name == b"class" {
                    classes.push(current.take().expect("a <class> on the stack is the current class"));
                }
                i = j + 1;
                continue;
            }
            // A start tag.
            let mut j = i + 1;
            while j < n && !is_name_end(b[j]) {
                j += 1;
            }
            let tag = &b[i + 1..j];
            if tag.is_empty() {
                self.bad(start, cat!("a tag with no name"));
            }
            let mut attrs: Vec<Attr> = Vec::new();
            let mut self_closing = false;
            loop {
                while j < n && is_space(b[j]) {
                    j += 1;
                }
                if j >= n || b[j] == b'<' {
                    self.bad(start, cat!("unterminated tag <", tag));
                }
                if b[j] == b'>' {
                    j += 1;
                    break;
                }
                if b[j] == b'/' {
                    if j + 1 < n && b[j + 1] == b'>' {
                        self_closing = true;
                        j += 2;
                        break;
                    }
                    self.bad(j, cat!("'/' not followed by '>' in <", tag));
                }
                let a0 = j;
                while j < n && !is_name_end(b[j]) {
                    j += 1;
                }
                let aname = &b[a0..j];
                if aname.is_empty() {
                    self.bad(j, cat!("malformed attribute in <", tag));
                }
                while j < n && is_space(b[j]) {
                    j += 1;
                }
                if j >= n || b[j] != b'=' {
                    self.bad(a0, cat!("attribute ", aname, " of <", tag, "> has no value"));
                }
                j += 1;
                while j < n && is_space(b[j]) {
                    j += 1;
                }
                if j >= n || (b[j] != b'"' && b[j] != b'\'') {
                    self.bad(a0, cat!("attribute ", aname, " of <", tag, "> is not quoted"));
                }
                let q = b[j];
                let v0 = j + 1;
                let v1 = index_of_byte(b, v0, q)
                    .unwrap_or_else(|| self.bad(a0, cat!("unterminated value of ", aname, " in <", tag)));
                if attr_value(&attrs, aname).is_some() {
                    self.bad(a0, cat!("attribute ", aname, " of <", tag, "> is given twice"));
                }
                let value = self.unescape(a0, &b[v0..v1]);
                attrs.push(Attr { name: aname, value });
                j = v1 + 1;
            }
            if stack.is_empty() {
                if saw_root {
                    self.bad(start, cat!("a second root element <", tag, ">"));
                }
                if tag != b"coverage" {
                    self.bad(start, cat!("the root element is <", tag, ">, not <coverage>"));
                }
                saw_root = true;
            }
            let depth = stack.len();
            let parent: &[u8] = if depth >= 1 { stack[depth - 1] } else { b"" };
            let grandparent: &[u8] = if depth >= 2 { stack[depth - 2] } else { b"" };
            if tag == b"class" {
                if current.is_some() {
                    self.bad(start, cat!("<class> inside <class>"));
                }
                let f = attr_value(&attrs, b"filename").unwrap_or(b"");
                if f.is_empty() {
                    self.bad(start, cat!("<class> has no filename"));
                }
                let c = Class { filename: f.to_vec(), lines: Vec::new() };
                if self_closing {
                    classes.push(c);
                } else {
                    current = Some(c);
                }
            } else if tag == b"line" && parent == b"lines" && grandparent == b"class" {
                // A <method>'s <lines> repeat the class's: only these are read.
                let num = self.number(start, &attrs, "number", tag);
                if num == 0 {
                    self.bad(start, cat!("<line> number 0 (lines start at 1)"));
                }
                if num > MAX_LINE {
                    self.bad(start, cat!("<line> number ", &num, " is above 10^9"));
                }
                let hits = self.number(start, &attrs, "hits", tag);
                let mut br = Branch::None;
                if let Some(bv) = attr_value(&attrs, b"branch") {
                    if bv == b"true" {
                        let cc = attr_value(&attrs, b"condition-coverage")
                            .unwrap_or_else(|| self.bad(start, cat!("a branch line has no condition-coverage")));
                        br = self.condition(start, cc);
                    } else if bv == b"false" {
                        br = Branch::False;
                    } else {
                        self.bad(start, cat!("<line> branch='", bv, "' is not true or false"));
                    }
                }
                current
                    .as_mut()
                    .expect("a <lines> inside a <class> is inside the current class")
                    .lines
                    .push(Line { number: num, hits: u8::from(hits > 0), branch: br });
            }
            if !self_closing {
                stack.push(tag);
            }
            i = j;
        }
        if !saw_root {
            self.bad(n, cat!("no <coverage> element"));
        }
        if let Some(&top) = stack.last() {
            self.bad(n, cat!("<", top, "> is never closed"));
        }
        classes
    }
}

// ---- mapping and merging ---------------------------------------------------------

struct Map {
    abs: Vec<u8>,
    repo: Vec<u8>,
}

/// The repository path of `filename`, or None when no --map covers it.
fn map_path(maps: &[Map], filename: &[u8]) -> Option<Vec<u8>> {
    let mut best: Option<&Map> = None;
    for m in maps {
        if filename.starts_with(&m.abs) && best.map_or(true, |b| m.abs.len() > b.abs.len()) {
            best = Some(m);
        }
    }
    let m = best?;
    Some(cat!(&m.repo, &filename[m.abs.len()..]))
}

/// Refuses a repository path that is not clean: empty, absolute, with an
/// empty, '.' or '..' segment, or holding a control byte.
fn check_repo_path(filename: &[u8], repo: &[u8]) {
    if repo.is_empty() || repo[0] == b'/' || repo[repo.len() - 1] == b'/' {
        fail(cat!("'", filename, "' maps to '", repo, "', which is not a relative file path"));
    }
    for seg in repo.split(|&c| c == b'/') {
        if seg.is_empty() || seg == b"." || seg == b".." {
            fail(cat!("'", filename, "' maps to '", repo, "', which has an empty, '.' or '..' segment"));
        }
    }
    for &c in repo {
        if c < 0x20 || c == 0x7f {
            fail(cat!("'", filename, "' maps to a path holding control byte 0x", format!("{c:02x}").as_str()));
        }
    }
    // covcheck decodes a file name lossily: a byte that is not UTF-8 would
    // name another file there.
    if std::str::from_utf8(repo).is_err() {
        fail(cat!("'", filename, "' maps to '", repo, "', which is not UTF-8"));
    }
}

fn merge_branch(repo: &[u8], number: u64, a: Branch, b: Branch) -> Branch {
    match (a, b) {
        (Branch::None, _) => b,
        (Branch::False, Branch::True { .. }) => b,
        (Branch::False, _) => a,
        (Branch::True { k: xk, n: xn }, Branch::True { k: yk, n: yn }) => {
            if xn != yn {
                fail(cat!(repo, ":", &number, ": two reports of the line give ", &xn, " and ", &yn, " branches"));
            }
            Branch::True { k: xk.max(yk), n: xn }
        }
        (Branch::True { .. }, _) => a,
    }
}

/// The lines of one class sorted by number, each number once. The sort is
/// stable, so lines of one number merge in document order.
fn merge_lines(repo: &[u8], lines: &mut [Line]) -> Vec<Line> {
    lines.sort_by_key(|l| l.number);
    let mut out: Vec<Line> = Vec::new();
    for &l in lines.iter() {
        match out.last_mut() {
            Some(last) if last.number == l.number => {
                last.hits |= l.hits;
                last.branch = merge_branch(repo, l.number, last.branch, l.branch);
            }
            _ => out.push(l),
        }
    }
    out
}

// ---- writing -----------------------------------------------------------------------

fn write_escaped(out: &mut Vec<u8>, s: &[u8]) {
    for &c in s {
        match c {
            b'&' => out.extend_from_slice(b"&amp;"),
            b'<' => out.extend_from_slice(b"&lt;"),
            b'>' => out.extend_from_slice(b"&gt;"),
            b'"' => out.extend_from_slice(b"&quot;"),
            b'\'' => out.extend_from_slice(b"&apos;"),
            _ => out.push(c),
        }
    }
}

fn render(classes: &[(Vec<u8>, Vec<Line>)]) -> Vec<u8> {
    let mut w: Vec<u8> = Vec::new();
    w.extend_from_slice(
        b"<?xml version=\"1.0\" ?>\n\
<coverage timestamp=\"0\">\n\
\t<sources>\n\
\t\t<source>.</source>\n\
\t</sources>\n\
\t<packages>\n\
\t\t<package name=\"\">\n\
\t\t\t<classes>\n",
    );
    for (repo, lines) in classes {
        w.extend_from_slice(b"\t\t\t\t<class name=\"");
        write_escaped(&mut w, repo);
        w.extend_from_slice(b"\" filename=\"");
        write_escaped(&mut w, repo);
        w.extend_from_slice(b"\">\n\t\t\t\t\t<lines>\n");
        for l in lines {
            let _ = write!(w, "\t\t\t\t\t\t<line number=\"{}\" hits=\"{}\"", l.number, l.hits);
            match l.branch {
                Branch::None => {}
                Branch::False => w.extend_from_slice(b" branch=\"false\""),
                Branch::True { k, n } => {
                    let _ = write!(w, " branch=\"true\" condition-coverage=\"{}% ({}/{})\"", k * 100 / n, k, n);
                }
            }
            w.extend_from_slice(b"/>\n");
        }
        w.extend_from_slice(b"\t\t\t\t\t</lines>\n\t\t\t\t</class>\n");
    }
    w.extend_from_slice(
        b"\t\t\t</classes>\n\
\t\t</package>\n\
\t</packages>\n\
</coverage>\n",
    );
    w
}

/// The directory part of `p` (None for a bare name), and its last component.
fn split_path(p: &[u8]) -> (Option<&[u8]>, &[u8]) {
    let mut end = p.len();
    while end > 1 && p[end - 1] == b'/' {
        end -= 1;
    }
    let trimmed = &p[..end];
    match trimmed.iter().rposition(|&c| c == b'/') {
        None => (None, trimmed),
        Some(i) => {
            let base = &trimmed[i + 1..];
            let mut d = i;
            while d > 0 && trimmed[d - 1] == b'/' {
                d -= 1;
            }
            (Some(if d == 0 { &b"/"[..] } else { &trimmed[..d] }), base)
        }
    }
}

/// A random name for the temporary file, 16 URL-safe base64 characters.
fn temp_name() -> Vec<u8> {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    // RandomState is seeded from the operating system's random source.
    let mut bits: u128 = 0;
    for _ in 0..2 {
        let mut h = RandomState::new().build_hasher();
        h.write_u32(process::id());
        bits = (bits << 64) | u128::from(h.finish());
    }
    (0..16).map(|i| ALPHABET[((bits >> (6 * i)) & 63) as usize]).collect()
}

fn os_path(b: &[u8]) -> std::path::PathBuf {
    std::ffi::OsString::from_vec(b.to_vec()).into()
}

/// Writes `bytes` to `path` through a temporary file in its directory renamed
/// over it, so a failed write leaves no file, partial or temporary: the
/// temporary file is removed before the error is returned.
fn write_out(path: &[u8], bytes: &[u8]) -> Result<(), &'static str> {
    let (dir, base) = split_path(path);
    let in_dir = |name: &[u8]| -> Vec<u8> {
        match dir {
            None => name.to_vec(),
            Some(d) if d.ends_with(b"/") => cat!(d, name),
            Some(d) => cat!(d, "/", name),
        }
    };
    let (tmp, mut file) = loop {
        let tmp = in_dir(&temp_name());
        match fs::OpenOptions::new().write(true).create_new(true).open(os_path(&tmp)) {
            Ok(f) => break (tmp, f),
            Err(e) if e.raw_os_error() == Some(17) => continue,
            Err(e) => return Err(err_name(Op::Open, &e)),
        }
    };
    let written = file.write_all(bytes).map_err(|e| err_name(Op::Write, &e));
    drop(file);
    let done = written.and_then(|()| {
        fs::rename(os_path(&tmp), os_path(&in_dir(base))).map_err(|e| err_name(Op::Rename, &e))
    });
    if done.is_err() {
        let _ = fs::remove_file(os_path(&tmp));
    }
    done
}

// ---- main ------------------------------------------------------------------------

fn main() {
    let argv: Vec<Vec<u8>> = std::env::args_os().map(|a| a.into_vec()).collect();

    let mut in_path: Option<&[u8]> = None;
    let mut out_path: Option<&[u8]> = None;
    let mut maps: Vec<Map> = Vec::new();
    let mut excludes: Vec<&[u8]> = Vec::new();
    let mut musts: Vec<&[u8]> = Vec::new();
    let mut forbids: Vec<&[u8]> = Vec::new();
    let mut a = 1;
    while a < argv.len() {
        let flag = argv[a].as_slice();
        if a + 1 >= argv.len() {
            usage_fail(cat!(flag, " has no value"));
        }
        let v = argv[a + 1].as_slice();
        match flag {
            b"--in" => {
                if in_path.is_some() {
                    usage_fail(cat!("--in given twice"));
                }
                in_path = Some(v);
            }
            b"--out" => {
                if out_path.is_some() {
                    usage_fail(cat!("--out given twice"));
                }
                out_path = Some(v);
            }
            b"--map" => {
                let eq = index_of_byte(v, 0, b'=')
                    .unwrap_or_else(|| usage_fail(cat!("--map '", v, "' is not ABS=REPO")));
                let abs = &v[..eq];
                let repo = &v[eq + 1..];
                if abs.len() < 2 || abs[0] != b'/' || abs[abs.len() - 1] != b'/' {
                    usage_fail(cat!("--map ABS '", abs, "' must be absolute and end with '/'"));
                }
                if !repo.is_empty() && (repo[0] == b'/' || repo[repo.len() - 1] != b'/') {
                    usage_fail(cat!("--map REPO '", repo, "' must be empty or relative and end with '/'"));
                }
                if maps.iter().any(|m| m.abs == abs) {
                    usage_fail(cat!("--map ABS '", abs, "' given twice"));
                }
                maps.push(Map { abs: abs.to_vec(), repo: repo.to_vec() });
            }
            b"--exclude" => {
                if v.len() < 2 || v[0] != b'/' || v[v.len() - 1] != b'/' {
                    usage_fail(cat!("--exclude '", v, "' must be absolute and end with '/'"));
                }
                excludes.push(v);
            }
            b"--must-contain" => {
                if v.is_empty() || v[0] == b'/' {
                    usage_fail(cat!("--must-contain '", v, "' must be a repository path"));
                }
                musts.push(v);
            }
            b"--forbid" => {
                if v.is_empty() {
                    usage_fail(cat!("--forbid is empty"));
                }
                forbids.push(v);
            }
            _ => usage_fail(cat!("unknown flag '", flag, "'")),
        }
        a += 2;
    }
    let in_file = in_path.unwrap_or_else(|| usage_fail(cat!("--in is required")));
    let out_file = out_path.unwrap_or_else(|| usage_fail(cat!("--out is required")));
    if maps.is_empty() {
        usage_fail(cat!("at least one --map is required"));
    }
    if musts.is_empty() {
        usage_fail(cat!("at least one --must-contain is required"));
    }

    let text = read_report(in_file).unwrap_or_else(|e| fail(cat!(in_file, ": ", e)));
    let reader = Reader { path: in_file, b: &text };
    let classes = reader.read();

    // Map, refuse the unmapped, and group by repository path in the order
    // each path is first seen.
    let mut index: HashMap<Vec<u8>, usize> = HashMap::new();
    let mut by_repo: Vec<(Vec<u8>, Vec<Line>)> = Vec::new();
    let mut excluded: usize = 0;
    let mut unmapped: usize = 0;
    for c in &classes {
        if excludes.iter().any(|e| c.filename.starts_with(e)) {
            excluded += 1;
            continue;
        }
        let Some(repo) = map_path(&maps, &c.filename) else {
            eprint_bytes(&cat!(
                "cov_normalize: unmapped file name '",
                &c.filename,
                "': no --map or --exclude prefix covers it\n"
            ));
            unmapped += 1;
            continue;
        };
        check_repo_path(&c.filename, &repo);
        let slot = *index.entry(repo.clone()).or_insert_with(|| {
            by_repo.push((repo, Vec::new()));
            by_repo.len() - 1
        });
        by_repo[slot].1.extend_from_slice(&c.lines);
    }
    if unmapped > 0 {
        fail(cat!(&unmapped, " unmapped file name(s) in ", in_file, "; nothing written"));
    }

    let mut outs: Vec<(Vec<u8>, Vec<Line>)> = Vec::with_capacity(by_repo.len());
    for (repo, lines) in by_repo.iter_mut() {
        let merged = merge_lines(repo, lines);
        outs.push((repo.clone(), merged));
    }
    outs.sort_by(|x, y| x.0.cmp(&y.0));

    for m in &musts {
        let Some(&slot) = index.get(*m) else {
            fail(cat!("no class for ", *m, " (--must-contain): its source was not in the report; nothing written"));
        };
        // A class with no line is no evidence that kcov read the source.
        if by_repo[slot].1.is_empty() {
            fail(cat!(
                "the class for ",
                *m,
                " has no line (--must-contain): kcov did not read its source; nothing written"
            ));
        }
    }

    let bytes = render(&outs);
    // A forbidden string is looked for as given and as the output writes it
    // in an attribute (escaped): `a&b` in a path is `a&amp;b` in the bytes.
    for s in &forbids {
        let mut esc = Vec::new();
        write_escaped(&mut esc, s);
        if index_of(&bytes, 0, s).is_some() || index_of(&bytes, 0, &esc).is_some() {
            fail(cat!("the output would hold '", *s, "' (--forbid); nothing written"));
        }
    }

    if let Err(e) = write_out(out_file, &bytes) {
        fail(cat!(out_file, ": ", e, "; nothing written"));
    }
    eprint_bytes(&cat!(
        "cov_normalize: ",
        &classes.len(),
        " class(es) read, ",
        &excluded,
        " excluded, ",
        &outs.len(),
        " written\n"
    ));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_path_names_directory_and_file() {
        assert_eq!(split_path(b"out.xml"), (None, &b"out.xml"[..]));
        assert_eq!(split_path(b"a/b/out.xml"), (Some(&b"a/b"[..]), &b"out.xml"[..]));
        assert_eq!(split_path(b"/out.xml"), (Some(&b"/"[..]), &b"out.xml"[..]));
        assert_eq!(split_path(b"a//out.xml"), (Some(&b"a"[..]), &b"out.xml"[..]));
    }

    #[test]
    fn longest_map_wins_whatever_the_order() {
        let maps = [
            Map { abs: b"/r/".to_vec(), repo: b"x/".to_vec() },
            Map { abs: b"/r/lib/".to_vec(), repo: b"y/".to_vec() },
        ];
        assert_eq!(map_path(&maps, b"/r/lib/a.mojo").unwrap(), b"y/a.mojo");
        assert_eq!(map_path(&maps, b"/r/t.mojo").unwrap(), b"x/t.mojo");
        assert!(map_path(&maps, b"/s/t.mojo").is_none());
    }

    #[test]
    fn branch_merge_is_true_over_false_over_none() {
        let t = |k, n| Branch::True { k, n };
        assert_eq!(merge_branch(b"p", 1, Branch::None, Branch::False), Branch::False);
        assert_eq!(merge_branch(b"p", 1, Branch::False, Branch::None), Branch::False);
        assert_eq!(merge_branch(b"p", 1, Branch::False, t(1, 2)), t(1, 2));
        assert_eq!(merge_branch(b"p", 1, t(1, 2), Branch::False), t(1, 2));
        assert_eq!(merge_branch(b"p", 1, t(2, 2), t(1, 2)), t(2, 2));
    }

    #[test]
    fn temp_names_are_url_safe_and_differ() {
        let a = temp_name();
        assert_eq!(a.len(), 16);
        assert!(a.iter().all(|c| c.is_ascii_alphanumeric() || *c == b'-' || *c == b'_'));
        assert_ne!(a, temp_name());
    }
}
