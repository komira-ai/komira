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

fn copy_dir(src: &Path, dest: &Path) -> Result<usize, String> {
    mkdir(dest)?;
    let mut names: Vec<_> = fs::read_dir(src).map_err(|e| format!("cannot read {}: {}", src.display(), e))?.map(|e| e.map(|e| e.file_name())).collect::<Result<_, _>>().map_err(|e| format!("cannot read {}: {}", src.display(), e))?;
    names.sort();
    let mut files = 0;
    for n in names {
        let (s, d) = (src.join(&n), dest.join(&n));
        let m = fs::symlink_metadata(&s).map_err(|e| format!("cannot read {}: {}", s.display(), e))?;
        if m.is_dir() {
            files += copy_dir(&s, &d)?;
        } else if m.is_file() {
            copy_file(&s, &d)?;
            files += 1;
        } else {
            return Err(format!("{}: not a regular file or directory", s.display()));
        }
    }
    Ok(files)
}

/// Lays the plan's places under `out`, a directory not yet there.
pub fn lay(out: &Path, plan: &Plan) -> Result<(), String> {
    mkdir(out)?;
    for p in &plan.0 {
        let rel = p.path.trim_end_matches('/');
        mkdirs(out, rel.rsplit_once('/').map_or("", |(d, _)| d))?;
        let dest = out.join(rel);
        if p.bundle {
            if copy_dir(Path::new(&p.src), &dest)? == 0 {
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
