use super::*;
use crate::header::{render, Pin};
use std::collections::BTreeSet;

fn header() -> String {
    render("t-gen", "1", &[Pin { name: "m.json", sha256: "ab" }])
}

/// The module `x.mojo`: a header, documentation, two imports, `n` structs of
/// `body` field lines each (each with a banner, a decorator and a docstring),
/// and a closing comment.
fn module(n: usize, body: usize) -> String {
    let mut s = header();
    s.push_str("# Documentation of the module.\n\n");
    s.push_str("from lib_a import (\n    Alpha,\n    Beta,\n)\nfrom lib_b import Gamma\n\n\n");
    for i in 0..n {
        s.push_str(&format!("# ---- section {i}\n"));
        s.push_str(&strukt(i, body));
        s.push_str("\n\n");
    }
    s.push_str("# End of x.\n");
    s
}

fn strukt(i: usize, body: usize) -> String {
    let mut s = format!("@fieldwise_init\nstruct S{i}(Copyable):\n    \"\"\"Struct {i}.\"\"\"\n\n");
    for k in 0..body {
        s.push_str(&format!("    var f{k}: Int\n"));
    }
    s.push_str(&format!("    # end of S{i}\n"));
    s
}

fn texts(files: &[Emitted]) -> Vec<&str> {
    files.iter().map(|f| f.text.as_str()).collect()
}

/// The names `text` imports from modules whose path starts with `prefix`.
fn imported_from(text: &str, prefix: &str) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    let lines: Vec<&str> = text.lines().collect();
    let mut i = 0;
    while i < lines.len() {
        let l = lines[i];
        if let Some(rest) = l.strip_prefix(&format!("from {prefix}")) {
            let (_, names) = rest.split_once(" import ").expect("an import");
            let mut flat = names.to_string();
            if names.trim() == "(" {
                flat.clear();
                i += 1;
                while lines[i] != ")" {
                    flat.push_str(lines[i]);
                    i += 1;
                }
            }
            for n in flat.split(',') {
                let n = n.trim().trim_start_matches('(').trim();
                if !n.is_empty() {
                    out.insert(n.to_string());
                }
            }
        }
        i += 1;
    }
    out
}

#[test]
fn a_module_under_the_limit_is_written_whole() {
    let text = module(3, 5);
    let files = split_file("x.mojo", &text).unwrap();
    assert_eq!(files, vec![Emitted { path: "x.mojo".into(), text }]);
}

#[test]
fn a_module_of_exactly_the_limit_is_split_and_one_line_fewer_is_not() {
    let mut text = header();
    let mut n = 0;
    while line_count(&text) < 99 {
        text.push_str(&format!("comptime A{n}: Int = 1\n"));
        n += 1;
    }
    assert_eq!(split_with("x.mojo", &text, 100).unwrap().len(), 1);
    text.push_str("comptime B: Int = 2\n");
    assert_eq!(line_count(&text), 100);
    assert!(split_with("x.mojo", &text, 100).unwrap().len() > 1);
}

#[test]
fn every_file_of_a_split_is_under_the_limit() {
    let text = module(48, 50);
    assert!(line_count(&text) > 2 * MAX_FILE_LINES, "the fixture is not large enough");
    let files = split_file("x.mojo", &text).unwrap();
    assert!(files.len() >= 4, "{}", files.len());
    for f in &files {
        assert!(line_count(&f.text) < MAX_FILE_LINES, "{} has {} lines", f.path, line_count(&f.text));
    }
}

#[test]
fn the_files_are_the_facade_then_numbered_parts_in_the_parts_directory() {
    let files = split_file("x.mojo", &module(48, 50)).unwrap();
    assert_eq!(files[0].path, "x.mojo");
    for (i, f) in files[1..].iter().enumerate() {
        assert_eq!(f.path, format!("_parts/x_p{:02}.mojo", i + 1));
    }
}

#[test]
fn a_module_in_a_directory_has_its_parts_beside_it() {
    let files = split_file("a/b/x.mojo", &module(48, 50)).unwrap();
    assert_eq!(files[0].path, "a/b/x.mojo");
    assert_eq!(files[1].path, "a/b/_parts/x_p01.mojo");
    assert!(files[0].text.contains("from ._parts.x_p01 import "));
}

#[test]
fn part_numbers_have_the_digits_of_the_largest_but_at_least_two() {
    // A hundred parts or more: three digits. One declaration of over 500
    // lines does not share a part with the next.
    let files = split_file("x.mojo", &module(105, 500)).unwrap();
    assert!(files.len() > 100, "{}", files.len());
    assert_eq!(files[1].path, "_parts/x_p001.mojo");
    let small = split_file("x.mojo", &module(48, 50)).unwrap();
    assert!(small.len() < 100);
    assert_eq!(small[1].path, "_parts/x_p01.mojo");
}

#[test]
fn the_split_is_deterministic() {
    let text = module(48, 50);
    assert_eq!(split_file("x.mojo", &text).unwrap(), split_file("x.mojo", &text).unwrap());
}

#[test]
fn appending_a_declaration_leaves_the_earlier_parts_as_they_were() {
    // Stability of the file set: the parts before the last are byte for byte
    // what they were (but for the count they state).
    let strip = |f: &Emitted, parts: usize| f.text.replace(&format!(" of {parts} of `x`"), " of N of `x`");
    let a = split_file("x.mojo", &module(48, 50)).unwrap();
    let longer = module(48, 50).replace("# End of x.\n", &format!("{}\n# End of x.\n", strukt(48, 50)));
    let b = split_file("x.mojo", &longer).unwrap();
    assert!(b.len() >= a.len());
    for i in 1..a.len() - 1 {
        assert_eq!(strip(&a[i], a.len() - 1), strip(&b[i], b.len() - 1), "part {i}");
        assert_eq!(a[i].path, b[i].path);
    }
}

#[test]
fn every_file_starts_with_the_generated_header() {
    let files = split_file("x.mojo", &module(48, 50)).unwrap();
    for f in &files {
        assert!(f.text.starts_with(&header()), "{}", f.path);
    }
}

#[test]
fn the_facade_re_exports_every_declared_name_and_nothing_else() {
    let text = module(48, 50);
    let files = split_file("x.mojo", &text).unwrap();
    let want: BTreeSet<String> = (0..48).map(|i| format!("S{i}")).collect();
    assert_eq!(imported_from(&files[0].text, "._parts."), want);
    // Each name comes from the part that declares it.
    for (p, f) in files[1..].iter().enumerate() {
        let m = format!("x_p{:02}", p + 1);
        for name in imported_from(&files[0].text, &format!("._parts.{m}")) {
            assert!(f.text.contains(&format!("struct {name}(")), "{name} is not in {m}");
        }
    }
}

#[test]
fn the_facade_keeps_the_documentation_and_the_closing_comment_and_no_import_of_its_own() {
    let files = split_file("x.mojo", &module(48, 50)).unwrap();
    let facade = &files[0].text;
    assert!(facade.contains("# Documentation of the module.\n"));
    assert!(facade.ends_with("# End of x.\n"), "{}", &facade[facade.len().saturating_sub(120)..]);
    assert!(!facade.contains("struct S"), "a declaration stayed in the facade");
    // What the module imported is not its own to re-export.
    assert!(!facade.contains("lib_a"), "{facade}");
    assert!(!facade.contains("lib_b"), "{facade}");
}

#[test]
fn a_part_imports_what_it_uses_of_the_modules_imports_and_no_more() {
    // Only S0 uses Beta and Gamma; nothing uses Alpha.
    let text = module(48, 50).replacen(
        "    var f0: Int\n    var f1: Int\n",
        "    var f0: Int\n    var b: Beta\n    var g: Gamma\n",
        1,
    );
    let files = split_file("x.mojo", &text).unwrap();
    let mut users = 0;
    for f in &files[1..] {
        let uses = f.text.contains("var b: Beta");
        users += usize::from(uses);
        assert_eq!(f.text.contains("from lib_a import Beta\n"), uses, "{}", f.path);
        assert_eq!(f.text.contains("from lib_b import Gamma\n"), uses, "{}", f.path);
        assert!(!f.text.contains("Alpha"), "{} imports a name it does not use", f.path);
    }
    assert_eq!(users, 1);
}

#[test]
fn a_part_imports_a_name_another_part_declares_from_that_part() {
    let mut text = module(48, 50);
    // The last struct holds the first.
    text = text.replace(
        "struct S47(Copyable):\n    \"\"\"Struct 47.\"\"\"\n\n    var f0: Int\n",
        "struct S47(Copyable):\n    \"\"\"Struct 47.\"\"\"\n\n    var first: S0\n",
    );
    let files = split_file("x.mojo", &text).unwrap();
    let last = files.last().unwrap();
    assert!(last.text.contains("var first: S0"));
    assert!(last.text.contains("from .x_p01 import S0\n"), "{}", &last.text[..400]);
    // And no part imports itself or a name it declares.
    for (p, f) in files[1..].iter().enumerate() {
        assert!(!f.text.contains(&format!("from .x_p{:02} import", p + 1)), "{} imports itself", f.path);
    }
}

#[test]
fn a_declaration_is_never_cut() {
    let files = split_file("x.mojo", &module(48, 50)).unwrap();
    for i in 0..48 {
        let holders: Vec<&Emitted> = files[1..]
            .iter()
            .filter(|f| f.text.contains(&format!("struct S{i}(")))
            .collect();
        assert_eq!(holders.len(), 1, "S{i}");
        assert!(holders[0].text.contains(&strukt(i, 50)), "S{i} is not whole");
    }
}

#[test]
fn a_decorator_and_the_comments_before_a_declaration_move_with_it() {
    let files = split_file("x.mojo", &module(48, 50)).unwrap();
    for f in &files[1..] {
        for (n, l) in f.text.lines().enumerate() {
            if let Some(name) = l.strip_prefix("struct S") {
                let i: usize = name.split('(').next().unwrap().parse().unwrap();
                let lines: Vec<&str> = f.text.lines().collect();
                assert_eq!(lines[n - 1], "@fieldwise_init", "S{i}");
                assert_eq!(lines[n - 2], format!("# ---- section {i}"), "S{i}");
            }
        }
    }
}

#[test]
fn a_line_at_column_zero_inside_a_docstring_is_not_a_declaration() {
    let mut text = header();
    for i in 0..6 {
        text.push_str(&format!(
            "struct T{i}:\n    \"\"\"Doc.\nstruct Fake{i}:\ndef fake{i}():\n    \"\"\"\n"
        ));
        for k in 0..30 {
            text.push_str(&format!("    var f{k}: Int\n"));
        }
        text.push('\n');
    }
    let files = split_with("x.mojo", &text, 100).unwrap();
    let names = imported_from(&files[0].text, "._parts.");
    assert_eq!(names, (0..6).map(|i| format!("T{i}")).collect::<BTreeSet<_>>());
    // The docstring stayed inside its struct.
    for i in 0..6 {
        let holder = files[1..].iter().find(|f| f.text.contains(&format!("struct T{i}:"))).unwrap();
        assert!(holder.text.contains(&format!("\"\"\"Doc.\nstruct Fake{i}:\ndef fake{i}():\n    \"\"\"\n")));
    }
}

#[test]
fn a_parenthesised_statement_and_a_continued_line_are_one_statement() {
    let lines = [
        "comptime A: String = (",
        "    \"x\"",
        ")",
        "comptime B: Int = 1 + \\",
        "    2",
        "comptime C: Int = 3",
    ];
    let class = classify(&lines);
    assert_eq!(
        class,
        vec![Class::Head, Class::Body, Class::Body, Class::Head, Class::Body, Class::Head]
    );
}

#[test]
fn brackets_inside_strings_and_comments_do_not_count() {
    let lines = [
        "comptime A: String = \"(((\"  # )))(",
        "comptime B: String = '[{'",
        "comptime `we(ird`: Int = 1",
        "comptime C: String = \"\"\"",
        "(",
        "\"\"\"",
        "comptime D: Int = 1",
    ];
    let class = classify(&lines);
    assert_eq!(
        class,
        vec![
            Class::Head,
            Class::Head,
            Class::Head,
            Class::Head,
            Class::Body,
            Class::Body,
            Class::Head
        ]
    );
}

#[test]
fn identifiers_skip_comments_and_strings() {
    let ids = identifiers(&["var x: Alpha = foo(\"Beta\")  # Gamma", "\"\"\"Delta", "Epsilon\"\"\"", "bar"]);
    let want: BTreeSet<String> = ["var", "x", "Alpha", "foo", "bar"].iter().map(|s| s.to_string()).collect();
    assert_eq!(ids, want);
}

#[test]
fn a_top_level_line_that_is_not_a_declaration_is_refused_with_its_line() {
    let mut text = module(48, 50);
    text = text.replace("# End of x.\n", "print(\"hello\")\n# End of x.\n");
    let err = split_file("x.mojo", &text).unwrap_err();
    match err {
        SplitError::Unrecognised { line, text } => {
            assert_eq!(text, "print(\"hello\")");
            assert_eq!(line, line_count(&module(48, 50)));
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_name_declared_twice_is_refused() {
    let mut text = module(48, 50);
    text = text.replace("# End of x.\n", &format!("{}\n# End of x.\n", strukt(3, 2)));
    assert_eq!(split_file("x.mojo", &text).unwrap_err(), SplitError::DuplicateName("S3".into()));
}

#[test]
fn a_declaration_that_cannot_fit_is_refused_by_name() {
    let mut text = module(4, 5);
    text.push_str(&strukt(99, 150));
    match split_with("x.mojo", &text, 100).unwrap_err() {
        SplitError::DeclarationTooLarge { name, lines } => {
            assert_eq!(name, "S99");
            assert!(lines > 150, "{lines}");
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_facade_that_cannot_fit_is_refused() {
    let mut text = header();
    for i in 0..3000 {
        text.push_str(&format!("comptime N{i}: Int = {i}\n"));
    }
    match split_with("x.mojo", &text, 100).unwrap_err() {
        SplitError::FacadeTooLarge { lines } => assert!(lines >= 100, "{lines}"),
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_module_with_no_header_is_refused() {
    let text = "comptime A: Int = 1\n".repeat(1100);
    assert_eq!(split_file("x.mojo", &text).unwrap_err(), SplitError::NoHeader);
}

#[test]
fn a_part_names_the_module_that_re_exports_it() {
    let files = split_file("x.mojo", &module(48, 50)).unwrap();
    let n = files.len() - 1;
    for (i, f) in files[1..].iter().enumerate() {
        assert!(f.text.contains(&format!("# Part {} of {n} of `x`", i + 1)), "{}", f.path);
    }
    assert_eq!(texts(&files).len(), n + 1);
}

#[test]
fn a_part_that_does_not_fit_with_its_imports_is_halved_until_it_does() {
    // Twenty-four structs, each using twenty-four imported names of 30
    // characters: a part of declarations up to 88% of the limit is over it
    // once the imports (eleven lines) are counted.
    let names: Vec<String> = (0..24).map(|i| format!("AnImportedNameOfThirtyChars{i:02}")).collect();
    let mut text = header();
    text.push_str(&format!("from lib import {}\n\n\n", names.join(", ")));
    for i in 0..24 {
        text.push_str(&format!("struct S{i}:\n    var all: Int = ({},)\n", names.join(", ")));
        for k in 0..2 {
            text.push_str(&format!("    var f{k}: Int\n"));
        }
        text.push('\n');
    }
    let one_part = split_with("x.mojo", &text, 1000).unwrap();
    assert_eq!(one_part.len(), 1, "the fixture must be under the limit unsplit");
    let files = split_with("x.mojo", &text, 100).unwrap();
    assert!(files.len() >= 4, "{}", files.len());
    for f in &files {
        assert!(line_count(&f.text) < 100, "{} has {} lines", f.path, line_count(&f.text));
    }
    // All twenty-four are still re-exported, each once.
    let names = imported_from(&files[0].text, "._parts.");
    assert_eq!(names, (0..24).map(|i| format!("S{i}")).collect::<BTreeSet<_>>());
}
