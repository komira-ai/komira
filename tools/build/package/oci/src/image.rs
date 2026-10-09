//! An image's filesystem: its layers applied in order, as a container
//! runtime applies them (OCI image spec, "Applying changesets").
//!
//! A later entry replaces an earlier one at the same path; an entry that is
//! not a directory also removes what was below that path. Whiteouts apply to
//! the layers below theirs, never to entries of their own layer:
//! `<dir>/.wh.<name>` removes `<dir>/<name>` and everything under it, and
//! `<dir>/.wh..wh..opq` (an opaque directory) removes every child of `<dir>`.

use crate::tar::{Entry, Kind};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Type {
    File,
    Dir,
    Symlink,
    Other,
}

impl Type {
    fn letter(self) -> char {
        match self {
            Type::File => '-',
            Type::Dir => 'd',
            Type::Symlink => 'l',
            Type::Other => '?',
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Node {
    pub ty: Type,
    pub mode: u32,
    pub size: u64,
    pub link: String,
}

const OPAQUE: &str = ".wh..wh..opq";
const WHITEOUT: &str = ".wh.";
const MAX_LINKS: usize = 40;

/// `p` relative to /, without empty, `.` and `..` parts (`..` at / stays at /).
pub fn normalize(p: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for c in p.split('/') {
        match c {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            _ => parts.push(c),
        }
    }
    parts.join("/")
}

fn join(dir: &str, name: &str) -> String {
    if dir.is_empty() {
        name.to_string()
    } else {
        format!("{}/{}", dir, name)
    }
}

fn split(p: &str) -> (&str, &str) {
    match p.rfind('/') {
        Some(i) => (&p[..i], &p[i + 1..]),
        None => ("", p),
    }
}

#[derive(Default)]
pub struct Fs {
    pub nodes: BTreeMap<String, Node>,
}

impl Fs {
    /// Every path strictly under `dir` ("" is /).
    fn remove_children(&mut self, dir: &str) {
        if dir.is_empty() {
            self.nodes.clear();
            return;
        }
        let from = format!("{}/", dir);
        let under: Vec<String> = self.nodes.range(from.clone()..).take_while(|(k, _)| k.starts_with(&from)).map(|(k, _)| k.clone()).collect();
        for k in under {
            self.nodes.remove(&k);
        }
    }

    /// `p` and everything under it.
    fn remove_tree(&mut self, p: &str) {
        self.nodes.remove(p);
        self.remove_children(p);
    }

    /// Applies one layer over this filesystem.
    pub fn apply(&mut self, entries: &[Entry]) -> Result<(), String> {
        // Whiteouts first: they hide the layers below, whatever their order
        // in the layer.
        for e in entries {
            let p = normalize(&e.path);
            let (dir, base) = split(&p);
            if base == OPAQUE {
                self.remove_children(dir);
            } else if let Some(name) = base.strip_prefix(WHITEOUT) {
                if name.is_empty() || name == "." || name == ".." {
                    return Err(format!("a whiteout `{}` names no entry", e.path));
                }
                self.remove_tree(&join(dir, name));
            }
        }
        for e in entries {
            let p = normalize(&e.path);
            if split(&p).1.starts_with(WHITEOUT) {
                continue;
            }
            if p.is_empty() {
                if e.kind != Kind::Dir {
                    return Err(format!("the layer's root entry `{}` is not a directory", e.path));
                }
                continue;
            }
            let node = match e.kind {
                Kind::Hardlink => {
                    let target = normalize(&e.link);
                    let n = self.nodes.get(&target).ok_or_else(|| format!("hard link {} -> {}: no such entry", p, e.link))?;
                    if n.ty == Type::Dir {
                        return Err(format!("hard link {} -> {}: a directory", p, e.link));
                    }
                    n.clone()
                }
                k => Node {
                    ty: match k {
                        Kind::File => Type::File,
                        Kind::Dir => Type::Dir,
                        Kind::Symlink => Type::Symlink,
                        _ => Type::Other,
                    },
                    mode: e.mode,
                    size: e.size,
                    link: e.link.clone(),
                },
            };
            if node.ty != Type::Dir {
                self.remove_children(&p);
            }
            self.nodes.insert(p, node);
        }
        Ok(())
    }

    /// The path `p` names once every symbolic link on the way is followed:
    /// a key of `nodes`, or a path that names nothing.
    pub fn resolve(&self, p: &str) -> Result<String, String> {
        let mut todo: Vec<String> = p.split('/').rev().map(str::to_string).collect();
        let mut cur = String::new();
        let mut links = 0;
        while let Some(c) = todo.pop() {
            match c.as_str() {
                "" | "." => continue,
                ".." => {
                    cur = split(&cur).0.to_string();
                    continue;
                }
                _ => {}
            }
            let next = join(&cur, &c);
            match self.nodes.get(&next) {
                Some(n) if n.ty == Type::Symlink => {
                    links += 1;
                    if links > MAX_LINKS {
                        return Err(format!("{}: more than {} symbolic links", p, MAX_LINKS));
                    }
                    todo.extend(n.link.split('/').rev().map(str::to_string));
                    if n.link.starts_with('/') {
                        cur.clear();
                    }
                }
                _ => cur = next,
            }
        }
        Ok(cur)
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Want {
    /// A regular file with mode 0755.
    Exec,
    /// A regular file of one byte or more.
    File,
}

/// The answer for each wanted path: `ok ...` lines, and failures.
pub fn check_paths(fs: &Fs, wants: &[(Want, String)]) -> (Vec<String>, Vec<String>) {
    let (mut ok, mut bad) = (Vec::new(), Vec::new());
    for (w, p) in wants {
        let kind = if *w == Want::Exec { "exec" } else { "file" };
        let r = match fs.resolve(p) {
            Ok(r) => r,
            Err(e) => {
                bad.push(format!("{} {}: {}", kind, p, e));
                continue;
            }
        };
        match fs.nodes.get(&r) {
            None => bad.push(format!("{} {}: not in the image", kind, p)),
            Some(n) if n.ty != Type::File => bad.push(format!("{} {}: {} is of type {}, not a regular file", kind, p, r, n.ty.letter())),
            Some(n) if *w == Want::Exec && n.mode != 0o755 => bad.push(format!("exec {}: {} has mode {:o}, want 755", p, r, n.mode)),
            Some(n) if *w == Want::File && n.size < 1 => bad.push(format!("file {}: {} is empty", p, r)),
            Some(_) => ok.push(format!("ok {} {} -> {}", kind, p, r)),
        }
    }
    (ok, bad)
}

/// The entries of `layer` (applied over `below`) that change the type of
/// an entry of `below`: a directory over a symlink (`bin/` over
/// `bin -> usr/bin`) hides everything the link reaches.
pub fn type_changes(below: &Fs, layer: &[Entry]) -> Vec<String> {
    let mut out = Vec::new();
    for e in layer {
        let p = normalize(&e.path);
        if split(&p).1.starts_with(WHITEOUT) {
            continue;
        }
        let ty = match e.kind {
            Kind::File | Kind::Hardlink => Type::File,
            Kind::Dir => Type::Dir,
            Kind::Symlink => Type::Symlink,
            Kind::Other => Type::Other,
        };
        if let Some(n) = below.nodes.get(&p) {
            if n.ty != ty {
                out.push(format!("the last layer turns {} from type {} into type {}", p, n.ty.letter(), ty.letter()));
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tar::{read, write::tar};

    const CERT: &str = "etc/ssl/certs/ca-certificates.crt";

    /// A base like the pinned distroless one, as far as these checks go.
    fn base() -> Vec<Entry> {
        read(&tar(&[
            ("./", b'5', 0o755, b"", ""),
            ("./etc/", b'5', 0o755, b"", ""),
            ("./etc/ssl/", b'5', 0o755, b"", ""),
            ("./etc/ssl/certs/", b'5', 0o755, b"", ""),
            ("./etc/ssl/certs/ca-certificates.crt", b'0', 0o644, b"PEM", ""),
            ("./etc/ssl/cert.pem", b'2', 0o777, b"", "certs/ca-certificates.crt"),
            ("./etc/os-release", b'2', 0o777, b"", "../usr/lib/os-release"),
            ("./usr/", b'5', 0o755, b"", ""),
            ("./usr/lib/", b'5', 0o755, b"", ""),
            ("./usr/lib/os-release", b'0', 0o644, b"ID=debian", ""),
            ("./usr/bin/", b'5', 0o755, b"", ""),
            ("./usr/bin/tool", b'0', 0o755, b"x", ""),
            ("./usr/bin/same", b'1', 0o755, b"", "usr/bin/tool"),
        ]))
        .unwrap()
    }

    fn image(last: &[(&str, u8, u32, &[u8], &str)]) -> (Fs, Fs, Vec<Entry>) {
        let mut below = Fs::default();
        below.apply(&base()).unwrap();
        let layer = read(&tar(last)).unwrap();
        let mut fs = Fs::default();
        fs.apply(&base()).unwrap();
        fs.apply(&layer).unwrap();
        (below, fs, layer)
    }

    fn certs_ok(fs: &Fs) -> Result<(), Vec<String>> {
        let (_, bad) = check_paths(fs, &[(Want::File, CERT.into())]);
        if bad.is_empty() {
            Ok(())
        } else {
            Err(bad)
        }
    }

    const FLOOR: &[(&str, u8, u32, &[u8], &str)] = &[("bin/", b'5', 0o755, b"", ""), ("bin/sh", b'0', 0o755, b"busybox", "")];

    #[test]
    fn control_image_is_green() {
        let (below, fs, layer) = image(FLOOR);
        assert_eq!(certs_ok(&fs), Ok(()));
        let (ok, bad) = check_paths(&fs, &[(Want::Exec, "bin/sh".into()), (Want::Exec, "/usr/bin/same".into()), (Want::File, "etc/ssl/cert.pem".into())]);
        assert!(bad.is_empty(), "{:?}", bad);
        assert_eq!(ok[2], "ok file etc/ssl/cert.pem -> etc/ssl/certs/ca-certificates.crt");
        assert!(type_changes(&below, &layer).is_empty());
    }

    #[test]
    fn a_directory_whiteout_removes_everything_under_it() {
        // etc/.wh.ssl removes etc/ssl, so etc/ssl/certs/... too.
        let (_, fs, _) = image(&[("etc/", b'5', 0o755, b"", ""), ("etc/.wh.ssl", b'0', 0o644, b"", "")]);
        assert_eq!(certs_ok(&fs), Err(vec![format!("file {}: not in the image", CERT)]));
        assert!(fs.nodes.keys().all(|k| !k.starts_with("etc/ssl")), "{:?}", fs.nodes.keys());
        assert!(fs.nodes.contains_key("etc/os-release"));
    }

    #[test]
    fn an_opaque_whiteout_removes_the_children_below() {
        let (_, fs, _) = image(&[("etc/ssl/certs/", b'5', 0o755, b"", ""), ("etc/ssl/certs/.wh..wh..opq", b'0', 0o644, b"", "")]);
        assert_eq!(certs_ok(&fs), Err(vec![format!("file {}: not in the image", CERT)]));
        assert_eq!(fs.nodes.get("etc/ssl/certs").map(|n| n.ty), Some(Type::Dir));
        assert!(fs.nodes.contains_key("etc/ssl/cert.pem"));
    }

    #[test]
    fn whiteouts_spare_their_own_layer_and_siblings() {
        // An opaque directory keeps what its own layer puts in it, in any
        // order; a whiteout of `cert` leaves `certs` alone.
        let (_, fs, _) = image(&[
            ("etc/ssl/certs/ca-certificates.crt", b'0', 0o644, b"NEW", ""),
            ("etc/ssl/certs/.wh..wh..opq", b'0', 0o644, b"", ""),
            ("etc/ssl/.wh.cert", b'0', 0o644, b"", ""),
        ]);
        assert_eq!(certs_ok(&fs), Ok(()));
        assert_eq!(fs.nodes[CERT].size, 3);
        // The same whiteout in a layer that adds nothing back: `cert` names
        // no entry, and `certs/`, what is under it and `cert.pem` (names
        // starting with `cert`) all stay.
        let (_, fs, _) = image(&[("etc/ssl/.wh.cert", b'0', 0o644, b"", "")]);
        assert_eq!(certs_ok(&fs), Ok(()));
        assert_eq!(fs.nodes[CERT].size, 3);
        assert_eq!(fs.nodes.get("etc/ssl/certs").map(|n| n.ty), Some(Type::Dir));
        assert_eq!(fs.nodes.get("etc/ssl/cert.pem").map(|n| n.ty), Some(Type::Symlink));
        // A file whiteout: that one file goes.
        let (_, fs, _) = image(&[("etc/ssl/certs/.wh.ca-certificates.crt", b'0', 0o644, b"", "")]);
        assert!(certs_ok(&fs).is_err());
        assert!(fs.nodes.contains_key("etc/ssl/certs"));
    }

    #[test]
    fn a_file_over_a_directory_hides_what_was_under_it() {
        let (below, fs, layer) = image(&[("etc/ssl", b'0', 0o644, b"x", "")]);
        assert!(certs_ok(&fs).is_err());
        assert_eq!(type_changes(&below, &layer), ["the last layer turns etc/ssl from type d into type -"]);
    }

    #[test]
    fn a_directory_over_a_symlink_is_a_type_change() {
        let (below, _, layer) = image(&[("etc/os-release/", b'5', 0o755, b"", ""), ("etc/os-release/x", b'0', 0o644, b"x", "")]);
        assert_eq!(type_changes(&below, &layer), ["the last layer turns etc/os-release from type l into type d"]);
    }

    #[test]
    fn modes_and_types_are_checked() {
        let (_, fs, _) = image(&[("bin/", b'5', 0o755, b"", ""), ("bin/sh", b'0', 0o644, b"x", ""), ("bin/e", b'0', 0o644, b"", ""), ("bin/d/", b'5', 0o755, b"", "")]);
        let (ok, bad) = check_paths(&fs, &[(Want::Exec, "bin/sh".into()), (Want::File, "bin/e".into()), (Want::Exec, "bin/d".into()), (Want::Exec, "nope".into())]);
        assert!(ok.is_empty());
        assert_eq!(
            bad,
            [
                "exec bin/sh: bin/sh has mode 644, want 755",
                "file bin/e: bin/e is empty",
                "exec bin/d: bin/d is of type d, not a regular file",
                "exec nope: not in the image",
            ]
        );
    }

    #[test]
    fn symlinks_resolve_through_directories_and_dot_dot() {
        let (_, fs, _) = image(&[("lib", b'2', 0o777, b"", "usr/lib"), ("abs", b'2', 0o777, b"", "/etc/os-release"), ("loop", b'2', 0o777, b"", "loop")]);
        assert_eq!(fs.resolve("lib/os-release").unwrap(), "usr/lib/os-release");
        assert_eq!(fs.resolve("abs").unwrap(), "usr/lib/os-release");
        assert_eq!(fs.resolve("/etc/../../etc/./os-release").unwrap(), "usr/lib/os-release");
        assert!(fs.resolve("loop").unwrap_err().contains("symbolic links"));
    }

    fn layer(entries: &[(&str, u8, u32, &[u8], &str)]) -> Vec<Entry> {
        read(&tar(entries)).unwrap()
    }

    fn based() -> Fs {
        let mut fs = Fs::default();
        fs.apply(&base()).unwrap();
        fs
    }

    #[test]
    fn a_layer_that_cannot_be_applied_is_refused() {
        for wh in ["etc/.wh.", "etc/.wh..", "etc/.wh..."] {
            assert_eq!(based().apply(&layer(&[(wh, b'0', 0o644, b"", "")])), Err(format!("a whiteout `{}` names no entry", wh)));
        }
        assert_eq!(Fs::default().apply(&layer(&[("./", b'0', 0o644, b"", "")])), Err("the layer's root entry `./` is not a directory".into()));
        let mut fs = Fs::default();
        fs.apply(&layer(&[("./", b'5', 0o755, b"", ""), ("/", b'5', 0o755, b"", "")])).unwrap();
        assert!(fs.nodes.is_empty(), "{:?}", fs.nodes);
        assert_eq!(based().apply(&layer(&[("a", b'1', 0o644, b"", "nope")])), Err("hard link a -> nope: no such entry".into()));
        assert_eq!(based().apply(&layer(&[("a", b'1', 0o644, b"", "etc")])), Err("hard link a -> etc: a directory".into()));
        // A hard link is its target: type, mode and size.
        let mut fs = based();
        fs.apply(&layer(&[("a", b'1', 0o644, b"", "./usr/bin/tool")])).unwrap();
        assert_eq!(fs.nodes["a"], Node { ty: Type::File, mode: 0o755, size: 1, link: String::new() });
    }

    #[test]
    fn whiteouts_are_never_entries_and_an_opaque_root_empties_all() {
        let (_, fs, _) = image(&[("etc/", b'5', 0o755, b"", ""), ("etc/.wh.ssl", b'0', 0o644, b"", ""), ("usr/.wh..wh..opq", b'0', 0o644, b"", "")]);
        assert!(fs.nodes.keys().all(|k| !k.contains(".wh.")), "{:?}", fs.nodes.keys());
        assert!(fs.nodes.keys().all(|k| !k.starts_with("usr/")), "{:?}", fs.nodes.keys());
        let mut fs = based();
        fs.apply(&layer(&[(".wh..wh..opq", b'0', 0o644, b"", "")])).unwrap();
        assert!(fs.nodes.is_empty(), "{:?}", fs.nodes.keys());
        // A directory over a directory keeps what is under it.
        let (_, fs, _) = image(&[("etc/", b'5', 0o700, b"", ""), ("etc/ssl/", b'5', 0o755, b"", "")]);
        assert_eq!(certs_ok(&fs), Ok(()));
        assert_eq!(fs.nodes["etc"].mode, 0o700);
    }

    #[test]
    fn at_most_forty_links_are_followed() {
        let chain = |prefix: &str, n: usize| -> Vec<(String, String)> { (0..n).map(|i| (format!("{}{}", prefix, i), if i + 1 == n { "usr/lib/os-release".to_string() } else { format!("{}{}", prefix, i + 1) })).collect() };
        let links: Vec<(String, String)> = chain("a", MAX_LINKS).into_iter().chain(chain("b", MAX_LINKS + 1)).collect();
        let entries: Vec<(&str, u8, u32, &[u8], &str)> = links.iter().map(|(p, t)| (p.as_str(), b'2', 0o777, &b""[..], t.as_str())).collect();
        let (_, fs, _) = image(&entries);
        assert_eq!(fs.resolve("a0"), Ok("usr/lib/os-release".into()));
        assert_eq!(fs.resolve("b0"), Err("b0: more than 40 symbolic links".into()));
        let (_, bad) = check_paths(&fs, &[(Want::File, "b0".into())]);
        assert_eq!(bad, ["file b0: b0: more than 40 symbolic links"]);
    }

    #[test]
    fn an_exec_is_exactly_0755_and_a_file_one_byte_or_more() {
        let (_, fs, _) = image(&[("bin/", b'5', 0o755, b"", ""), ("bin/a", b'0', 0o775, b"x", ""), ("bin/b", b'0', 0o4755, b"x", ""), ("one", b'0', 0o644, b"x", "")]);
        let (ok, bad) = check_paths(&fs, &[(Want::Exec, "bin/a".into()), (Want::Exec, "bin/b".into()), (Want::File, "one".into()), (Want::File, "bin/a".into())]);
        assert_eq!(bad, ["exec bin/a: bin/a has mode 775, want 755", "exec bin/b: bin/b has mode 4755, want 755"]);
        assert_eq!(ok, ["ok file one -> one", "ok file bin/a -> bin/a"]);
    }

    #[test]
    fn every_type_change_of_the_last_layer_is_named() {
        let (below, _, layer) = image(&[
            ("etc/", b'5', 0o755, b"", ""),
            ("etc/ssl/", b'1', 0o644, b"", "usr/bin/tool"),
            ("usr/lib/os-release", b'3', 0o644, b"", ""),
            ("usr/lib/", b'5', 0o755, b"", ""),
            ("usr/bin", b'2', 0o777, b"", "lib"),
            ("usr/bin/tool", b'0', 0o644, b"y", ""),
        ]);
        assert_eq!(
            type_changes(&below, &layer),
            [
                "the last layer turns etc/ssl from type d into type -",
                "the last layer turns usr/lib/os-release from type - into type ?",
                "the last layer turns usr/bin from type d into type l",
            ]
        );
    }

    #[test]
    fn normalize_stays_under_root() {
        assert_eq!(normalize("./a//b/../c/"), "a/c");
        assert_eq!(normalize("/../../a"), "a");
        assert_eq!(normalize("./"), "");
    }
}
