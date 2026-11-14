//! Whole runs over small checkouts written into a scratch directory of each test's own.

use crate::error::Error;
use crate::map::Mapping;
use crate::tree::{self, Kind, Plan};
use crate::{parse_args, rename, run, Args, USAGE};
use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// A directory of one test's own under the temporary directory, removed when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new(test: &str) -> Scratch {
        let dir = std::env::temp_dir().join(format!("ns_rename_{}_{test}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        Scratch(dir)
    }

    fn write(&self, rel: &str, bytes: impl AsRef<[u8]>) {
        let path = self.0.join(rel);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
    }

    fn read(&self, rel: &str) -> String {
        fs::read_to_string(self.0.join(rel)).unwrap()
    }

    fn exists(&self, rel: &str) -> bool {
        self.0.join(rel).symlink_metadata().is_ok()
    }

    /// Every file under the directory with its bytes.
    fn snapshot(&self) -> BTreeMap<PathBuf, Vec<u8>> {
        fn walk(root: &Path, dir: &Path, out: &mut BTreeMap<PathBuf, Vec<u8>>) {
            for entry in fs::read_dir(dir).unwrap() {
                let path = entry.unwrap().path();
                let meta = path.symlink_metadata().unwrap();
                if meta.is_dir() {
                    walk(root, &path, out);
                } else if meta.is_file() {
                    let rel = path.strip_prefix(root).unwrap().to_path_buf();
                    out.insert(rel, fs::read(&path).unwrap());
                }
            }
        }
        let mut out = BTreeMap::new();
        walk(&self.0, &self.0, &mut out);
        out
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

const MAP: &str = "komira_hash\thashing\nkomira_json\tjson\n";

/// A checkout with two packages and one of each case the rename meets.
fn checkout(test: &str) -> Scratch {
    let s = Scratch::new(test);
    s.write(
        "src/komira_json/mopm.toml",
        "[package]\nname = \"komira_json\"\n\n[dependencies]\n\
         komira_hash = { path = \"../komira_hash\", version = \"0.1\" }\n\n\
         [targets]\nlib = { path = \"src/komira_json\" }\n",
    );
    s.write(
        "src/komira_json/BUCK",
        "mojo_adopted_library(\n    name = \"komira_json\",\n    \
         srcs = glob([\"src/komira_json/**/*.mojo\"]),\n    \
         deps = [\"//src/komira_hash:komira_hash\"],\n)\n",
    );
    s.write(
        "src/komira_json/src/komira_json/__init__.mojo",
        "from komira_hash import fnv1a\n    import komira_hash.fnv as h\n\
         # komira_json_index is another package\nvar hashing = 1\n",
    );
    s.write(
        "src/komira_json/src/komira_json/codec.mojo",
        "import std.os, komira_hash.fnv\nvar hashing = komira_hash.fnv.x\n",
    );
    s.write(
        "src/komira_json/tests/test_parse.mojo",
        "from komira_json import parse\nfrom json import other\n",
    );
    s.write(
        "src/komira_hash/BUCK",
        "mojo_library(name = \"komira_hash\")\n",
    );
    s.write(
        "src/komira_hash/defs.bzl",
        "load(\"//src/komira_json:defs.bzl\", \"x\")\n",
    );
    s.write(
        "src/komira_hash/tests/test_fnv.mojo",
        "from komira_hash import fnv1a\n",
    );
    s.write(
        "src/komira_hash/src/komira_hash/fnv.mojo",
        "fn fnv1a(): pass\n",
    );
    s.write(
        "src/tests/e2e/komira_json_e2e.mojo",
        "import komira_json_e2e\n",
    );
    s.write("src/README.md", "packages: komira_json, komira_hash\n");
    s.write("docs/komira_json.md", "# komira_json\n");
    s.write(
        "release/staged_set/komira_json/mopm.toml",
        "name = \"komira_json\"\n",
    );
    s.write("README.md", "See src/komira_json.\n");
    s.write("tools/build/ns_rename/kept.txt", "komira_json\n");
    s.write(".git/HEAD", "komira_json\n");
    s.write("buck-out/v2/komira_json", "komira_json\n");
    s.write("docs/logo.bin", b"\xff\xfe komira_json \x00");
    s.write("docs/other.bin", b"\xff\xfe komira_jsonx \x00");
    std::os::unix::fs::symlink("src/komira_json", s.0.join("link_komira_json")).unwrap();
    s
}

/// The paths of the checkout a `git ls-files` would list: every file and symbolic link but those
/// under `.git`, `buck-out` and `release/staged_set` (untracked, as a build leaves them).
fn tracked(s: &Scratch) -> Vec<PathBuf> {
    fn walk(root: &Path, dir: &Path, out: &mut Vec<PathBuf>) {
        for entry in fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            let rel = path.strip_prefix(root).unwrap().to_path_buf();
            if [".git", "buck-out", "release/staged_set"]
                .iter()
                .any(|u| rel.starts_with(u))
            {
                continue;
            }
            if path.symlink_metadata().unwrap().is_dir() {
                walk(root, &path, out);
            } else {
                out.push(rel);
            }
        }
    }
    let mut out = Vec::new();
    walk(&s.0, &s.0, &mut out);
    out
}

/// Writes `paths` as a `git ls-files -z` list beside the mapping and returns its path.
fn list_file(map: &Path, paths: &[PathBuf]) -> PathBuf {
    use std::os::unix::ffi::OsStrExt;
    let mut bytes = Vec::new();
    for path in paths {
        bytes.extend_from_slice(path.as_os_str().as_bytes());
        bytes.push(0);
    }
    let list = map.with_file_name("files.list");
    fs::write(&list, bytes).unwrap();
    list
}

fn args(s: &Scratch, map: &Path, dry_run: bool) -> Args {
    Args {
        repo: s.0.clone(),
        map: map.to_path_buf(),
        files: list_file(map, &tracked(s)),
        dry_run,
    }
}

/// The mapping written outside the checkout.
fn map_file(test: &str, text: &str) -> Scratch {
    let m = Scratch::new(&format!("{test}_map"));
    m.write("map.tsv", text);
    m
}

const SUMMARY_BODY: &str = "packages renamed: 2\n\
     \x20 src/komira_hash -> src/hashing\n\
     \x20 src/komira_json -> src/json\n\
     files moved: 10\n\
     files rewritten: 11, lines changed: 17\n\
     \x20 by kind:\n\
     \x20   .mojo: 4 files, 6 lines (5 import lines)\n\
     \x20   BUCK and .bzl: 3 files, 5 lines\n\
     \x20   mopm.toml: 1 files, 3 lines (1 package names and 1 dependency keys set to komira-ai/<name>)\n\
     \x20   other: 3 files, 3 lines\n\
     \x20 by top-level directory:\n\
     \x20   (top level): 1 files, 1 lines\n\
     \x20   docs/: 1 files, 1 lines\n\
     \x20   src/: 9 files, 15 lines\n\
     files that are not UTF-8 and hold an old name, left unchanged: 1\n\
     \x20 docs/logo.bin\n\
     listed entries that are not regular files, left unchanged: 1\n\
     \x20 link_komira_json\n\
     .mojo files that import a renamed module and already use its new name (check for shadowing): 1\n\
     \x20 src/komira_json/src/komira_json/codec.mojo: hashing\n";

#[test]
fn renames_directories_imports_targets_and_manifests() {
    let s = checkout("full");
    let m = map_file("full", MAP);
    let summary = rename(&args(&s, &m.0.join("map.tsv"), false)).unwrap();
    assert_eq!(summary, format!("ns-rename: written\n{SUMMARY_BODY}"));

    assert_eq!(
        s.read("src/json/mopm.toml"),
        "[package]\nname = \"komira-ai/json\"\n\n[dependencies]\n\
         \"komira-ai/hashing\" = { path = \"../hashing\", version = \"0.1\" }\n\n\
         [targets]\nlib = { path = \"src/json\" }\n"
    );
    assert_eq!(
        s.read("src/json/BUCK"),
        "mojo_adopted_library(\n    name = \"json\",\n    \
         srcs = glob([\"src/json/**/*.mojo\"]),\n    \
         deps = [\"//src/hashing:hashing\"],\n)\n"
    );
    assert_eq!(
        s.read("src/json/src/json/__init__.mojo"),
        "from hashing import fnv1a\n    import hashing.fnv as h\n\
         # komira_json_index is another package\nvar hashing = 1\n"
    );
    assert_eq!(
        s.read("src/json/src/json/codec.mojo"),
        "import std.os, hashing.fnv\nvar hashing = hashing.fnv.x\n"
    );
    assert_eq!(
        s.read("src/json/tests/test_parse.mojo"),
        "from json import parse\nfrom json import other\n"
    );
    assert_eq!(
        s.read("src/hashing/BUCK"),
        "mojo_library(name = \"hashing\")\n"
    );
    assert_eq!(
        s.read("src/hashing/defs.bzl"),
        "load(\"//src/json:defs.bzl\", \"x\")\n"
    );
    assert_eq!(
        s.read("src/hashing/tests/test_fnv.mojo"),
        "from hashing import fnv1a\n"
    );
    assert_eq!(
        s.read("src/hashing/src/hashing/fnv.mojo"),
        "fn fnv1a(): pass\n"
    );
    assert_eq!(
        s.read("src/tests/e2e/komira_json_e2e.mojo"),
        "import komira_json_e2e\n"
    );
    assert_eq!(s.read("src/README.md"), "packages: json, hashing\n");
    assert_eq!(s.read("docs/json.md"), "# json\n");
    assert_eq!(s.read("README.md"), "See src/json.\n");
    // Kept and skipped paths, a binary file and a symbolic link are left as they were.
    assert_eq!(s.read("tools/build/ns_rename/kept.txt"), "komira_json\n");
    assert_eq!(s.read(".git/HEAD"), "komira_json\n");
    assert_eq!(s.read("buck-out/v2/komira_json"), "komira_json\n");
    // An untracked path is neither rewritten nor moved.
    assert_eq!(
        s.read("release/staged_set/komira_json/mopm.toml"),
        "name = \"komira_json\"\n"
    );
    assert_eq!(
        fs::read(s.0.join("docs/logo.bin")).unwrap(),
        b"\xff\xfe komira_json \x00"
    );
    assert_eq!(
        fs::read_link(s.0.join("link_komira_json")).unwrap(),
        PathBuf::from("src/komira_json")
    );
    // The old directories are gone, not left empty.
    for old in ["src/komira_json", "src/komira_hash", "docs/komira_json.md"] {
        assert!(!s.exists(old), "{old}");
    }
    assert!(s.exists("docs"));
}

#[test]
fn a_second_run_over_the_renamed_tree_is_refused() {
    let s = checkout("again");
    let m = map_file("again", MAP);
    rename(&args(&s, &m.0.join("map.tsv"), false)).unwrap();
    let before = s.snapshot();
    let err = rename(&args(&s, &m.0.join("map.tsv"), false)).unwrap_err();
    assert_eq!(
        err.to_string(),
        "the mapping names komira_hash, but src/komira_hash is not a directory"
    );
    assert_eq!(s.snapshot(), before);
}

#[test]
fn a_dry_run_prints_the_same_summary_and_writes_nothing() {
    let s = checkout("dry");
    let m = map_file("dry", MAP);
    let before = s.snapshot();
    let summary = rename(&args(&s, &m.0.join("map.tsv"), true)).unwrap();
    assert_eq!(
        summary,
        format!("ns-rename: dry run, nothing written\n{SUMMARY_BODY}")
    );
    assert_eq!(s.snapshot(), before);
}

#[test]
fn a_mapping_inside_the_checkout_is_not_rewritten() {
    let s = checkout("inside");
    s.write("ns-map.tsv", MAP);
    rename(&args(&s, &s.0.join("ns-map.tsv"), false)).unwrap();
    assert_eq!(s.read("ns-map.tsv"), MAP);
}

#[test]
fn a_non_utf8_file_name_is_neither_moved_nor_a_failure() {
    use std::os::unix::ffi::OsStrExt;
    let s = checkout("nonutf8");
    let name = std::ffi::OsStr::from_bytes(b"komira_json\xff.txt");
    fs::write(s.0.join("docs").join(name), "komira_json\n").unwrap();
    let m = map_file("nonutf8", MAP);
    rename(&args(&s, &m.0.join("map.tsv"), false)).unwrap();
    assert_eq!(
        fs::read_to_string(s.0.join("docs").join(name)).unwrap(),
        "json\n"
    );
}

/// Runs `rename` and checks it refused with `message` and wrote nothing.
fn refused(s: &Scratch, map: &str, message: &str) {
    let m = map_file(
        &format!("{}_refused", s.0.file_name().unwrap().to_string_lossy()),
        map,
    );
    let before = s.snapshot();
    let err = rename(&args(s, &m.0.join("map.tsv"), false)).unwrap_err();
    assert_eq!(err.to_string(), message);
    assert_eq!(err.exit_code(), 1);
    assert_eq!(s.snapshot(), before);
}

#[test]
fn refuses_a_mapped_package_with_no_directory() {
    let s = checkout("missing");
    refused(
        &s,
        "komira_hash\thashing\nkomira_json\tjson\nkomira_zz\tzz\n",
        "the mapping names komira_zz, but src/komira_zz is not a directory",
    );
}

#[test]
fn refuses_a_package_directory_the_mapping_leaves_out() {
    let s = checkout("unmapped");
    s.write("src/komira_extra/BUCK", "");
    refused(
        &s,
        MAP,
        "src/komira_extra is a directory the mapping does not name",
    );
}

#[test]
fn refuses_a_new_name_that_is_already_a_directory() {
    let s = checkout("taken");
    s.write("src/json/BUCK", "");
    refused(
        &s,
        MAP,
        "the mapping renames komira_json to json, but src/json already exists",
    );
}

#[test]
fn refuses_a_move_onto_an_existing_file() {
    let s = checkout("exists");
    s.write("docs/json.md", "other\n");
    refused(
        &s,
        MAP,
        "docs/komira_json.md would move to docs/json.md, which already exists",
    );
}

#[test]
fn refuses_two_files_moving_to_one_path() {
    let s = checkout("same");
    s.write("x/json/komira_json", "");
    s.write("x/komira_json/json", "");
    refused(
        &s,
        MAP,
        "x/json/komira_json and x/komira_json/json would both move to x/json/json",
    );
}

#[test]
fn refuses_a_bad_mapping_naming_its_file() {
    let s = checkout("badmap");
    let m = map_file("badmap", "komira_json\tcollections\n");
    let map = m.0.join("map.tsv");
    let err = rename(&args(&s, &map, false)).unwrap_err();
    assert_eq!(
        err.to_string(),
        format!(
            "{}: line 1: new name 'collections' is a name in the Mojo standard library",
            map.display()
        )
    );
}

#[test]
fn refuses_a_checkout_without_src() {
    let s = Scratch::new("nosrc");
    let m = map_file("nosrc", MAP);
    let err = rename(&args(&s, &m.0.join("map.tsv"), false)).unwrap_err();
    assert!(matches!(err, Error::Io { ref path, .. } if path == &s.0.join("src")));
}

#[test]
fn refuses_a_missing_or_unreadable_mapping() {
    let s = checkout("nomap");
    let missing = s.0.join("no-such.tsv");
    let err = rename(&args(&s, &missing, false)).unwrap_err();
    assert!(matches!(err, Error::Io { ref path, .. } if path == &missing));
    s.write("bad.tsv", b"\xff\n");
    let bad = s.0.join("bad.tsv");
    let err = rename(&args(&s, &bad, false)).unwrap_err();
    assert!(matches!(err, Error::Io { ref path, .. } if path == &bad));
}

#[test]
fn apply_reports_the_path_it_cannot_write() {
    let s = Scratch::new("applyio");
    let write_plan = Plan {
        rewrites: vec![tree::Rewrite {
            path: "no/such/dir/f".into(),
            kind: Kind::Other,
            text: String::new(),
            lines: 1,
            import_lines: 0,
        }],
        ..Plan::default()
    };
    let err = tree::apply(&s.0, &write_plan).unwrap_err();
    assert!(matches!(err, Error::Io { ref path, .. } if path == &s.0.join("no/such/dir/f")));

    let move_plan = Plan {
        moves: vec![("komira_a/f".into(), "aa/f".into())],
        ..Plan::default()
    };
    let err = tree::apply(&s.0, &move_plan).unwrap_err();
    assert!(matches!(err, Error::Io { ref path, .. } if path == &s.0.join("komira_a/f")));

    s.write("blocker", "a file where a directory must go");
    s.write("komira_b/f", "");
    let parent_plan = Plan {
        moves: vec![("komira_b/f".into(), "blocker/f".into())],
        ..Plan::default()
    };
    let err = tree::apply(&s.0, &parent_plan).unwrap_err();
    assert!(matches!(err, Error::Io { ref path, .. } if path == &s.0.join("blocker")));
}

#[test]
fn apply_keeps_a_directory_that_still_holds_files() {
    let s = Scratch::new("keepdir");
    s.write("d/komira_a/f", "");
    s.write("d/stays", "");
    let plan = Plan {
        moves: vec![("d/komira_a/f".into(), "d/aa/f".into())],
        ..Plan::default()
    };
    tree::apply(&s.0, &plan).unwrap();
    assert!(!s.exists("d/komira_a"));
    assert!(s.exists("d/stays"));
    assert!(s.exists("d/aa/f"));
}

#[test]
fn plan_with_no_mapping_path_walks_everything() {
    let s = checkout("nomappath");
    s.write("map.tsv", MAP);
    let mapping = Mapping::parse(MAP).unwrap();
    let plan = tree::plan(&s.0, &mapping, None, &tracked(&s)).unwrap();
    assert!(plan.rewrites.iter().any(|r| r.path == Path::new("map.tsv")));
}

fn strings(args: &[&str]) -> Vec<String> {
    args.iter().map(|a| a.to_string()).collect()
}

#[test]
fn parses_the_command_line() {
    assert_eq!(
        parse_args(&strings(&[
            "--map",
            "m",
            "--dry-run",
            "--files",
            "f",
            "--repo",
            "r"
        ]))
        .unwrap(),
        Args {
            repo: "r".into(),
            map: "m".into(),
            files: "f".into(),
            dry_run: true,
        }
    );
    assert!(
        !parse_args(&strings(&["--repo", "r", "--map", "m", "--files", "f"]))
            .unwrap()
            .dry_run
    );
    let cases = [
        (vec!["--repo"], "--repo needs a value"),
        (vec!["--repo", "r", "--map"], "--map needs a value"),
        (vec!["--repo", "r", "--repo", "s"], "--repo is given twice"),
        (vec!["--apply"], "unknown argument '--apply'"),
        (vec!["--map", "m"], "--repo is required"),
        (vec!["--repo", "r"], "--map is required"),
        (vec!["--repo", "r", "--map", "m"], "--files is required"),
        (
            vec!["--files", "f", "--files", "g"],
            "--files is given twice",
        ),
        (vec!["--files"], "--files needs a value"),
        (vec![], "--repo is required"),
    ];
    for (argv, problem) in cases {
        let err = parse_args(&strings(&argv)).unwrap_err();
        assert_eq!(err.to_string(), format!("{problem}\n{USAGE}"), "{argv:?}");
        assert_eq!(err.exit_code(), 2);
    }
}

#[test]
fn run_prints_the_summary_and_exits_0() {
    let s = checkout("run");
    let m = map_file("run", MAP);
    let map = m.0.join("map.tsv");
    let argv = strings(&[
        "--repo",
        s.0.to_str().unwrap(),
        "--map",
        map.to_str().unwrap(),
        "--files",
        list_file(&map, &tracked(&s)).to_str().unwrap(),
        "--dry-run",
    ]);
    let (mut out, mut err) = (Vec::new(), Vec::new());
    assert_eq!(run(&argv, &mut out, &mut err), 0);
    assert_eq!(
        String::from_utf8(out).unwrap(),
        format!("ns-rename: dry run, nothing written\n{SUMMARY_BODY}")
    );
    assert!(err.is_empty());
}

#[test]
fn run_prints_a_refusal_with_its_exit_code() {
    let (mut out, mut err) = (Vec::new(), Vec::new());
    assert_eq!(run(&strings(&["--bogus"]), &mut out, &mut err), 2);
    assert!(out.is_empty());
    assert_eq!(
        String::from_utf8(err).unwrap(),
        format!("ns-rename: unknown argument '--bogus'\n{USAGE}\n")
    );

    let s = Scratch::new("runrefused");
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let absent = s.0.join("absent.tsv");
    let argv = strings(&[
        "--repo",
        s.0.to_str().unwrap(),
        "--map",
        absent.to_str().unwrap(),
        "--files",
        absent.to_str().unwrap(),
    ]);
    assert_eq!(run(&argv, &mut out, &mut err), 1);
    assert_eq!(
        String::from_utf8(err).unwrap(),
        format!(
            "ns-rename: {}: {}\n",
            absent.display(),
            io::Error::from_raw_os_error(2)
        )
    );
}

/// A writer that refuses every write.
struct Broken;

impl io::Write for Broken {
    fn write(&mut self, _: &[u8]) -> io::Result<usize> {
        Err(io::Error::new(io::ErrorKind::BrokenPipe, "closed"))
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn run_fails_when_the_summary_cannot_be_written() {
    let s = checkout("broken");
    let m = map_file("broken", MAP);
    let map = m.0.join("map.tsv");
    let argv = strings(&[
        "--repo",
        s.0.to_str().unwrap(),
        "--map",
        map.to_str().unwrap(),
        "--files",
        list_file(&map, &tracked(&s)).to_str().unwrap(),
        "--dry-run",
    ]);
    let mut err = Vec::new();
    assert_eq!(run(&argv, &mut Broken, &mut err), 1);
    assert_eq!(
        String::from_utf8(err).unwrap(),
        "ns-rename: writing the summary: closed\n"
    );
    assert!(io::Write::flush(&mut Broken).is_ok());
}

#[test]
fn only_a_plain_import_binds_the_module_name() {
    for text in [
        "import komira_json",
        "  import komira_json.parse",
        "import std.os, komira_json",
        "x = 1\n\timport komira_json # a comment",
    ] {
        assert!(tree::binds_module(text, "komira_json"), "{text:?}");
    }
    for text in [
        "from komira_json import parse",
        "import komira_json as j",
        "import komira_json.parse as p",
        "import komira_json_index",
        "import komira_jsonx.y",
        "# import komira_json",
        "import",
        "import ",
        "importkomira_json",
        "",
    ] {
        assert!(!tree::binds_module(text, "komira_json"), "{text:?}");
    }
}

#[test]
fn refuses_a_file_list_entry_outside_the_checkout() {
    let s = checkout("listentry");
    let m = map_file("listentry", MAP);
    let map = m.0.join("map.tsv");
    let mapping = Mapping::parse(MAP).unwrap();
    let err = tree::plan(&s.0, &mapping, None, &[PathBuf::new()]).unwrap_err();
    assert_eq!(
        err.to_string(),
        "file list entry '' is not a relative path inside the checkout"
    );
    for entry in ["../outside", "/abs", "a/../b", "."] {
        let mut a = args(&s, &map, true);
        a.files = list_file(&map, &[PathBuf::from(entry)]);
        let err = rename(&a).unwrap_err();
        assert_eq!(
            err.to_string(),
            format!("file list entry '{entry}' is not a relative path inside the checkout"),
        );
    }
}

#[test]
fn refuses_a_listed_path_that_does_not_exist_and_a_missing_list() {
    let s = checkout("listmissing");
    let m = map_file("listmissing", MAP);
    let map = m.0.join("map.tsv");
    let mut a = args(&s, &map, true);
    a.files = list_file(&map, &[PathBuf::from("docs/gone.md")]);
    let err = rename(&a).unwrap_err();
    assert!(matches!(err, Error::Io { ref path, .. } if path == &s.0.join("docs/gone.md")));
    a.files = m.0.join("no-such.list");
    let err = rename(&a).unwrap_err();
    assert!(matches!(err, Error::Io { ref path, .. } if path == &m.0.join("no-such.list")));
}

#[test]
fn a_listed_directory_is_left_as_another_entry_and_empty_entries_are_ignored() {
    let s = checkout("listdir");
    s.write("vendor/komira_json_sub/x", "komira_json\n");
    let m = map_file("listdir", MAP);
    let map = m.0.join("map.tsv");
    let mut a = args(&s, &map, false);
    // A submodule is listed as its directory, not as its files.
    let mut paths = tracked(&s);
    paths.retain(|p| !p.starts_with("vendor"));
    paths.push(PathBuf::from("vendor"));
    a.files = list_file(&map, &paths);
    let mut bytes = fs::read(&a.files).unwrap();
    bytes.extend_from_slice(b"\0\0");
    fs::write(&a.files, bytes).unwrap();
    let summary = rename(&a).unwrap();
    assert!(
        summary.contains(
            "listed entries that are not regular files, left unchanged: 2\n  link_komira_json\n  vendor\n"
        ),
        "{summary}"
    );
    assert_eq!(s.read("vendor/komira_json_sub/x"), "komira_json\n");
}
