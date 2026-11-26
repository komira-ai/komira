//! The mapping: one line `<old directory name><TAB><new import name>` per `komira_*` package, no
//! header, sorted by the old name as bytes (mopm's `docs/design/namespaces-komira-map.tsv`, a copy
//! of which is `namespaces-komira-map.tsv` beside this crate).

use crate::names::{grammar_ok, name_problem, NameProblem};
use std::collections::BTreeMap;
use std::fmt;

/// The prefix every old name has.
pub const OLD_PREFIX: &str = "komira_";

/// The suffixes komira's and buildrules' rules append to a target's name to name the targets
/// they derive from it (`name + "_conda"` in tools/build/mojo/defs.bzl, `_cov_gate` beside it,
/// `_gen` in tools/build/mojo/proto.bzl and tools/build/cloud, `_fresh` in tools/build/gen). A
/// word that is an old name with one of them is the derived target of the renamed one, so it is
/// renamed with it: `komira_json_conda` becomes `json_conda`.
pub(crate) const DERIVED_SUFFIXES: &[&str] = &["_conda", "_cov_gate", "_fresh", "_gen"];

/// The prefix of the test file of a package: `test_<name>.mojo` holds the tests of `<name>`
/// (`tests/test_komira_json.mojo` of the JSON conformance suite), so `test_<old>` becomes
/// `test_<new>`, and a test file named after the package's new name moves to it
/// (`tree::own_name_test`).
pub(crate) const TEST_PREFIX: &str = "test_";

/// A mapping that passed every check: old names to new import names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mapping {
    pairs: BTreeMap<String, String>,
    /// `pairs`, plus each old name's `test_` and derived-suffix words with their new forms.
    words: BTreeMap<String, String>,
}

/// Why a mapping is refused. `line` counts from 1.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MapError {
    /// The file has no line.
    Empty,
    /// The last line has no `\n`.
    NoFinalNewline,
    /// A line holds a carriage return.
    CarriageReturn { line: usize },
    /// A line does not have exactly two tab-separated fields.
    Fields { line: usize, found: usize },
    /// An old name is not `komira_` followed by the name grammar.
    OldName { line: usize, name: String },
    /// An old name is not after the previous line's, as bytes (unsorted or repeated).
    NotSorted {
        line: usize,
        name: String,
        previous: String,
    },
    /// A new name fails a check of the design's section 12.2.
    NewName {
        line: usize,
        name: String,
        problem: NameProblem,
    },
    /// A new name is also an old name: the rename would depend on the order it runs in.
    NewIsOld { line: usize, name: String },
    /// Two lines have the same new name.
    DuplicateNew {
        line: usize,
        name: String,
        first_line: usize,
    },
    /// A word derived from the old name of a line (`test_<old>`, `<old>_conda`, ...) is itself an
    /// old name, so it would be renamed two ways.
    DerivedIsOld { line: usize, word: String },
}

impl fmt::Display for MapError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MapError::Empty => write!(f, "the mapping has no line"),
            MapError::NoFinalNewline => write!(f, "the last line of the mapping has no newline"),
            MapError::CarriageReturn { line } => {
                write!(f, "line {line}: a carriage return; lines end with \\n only")
            }
            MapError::Fields { line, found } => write!(
                f,
                "line {line}: {found} tab-separated fields; a line is <old name><TAB><new name>"
            ),
            MapError::OldName { line, name } => write!(
                f,
                "line {line}: old name '{name}' is not {OLD_PREFIX} followed by a package name"
            ),
            MapError::NotSorted {
                line,
                name,
                previous,
            } => write!(
                f,
                "line {line}: old name '{name}' is not after '{previous}' as bytes; \
                 lines are sorted by the old name and each old name appears once"
            ),
            MapError::NewName {
                line,
                name,
                problem,
            } => write!(f, "line {line}: new name '{name}' {problem}"),
            MapError::NewIsOld { line, name } => {
                write!(f, "line {line}: new name '{name}' is also an old name")
            }
            MapError::DuplicateNew {
                line,
                name,
                first_line,
            } => write!(
                f,
                "line {line}: new name '{name}' is already the new name of line {first_line}"
            ),
            MapError::DerivedIsOld { line, word } => write!(
                f,
                "line {line}: '{word}', a word derived from its old name, is also an old name"
            ),
        }
    }
}

impl std::error::Error for MapError {}

impl Mapping {
    /// Reads and checks a mapping.
    pub fn parse(text: &str) -> Result<Mapping, MapError> {
        if text.is_empty() {
            return Err(MapError::Empty);
        }
        let Some(body) = text.strip_suffix('\n') else {
            return Err(MapError::NoFinalNewline);
        };
        let mut pairs = BTreeMap::new();
        let mut new_lines: BTreeMap<&str, usize> = BTreeMap::new();
        let mut previous: Option<&str> = None;
        for (index, row) in body.split('\n').enumerate() {
            let line = index + 1;
            if row.contains('\r') {
                return Err(MapError::CarriageReturn { line });
            }
            let fields: Vec<&str> = row.split('\t').collect();
            let [old, new] = fields[..] else {
                return Err(MapError::Fields {
                    line,
                    found: fields.len(),
                });
            };
            if !old
                .strip_prefix(OLD_PREFIX)
                .is_some_and(|rest| !rest.is_empty())
                || !grammar_ok(old)
            {
                return Err(MapError::OldName {
                    line,
                    name: old.to_string(),
                });
            }
            if let Some(prev) = previous {
                if old.as_bytes() <= prev.as_bytes() {
                    return Err(MapError::NotSorted {
                        line,
                        name: old.to_string(),
                        previous: prev.to_string(),
                    });
                }
            }
            previous = Some(old);
            if let Some(problem) = name_problem(new) {
                return Err(MapError::NewName {
                    line,
                    name: new.to_string(),
                    problem,
                });
            }
            if let Some(first_line) = new_lines.insert(new, line) {
                return Err(MapError::DuplicateNew {
                    line,
                    name: new.to_string(),
                    first_line,
                });
            }
            pairs.insert(old.to_string(), new.to_string());
        }
        if let Some((new, line)) = new_lines.iter().find(|(new, _)| pairs.contains_key(**new)) {
            return Err(MapError::NewIsOld {
                line: *line,
                name: new.to_string(),
            });
        }
        let mut words = pairs.clone();
        for (line, (old, new)) in pairs.iter().enumerate() {
            let derived =
                std::iter::once((format!("{TEST_PREFIX}{old}"), format!("{TEST_PREFIX}{new}")))
                    .chain(
                        DERIVED_SUFFIXES
                            .iter()
                            .map(|suffix| (format!("{old}{suffix}"), format!("{new}{suffix}"))),
                    );
            for (word, renamed) in derived {
                if pairs.contains_key(&word) {
                    // Lines are sorted by the old name, so the index is the line less one.
                    return Err(MapError::DerivedIsOld {
                        line: line + 1,
                        word,
                    });
                }
                words.insert(word, renamed);
            }
        }
        Ok(Mapping { pairs, words })
    }

    /// Old name to new name, sorted by the old name.
    pub fn pairs(&self) -> &BTreeMap<String, String> {
        &self.pairs
    }

    /// The new name of `old`, if `old` is mapped.
    pub fn new_name(&self, old: &str) -> Option<&str> {
        self.pairs.get(old).map(String::as_str)
    }

    /// Every word the rename replaces, with its replacement: each old name, its `test_<old>`
    /// and each `<old><suffix>` of [`DERIVED_SUFFIXES`].
    pub(crate) fn words(&self) -> &BTreeMap<String, String> {
        &self.words
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_checked_in_mapping_passes_with_260_lines() {
        let mapping = Mapping::parse(include_str!("../namespaces-komira-map.tsv")).unwrap();
        assert_eq!(mapping.pairs().len(), 260);
        assert_eq!(mapping.new_name("komira_json"), Some("json"));
        assert_eq!(mapping.new_name("komira_collections"), Some("containers"));
        assert_eq!(mapping.new_name("komira_hash"), Some("hashing"));
        assert_eq!(mapping.new_name("komira_buffer"), Some("byte_buffer"));
        assert_eq!(mapping.new_name("komira_async"), Some("async_rt"));
        assert_eq!(mapping.new_name("kci_api"), None);
    }

    #[test]
    fn reads_a_small_mapping() {
        let mapping = Mapping::parse("komira_a\taa\nkomira_b\tbb\n").unwrap();
        let pairs: Vec<(&str, &str)> = mapping
            .pairs()
            .iter()
            .map(|(a, b)| (a.as_str(), b.as_str()))
            .collect();
        assert_eq!(pairs, [("komira_a", "aa"), ("komira_b", "bb")]);
    }

    fn refused(text: &str) -> String {
        Mapping::parse(text).unwrap_err().to_string()
    }

    #[test]
    fn refuses_an_empty_file_and_a_missing_final_newline() {
        assert_eq!(refused(""), "the mapping has no line");
        assert_eq!(
            refused("komira_a\taa"),
            "the last line of the mapping has no newline"
        );
    }

    #[test]
    fn refuses_a_carriage_return() {
        assert_eq!(
            refused("komira_a\taa\r\n"),
            "line 1: a carriage return; lines end with \\n only"
        );
    }

    #[test]
    fn refuses_a_line_without_two_fields() {
        let expected = |n: usize, line: usize| {
            format!("line {line}: {n} tab-separated fields; a line is <old name><TAB><new name>")
        };
        assert_eq!(refused("komira_a\taa\n\n"), expected(1, 2));
        assert_eq!(refused("komira_a aa\n"), expected(1, 1));
        assert_eq!(refused("komira_a\taa\tx\n"), expected(3, 1));
    }

    #[test]
    fn refuses_an_old_name_outside_the_prefix_or_the_grammar() {
        for old in ["kci_api", "komira_", "komira_A", "json", "komira-json"] {
            assert_eq!(
                refused(&format!("{old}\taa\n")),
                format!("line 1: old name '{old}' is not komira_ followed by a package name")
            );
        }
    }

    #[test]
    fn refuses_unsorted_and_repeated_old_names() {
        assert_eq!(
            refused("komira_b\tbb\nkomira_a\taa\n"),
            "line 2: old name 'komira_a' is not after 'komira_b' as bytes; \
             lines are sorted by the old name and each old name appears once"
        );
        assert_eq!(
            refused("komira_a\taa\nkomira_a\tbb\n"),
            "line 2: old name 'komira_a' is not after 'komira_a' as bytes; \
             lines are sorted by the old name and each old name appears once"
        );
    }

    #[test]
    fn refuses_each_kind_of_bad_new_name() {
        let cases = [
            ("Json", "is not a package name (^[a-z][a-z0-9_]{1,63}$)"),
            ("", "is not a package name (^[a-z][a-z0-9_]{1,63}$)"),
            ("async", "is a Mojo keyword"),
            ("match", "is a Mojo keyword"),
            ("hash", "is a Mojo builtin"),
            ("std", "is reserved by mopm"),
            ("collections", "is a name in the Mojo standard library"),
            ("host", "is a name in the Mojo standard library"),
        ];
        for (new, problem) in cases {
            assert_eq!(
                refused(&format!("komira_a\taa\nkomira_b\t{new}\n")),
                format!("line 2: new name '{new}' {problem}")
            );
        }
    }

    #[test]
    fn refuses_a_new_name_used_twice() {
        assert_eq!(
            refused("komira_a\tsame\nkomira_b\tother\nkomira_c\tsame\n"),
            "line 3: new name 'same' is already the new name of line 1"
        );
    }

    #[test]
    fn refuses_a_new_name_that_is_an_old_name() {
        assert_eq!(
            refused("komira_a\tkomira_b\nkomira_b\tbb\n"),
            "line 1: new name 'komira_b' is also an old name"
        );
    }

    #[test]
    fn words_add_the_test_file_and_derived_target_forms_of_each_name() {
        let mapping = Mapping::parse("komira_a\taa\n").unwrap();
        let words: Vec<(&str, &str)> = mapping
            .words()
            .iter()
            .map(|(a, b)| (a.as_str(), b.as_str()))
            .collect();
        assert_eq!(
            words,
            [
                ("komira_a", "aa"),
                ("komira_a_conda", "aa_conda"),
                ("komira_a_cov_gate", "aa_cov_gate"),
                ("komira_a_fresh", "aa_fresh"),
                ("komira_a_gen", "aa_gen"),
                ("test_komira_a", "test_aa"),
            ]
        );
    }

    #[test]
    fn refuses_a_derived_word_that_is_an_old_name() {
        assert_eq!(
            refused("komira_a\taa\nkomira_a_gen\tbb\n"),
            "line 1: 'komira_a_gen', a word derived from its old name, is also an old name"
        );
        assert_eq!(
            refused("komira_a\taa\nkomira_b\tbb\nkomira_b_conda\tcc\n"),
            "line 2: 'komira_b_conda', a word derived from its old name, is also an old name"
        );
    }

    #[test]
    fn the_checked_in_mapping_derives_no_old_name() {
        let mapping = Mapping::parse(include_str!("../namespaces-komira-map.tsv")).unwrap();
        assert_eq!(mapping.words().len(), 260 * 6);
        assert_eq!(
            mapping.words().get("komira_hash_conda").map(String::as_str),
            Some("hashing_conda")
        );
        assert_eq!(
            mapping.words().get("test_komira_json").map(String::as_str),
            Some("test_json")
        );
    }
}
