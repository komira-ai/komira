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
| `split_selftest.py` | seeded import statements and the line `split.py` must write for each, including `from .. arrow.x` (blanks after the dots, which Mojo accepts) |
| `gen_build.py`, `deps.py` | write each package's `BUCK`, `__init__.mojo` and `README.md`; the deps come from the generated files' imports and `external_call` strings, never from `:komira_core` |
| `packages.tsv`, `c_symbols.tsv` | the one sentence of each package; which package owns each C symbol of the shim |
| `deps_selftest.py` | seeded packages with and without a local C library: what `check.py deps` must accept and must still reject |
| `check.py` | `digest`, `map`, `copy`, `copy_range`, `deps` and `importers` checks, each exiting 1 when red |
| `defs.bzl`, `BUCK` | the test targets `core_frozen`, `libc_frozen`, `map_total`, `libc_map_total` |
| `no_mixed_closure.sh` | no target may depend on a package and on its replacement; `--selftest` proves it can fail |
| `fixture/` | the seeded targets of that self-test |

Run the Buck gates with `./buck2 test //tools/core_split/...` (they also run in
`./buck2 test //...`). **No workflow runs the rest, and no pull request check
does:** the gates that read history or the whole tree (`core_frozen_vs_F`,
`copy_range`, `importers`) are retired with the cutover that deletes
`src/komira_core`, which was their only subject, and `no_mixed_closure` is red
on `main` until then. Run them by hand when a split step needs them:

```sh
tools/core_split/no_mixed_closure.sh --selftest   # prove the check can fail
tools/core_split/no_mixed_closure.sh              # check the tree
python3 tools/core_split/check.py copy_range --repo . --base <base> --head HEAD ...
python3 tools/core_split/check.py deps --tree . --map tools/core_split/split_map.tsv --core src
python3 tools/core_split/check.py importers --root . --word <komira_core|komira_core_ffi> ...
```

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
  `arrow_types.mojo` data of the census test); the commits that make those packages add them. Added by hand later, not
  from `komira_core`: `komira_collections`' `hyperloglog.mojo` and `tests/test_hyperloglog.mojo`. A re-run of
  `gen_build.py` drops that test from the `BUCK` `test_srcs`, and `check.py copy` reports the module as an extra.
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

`core_split.yml` (now deleted) never ran. Every step was emulated
locally, from the commands it ran (`check.py copy_range`, `check.py deps`, `check.py importers`,
`no_mixed_closure.sh`, `./buck2 test //tools/core_split/...`), each with a seeded red case. `core_frozen_vs_F` stays unproven: it needs the history of the commit that records the digests.
