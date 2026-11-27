# The Python package: where a change writes

Status: built.

A change to the Python package, such as a DataFrame verb with its tests, docs and changelog line,
used to edit the same lines as every other change in flight. It added a bullet under `## Unreleased`
in `python/CHANGELOG.md`, a stanza and a row next to its neighbours in `python/tests/BUCK` and
the check set's shard file, a row in `tools/build/lint/interpreter_allowlist.tsv`, an entry in
`test_srcs` of `src/sdk_exec/BUCK` with a bullet in its README, and a line in the shared verb lists of
`python/README.md` and `docs/design/dataframe_surface.md`. Two changes that were each clean against
main then conflicted with each other in the merge queue. This document records where each kind of
edit goes now. The rule throughout: a new thing is a new file, or a line of its own in a sorted list
that a check holds sorted.

## The places

| What a change adds | Where it goes | What keeps the check meaningful |
|---|---|---|
| A changelog line | a new file `python/changelog.d/<slug>.md` of bullets | `//python:changelog` assembles the release section from the files and refuses a malformed one by file and line; `//python/tests:changelog_names_test` fails when a public name of `komira` or `komira.pl` appears in no code span of the changelog text (a change that adds no name needs its fragment by review) |
| A test of a common shape | a new file in a family directory of `python/tests` (`plan/`, `run/`, `duckdb/`, `pl/`, `pl_oracle/`) | the BUCK load fails on a `test_*.py` no target runs and on two files that give one target name ([families.bzl](../../python/tests/families.bzl)) |
| A test of its own shape | a stanza in `python/tests/BUCK` | the same load check; the stanza's target joins `:all` through the registry |
| A check-set row | nothing: the one root `komira//python/tests:all` (its file `ci/roots/komira/python/tests:all`) stands for the package | `guard.bxl:check` still fails when a root is missing from `//ci:pr` |
| An interpreter file under `python/komira` or `python/tests` | nothing: the glob rows `python/komira/**/*.py` and `python/tests/**/*.py` cover them | every other interpreter file, and every non-`.py` one under those directories, still needs a reviewed row; rows are one per line, sorted and unique, and a glob row that covers no file is stale ([gates_test_welding_and_lints.md](gates_test_welding_and_lints.md)) |
| An `sdk_exec` test | a new file `src/sdk_exec/tests/test_*.mojo` whose header says what it holds | `test_srcs` of the library is a glob, so the file is welded with no list edit |
| A DataFrame or `komira.pl` feature's documentation | a page of its own under `python/docs/dataframe/` or `python/docs/pl/` | `//:docs` resolves every link; the README links the directories, not each page |
| What is built and what is not | its row of [dataframe_surface_verbs.md](dataframe_surface_verbs.md) | the Status paragraph of [dataframe_surface.md](dataframe_surface.md) points to that table instead of listing verbs |

## The changelog at release

`python/CHANGELOG.md` holds a preamble and the sections a maintainer keeps. `//python:changelog`
writes the file the wheel describes: the kept sections, preceded by a section for the release being
built, `## 0.1.<n>` when the build is stamped and `## Unreleased` when it is not, whose bullets are the
fragments in name order. The wheel's description is `README.md` followed by that changelog, one heading
level down. Fragments are not deleted at release: a maintainer keeps a section by moving its bullets
under a version heading and deleting the files in one change, and until then each release lists every
change since the newest kept section.

## How a change in flight moves

A change that edited the old places rebases like this: its `## Unreleased` bullet becomes a file of
`python/changelog.d/`; its test file moves to the family directory whose dependencies and Python
versions it uses, and its stanza and shard rows are dropped (a test with inputs no family has keeps a
stanza); its allowlist row for a `.py` file under `python/komira` or `python/tests` is dropped; its
`test_srcs` entry is dropped and its README bullet becomes the test file's header; and its README or
design-doc verb text becomes a page under `python/docs/` and a row of the capability table.
