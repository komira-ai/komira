# The komira_core split: gates and tools

`src/komira_core` is replaced by smaller packages, each created by its own pull
request as a copy of the modules it takes, and the importers are repointed
afterwards. Until `src/komira_core` and `src/komira_core_ffi` are deleted, the
files here keep both frozen and the copies exact. All of it is deleted with
them.

| file | what it is |
| --- | --- |
| `split_map.tsv` | one row per file of `src/komira_core`: where it goes, or why it does not |
| `libc_rename_map.tsv` | the same for `src/komira_core_ffi`, which becomes `komira_libc`; `komira_libc` also takes the four `komira_posix_io` modules, their six tests and the 19 POSIX symbols of the C shim from `split_map.tsv` (there is no `komira_posix_io` package) |
| `core.sha256`, `libc.sha256` | the recorded digest of each frozen package (`defs.bzl` says how it is computed) |
| `owners.tsv` | which branch may rewrite the importers of which package |
| `split.py` | derives the modules and tests of the new packages from the map, rewriting imports |
| `repoint.py`, `repoint_selftest.py` | rewrites the importers of `komira_core` and `komira_core_ffi` in place onto the new packages (imports, `BUCK` deps, mentions in text), on main or on an open branch, and can be run again; the self-test seeds each case and a second run that must change nothing |
| `split_selftest.py` | seeded import statements and the line `split.py` must write for each, including `from .. arrow.x` (blanks after the dots, which Mojo accepts) |
| `gen_build.py`, `deps.py` | write each package's `BUCK`, `__init__.mojo` and `README.md`; the deps come from the generated files' imports and `external_call` strings, never from `:komira_core` |
| `packages.tsv`, `c_symbols.tsv` | the one sentence of each package; which package owns each C symbol of the shim |
| `deps_selftest.py` | seeded packages with and without a local C library: what `check.py deps` must accept and must still reject |
| `check.py` | `digest`, `map`, `copy`, `copy_range`, `deps` and `importers` checks, each exiting 1 when red |
| `defs.bzl`, `BUCK` | the test targets `core_frozen`, `libc_frozen`, `map_total`, `libc_map_total` |
| `no_mixed_closure.sh` | no target may depend on a package and on its replacement; `--selftest` proves it can fail |
| `fixture/` | the seeded targets of that self-test |

Run the Buck gates with `./buck2 test //tools/core_split/...`, and the closure
check with `tools/core_split/no_mixed_closure.sh`. The remaining gates read
history or the whole tree and run in `.github/workflows/core_split.yml`.

## Repointing importers (`repoint.py`)

```sh
python3 tools/core_split/repoint.py --dry-run --report /path/to/report.txt   # what it would do, over the whole tree
python3 tools/core_split/repoint.py --only src/komira_orc --exclude src/komira_compiler   # do it, for some paths
python3 tools/core_split/repoint.py --strict                                 # exit 1 on an unresolved name or a left-over import
python3 tools/core_split/repoint_selftest.py                                 # the self-test
```

- A name imported through a re-exporting `__init__.mojo` is resolved to the module that defines it, so
  `from komira_core.arrow import Column, Schema` may become two statements in two packages.
- The `BUCK` deps of a package are the packages its own files import plus the owners of the C symbols they call
  (`c_symbols.tsv`), so the set is minimal and no `komira_core` edge is left. A package whose `deps` are
  written on one line stays on one line.
- It is safe to run on an open branch: a file that is already repointed is not touched, and a second run changes
  nothing. Once `src/komira_core` is deleted the tool reads it from the parent of the commit that deleted it.
- `--renames` also performs the package renames listed in `RENAMES` (directory, imports, labels, text); a rename the
  tree has already done is honoured without the flag.
- The report separates the **import and dep** lines that are left (these must be zero) from **prose** mentions in
  comments and documents, which only a person can reword.

## What the checks do and do not prove yet

- **`deps_derived`** (`check.py deps`): each package's `BUCK` deps equal the deps derived from its own files, and every
  `komira_` symbol of the C shim has an owner in `c_symbols.tsv`. It reports NOT CHECKED, not GREEN, while no derived
  package exists. **Package-local C libraries:** a package that owns C symbols carries a hand-added `cxx_library` in its
  own `BUCK` (`komira_libc`, `komira_concurrency`, `komira_scan_source`) and its `mojo_library` depends on it as
  `":name"`. That edge cannot be derived from files, so the check accepts exactly a `":name"` dep that is a `cxx_library`
  of the same `BUCK`, whose every src is a C file under `native/` (given directly or as `:<staged_files>[native/x.c]` of
  that `BUCK`, which must name the file), and every `komira_` symbol of which `c_symbols.tsv` gives to this package. It
  also requires that library: if the package's files call a symbol the package owns, some accepted local library must
  define it. Everything else stays an extra dep and is RED (an `//src/...` dep that is not derived, a `":name"` that is
  not such a `cxx_library`, a library with a source outside `native/`, a library defining a symbol of another package or
  of no row). `deps_selftest.py` seeds each of these cases and fails if one gets the wrong verdict. Not generated: the
  `cxx_library` of the three symbol owners and the two `komira_arrow_ipc` extras (`large_writes_check`, the
  `arrow_types.mojo` data of the census test); the commits that make those packages add them.
- **`copy_exact`** (`check.py copy_range`): a commit with a `Core-Split-Copy: <package>` trailer must equal what
  `split.py` generates from the `src/komira_core` of the same commit. A range with no trailered commit is reported
  NOT CHECKED, never GREEN; on events other than a pull request the range is the whole history.
- **`no_mixed_closure`** is a `buck2 cquery` (a `uquery` over `//src/...` fails on `komira_core_posix`, and a failed
  query exits 3, never an empty answer). **It compares nothing in this pull request**: no derived package exists yet,
  so the first query has an empty set on one side (`--selftest` seeds only a fixture). **The first S2 pull request must
  add the real-package seed**: a scratch target depending on both `//src/komira_core:komira_core` and the new package,
  which must turn the check red (exit 1), then removed again. It was proved with a seed on generated `komira_collections`.
- **Importer checks**, one marker per word because the two words are repointed at different times:
  `libc_importers_enforced` is added by S3.0 (the repoint of the one `komira_core_ffi` importer) and turns
  `komira_core_ffi` on; `core_importers_enforced` is added at S4, with the repoint of the two design documents that
  still name `komira_core` and the deletion of `src/komira_core`. An absent marker is reported NOT ENFORCED.

## What was proved without GitHub Actions

`core_split.yml` has never run: it was not dry-run in a scratch repository. Every step was emulated
locally, from the same commands the workflow runs (`check.py copy_range`, `check.py deps`, `check.py importers`,
`no_mixed_closure.sh`, `./buck2 test //tools/core_split/...`), each with a seeded red case. What stays unproven until
the workflow runs for real: the YAML itself (the event and secret plumbing, the `fetch-depth` history on the farm
runner, `$RUNNER_TEMP`), and `core_frozen_vs_F`, which needs the history of the commit that records the digests.
