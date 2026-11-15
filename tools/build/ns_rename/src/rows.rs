//! Files whose rows are kept in byte order. Renaming a row's name can move it: `komira_buffer`
//! sorts before `komira_bump_arena`, but `byte_buffer` sorts after `bump_arena`. The files listed
//! in [`SORTED_ROWS`] are read by a check or a tool that needs their rows sorted, so after the
//! words are replaced, each block of rows is sorted again.

use std::path::Path;

/// The files whose rows are kept in byte order, with what needs the order.
pub const SORTED_ROWS: &[(&str, &str)] = &[
    (
        "release/prod_claimed_names.txt",
        "//release:prod_claimed_names_cases refuses a list that is not sorted",
    ),
    (
        "release/readme_e2e/packages.bzl",
        "tools/build/mopm_migrate inserts a package's row keeping the rows in byte order",
    ),
    (
        "release/mopm_native_ids.bzl",
        "tools/build/mopm_migrate inserts a native's row keeping the rows in byte order",
    ),
];

/// True when `rel` is one of [`SORTED_ROWS`].
pub fn keeps_rows_sorted(rel: &Path) -> bool {
    SORTED_ROWS.iter().any(|(path, _)| rel == Path::new(path))
}

/// True for a row: in a `.bzl` file, a line whose text starts with a quoted string (an entry of
/// a list or a dict); in any other file, a line that is neither empty nor a `#` comment.
fn is_row(line: &str, starlark: bool) -> bool {
    let text = line.trim_start_matches([' ', '\t']);
    if starlark {
        text.starts_with('"')
    } else {
        !text.is_empty() && !text.starts_with('#')
    }
}

fn indent(line: &str) -> &str {
    &line[..line.len() - line.trim_start_matches([' ', '\t']).len()]
}

/// `text` with each block of rows sorted by bytes: a block is a run of consecutive rows with the
/// same indentation, so a row's position among the other lines (comments, headers, the lines
/// that open and close a list) never changes. `None` when every block is already sorted.
pub fn sort_rows(text: &str, starlark: bool) -> Option<String> {
    let mut lines: Vec<&str> = text.split('\n').collect();
    let mut changed = false;
    let mut i = 0;
    while i < lines.len() {
        if !is_row(lines[i], starlark) {
            i += 1;
            continue;
        }
        let mut end = i + 1;
        while end < lines.len()
            && is_row(lines[end], starlark)
            && indent(lines[end]) == indent(lines[i])
        {
            end += 1;
        }
        let block = &mut lines[i..end];
        if !block.is_sorted() {
            block.sort_unstable();
            changed = true;
        }
        i = end;
    }
    changed.then(|| lines.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sorts_each_block_of_rows_and_keeps_the_other_lines_in_place() {
        let text = "# a header\nzeta\nalpha\n\n# second\ndelta\nbeta\n";
        assert_eq!(
            sort_rows(text, false).as_deref(),
            Some("# a header\nalpha\nzeta\n\n# second\nbeta\ndelta\n")
        );
    }

    #[test]
    fn a_starlark_block_is_the_quoted_entries_of_one_indentation() {
        let text =
            "PACKAGES = {\n    \"byte_buffer\": \"0.1.0\",\n    \"bump_arena\": \"0.1.0\",\n}\n\
                    IDS = [\n    \"b\",\n        \"z\",\n        \"a\",\n]\n";
        assert_eq!(
            sort_rows(text, true).as_deref(),
            Some(
                "PACKAGES = {\n    \"bump_arena\": \"0.1.0\",\n    \"byte_buffer\": \"0.1.0\",\n}\n\
                 IDS = [\n    \"b\",\n        \"a\",\n        \"z\",\n]\n"
            )
        );
    }

    #[test]
    fn a_comment_or_a_line_that_is_not_a_row_ends_a_block() {
        // In Starlark, a bare word is not a row; in a list file, a comment is not.
        assert_eq!(sort_rows("    \"b\",\n    x,\n    \"a\",\n", true), None);
        assert_eq!(sort_rows("b\n# c\na\n", false), None);
    }

    #[test]
    fn sorted_text_is_unchanged() {
        assert_eq!(sort_rows("a\nb\n", false), None);
        assert_eq!(sort_rows("", false), None);
        assert_eq!(sort_rows("x = [\n    \"a\",\n    \"b\",\n]\n", true), None);
    }

    #[test]
    fn names_the_listed_files_only() {
        assert!(keeps_rows_sorted(Path::new(
            "release/prod_claimed_names.txt"
        )));
        assert!(keeps_rows_sorted(Path::new(
            "release/readme_e2e/packages.bzl"
        )));
        assert!(!keeps_rows_sorted(Path::new("release/other.txt")));
        assert!(!keeps_rows_sorted(Path::new(
            "x/release/prod_claimed_names.txt"
        )));
    }
}
