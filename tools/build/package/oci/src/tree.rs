//! `komira_oci tree`: bundles and files laid at paths in one directory, the
//! tree `oci_image` lays at / in an image.
//!
//! The places are refused unless every path is plain (no empty, `.` or `..`
//! part; letters, digits and `_.+-`), a bundle's ends in /, and no path is
//! inside another, so no copy overwrites another's file (a file at
//! `app/bin/x` beside a bundle at `app/` would replace the bundle's
//! program). `lay` takes only a `Plan`, which only `plan` makes, so nothing
//! is laid without those refusals. Modes are 0755 for directories and for
//! files with any exec bit, else 0644; a bundle holds regular files and
//! directories only.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

#[derive(Debug, Clone, PartialEq)]
pub struct Place {
    /// The path in the tree; a bundle's ends in /.
    pub path: String,
    pub src: String,
    pub bundle: bool,
}

/// Places `plan` accepted.
#[derive(Debug)]
pub struct Plan(Vec<Place>);

fn plain(p: &str) -> bool {
    !p.is_empty() && p.split('/').all(|c| !c.is_empty() && c != "." && c != ".." && c.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.+-".contains(&b)))
}

/// The places, or every reason they are refused.
pub fn plan(places: Vec<Place>) -> Result<Plan, Vec<String>> {
    let mut out = Vec::new();
    if places.is_empty() {
        out.push("an empty tree".to_string());
    }
    for p in &places {
        if p.bundle && !(p.path.ends_with('/') && plain(&p.path[..p.path.len() - 1])) {
            out.push(format!("bundle path `{}` must be a plain relative path ending in /", p.path));
        }
        if !p.bundle && !plain(&p.path) {
            out.push(format!("file path `{}` must be a plain relative path", p.path));
        }
    }
    let mut paths: Vec<&str> = places.iter().map(|p| p.path.as_str()).collect();
    paths.sort();
    for (i, p) in paths.iter().enumerate() {
        if i > 0 && paths[i - 1] == *p {
            out.push(format!("`{}` given twice", p));
        }
        let dir = if p.ends_with('/') { p.to_string() } else { format!("{}/", p) };
        for q in &paths {
            if q != p && q.starts_with(&dir) {
                out.push(format!("`{}` is inside `{}`", q, p));
            }
        }
    }
    if out.is_empty() {
        Ok(Plan(places))
    } else {
        Err(out)
    }
}

fn mode_for(src: &fs::Metadata) -> u32 {
    if src.permissions().mode() & 0o111 != 0 {
        0o755
    } else {
        0o644
    }
}

fn chmod(p: &Path, mode: u32) -> Result<(), String> {
    fs::set_permissions(p, fs::Permissions::from_mode(mode)).map_err(|e| format!("cannot chmod {}: {}", p.display(), e))
}

fn mkdir(p: &Path) -> Result<(), String> {
    fs::create_dir(p).map_err(|e| format!("cannot create {}: {}", p.display(), e))?;
    chmod(p, 0o755)
}

/// `dir` under `out`, each missing part made with mode 0755.
fn mkdirs(out: &Path, dir: &str) -> Result<(), String> {
    let mut at = out.to_path_buf();
    for c in dir.split('/').filter(|c| !c.is_empty()) {
        at.push(c);
        match fs::symlink_metadata(&at) {
            Ok(m) if m.is_dir() => {}
            Ok(_) => return Err(format!("{}: not a directory", at.display())),
            Err(_) => mkdir(&at)?,
        }
    }
    Ok(())
}

fn copy_file(src: &Path, dest: &Path) -> Result<(), String> {
    let m = fs::metadata(src).map_err(|e| format!("cannot read {}: {}", src.display(), e))?;
    if !m.is_file() {
        return Err(format!("{}: not a regular file", src.display()));
    }
    if fs::symlink_metadata(dest).is_ok() {
        return Err(format!("{}: already in the tree", dest.display()));
    }
    fs::copy(src, dest).map_err(|e| format!("cannot copy {} to {}: {}", src.display(), dest.display(), e))?;
    chmod(dest, mode_for(&m))
}

/// Whether it copied any file.
fn copy_dir(src: &Path, dest: &Path) -> Result<bool, String> {
    mkdir(dest)?;
    let mut names: Vec<_> = fs::read_dir(src).map_err(|e| format!("cannot read {}: {}", src.display(), e))?.map(|e| e.map(|e| e.file_name())).collect::<Result<_, _>>().map_err(|e| format!("cannot read {}: {}", src.display(), e))?;
    names.sort();
    let mut any = false;
    for n in names {
        let (s, d) = (src.join(&n), dest.join(&n));
        let m = fs::symlink_metadata(&s).map_err(|e| format!("cannot read {}: {}", s.display(), e))?;
        if m.is_dir() {
            any |= copy_dir(&s, &d)?;
        } else if m.is_file() {
            copy_file(&s, &d)?;
            any = true;
        } else {
            return Err(format!("{}: not a regular file or directory", s.display()));
        }
    }
    Ok(any)
}

/// Lays the plan's places under `out`, a directory not yet there.
pub fn lay(out: &Path, plan: &Plan) -> Result<(), String> {
    mkdir(out)?;
    for p in &plan.0 {
        let rel = p.path.trim_end_matches('/');
        mkdirs(out, rel.rsplit_once('/').map_or("", |(d, _)| d))?;
        let dest = out.join(rel);
        if p.bundle {
            if !copy_dir(Path::new(&p.src), &dest)? {
                return Err(format!("bundle {} holds no files", p.src));
            }
        } else {
            copy_file(Path::new(&p.src), &dest)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn places(bundles: &[&str], files: &[&str]) -> Vec<Place> {
        let mk = |p: &&str, bundle| Place { path: p.to_string(), src: format!("src-of-{}", p), bundle };
        bundles.iter().map(|p| mk(p, true)).chain(files.iter().map(|p| mk(p, false))).collect()
    }

    fn refusals(bundles: &[&str], files: &[&str]) -> Vec<String> {
        match plan(places(bundles, files)) {
            Ok(p) => {
                // An accepted plan holds the places as given.
                assert_eq!(p.0, places(bundles, files));
                Vec::new()
            }
            Err(e) => e,
        }
    }

    #[test]
    fn the_base_images_tree_is_accepted() {
        assert_eq!(refusals(&["komira/", "opt/kci/"], &["bin/sh"]), Vec::<String>::new());
        assert_eq!(refusals(&["komira/", "komira2/"], &["bin/sh", "bin/sh2", "bin/s"]), Vec::<String>::new());
        assert_eq!(refusals(&[], &["etc/.wh.ssl", "etc/ssl/certs/.wh..wh..opq"]), Vec::<String>::new());
    }

    #[test]
    fn a_path_inside_another_is_refused() {
        assert_eq!(refusals(&["komira/"], &["komira/bin/supervisor"]), ["`komira/bin/supervisor` is inside `komira/`"]);
        assert_eq!(refusals(&["opt/", "opt/kci/"], &[]), ["`opt/kci/` is inside `opt/`"]);
        assert_eq!(refusals(&[], &["a", "a/b"]), ["`a/b` is inside `a`"]);
        assert_eq!(refusals(&["bin/"], &["bin"]), ["`bin/` is inside `bin`"]);
        assert_eq!(refusals(&[], &["a", "a"]), ["`a` given twice"]);
    }

    #[test]
    fn plain_is_letters_digits_and_four_marks() {
        assert_eq!(refusals(&["A_b+c-d.9/"], &["x/A_b+c-d.9"]), Vec::<String>::new());
        for bad in ["a:b", "a*b", "a\\b", "a b", "\u{e9}", "a=b"] {
            assert_eq!(refusals(&[], &[bad]), [format!("file path `{}` must be a plain relative path", bad)]);
        }
    }

    /// A directory of its own under this run's TMPDIR.
    fn scratch(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("tree_{}_{}", name, std::process::id()));
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn at(p: &str, src: &Path, bundle: bool) -> Place {
        Place { path: p.into(), src: src.to_str().unwrap().into(), bundle }
    }

    fn mode(p: &Path) -> u32 {
        fs::symlink_metadata(p).unwrap().permissions().mode() & 0o7777
    }

    #[test]
    fn lay_copies_with_plain_modes() {
        let d = scratch("lay");
        let src = d.join("src");
        fs::create_dir_all(src.join("b/sub")).unwrap();
        for (f, m) in [("exe", 0o700), ("ro", 0o400), ("b/sub/f", 0o600), ("b/g", 0o610), ("b/o", 0o601)] {
            fs::write(src.join(f), f).unwrap();
            fs::set_permissions(src.join(f), fs::Permissions::from_mode(m)).unwrap();
        }
        let p = plan(vec![at("bin/exe", &src.join("exe"), false), at("bin/ro", &src.join("ro"), false), at("opt/b/", &src.join("b"), true)]).unwrap();
        let out = d.join("out");
        lay(&out, &p).unwrap();
        for (f, m) in [("", 0o755), ("bin", 0o755), ("bin/exe", 0o755), ("bin/ro", 0o644), ("opt", 0o755), ("opt/b", 0o755), ("opt/b/sub", 0o755), ("opt/b/sub/f", 0o644), ("opt/b/g", 0o755), ("opt/b/o", 0o755)] {
            assert_eq!(mode(&out.join(f)), m, "{}", f);
        }
        assert_eq!(fs::read(out.join("opt/b/sub/f")).unwrap(), b"b/sub/f");
        assert!(lay(&out, &p).unwrap_err().starts_with(&format!("cannot create {}: ", out.display())));
        // A bundle whose one file is in its first directory, an empty one
        // after it: it holds a file all the same.
        let src = d.join("nested");
        fs::create_dir_all(src.join("a")).unwrap();
        fs::create_dir_all(src.join("b")).unwrap();
        fs::write(src.join("a/f"), b"f").unwrap();
        lay(&d.join("out2"), &plan(vec![at("n/", &src, true)]).unwrap()).unwrap();
        assert_eq!(fs::read(d.join("out2/n/a/f")).unwrap(), b"f");
    }

    #[test]
    fn lay_refuses_what_it_cannot_copy() {
        let d = scratch("refuse");
        fs::create_dir_all(d.join("empty/sub")).unwrap();
        fs::create_dir(d.join("linky")).unwrap();
        std::os::unix::fs::symlink("x", d.join("linky/l")).unwrap();
        let laid = |name: &str, place: Place| lay(&d.join(name), &plan(vec![place]).unwrap());
        assert_eq!(laid("o1", at("e/", &d.join("empty"), true)), Err(format!("bundle {} holds no files", d.join("empty").display())));
        assert_eq!(laid("o2", at("l/", &d.join("linky"), true)), Err(format!("{}: not a regular file or directory", d.join("linky/l").display())));
        assert_eq!(laid("o3", at("f", &d.join("empty"), false)), Err(format!("{}: not a regular file", d.join("empty").display())));
        assert!(laid("o4", at("f", &d.join("missing"), false)).unwrap_err().starts_with(&format!("cannot read {}: ", d.join("missing").display())));
        // What a plan never asks for: a file over one already laid, a
        // directory through a file.
        fs::write(d.join("x"), b"x").unwrap();
        assert_eq!(copy_file(&d.join("x"), &d.join("x")), Err(format!("{}: already in the tree", d.join("x").display())));
        assert_eq!(mkdirs(&d, "x/y"), Err(format!("{}: not a directory", d.join("x").display())));
        assert_eq!(mkdirs(&d, "empty/sub/new"), Ok(()));
        assert_eq!(mode(&d.join("empty/sub/new")), 0o755);
        // Names are read in sorted order, so of many it cannot copy the
        // first by name is the one named.
        fs::create_dir(d.join("links")).unwrap();
        for i in (0..50).rev() {
            std::os::unix::fs::symlink("x", d.join(format!("links/{:02}", i))).unwrap();
        }
        assert_eq!(laid("o5", at("k/", &d.join("links"), true)), Err(format!("{}: not a regular file or directory", d.join("links/00").display())));
    }

    #[test]
    fn a_path_that_is_not_plain_is_refused() {
        assert_eq!(refusals(&["komira"], &[]), ["bundle path `komira` must be a plain relative path ending in /"]);
        assert_eq!(refusals(&[], &["/bin/sh"]), ["file path `/bin/sh` must be a plain relative path"]);
        assert_eq!(refusals(&["a/../b/"], &["c/../d"]), ["bundle path `a/../b/` must be a plain relative path ending in /", "file path `c/../d` must be a plain relative path"]);
        assert_eq!(refusals(&[], &["./bin/sh"]), ["file path `./bin/sh` must be a plain relative path"]);
        assert_eq!(refusals(&[], &["bin/"]), ["file path `bin/` must be a plain relative path"]);
        assert_eq!(refusals(&["/"], &["a b"]), ["bundle path `/` must be a plain relative path ending in /", "file path `a b` must be a plain relative path"]);
        assert_eq!(refusals(&[], &[]), ["an empty tree"]);
    }
}
