//! `ns-rename`: renames komira's `komira_*` packages from the mapping of mopm's design of owner
//! namespaces (section 12.3). Each `src/komira_<x>` directory moves to `src/<new name>`; every
//! whole word that is an old name, in every text file and every path, becomes the new name (imports,
//! BUCK targets and paths, docs); each `mopm.toml` gets `name = "komira-ai/<new name>"` and quoted
//! `"komira-ai/<new name>"` dependency keys. Everything is read and checked before anything is
//! written; `--dry-run` prints the summary and writes nothing. See README.md.

pub mod error;
pub mod manifest;
pub mod map;
pub mod names;
pub mod report;
pub mod tree;
pub mod words;

#[cfg(test)]
mod scenario_tests;

use error::Error;
use map::Mapping;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

/// The usage line.
pub const USAGE: &str = "usage: ns-rename --repo <checkout> --map <mapping.tsv> [--dry-run]";

/// The parsed command line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Args {
    pub repo: PathBuf,
    pub map: PathBuf,
    pub dry_run: bool,
}

fn usage(problem: &str) -> Error {
    Error::Usage(format!("{problem}\n{USAGE}"))
}

/// Reads the command line (without the program name).
pub fn parse_args(args: &[String]) -> Result<Args, Error> {
    let mut repo = None;
    let mut map = None;
    let mut dry_run = false;
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--repo" | "--map" => {
                let value = it
                    .next()
                    .ok_or_else(|| usage(&format!("{arg} needs a value")))?;
                let slot = if arg == "--repo" { &mut repo } else { &mut map };
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
    let plan = tree::plan(&repo, &mapping, Some(&map_path))?;
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
