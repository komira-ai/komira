# mopm_migrate

Moves one komira Mojo library (`src/<name>`, built by `mojo_library`) onto buildrules'
`mojo_package` and a mopm package, the way the hand migrations did (`komira_resources` is the worked
example: a library with a dependency). It derives what the old files state, writes what the
migration needs and refuses, with a message that names the file and the fact, whatever it would have
to guess.

```sh
./buck2 build komira//tools/build/mopm_migrate:mopm_migrate --show-output
mopm_migrate --package komira_example --description "One sentence for mopm." --mopm 0.0.86 --dry-run
mopm_migrate --package komira_example --description "One sentence for mopm." --mopm 0.0.86
```

Run it from the repository root (or pass `--repo <dir>`). The flags:

| flag | meaning |
|---|---|
| `--package <name>` | the directory name under `src/` (also the import name and the target name) |
| `--description <text>` | the sentence in `mopm.toml`; required, because no old file states it |
| `--dry-run` | print the whole plan and write nothing |
| `--mopm <version>` | required, no default: the mopm of `mopm-toolchain.toml` and of `mojo_conda`. Pass the version the repository builds with, the `MOPM` of `release/readme_e2e/packages.bzl` without its `toolchains//:mopm_` prefix and with dots (`//tools/build/lint:one_mopm` refuses a package that names another) |
| `--test-layout installed\|default` | required when the old file has `test_data` or `test_env`: the layout the test runs in is not in the old file (`installed` when the test reads `share/`) |
| `--dev-dependencies` | write the dependencies only the tests import as `[dev-dependencies]` (see below) |

## What it does

Without `--dry-run` it runs the `git mv`s, writes the files and `git add`s the new ones. It
commits nothing and never rewrites history. The plan:

1. **Move** every library `.mojo` file (everything that is not under `tests/`) to
   `src/<name>/src/<name>/`, keeping its relative path. `tests/`, `README.md`, `coverage_census.tsv`,
   `coverage_held` and fixtures stay. For each moved file it then prints the lines of the repository
   that still name the old path (`git grep`): those are edits for the author, because the right
   edit depends on the file (a hold table, a doc link, a BXL case).
2. **`mopm.toml`**: `[package]` as the recipe has it (version `0.1.0`); `[dependencies]` are the
   packages the library sources **import**, as sibling path dependencies with the range
   `MAJOR.MINOR` of the dependency's own version (`version = "0.1"`: any 0.1.x, never an exact pin);
   `[dev-dependencies]` the packages only the tests import; `[targets]` is `src/<name>` and `tests`.
   The BUCK `deps` are checked against the imports and must agree in both directions. An import
   counts for every module of an `import a, b` list; a name after `from m import` is not a module.
3. **`mopm-toolchain.toml`** and **`mopm.lock`** (the toolchain pins and one `path` row per package
   of the dependency closure, with `deps` for a package that has some).
4. **`BUCK`**: `mojo_package` (with `test_data`, `test_env` and the stated `test_layout` carried from the
   old file as written), `mojo_adopted_library(deps = ...)`, the helper `mojo_binary` targets kept (a
   dependency label that is an alias of a migrated package is written as `//src/<dep>:<dep>`),
   `mojo_conda` (`dir` and `members` when there are dependencies), `mojo_conda_holds` (the direct
   dependencies, `>=MAJOR.MINOR,<MAJOR.MINOR+1`) and the old `conda_package`. The comment above the old
   `mojo_library` is kept above `mojo_package`; the other comments are written by the tool.
5. **`README.md`**: a `## Build files` section is appended.
6. **Shared rows**, each inserted at its sorted place: `release/readme_e2e/packages.bzl` and
   `release/mopm_native_ids.bzl` (the `load` and the row). It does not edit `ci/targets.bzl` or its
   shards: those are generated (see below).

What it leaves to the farm, and prints: `buildrules.mojo.bzl` and `buildrules.mojo.lock.bzl`
(`buildrules mojo sync`, the recipe's step 4), `coverage_floor.txt` (a measure), and the regeneration of the
`ci/targets` rows (`:ci`, `:conda_holds`, `:coverage_floor`, `:table` of the package): the plan prints the
command for the layout it finds, `./buck2 bxl komira//tools/build/ci/targets.bxl:generate > ci/targets.bzl`
for one file, `out=$(./buck2 bxl komira//tools/build/ci/targets.bxl:generate) && [ -d "$out" ] && [ "$out" != / ] && cp -rL --no-preserve=mode "$out"/. ci/`
for the sharded layout (`ci/targets/shard_<n>.bzl`; the form refuses an empty or missing generator output, which a bare `"$(...)"/.` would turn into a copy of `/`), then `guard.bxl:check`. The tool builds and runs nothing.

## What it refuses

| class | the refusal names |
|---|---|
| an import that maps to no package | the file and the module (`there is no src/<module>/BUCK`) |
| a dependency still on `mojo_library` | the module: migrate it first |
| native code | a C or archive file in the package, a `native*`/`dlopen`/`c_deps` attribute, a `native*` rule, a `DLHandle` or `OwnedDLHandle` in code of any `.mojo` file of the package (a library loaded at run time; comments and docstrings do not count) |
| a dependency with natives the hand migrations do not cover | a package of the dependency closure whose manifest has a `[native-dependencies]` table or a `[native.<id>]` table that is not `kind = "static"`; a package with static natives that only the tests reach (`[dev-dependencies]`) |
| a BUCK file it cannot read as data | the line: a variable, a comprehension, an operator between values, `def`, a triple-quoted string, an escape it does not decode |
| what the recipe does not cover | another rule or load, another `mojo_library` attribute (`test_defines`, `import_name`, ...), a `srcs` that is not the standard glob, a `visibility` that is not `["PUBLIC"]` |
| files and BUCK that disagree | `deps` or `test_deps` that differ from the imports, a `test_srcs` that is not the `tests/test_*.mojo` files |
| an unstated choice | `test_data`/`test_env` with no `--test-layout`; a test-only dependency with no `--dev-dependencies`; no `--description` |
| a file `git mv` cannot move | a library `.mojo` file that git does not track (checked with `git ls-files` before the first move, in the dry run too: nothing has moved when it refuses) |
| a tree that is not a plain migration | already migrated, a `src/` or `generated/` directory in the package, a `README.md` that is missing or has a `Build files` section |

A dependency that declares only static natives (`[native.<id>]`, `kind = "static"`) is not refused,
whether the package imports it or reaches it through another dependency (`komira_libc` through
`komira_buffer`). The package owns no C, so it names no `c_deps`; the plan gives its
`mojo_adopted_library` the attribute the hand migrations of such dependents carry,
`cxx_toolchain = "komira//tools/build/mojo:adopt_cxx_link_facts"`, with a comment naming the package(s) that
link C, so a dependent's link takes the archive from the closure. Nothing else changes: `mopm.toml`, `mopm.lock`
and the `members` of `:conda` are the same as for a dependency with no natives, and the README section gains one
sentence naming the package(s).

`[dev-dependencies]` is behind a flag because no migrated package has one: its lock rows and the
sync's workspaces are unverified by a hand migration.

It also prints a note, and does not refuse, when the comment kept above `mojo_package` says the
package has no dependencies (`no dependencies`, `dependency-free`, ...) and the package has some: the
tool keeps the comment as written, so the author edits it.

## Tests

`mopm_migrate_test.zig` (welded into the tool: it is built only when they pass):

- **golden** (`fixtures/komira_resources`): the tool runs on the tree `komira_resources` had before its
  hand migration, and the output must be the hand migration's: `mopm.toml`, `mopm-toolchain.toml` and
  `mopm.lock` byte for byte; the two shared rows files as the line-for-line diff the hand
  migration made (`rows/*.diff`: the output minus the added lines is the old file, in order, and each
  hunk with its context is one run of lines); the `BUCK` file with its code byte for byte and its
  comments word for word.
- **golden** (`fixtures/komira_collections`): the same for a library with a `[dependencies]` entry
  (`komira_atomic_alias`) and seven tests, from the tree before its hand migration. Three differences
  in comment words are asserted where they are tested (the old header said "no dependencies"; two
  sentences the hand file worded differently). The library sources are stored as `*.mojo.fixture`, so
  the Mojo lints do not read them.
- **golden** (`fixtures/komira_dynamic_filter`): the same for a package whose closure holds a package with
  static natives (`komira_buffer`, which reaches `komira_libc`), from the tree before its hand migration:
  `mopm.toml`, `mopm-toolchain.toml` and `mopm.lock` byte for byte, the rows as diffs, and the `BUCK` file in
  code (the `cxx_toolchain` attribute included) byte for byte and in comment words, with the differences
  asserted where they are tested. The same package with no native in the closure gets no `cxx_toolchain`.
  Refused: a closure package with `[native-dependencies]`, a native table that is not static, static natives
  reached only through `[dev-dependencies]`, and (as before) natives of the package itself.
- the documented differences of the golden: the hand migration wrapped comments by eye (the test
  compares paragraphs, not lines); it edited one path in the carried header comment (`see resources.mojo`
  became `see src/komira_resources/resources.mojo`; the tool carries the comment as written); it added a
  comment above the helper binary that the old file did not have; the rows diffs keep
  only the package's rows (the same pull request added unrelated rows); `release/BUCK` and
  `release/artifacts.textproto` are the lines that name the label, not the whole files.
- each class of refusal above, and that a refused run writes nothing (a file git does not track
  refuses before the first move: the test passes the tracked list in, the workers have no git).
- the plan writes no `ci/targets` row and names the generator for each layout.
- the dry run prints the plan and the tree is byte for byte what it was.
- a real run on a scratch tree, and a second run that refuses.
- the BUCK reader and the import scanner on their own.
