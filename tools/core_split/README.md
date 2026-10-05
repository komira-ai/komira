# Repointing a branch that still imports `komira_core`

`src/komira_core` and `src/komira_core_ffi` are deleted: their modules live in the
smaller packages the split made (`komira_arrow`, `komira_buffer`, `komira_collections`,
`komira_plan_expr`, ... and `komira_libc`, which `komira_core_ffi` became). A branch
that was opened before the delete, or that was written from an old checkout, may still
import them. This directory is the tool that rewrites such a branch in place, and the
data it reads. Nothing else here is needed to build the repository.

| file | what it is |
| --- | --- |
| `repoint.py` | rewrites the importers in place (imports, `BUCK` deps, mentions in text), `--check`s that nothing names `komira_core`, and does the package renames |
| `repoint_selftest.py` | seeds each case the tool must handle; a second run must change nothing, an unresolvable import must be red |
| `split.py`, `split_selftest.py` | the import rewriting it is built on (a name imported through a re-exporting `__init__.mojo` is resolved to the module that defines it), and its self-test |
| `deps.py` | derives a package's `BUCK` deps from its own files |
| `split_map.tsv` | one row per file `src/komira_core` had: where it went, or why it did not |
| `libc_rename_map.tsv` | the same for `src/komira_core_ffi`, which became `komira_libc` |
| `c_symbols.tsv` | which package owns each C symbol of the shim the old package carried |
| `renames.tsv` | packages renamed after they were created (the maps keep the old names) |

## Run it on a branch

```sh
git merge origin/main                     # a branch that does not have the delete yet keeps its own src/komira_core
python3 tools/core_split/repoint.py --dry-run --report /path/to/report.txt   # what it would do
python3 tools/core_split/repoint.py                                          # do it, then commit the result
python3 tools/core_split/repoint.py --check                                  # exit 1 if a file still names komira_core
python3 tools/core_split/repoint_selftest.py                                 # the self-test
```

- A name imported through a re-exporting `__init__.mojo` is resolved to the module that
  defines it, so `from komira_core.arrow import Column, Schema` may become two
  statements in two packages. Relative imports are left alone.
- The `BUCK` deps of a package are the packages its own files import plus the owners of
  the C symbols they call, so the set is minimal and no `komira_core` edge is left.
- It is safe to run again: a file that is already repointed is not touched, and a second
  run changes nothing. On a tree without `src/komira_core` it reads the old package from
  the parent of the commit that deleted it (`--core-rev` names another).
- `--only PREFIX` and `--exclude PREFIX` limit it to some paths; `--strict` exits 1 on an
  imported name it cannot resolve or an import it leaves.
- `--renames-only` performs the renames in `renames.tsv` (directory, imports, labels,
  text); a rename the tree has already done is honoured without the flag.
- `--reword-prose` also rewrites the comments that still name `komira_core`
  ("lives in `komira_core`" names the package of the file, anything else says "the core
  packages"). Markdown, string literals and code are reported for a person.

`.github/workflows/repoint_tool.yml` runs the self-tests and `--check` on every pull
request, so a branch that adds an import of `komira_core` is red until it has been
repointed. The directory can be deleted once no open branch predates the delete.
