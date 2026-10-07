# komira_test_python

The tests of the hermetic Python ([tools/build/python](../../../../tools/build/python/README.md),
pins in [third_party/python](../../../../third_party/python/README.md)). Most
are `py_test`s: building the target runs the script with the pinned
interpreter on the farm, and the target exists only if the script passed. A
`python_oracle` exists only if its two runs wrote the same tree, and the
Mojo library only if its welded test passed.

```sh
./buck2 build komira//src/tests/helpers/komira_test_python:smoke
```

| target | what it proves | the defect it catches |
|---|---|---|
| `:smoke` | every pinned wheel imports (protobuf's native `google._upb._message` too, which `import google.protobuf` does not load), and the interpreter's version and each distribution's version (its `__version__`, or its metadata where it has none) are exactly the pins; the distributions checked are exactly the pinned ones | a pin whose bytes are another release; a wheel that does not import (a missing dep, a library it cannot load); a wheel pinned without being checked |
| `:oracle_demo` | DuckDB computes `SUM(v)` over the rows 10, 20, 30 as exactly 60; pyarrow writes a two-column batch (int64 with three values, string with a null) as an IPC stream to a file and reads back the same schema and values | an oracle that does not run, or answers wrongly, in the hermetic interpreter |
| `:missing_module` | a script importing `requests`, which no pinned wheel installs, fails with exactly `ModuleNotFoundError: No module named 'requests'` (`expect_error`) | a module reaching the script from outside the closure (the worker's or the archive's site-packages) |
| `:isolation` | `sys.executable`, `sys.prefix` and every `sys.path` entry are under the action's `buck-out/`; no `PATH` entry is outside the action; the archive's site-packages is not on `sys.path` and pip is not importable; with pyarrow (with Flight and Parquet), DuckDB, numpy, pandas, polars, grpc and protobuf imported (protobuf through `descriptor_pb2`, which loads its upb backend), a shared object of each of `_duckdb`, `_polars_runtime_32`, `google._upb`, `grpc`, `numpy`, `pandas` and `pyarrow` is mapped, and no file is mapped from the worker except glibc's libraries | a host interpreter or host packages on the path; a native module the imports never load, so that its libraries go unchecked; an extension module loading the worker's `libstdc++.so.6` or `libz.so.1`; the worker's locale files |
| `:licenses` | the licences of the interpreter and the wheels are those [recorded](../../../../third_party/python/README.md#licences): each installed distribution is pinned, a declared `License-Expression` equals the pin, no licence file is the AGPL, and the files naming a GNU licence (and the bundled GCC libraries) are exactly the reviewed list in [`BUCK`](BUCK) | a pin bump that changes a licence or brings a GPL or AGPL component unreviewed; a reviewed entry left behind when its file goes |
| `:runner_cases` | `pyrun.py`, the runner of every `py_test`, run as the action runs it on the scripts of [`cases/`](cases/): a pass writes the marker; an exception and a non-zero `sys.exit` fail with `pyrun: <script> failed: <line>`; `expect_error` passes only on the exact line, and fails on a prefix of it, on another error and on a script that passes | a runner that turns a failing script green, so that every `py_test` would pass |

| `:golden_sums`, `:golden_sums_twin` | `python_oracle`s: DuckDB sums `oracle_data/scores.csv` (checked-in test data) per team into `sums.tsv` and counts its rows into `summary/count.txt`; each builds only if its two runs wrote the same bytes | an oracle whose output is not reproducible |
| `:oracle_twins` | the two oracles above, two actions with the same script and inputs, wrote the same tree byte for byte | an oracle whose output depends on the action that ran it, which the two runs inside one action cannot see |
| `:oracle_cases` | `oracle_run.py`, the runner of every `python_oracle`, run as the action runs it on the scripts of [`oracle_cases/`](oracle_cases/): a deterministic tree passes (with and without `outs`), its data file arrives and the scratch directory is emptied; a set of 64 strings written in iteration order passes, which needs the fixed hash seed; a clock, the output path, a file only one run writes and an executable bit only one run sets fail with `python_oracle: two runs of <script> differ at <path>: <what>`; a symlink, nothing written, a file `outs` does not declare (or a directory named as an out), an out not written, an exception, an exit status that only the second run returns (`second_fails.py`) and a killed run each fail with their exact line | a runner that lets a non-reproducible output through, or turns a failing oracle green |
| `:komira_test_python` | a welded Mojo test reads `:golden_sums[sums.tsv]` and the whole `:golden_sums` directory as declared `test_data`, and finds the sums worked out by hand from the CSV | an oracle's output that a Mojo test cannot stage, or a sub-target naming another file |
| `:protobuf_gencode` | the pinned protobuf runtime imports `gencode_probe_pb2`, which the pinned protoc generated (`python_proto`) and which records gencode 5.29.1, with its upb backend, and parses fixed wire bytes to the values they encode and back to the same bytes | a protobuf pin that refuses the gencode of the repository's protoc (the runtime's `VersionError`), or a protoc bump that changes the gencode unnoticed |

The mutants each was seen red against are in the pull request that added
them.
