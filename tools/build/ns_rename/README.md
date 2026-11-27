# ns-rename

Renames komira's 260 `komira_*` packages to the names they get in mopm's owner namespaces
(komira-ai/mopm, `docs/design/namespaces.md`, section 12.3): `src/komira_json` becomes `src/json`,
imported as `json`, published as `komira-ai/json`. The new names come from one checked-in mapping;
the tool never invents a name.

```sh
cargo build --release --manifest-path tools/build/ns_rename/Cargo.toml
ns-rename --repo . --map tools/build/ns_rename/namespaces-komira-map.tsv --files <(git ls-files -z) --dry-run
ns-rename --repo . --map tools/build/ns_rename/namespaces-komira-map.tsv --files <(git ls-files -z)
```

The Buck2 target is `komira//tools/build/ns_rename:ns-rename`. `--repo`, `--map` and `--files` are
required. `--files` is the checkout's tracked paths, NUL-separated and relative to it (`git ls-files
-z`): the tool reads and changes those paths only, so build caches, staged releases and other
untracked or ignored files are never touched, and every checkout of one commit gives the same
result. An entry that is not a relative path of normal components (`..`, an absolute path) is
refused. `--dry-run` prints the summary and writes nothing. Exit codes: 0 done, 1 refused (the message names the line,
package or path), 2 a usage error.

## The mapping

[`namespaces-komira-map.tsv`](namespaces-komira-map.tsv) is a byte-for-byte copy of
`docs/design/namespaces-komira-map.tsv` in komira-ai/mopm: 260 lines `<old directory
name><TAB><new import name>`, no header, sorted by the old name as bytes. The namespace is
`komira-ai` for every line. It sits beside the tool so that the tool's tests read it (its check is
`map::tests::the_checked_in_mapping_passes_with_260_lines`); a change to the names is made in mopm's
design first and copied here.

The tool refuses a mapping, naming the line, when:

- the file is empty, its last line has no newline, or a line has a carriage return;
- a line does not have exactly two tab-separated fields;
- an old name is not `komira_` followed by a package name, or is not after the previous line's old
  name as bytes (unsorted or repeated);
- a new name is not `^[a-z][a-z0-9_]{1,63}$`, is a Mojo keyword (mopm's list plus `match` and `case`, reserved from Mojo 1.2.0) or builtin (mopm's
  `src/core/manifest.zig` lists), one of mopm's reserved names (`mopm`, `mojo`, `max`, `modular`,
  `std`, `stdlib`), or any directory or file name of the Mojo 1.0.0 standard library (the 173 names
  under `mojo/stdlib/std/`, at any depth: `src/names.rs`);
- two lines have the same new name, or a new name is also an old name.

It then refuses a checkout whose `src/komira_*` directories are not exactly the mapping's old names
(a mapped name with no directory, or a directory with no line), or where a new name is already a
`src/` directory. So the mapping's 260 lines are the 260 `src/komira_*` directories of the checkout,
and running the tool a second time over a renamed tree is refused.

## What it changes

A word is a maximal run of ASCII letters, digits and `_` (as `git grep -w` reads one), so
`komira_gcp_firestore` never matches inside `komira_gcp_firestore_v1`, and `komira_json` matches in
`//src/komira_json:komira_json`. Every word that is an old name is replaced by its new name, and
so is every word derived from one, in one pass:

- `<old>_conda`, `<old>_cov_gate`, `<old>_fresh` and `<old>_gen` become `<new>` with the same
  suffix. komira's and buildrules' rules name the targets they derive from a target `name` that way
  (`name + "_conda"` in `tools/build/mojo/defs.bzl`), so a reference such as
  `//src/komira_json:komira_json_conda` must follow the renamed target: `//src/json:json_conda`.
  A rule that derives a target name with another suffix adds it to `DERIVED_SUFFIXES` in
  `src/map.rs`.
- `test_<old>` becomes `test_<new>`: a suite that names its test files after the packages it tests
  (`tests/test_{}.mojo".format(p)` over a list of package names) finds `tests/test_json.mojo`.

A mapping where one of these derived words is itself an old name is refused, naming its line.

The rename applies:

- in every listed path: each file under a component holding an old name moves (`src/komira_json/src/komira_json/x.mojo`
  to `src/json/src/json/x.mojo`, `docs/komira_json.md` to `docs/json.md`), and the directories the
  moves empty are removed;
- in the text of every listed UTF-8 file: imports, BUCK targets and paths, `.bzl` files, docs, workflows.

One move is not a word replacement: a test file directly under a package's `tests/` whose stem is the
package's new name (`src/komira_test_run_id/tests/test_run_id.mojo`, package `test_run_id`) moves to
`tests/test_<new>.mojo` (`tests/test_test_run_id.mojo`). buildrules' `mojo_package` declares a target
per test file named by its stem, so without the move the test's target and the package's own target
would have one name and the BUCK file would fail to load. A path that names such a file
(`src/<new>/tests/<new>.mojo` once the words are replaced: `buildrules.mojo.lock.bzl` lists each
test file by its path) names it where it moves; one that ends a sentence (`see
src/a/tests/a.mojo.`) reads as part of a longer path and is left for a hand edit. The summary lists these moves.

A renamed row can change places in a sorted list: `komira_buffer` sorts before `komira_bump_arena`,
`byte_buffer` after `bump_arena`. Three files are read by a check or a tool that needs their rows
in byte order (`SORTED_ROWS` in `src/rows.rs`, with the reason for each in a comment):
`release/prod_claimed_names.txt`, `release/readme_e2e/packages.bzl` and
`release/mopm_native_ids.bzl`. In those files, after the words are replaced, each block of rows (a run
of consecutive rows of one kind and one indentation; in a `.bzl` file a row is a line that starts
with a quoted string or with `load(`, elsewhere a line that is neither empty nor a `#` comment) is
sorted again. The summary
lists them. Other sorted lists (a BUCK file's `deps`) are left in the order the replacement gives,
which nothing reads; the check set's root files (`ci/roots/`, `ci/test_roots/`) are written again by their generator.
`release/UNPUBLISHED.md` (the libraries not published, one table row each in name order) is not among
them: after a rename, re-sort its rows by hand, or `//release:unpublished_cases` refuses the order.

Each file named `mopm.toml` also gets full names (mopm's design, section 3): `[package] name =
"komira_json"` becomes `name = "komira-ai/json"`, and a `[dependencies]` or `[dev-dependencies]` key
that is an old name becomes the quoted `"komira-ai/<new>"` (a bare key, a quoted key, a dotted key,
or a `[dependencies.komira_x]` header). The rest of the file is word-replaced (`lib = { path =
"src/json" }`). It reads the manifest line by line; a line it cannot read as one of those forms is
only word-replaced.

Everything is read and every conflict checked before anything is written: two files moving to one
path, or a file moving onto a path that exists, is refused and nothing changes. A failure while
writing (a full disk) leaves a partly renamed checkout, which `git checkout` and `git clean`
restore.

## What it leaves

- Every path not in the `--files` list (untracked and ignored files), and this directory (`tools/build/ns_rename`, whose sources and
  tests hold the old names on purpose), and the mapping file wherever it is.
- `release/ci/tests/test_set_json.zig`: its member names are fixture rows that goldens taken from
  the retired release writer hash, so renaming them would break the goldens without changing what
  they check (`KEPT` in `src/tree.rs`).
- A file that is not UTF-8: listed when it holds an old name as a word, for a hand edit.
- Listed entries that are not regular files (symbolic links, a submodule's directory): listed.
- Words that are neither an old name nor derived from one as above: `komira_json_index`,
  `komira_json_v1`, `libkomira_json`, `libkomira_json_gen`, `KOMIRA_JSON`.
- Hashes and generated files that depend on the text it changes (`buildrules.mojo.lock.bzl`,
  `mopm.lock`): the pull request that applies the rename regenerates them with the tools that own
  them.

## The summary

The summary lists the packages renamed, the files moved (with the test files moved off their package's new name), the files rewritten (with
the files whose rows were sorted again) and the lines changed,
by kind (`.mojo` with its import lines, BUCK and `.bzl`, `mopm.toml` with the names and keys set to
full names, other) and by top-level directory, then the files left unchanged and the `.mojo` files
that import a renamed module by its own name (`import komira_x`, which binds the name) and already
use the new name as a word: the places a renamed module name could meet a local name.

## Tests

The crate's inline `#[test]`s (`komira_ns_rename_unit`, welded to the library) cover each module:
`names` (the lists and the grammar), `words` (whole-word replacement), `rows` (the sorted blocks), `map` (the checked-in mapping
and each refusal), `manifest` (each manifest form), `report` (the summary), `error` (each message),
and `scenario_tests`, which writes small checkouts into a scratch directory of each test's own and
runs the whole rename over them: the result file by file (with the derived words and the test
file named after its package's new name), a dry run that writes nothing, each
refusal leaving the checkout unchanged, a second run refused, and the command line.

## Why Rust

Build tooling here is Zig by default (`tools/build/README.md`); mopm's design names this tool a Rust
binary, and it uses the standard library only, so it builds with Cargo as well as Buck2 and needs
no new vendored crate.
