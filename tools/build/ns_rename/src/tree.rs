//! The rename of a checkout: every file read, every change computed and checked before anything
//! is written (`plan`), then written (`apply`).

use crate::error::Error;
use crate::manifest::rewrite_manifest;
use crate::map::{Mapping, OLD_PREFIX, TEST_PREFIX};
use crate::words::{changed_lines, contains_word, replace_words};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};

/// Repository paths kept as they are: this tool, whose sources and tests hold the old names on
/// purpose, and with it the copy of the mapping.
pub const KEPT: &[&str] = &["tools/build/ns_rename"];

/// The kind of a rewritten file, for the summary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Kind {
    /// A `.mojo` source.
    Mojo,
    /// A `BUCK` file or a `.bzl` file.
    Build,
    /// A `mopm.toml`.
    Manifest,
    /// Any other text file.
    Other,
}

impl Kind {
    fn of(path: &Path) -> Kind {
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if name.ends_with(".mojo") {
            Kind::Mojo
        } else if name == "BUCK" || name.ends_with(".bzl") {
            Kind::Build
        } else if name == "mopm.toml" {
            Kind::Manifest
        } else {
            Kind::Other
        }
    }

    /// The label the summary prints.
    pub fn label(self) -> &'static str {
        match self {
            Kind::Mojo => ".mojo",
            Kind::Build => "BUCK and .bzl",
            Kind::Manifest => "mopm.toml",
            Kind::Other => "other",
        }
    }
}

/// One file whose text changes. Paths are relative to the repository, before any move.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rewrite {
    pub path: PathBuf,
    pub kind: Kind,
    pub text: String,
    /// Lines that differ.
    pub lines: usize,
    /// Of those, lines of a `.mojo` file that start with `from ` or `import ` once indented.
    pub import_lines: usize,
}

/// Everything the rename does, computed without writing.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Plan {
    /// The `src/` directories renamed: old name, new name.
    pub packages: Vec<(String, String)>,
    /// Files moved, from and to, relative to the repository.
    pub moves: Vec<(PathBuf, PathBuf)>,
    /// Files whose text changes.
    pub rewrites: Vec<Rewrite>,
    /// `[package] name` values set to a full name.
    pub manifest_names: usize,
    /// Dependency keys set to a full name.
    pub manifest_keys: usize,
    /// Files that are not UTF-8 and hold an old name as a whole word: left unchanged.
    pub binary: Vec<PathBuf>,
    /// Listed entries that are not regular files (symbolic links, submodules): left unchanged.
    pub not_files: Vec<PathBuf>,
    /// Test files named after their package's new name (`src/<old>/tests/<new>.mojo`), moved to
    /// `tests/test_<new>.mojo`, from and to: buildrules' `mojo_package` names the test target of
    /// a file by its stem, which would be the package's own target name.
    pub own_name_tests: Vec<(PathBuf, PathBuf)>,
    /// `.mojo` files that change, bind a package's module name (`import komira_x`) and already use
    /// its new name as a word before the rename, with those names: the places a renamed module
    /// name could meet a local name.
    pub shadow: Vec<(PathBuf, Vec<String>)>,
}

fn io_error(path: &Path) -> impl FnOnce(io::Error) -> Error + '_ {
    move |source| Error::Io {
        path: path.to_path_buf(),
        source,
    }
}

/// The relative path with every word of [`Mapping::words`] replaced in each component.
fn moved_path(rel: &Path, mapping: &Mapping) -> Option<PathBuf> {
    let text = rel.to_str()?;
    replace_words(text, mapping.words()).map(PathBuf::from)
}

/// Where a test file named after its package's new name moves: `src/<old>/tests/<new>.mojo`
/// to `src/<new>/tests/test_<new>.mojo`. buildrules' `mojo_package` declares a target per test
/// file named by its stem, so the file's target and the package's own `<new>` target would be one
/// name (`src/komira_test_run_id/tests/test_run_id.mojo`). Only a file directly under `tests/`.
pub fn own_name_test(rel: &Path, mapping: &Mapping) -> Option<PathBuf> {
    let parts: Vec<&str> = rel
        .components()
        .map(|c| c.as_os_str().to_str())
        .collect::<Option<_>>()?;
    let ["src", old, "tests", file] = parts[..] else {
        return None;
    };
    let new = mapping.new_name(old)?;
    (file.strip_suffix(".mojo") == Some(new))
        .then(|| PathBuf::from(format!("src/{new}/tests/{TEST_PREFIX}{new}.mojo")))
}

/// The listed paths sorted into files and other entries (symbolic links, directories such as a
/// submodule), minus the kept ones and `skip_file`. Each must be a relative path of normal
/// components that exists in `repo`.
fn classify(
    repo: &Path,
    listed: &[PathBuf],
    skip_file: Option<&Path>,
) -> Result<(Vec<PathBuf>, Vec<PathBuf>), Error> {
    let mut files = Vec::new();
    let mut others = Vec::new();
    for rel in listed {
        let normal = rel.components().count() > 0
            && rel.components().all(|c| matches!(c, Component::Normal(_)));
        if !normal {
            return Err(Error::ListEntry(rel.clone()));
        }
        if KEPT.iter().any(|k| rel.starts_with(k)) || Some(rel.as_path()) == skip_file {
            continue;
        }
        let full = repo.join(rel);
        if full.symlink_metadata().map_err(io_error(&full))?.is_file() {
            files.push(rel.clone());
        } else {
            others.push(rel.clone());
        }
    }
    files.sort();
    others.sort();
    Ok((files, others))
}

/// Checks that the mapping's old names are exactly the `src/komira_*` directories, and that no
/// new name is already a directory of `src/`.
fn check_tree(repo: &Path, mapping: &Mapping) -> Result<(), Error> {
    let src = repo.join("src");
    let mut present = BTreeSet::new();
    for entry in fs::read_dir(&src)
        .and_then(|it| it.collect::<Result<Vec<_>, _>>())
        .map_err(io_error(&src))?
    {
        let is_dir = entry
            .file_type()
            .map_err(io_error(&src.join(entry.file_name())))?
            .is_dir();
        if let (true, Some(name)) = (is_dir, entry.file_name().to_str()) {
            present.insert(name.to_string());
        }
    }
    for (old, new) in mapping.pairs() {
        if !present.contains(old) {
            return Err(Error::MissingPackage(old.clone()));
        }
        if present.contains(new) {
            return Err(Error::NewNameTaken {
                old: old.clone(),
                new: new.clone(),
            });
        }
    }
    if let Some(extra) = present
        .iter()
        .find(|name| name.starts_with(OLD_PREFIX) && mapping.new_name(name).is_none())
    {
        return Err(Error::UnmappedPackage(extra.clone()));
    }
    Ok(())
}

fn import_line(line: &str) -> bool {
    let rest = line.trim_start_matches([' ', '\t']);
    rest.starts_with("from ") || rest.starts_with("import ")
}

/// True when a line of `text` is `import <old>` or `import <old>.<module>` without `as` (alone or
/// in a comma-separated list): the statements that bind the package's own name, which after the
/// rename is the new name and can meet a local name. `from <old> import x` binds only `x`.
pub fn binds_module(text: &str, old: &str) -> bool {
    text.split('\n').any(|line| {
        let Some(items) = line.trim_start_matches([' ', '\t']).strip_prefix("import ") else {
            return false;
        };
        items.split(',').any(|item| {
            let mut tokens = item.split_whitespace();
            let module = tokens.next().unwrap_or("");
            tokens.next() != Some("as") && module.split('.').next() == Some(old)
        })
    })
}

fn rewrite_text(rel: &Path, text: &str, mapping: &Mapping, plan: &mut Plan) {
    let kind = Kind::of(rel);
    let new = if kind == Kind::Manifest {
        rewrite_manifest(text, mapping).map(|(new, stats)| {
            plan.manifest_names += stats.names;
            plan.manifest_keys += stats.keys;
            new
        })
    } else {
        replace_words(text, mapping.words())
    };
    let Some(new) = new else {
        return;
    };
    let mut import_lines = 0;
    if kind == Kind::Mojo {
        import_lines = text
            .split('\n')
            .zip(new.split('\n'))
            .filter(|(a, b)| a != b && import_line(a))
            .count();
        let shadowed: Vec<String> = mapping
            .pairs()
            .iter()
            .filter(|(old, new)| binds_module(text, old) && contains_word(text, new))
            .map(|(_, new)| new.clone())
            .collect();
        if !shadowed.is_empty() {
            plan.shadow.push((rel.to_path_buf(), shadowed));
        }
    }
    plan.rewrites.push(Rewrite {
        path: rel.to_path_buf(),
        kind,
        lines: changed_lines(text, &new),
        import_lines,
        text: new,
    });
}

/// True when `bytes` hold a word of [`Mapping::words`].
fn bytes_hold_old_name(bytes: &[u8], mapping: &Mapping) -> bool {
    bytes
        .split(|b| !crate::words::is_word_byte(*b))
        .any(|word| std::str::from_utf8(word).is_ok_and(|w| mapping.words().contains_key(w)))
}

/// Reads the `listed` paths of the checkout at `repo` (its tracked files, `git ls-files`) and
/// computes the rename, refusing a conflict before anything is written. `map_path` is left out
/// when it lies inside `repo`.
pub fn plan(
    repo: &Path,
    mapping: &Mapping,
    map_path: Option<&Path>,
    listed: &[PathBuf],
) -> Result<Plan, Error> {
    check_tree(repo, mapping)?;
    let skip_file = map_path.and_then(|p| p.strip_prefix(repo).ok());
    let (files, others) = classify(repo, listed, skip_file)?;
    let mut plan = Plan {
        packages: mapping
            .pairs()
            .iter()
            .map(|(a, b)| (a.clone(), b.clone()))
            .collect(),
        not_files: others,
        ..Plan::default()
    };
    let mut targets: BTreeMap<PathBuf, PathBuf> = BTreeMap::new();
    for rel in &files {
        let full = repo.join(rel);
        let bytes = fs::read(&full).map_err(io_error(&full))?;
        match std::str::from_utf8(&bytes) {
            Ok(text) => rewrite_text(rel, text, mapping, &mut plan),
            Err(_) if bytes_hold_old_name(&bytes, mapping) => plan.binary.push(rel.clone()),
            Err(_) => {}
        }
        let own = own_name_test(rel, mapping);
        if let Some(to) = own.clone().or_else(|| moved_path(rel, mapping)) {
            if let Some(first) = targets.insert(to.clone(), rel.clone()) {
                return Err(Error::SameTarget {
                    first,
                    second: rel.clone(),
                    target: to,
                });
            }
            // A target never holds an old name, so nothing already there is moved away.
            if repo.join(&to).symlink_metadata().is_ok() {
                return Err(Error::TargetExists {
                    from: rel.clone(),
                    target: to,
                });
            }
            if own.is_some() {
                plan.own_name_tests.push((rel.clone(), to.clone()));
            }
            plan.moves.push((rel.clone(), to));
        }
    }
    Ok(plan)
}

/// Writes the plan: every rewritten file in place, then every move, then the directories the
/// moves left empty are removed.
pub fn apply(repo: &Path, plan: &Plan) -> Result<(), Error> {
    for rewrite in &plan.rewrites {
        let full = repo.join(&rewrite.path);
        fs::write(&full, &rewrite.text).map_err(io_error(&full))?;
    }
    let mut left: BTreeSet<PathBuf> = BTreeSet::new();
    for (from, to) in &plan.moves {
        let target = repo.join(to);
        let parent = target.parent().unwrap_or(repo);
        fs::create_dir_all(parent).map_err(io_error(parent))?;
        let source = repo.join(from);
        fs::rename(&source, &target).map_err(io_error(&source))?;
        left.extend(from.ancestors().skip(1).map(Path::to_path_buf));
    }
    // Deepest first, so a parent is looked at after its children.
    let mut dirs: Vec<PathBuf> = left
        .into_iter()
        .filter(|d| !d.as_os_str().is_empty())
        .collect();
    dirs.sort_by_key(|d| std::cmp::Reverse(d.components().count()));
    for dir in dirs {
        let full = repo.join(&dir);
        match fs::remove_dir(&full) {
            Ok(()) => {}
            // A directory that still holds files (unrenamed ones, or kept ones) stays.
            Err(e) if e.kind() == io::ErrorKind::DirectoryNotEmpty => {}
            Err(source) => return Err(Error::Io { path: full, source }),
        }
    }
    Ok(())
}
