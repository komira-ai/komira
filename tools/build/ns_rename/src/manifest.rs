//! A `mopm.toml` rewritten to full names (mopm's design of owner namespaces, section 3): the
//! `[package] name` of a mapped package becomes `"komira-ai/<new>"`, and so does each key of
//! `[dependencies]` and `[dev-dependencies]` that is a mapped old name, quoted because it holds a
//! `/`. Every other word of the file is replaced as in any other file (`lib = { path =
//! "src/komira_json" }` becomes `src/json`).
//!
//! It reads the file line by line, as the manifests komira writes are laid out (one key per line,
//! no multi-line strings); a line it does not recognise is only word-replaced.

use crate::map::Mapping;
use crate::words::replace_words;

/// The namespace of every package of the mapping.
pub const NAMESPACE: &str = "komira-ai";

/// What a manifest rewrite changed.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ManifestStats {
    /// `[package] name` values set to a full name.
    pub names: usize,
    /// Dependency keys (or dependency table headers) set to a full name.
    pub keys: usize,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Section {
    Package,
    Dependencies,
    Other,
}

fn full_name(new: &str) -> String {
    format!("\"{NAMESPACE}/{new}\"")
}

/// Splits a TOML key at the start of `s`: a bare key (`[A-Za-z0-9_-]+`) or a basic quoted key with
/// no escape. Returns the key's text without quotes and the rest of `s`.
fn split_key(s: &str) -> Option<(&str, &str)> {
    if let Some(quoted) = s.strip_prefix('"') {
        let end = quoted.find('"')?;
        let key = &quoted[..end];
        if key.contains('\\') {
            return None;
        }
        return Some((key, &quoted[end + 1..]));
    }
    let end = s
        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '-'))
        .unwrap_or(s.len());
    if end == 0 {
        return None;
    }
    Some((&s[..end], &s[end..]))
}

fn indent_of(line: &str) -> (&str, &str) {
    let rest = line.trim_start_matches([' ', '\t']);
    (&line[..line.len() - rest.len()], rest)
}

/// A table header line: its section, and the header rewritten when it names a dependency by a
/// mapped old name (`[dependencies.komira_json]`).
fn header(rest: &str, mapping: &Mapping) -> Option<(Section, Option<String>)> {
    let inner = rest.strip_prefix('[')?;
    if inner.starts_with('[') {
        return Some((Section::Other, None));
    }
    let close = inner.find(']')?;
    let name = inner[..close].trim_matches([' ', '\t']);
    let after = &inner[close..];
    let section = match name {
        "package" => Section::Package,
        "dependencies" | "dev-dependencies" => Section::Dependencies,
        _ => Section::Other,
    };
    for table in ["dependencies.", "dev-dependencies."] {
        if let Some((key, tail)) = name.strip_prefix(table).and_then(split_key) {
            if tail.is_empty() {
                if let Some(new) = mapping.new_name(key) {
                    let rewritten = format!("[{table}{}{after}", full_name(new));
                    return Some((Section::Other, Some(rewritten)));
                }
            }
        }
    }
    Some((section, None))
}

/// `rest` (a line without its indent) with its key set to the full name when the key is a mapped
/// old name; the remainder of the line word-replaced.
fn rewrite_key(rest: &str, mapping: &Mapping) -> Option<String> {
    let (key, tail) = split_key(rest)?;
    let new = mapping.new_name(key)?;
    let tail = replace_words(tail, mapping.words()).unwrap_or_else(|| tail.to_string());
    Some(format!("{}{tail}", full_name(new)))
}

/// `rest` (a `[package]` line without its indent) with a `name = "<old>"` value set to the full
/// name.
fn rewrite_name(rest: &str, mapping: &Mapping) -> Option<String> {
    let (key, tail) = split_key(rest)?;
    if key != "name" {
        return None;
    }
    let (eq_pad, value) = tail.split_once('=')?;
    if !eq_pad.trim_matches([' ', '\t']).is_empty() {
        return None;
    }
    let (value_pad, quoted) = indent_of(value);
    let (old, after) = quoted.strip_prefix('"')?.split_once('"')?;
    let new = mapping.new_name(old)?;
    Some(format!(
        "{key}{eq_pad}={value_pad}{}{after}",
        full_name(new)
    ))
}

/// The manifest rewritten, or `None` when nothing in it changes.
pub fn rewrite_manifest(text: &str, mapping: &Mapping) -> Option<(String, ManifestStats)> {
    let mut stats = ManifestStats::default();
    let mut section = Section::Other;
    let mut out = String::with_capacity(text.len());
    for line in text.split_inclusive('\n') {
        let (body, eol) = match line.strip_suffix('\n') {
            Some(body) => (body, "\n"),
            None => (line, ""),
        };
        let (indent, rest) = indent_of(body);
        let mut special = None;
        if let Some((next, rewritten)) = header(rest, mapping) {
            section = next;
            if rewritten.is_some() {
                stats.keys += 1;
            }
            special = rewritten;
        } else if section == Section::Package {
            special = rewrite_name(rest, mapping);
            if special.is_some() {
                stats.names += 1;
            }
        } else if section == Section::Dependencies {
            special = rewrite_key(rest, mapping);
            if special.is_some() {
                stats.keys += 1;
            }
        }
        match special {
            Some(rest) => {
                out.push_str(indent);
                out.push_str(&rest);
            }
            None => match replace_words(body, mapping.words()) {
                Some(replaced) => out.push_str(&replaced),
                None => out.push_str(body),
            },
        }
        out.push_str(eol);
    }
    (out != text).then_some((out, stats))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mapping() -> Mapping {
        Mapping::parse(
            "komira_atomic_alias\tatomic_alias\nkomira_hash\thashing\nkomira_json\tjson\n",
        )
        .unwrap()
    }

    #[test]
    fn rewrites_a_package_manifest_to_full_names() {
        let old = "[package]\n\
                   name = \"komira_json\"\n\
                   version = \"0.1.0\"\n\
                   description = \"JSON for komira_hash users\"\n\
                   \n\
                   [dependencies]\n\
                   komira_atomic_alias = { path = \"../komira_atomic_alias\", version = \"0.1\" }\n\
                   \"komira_hash\" = \"0.1\"\n\
                   zstd = { version = \">=1.5.2,<2\" }\n\
                   \n\
                   [dev-dependencies]\n\
                   \x20 komira_json = { path = \"..\" }\n\
                   \n\
                   [native.komira_concurrency_pool_depth]\n\
                   srcs = [\"native/komira_json.c\"]\n\
                   \n\
                   [targets]\n\
                   lib = { path = \"src/komira_json\" }\n\
                   name = \"komira_json\"\n";
        let (new, stats) = rewrite_manifest(old, &mapping()).unwrap();
        assert_eq!(
            new,
            "[package]\n\
             name = \"komira-ai/json\"\n\
             version = \"0.1.0\"\n\
             description = \"JSON for hashing users\"\n\
             \n\
             [dependencies]\n\
             \"komira-ai/atomic_alias\" = { path = \"../atomic_alias\", version = \"0.1\" }\n\
             \"komira-ai/hashing\" = \"0.1\"\n\
             zstd = { version = \">=1.5.2,<2\" }\n\
             \n\
             [dev-dependencies]\n\
             \x20 \"komira-ai/json\" = { path = \"..\" }\n\
             \n\
             [native.komira_concurrency_pool_depth]\n\
             srcs = [\"native/json.c\"]\n\
             \n\
             [targets]\n\
             lib = { path = \"src/json\" }\n\
             name = \"json\"\n"
        );
        assert_eq!(stats, ManifestStats { names: 1, keys: 3 });
    }

    #[test]
    fn rewrites_dependency_table_headers_and_dotted_keys() {
        let old = "[dependencies.komira_json]\n\
                   path = \"../komira_json\"\n\
                   [dev-dependencies.\"komira_hash\"] # dev\n\
                   [dependencies]\n\
                   komira_json.version = \"0.1\"\n";
        let (new, stats) = rewrite_manifest(old, &mapping()).unwrap();
        assert_eq!(
            new,
            "[dependencies.\"komira-ai/json\"]\n\
             path = \"../json\"\n\
             [dev-dependencies.\"komira-ai/hashing\"] # dev\n\
             [dependencies]\n\
             \"komira-ai/json\".version = \"0.1\"\n"
        );
        assert_eq!(stats, ManifestStats { names: 0, keys: 3 });
    }

    #[test]
    fn leaves_unmapped_names_and_other_tables_alone() {
        let old = "[package]\n\
                   name = \"komira_other\"\n\
                   [dependencies]\n\
                   other = \"1\"\n\
                   [[bin]]\n\
                   name = \"x\"\n";
        assert_eq!(rewrite_manifest(old, &mapping()), None);
    }

    #[test]
    fn a_package_name_written_oddly_is_only_word_replaced() {
        let cases = [
            ("name.x = \"komira_json\"", "name.x = \"json\""),
            ("name x= \"komira_json\"", "name x= \"json\""),
            ("name = komira_json", "name = json"),
            ("name = \"komira_json", "name = \"json"),
            ("label = \"komira_json\"", "label = \"json\""),
            ("name \"komira_json\"", "name \"json\""),
            ("= komira_json", "= json"),
        ];
        for (line, expected) in cases {
            let old = format!("[package]\n{line}\n");
            let (new, stats) = rewrite_manifest(&old, &mapping()).unwrap();
            assert_eq!(new, format!("[package]\n{expected}\n"), "{line}");
            assert_eq!(stats, ManifestStats::default(), "{line}");
        }
    }

    #[test]
    fn keeps_spacing_around_a_rewritten_name_and_a_file_without_final_newline() {
        let old = "[ package ]\n\tname\t=\t\"komira_json\" # the name";
        let (new, stats) = rewrite_manifest(old, &mapping()).unwrap();
        assert_eq!(new, "[ package ]\n\tname\t=\t\"komira-ai/json\" # the name");
        assert_eq!(stats.names, 1);
    }

    #[test]
    fn a_dependency_key_it_cannot_read_is_only_word_replaced() {
        let old = "[dependencies]\n\
                   \"komira_json\\u0041\" = \"1\"\n\
                   \"komira_json = \"1\"\n\
                   = komira_json\n\
                   [dependencies.\"komira_json\\n\"]\n\
                   [dependencies.komira_json.x]\n\
                   [dependencies.other]\n\
                   [dependencies\n";
        let (new, stats) = rewrite_manifest(old, &mapping()).unwrap();
        assert_eq!(
            new,
            "[dependencies]\n\
             \"json\\u0041\" = \"1\"\n\
             \"json = \"1\"\n\
             = json\n\
             [dependencies.\"json\\n\"]\n\
             [dependencies.json.x]\n\
             [dependencies.other]\n\
             [dependencies\n"
        );
        assert_eq!(stats, ManifestStats::default());
    }
}
