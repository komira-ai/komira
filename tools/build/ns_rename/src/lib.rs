//! `ns-rename`: renames komira's `komira_*` packages from the mapping of mopm's design of owner
//! namespaces (section 12.3). Each `src/komira_<x>` directory moves to `src/<new name>`; every
//! whole word that is an old name, or derived from one (`test_<old>`, `<old>_conda` and the other
//! derived target names of `map::DERIVED_SUFFIXES`), in every listed text file and path
//! (`--files`, the checkout's tracked files), becomes the new name or its derived form (imports,
//! BUCK targets and paths, docs); a test file named after its package's new name moves to
//! `tests/test_<new>.mojo`; each `mopm.toml` gets `name = "komira-ai/<new name>"` and quoted
//! `"komira-ai/<new name>"` dependency keys. Everything is read and checked before anything is
//! written; `--dry-run` prints the summary and writes nothing. See README.md.

pub mod error;
pub mod manifest;
pub mod map;
pub mod names;
pub mod report;
pub(crate) mod rows;
pub mod tree;
pub mod words;

#[cfg(test)]
mod scenario_tests;

use error::Error;
use map::Mapping;
use std::ffi::OsStr;
use std::fs;
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

/// The usage line.
pub const USAGE: &str =
    "usage: ns-rename --repo <checkout> --map <mapping.tsv> --files <list> [--dry-run]";

/// The parsed command line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Args {
    pub repo: PathBuf,
    pub map: PathBuf,
    /// The checkout's tracked files, NUL-separated and relative to it (`git ls-files -z`).
    pub files: PathBuf,
    pub dry_run: bool,
}

fn usage(problem: &str) -> Error {
    Error::Usage(format!("{problem}\n{USAGE}"))
}

/// Reads the command line (without the program name).
pub fn parse_args(args: &[String]) -> Result<Args, Error> {
    let mut repo = None;
    let mut map = None;
    let mut files = None;
    let mut dry_run = false;
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--repo" | "--map" | "--files" => {
                let value = it
                    .next()
                    .ok_or_else(|| usage(&format!("{arg} needs a value")))?;
                let slot = match arg.as_str() {
                    "--repo" => &mut repo,
                    "--map" => &mut map,
                    _ => &mut files,
                };
                if slot.replace(PathBuf::from(value)).is_some() {
                    return Err(usage(&format!("{arg} is given twice")));
                }
            }
            "--dry-run" => dry_run = true,
            other => return Err(usage(&format!("unknown argument '{other}'"))),
        }
    }
    Ok(Args {
        repo: repo.ok_or_else(|| usage("--repo is required"))?,
        map: map.ok_or_else(|| usage("--map is required"))?,
        files: files.ok_or_else(|| usage("--files is required"))?,
        dry_run,
    })
}

fn canonical(path: &Path) -> Result<PathBuf, Error> {
    fs::canonicalize(path).map_err(|source| Error::Io {
        path: path.to_path_buf(),
        source,
    })
}

/// Runs the rename and returns the summary.
pub fn rename(args: &Args) -> Result<String, Error> {
    let repo = canonical(&args.repo)?;
    let map_path = canonical(&args.map)?;
    let text = fs::read_to_string(&map_path).map_err(|source| Error::Io {
        path: args.map.clone(),
        source,
    })?;
    let mapping = Mapping::parse(&text).map_err(|source| Error::Map {
        path: args.map.clone(),
        source,
    })?;
    let list = fs::read(&args.files).map_err(|source| Error::Io {
        path: args.files.clone(),
        source,
    })?;
    let listed: Vec<PathBuf> = list
        .split(|b| *b == 0)
        .filter(|entry| !entry.is_empty())
        .map(|entry| PathBuf::from(OsStr::from_bytes(entry)))
        .collect();
    let plan = tree::plan(&repo, &mapping, Some(&map_path), &listed)?;
    if !args.dry_run {
        tree::apply(&repo, &plan)?;
    }
    Ok(report::summary(&plan, args.dry_run))
}

/// The whole program: reads `args`, writes the summary to `out` or the refusal to `err`, and
/// returns the exit code (0, 1 for a refusal or failure, 2 for a usage error).
pub fn run(args: &[String], out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    match parse_args(args).and_then(|a| rename(&a)) {
        Ok(summary) => match out.write_all(summary.as_bytes()) {
            Ok(()) => 0,
            Err(e) => {
                let _ = writeln!(err, "ns-rename: writing the summary: {e}");
                1
            }
        },
        Err(e) => {
            let _ = writeln!(err, "ns-rename: {e}");
            e.exit_code()
        }
    }
}
