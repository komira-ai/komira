//! Why the tool stops. Each refusal names the file, package or path it is about.

use crate::map::MapError;
use std::fmt;
use std::io;
use std::path::PathBuf;

/// A refusal or a failure of the rename.
#[derive(Debug)]
pub enum Error {
    /// The command line is wrong; the text says how.
    Usage(String),
    /// The mapping file fails a check.
    Map { path: PathBuf, source: MapError },
    /// Reading or writing a path failed.
    Io { path: PathBuf, source: io::Error },
    /// An entry of the file list is not a relative path of normal components.
    ListEntry(PathBuf),
    /// A mapped old name has no `src/` directory.
    MissingPackage(String),
    /// A `src/komira_*` directory has no line in the mapping.
    UnmappedPackage(String),
    /// A new name is already a `src/` directory.
    NewNameTaken { old: String, new: String },
    /// Two files would move to one path.
    SameTarget {
        first: PathBuf,
        second: PathBuf,
        target: PathBuf,
    },
    /// A file would move onto a path that already exists.
    TargetExists { from: PathBuf, target: PathBuf },
}

impl Error {
    /// The process exit code: 2 for a usage error, 1 for every other refusal or failure.
    pub fn exit_code(&self) -> i32 {
        match self {
            Error::Usage(_) => 2,
            _ => 1,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Usage(text) => f.write_str(text),
            Error::Map { path, source } => write!(f, "{}: {source}", path.display()),
            Error::Io { path, source } => write!(f, "{}: {source}", path.display()),
            Error::ListEntry(path) => write!(
                f,
                "file list entry '{}' is not a relative path inside the checkout",
                path.display()
            ),
            Error::MissingPackage(old) => {
                write!(
                    f,
                    "the mapping names {old}, but src/{old} is not a directory"
                )
            }
            Error::UnmappedPackage(old) => {
                write!(f, "src/{old} is a directory the mapping does not name")
            }
            Error::NewNameTaken { old, new } => write!(
                f,
                "the mapping renames {old} to {new}, but src/{new} already exists"
            ),
            Error::SameTarget {
                first,
                second,
                target,
            } => write!(
                f,
                "{} and {} would both move to {}",
                first.display(),
                second.display(),
                target.display()
            ),
            Error::TargetExists { from, target } => write!(
                f,
                "{} would move to {}, which already exists",
                from.display(),
                target.display()
            ),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Map { source, .. } => Some(source),
            Error::Io { source, .. } => Some(source),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::error::Error as _;

    #[test]
    fn exit_code_is_2_for_usage_and_1_otherwise() {
        assert_eq!(Error::Usage("x".into()).exit_code(), 2);
        assert_eq!(Error::MissingPackage("komira_a".into()).exit_code(), 1);
    }

    #[test]
    fn each_refusal_names_what_it_is_about() {
        let cases: Vec<(Error, &str)> = vec![
            (Error::Usage("bad flag".into()), "bad flag"),
            (
                Error::Map {
                    path: "m.tsv".into(),
                    source: MapError::Empty,
                },
                "m.tsv: the mapping has no line",
            ),
            (
                Error::Io {
                    path: "a/b".into(),
                    source: io::Error::new(io::ErrorKind::NotFound, "gone"),
                },
                "a/b: gone",
            ),
            (
                Error::ListEntry("../x".into()),
                "file list entry '../x' is not a relative path inside the checkout",
            ),
            (
                Error::MissingPackage("komira_a".into()),
                "the mapping names komira_a, but src/komira_a is not a directory",
            ),
            (
                Error::UnmappedPackage("komira_z".into()),
                "src/komira_z is a directory the mapping does not name",
            ),
            (
                Error::NewNameTaken {
                    old: "komira_a".into(),
                    new: "aa".into(),
                },
                "the mapping renames komira_a to aa, but src/aa already exists",
            ),
            (
                Error::SameTarget {
                    first: "x/komira_a".into(),
                    second: "komira_a/x".into(),
                    target: "aa/aa".into(),
                },
                "x/komira_a and komira_a/x would both move to aa/aa",
            ),
            (
                Error::TargetExists {
                    from: "komira_a.md".into(),
                    target: "aa.md".into(),
                },
                "komira_a.md would move to aa.md, which already exists",
            ),
        ];
        for (error, text) in cases {
            assert_eq!(error.to_string(), text);
        }
    }

    #[test]
    fn map_and_io_errors_keep_their_source() {
        let map = Error::Map {
            path: "m".into(),
            source: MapError::Empty,
        };
        assert_eq!(map.source().unwrap().to_string(), "the mapping has no line");
        let io = Error::Io {
            path: "p".into(),
            source: io::Error::other("boom"),
        };
        assert_eq!(io.source().unwrap().to_string(), "boom");
        assert!(Error::Usage("u".into()).source().is_none());
    }
}
