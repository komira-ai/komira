//! The summary the tool prints, for a dry run and for a run that wrote.

use crate::manifest::NAMESPACE;
use crate::tree::{Kind, Plan};
use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::path::Path;

#[derive(Default, Clone, Copy)]
struct Tally {
    files: usize,
    lines: usize,
    import_lines: usize,
}

impl Tally {
    fn add(&mut self, lines: usize, import_lines: usize) {
        self.files += 1;
        self.lines += lines;
        self.import_lines += import_lines;
    }
}

fn top(path: &Path) -> String {
    let mut parts = path.components();
    let first = parts
        .next()
        .map(|c| c.as_os_str().to_string_lossy().into_owned());
    match (first, parts.next()) {
        (Some(dir), Some(_)) => format!("{dir}/"),
        _ => "(top level)".to_string(),
    }
}

/// The summary of `plan`. `dry_run` says whether anything was written.
pub fn summary(plan: &Plan, dry_run: bool) -> String {
    let mut by_kind: BTreeMap<Kind, Tally> = BTreeMap::new();
    let mut by_top: BTreeMap<String, Tally> = BTreeMap::new();
    let mut total = Tally::default();
    for r in &plan.rewrites {
        by_kind
            .entry(r.kind)
            .or_default()
            .add(r.lines, r.import_lines);
        by_top
            .entry(top(&r.path))
            .or_default()
            .add(r.lines, r.import_lines);
        total.add(r.lines, r.import_lines);
    }
    let mut out = String::new();
    let _ = writeln!(
        out,
        "ns-rename: {}",
        if dry_run {
            "dry run, nothing written"
        } else {
            "written"
        }
    );
    let _ = writeln!(out, "packages renamed: {}", plan.packages.len());
    for (old, new) in &plan.packages {
        let _ = writeln!(out, "  src/{old} -> src/{new}");
    }
    let _ = writeln!(out, "files moved: {}", plan.moves.len());
    let _ = writeln!(
        out,
        "files rewritten: {}, lines changed: {}",
        total.files, total.lines
    );
    let _ = writeln!(out, "  by kind:");
    for (kind, t) in &by_kind {
        let _ = write!(
            out,
            "    {}: {} files, {} lines",
            kind.label(),
            t.files,
            t.lines
        );
        match kind {
            Kind::Mojo => {
                let _ = write!(out, " ({} import lines)", t.import_lines);
            }
            Kind::Manifest => {
                let _ = write!(
                    out,
                    " ({} package names and {} dependency keys set to {NAMESPACE}/<name>)",
                    plan.manifest_names, plan.manifest_keys
                );
            }
            Kind::Build | Kind::Other => {}
        }
        let _ = writeln!(out);
    }
    let _ = writeln!(out, "  by top-level directory:");
    for (dir, t) in &by_top {
        let _ = writeln!(out, "    {dir}: {} files, {} lines", t.files, t.lines);
    }
    let _ = writeln!(
        out,
        "files that are not UTF-8 and hold an old name, left unchanged: {}",
        plan.binary.len()
    );
    for path in &plan.binary {
        let _ = writeln!(out, "  {}", path.display());
    }
    let _ = writeln!(
        out,
        "entries that are not files or directories, left unchanged: {}",
        plan.not_files.len()
    );
    for path in &plan.not_files {
        let _ = writeln!(out, "  {}", path.display());
    }
    let _ = writeln!(
        out,
        ".mojo files that import a renamed module and already use its new name (check for shadowing): {}",
        plan.shadow.len()
    );
    for (path, names) in &plan.shadow {
        let _ = writeln!(out, "  {}: {}", path.display(), names.join(", "));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tree::Rewrite;
    use std::path::PathBuf;

    fn rewrite(path: &str, kind: Kind, lines: usize, import_lines: usize) -> Rewrite {
        Rewrite {
            path: PathBuf::from(path),
            kind,
            text: String::new(),
            lines,
            import_lines,
        }
    }

    #[test]
    fn prints_every_section_with_its_count() {
        let plan = Plan {
            packages: vec![("komira_json".into(), "json".into())],
            moves: vec![("src/komira_json/BUCK".into(), "src/json/BUCK".into())],
            rewrites: vec![
                rewrite("src/komira_json/a.mojo", Kind::Mojo, 3, 2),
                rewrite("src/komira_json/BUCK", Kind::Build, 4, 0),
                rewrite("src/komira_json/mopm.toml", Kind::Manifest, 2, 0),
                rewrite("README.md", Kind::Other, 1, 0),
            ],
            manifest_names: 1,
            manifest_keys: 1,
            binary: vec!["docs/x.png".into()],
            not_files: vec!["link".into()],
            shadow: vec![("src/komira_json/a.mojo".into(), vec!["json".into()])],
        };
        assert_eq!(
            summary(&plan, true),
            "ns-rename: dry run, nothing written\n\
             packages renamed: 1\n\
             \x20 src/komira_json -> src/json\n\
             files moved: 1\n\
             files rewritten: 4, lines changed: 10\n\
             \x20 by kind:\n\
             \x20   .mojo: 1 files, 3 lines (2 import lines)\n\
             \x20   BUCK and .bzl: 1 files, 4 lines\n\
             \x20   mopm.toml: 1 files, 2 lines (1 package names and 1 dependency keys set to komira-ai/<name>)\n\
             \x20   other: 1 files, 1 lines\n\
             \x20 by top-level directory:\n\
             \x20   (top level): 1 files, 1 lines\n\
             \x20   src/: 3 files, 9 lines\n\
             files that are not UTF-8 and hold an old name, left unchanged: 1\n\
             \x20 docs/x.png\n\
             entries that are not files or directories, left unchanged: 1\n\
             \x20 link\n\
             .mojo files that import a renamed module and already use its new name (check for shadowing): 1\n\
             \x20 src/komira_json/a.mojo: json\n"
        );
    }

    #[test]
    fn an_empty_plan_that_was_written_says_so() {
        assert_eq!(
            summary(&Plan::default(), false),
            "ns-rename: written\n\
             packages renamed: 0\n\
             files moved: 0\n\
             files rewritten: 0, lines changed: 0\n\
             \x20 by kind:\n\
             \x20 by top-level directory:\n\
             files that are not UTF-8 and hold an old name, left unchanged: 0\n\
             entries that are not files or directories, left unchanged: 0\n\
             .mojo files that import a renamed module and already use its new name (check for shadowing): 0\n"
        );
    }
}
