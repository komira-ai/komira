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
| `:oracle_demo` | DuckDB computes `SUM(v)` over the rows 10, 20, 30 as exactly 60; pyarrow writes a two-column batch (int64 with three values, string with a null) as an IPC stream to a file and reads back the same schema and values; polars takes that table from Arrow, sums `id` to exactly 6, and hands back the same values through Arrow and through pandas | an oracle that does not run, or answers wrongly, in the hermetic interpreter; pins of pyarrow, polars, pandas and numpy that do not work together |
| `:timezones` | `TZDIR` is the tzdata wheel's `zoneinfo` directory, `zoneinfo.TZPATH` is that directory alone and `TZ` is `UTC0`; pyarrow's ORC writer and reader round-trip a timestamp column (pre-epoch with microseconds, a null, the last whole second of `timestamp[ns]`) exactly, and with `TZDIR` naming an empty directory the writer raises `pyarrow.lib.ArrowException` with exactly the message `Unknown error: Time zone file <dir>/GMT does not exist. Please install IANA time zone database and set TZDIR env.`; a zoned array's `to_pylist()` in `America/New_York` gives the exact local times, offsets and folds around the 2027 spring-forward gap and fall-back fold; every file Python opens for a zone is under the action and the zone is read from `TZDIR` | a time-zone read from the worker: ORC failing for want of `/usr/share/zoneinfo/GMT` on a worker without it, `zoneinfo` searching the worker's directories first, local time from the worker's `/etc/localtime` |
| `:missing_module` | a script importing `requests`, which no pinned wheel installs, fails with exactly `ModuleNotFoundError: No module named 'requests'` (`expect_error`) | a module reaching the script from outside the closure (the worker's or the archive's site-packages) |
| `:isolation` | `sys.executable`, `sys.prefix` and every `sys.path` entry are under the action's `buck-out/`; no `PATH` entry is outside the action; the archive's site-packages is not on `sys.path` and pip is not importable; with pyarrow (with Flight and Parquet), DuckDB, numpy, pandas, polars, grpc and protobuf imported (protobuf through `descriptor_pb2`, which loads its upb backend), a shared object of each of `_duckdb`, `_polars_runtime_32`, `google._upb`, `grpc`, `numpy`, `pandas` and `pyarrow` is mapped, and no file is mapped from the worker except glibc's libraries | a host interpreter or host packages on the path; a native module the imports never load, so that its libraries go unchecked; an extension module loading the worker's `libstdc++.so.6` or `libz.so.1`; the worker's locale files |
| `:licenses` | the licences of the interpreter and the wheels are those [recorded](../../../../third_party/python/README.md#licences): each installed distribution is pinned, a declared `License-Expression` equals the pin, no licence file is the AGPL, and the files naming a GNU licence (and the bundled GCC libraries) are exactly the reviewed list in [`BUCK`](BUCK) | a pin bump that changes a licence or brings a GPL or AGPL component unreviewed; a reviewed entry left behind when its file goes |
| `:runner_cases` | `pyrun.py`, the runner of every `py_test`, run as the action runs it on the scripts of [`cases/`](cases/): a pass writes the marker; an exception and a non-zero `sys.exit` fail with `pyrun: <script> failed: <line>`; `expect_error` passes only on the exact line, and fails on a prefix of it, on another error and on a script that passes; run with no `TZDIR`, `zoneinfo.TZPATH` is empty | a runner that turns a failing script green, so that every `py_test` would pass; a runner that, given no `TZDIR`, leaves `zoneinfo` searching the worker's zone directories |

| `:golden_sums`, `:golden_sums_twin` | `python_oracle`s: DuckDB sums `oracle_data/scores.csv` (checked-in test data) per team into `sums.tsv` and counts its rows into `summary/count.txt`; each builds only if its two runs wrote the same bytes | an oracle whose output is not reproducible |
| `:oracle_twins` | the two oracles above, two actions with the same script and inputs, wrote the same tree byte for byte | an oracle whose output depends on the action that ran it, which the two runs inside one action cannot see |
| `:oracle_cases` | `oracle_run.py`, the runner of every `python_oracle`, run as the action runs it on the scripts of [`oracle_cases/`](oracle_cases/): a deterministic tree passes (with and without `outs`), its data file arrives and the scratch directory is emptied; a set of 64 strings written in iteration order passes, which needs the fixed hash seed; a clock, the output path, a file only one run writes and an executable bit only one run sets fail with `python_oracle: two runs of <script> differ at <path>: <what>`; a symlink, nothing written, a file `outs` does not declare (or a directory named as an out), an out not written, an exception, an exit status that only the second run returns (`second_fails.py`), a run killed by a signal in the first run (`killed.py`) or only in the second (`killed_second.py`), and a raw exit status other than 0 or 1 in the second run only (`exit_second.py`) each fail with their exact line; `tz.py` run with a relative `TZDIR` sees it absolute, as `zoneinfo.TZPATH` alone, with `TZ=UTC0` and no other variable beyond `LC_ALL` and `PYTHONHASHSEED`, and run with none sees an empty `zoneinfo.TZPATH` | a runner that lets a non-reproducible output through, or turns a failing oracle green; a runner that drops `TZDIR` or leaves it relative for the child, or leaves `zoneinfo` searching the worker's zone directories |
| `:orc_timestamps` | a `python_oracle`: pyarrow writes a `timestamp[us]` column (2027 instants, microseconds, a null) as ORC, which needs the `GMT` zone from `TZDIR`, reads back the same values, and finds `TZ=UTC0` and `TZDIR` equal to the tzdata wheel's `zoneinfo` directory and `zoneinfo.TZPATH` that directory alone; it builds only if both runs wrote the same bytes | a `python_oracle` rule that gives its runs no zone database (or the worker's), or ORC output that is not reproducible |
| `:komira_test_python` | a welded Mojo test reads `:golden_sums[sums.tsv]` and the whole `:golden_sums` directory as declared `test_data`, and finds the sums worked out by hand from the CSV | an oracle's output that a Mojo test cannot stage, or a sub-target naming another file |
| `:protobuf_gencode` | the pinned protobuf runtime imports `gencode_probe_pb2`, which the pinned protoc generated (`python_proto`) and which records gencode 5.29.1, with its upb backend, and parses fixed wire bytes to the values they encode and back to the same bytes | a protobuf pin that refuses the gencode of the repository's protoc (the runtime's `VersionError`), or a protoc bump that changes the gencode unnoticed |

## CPython 3.14 and free-threaded 3.14t

These run on `:cpython314` or `:cpython314t`
([third_party/python](../../../../third_party/python/README.md#cpython-314))
with its own closure. Their pinned outcomes, in [`BUCK`](BUCK), are facts
about the pinned versions, recorded so that a bump that changes one fails
until the pin says the new outcome.

| target | what it proves | the defect it catches |
|---|---|---|
| `:gil_cp314`, `:gil_cp314t` | the interpreter is 3.14.8 and a GIL build (`Py_GIL_DISABLED` unset, the GIL enabled at startup) or a free-threaded one (the GIL disabled at startup, `sys._is_gil_enabled()`); each distribution of the closure imports at its pinned version in a fresh child interpreter, whose GIL is in the build's state when it starts; the GIL's state after the import, and after importing every extension module the distribution installs, is the pinned one (`disabled`, `enabled`, or `enabled by <module>` from CPython's warning); the parser of that warning reads each kind of result, and on 3.14t the warning's text is found in the interpreter's own files (no import of the pinned closure enables the GIL, so the `enabled by <module>` reading is proved by this synthetic check, not by a real import); a child's result, and a child that exits non-zero or is killed, are read as such | a free-threaded pin that is a GIL build or the reverse; a wheel bump whose extension module stops declaring free-threading support, so that importing it puts user code meant to run in parallel back behind the GIL; a parser that misreads CPython's warning |
| `:subinterp_cp314`, `:subinterp_cp314t` | each of cloudpickle, numpy, pandas, pyarrow and scikit-learn, imported in a child process inside one own-GIL sub-interpreter (`concurrent.interpreters`), gives its pinned outcome: `ok`, or the innermost exception of the failure; the walk to that exception follows a `raise ... from` cause, an implicit context and a context `from None` suppresses, and a child killed by a signal, exiting non-zero or printing nothing is read as such, with absolute paths cut to their last component | a bump that changes which libraries a user-defined function can import in a sub-interpreter, unnoticed |
| `:licenses_cp314`, `:licenses_cp314t` | `licenses.py`, as `:licenses`, over each 3.14 interpreter and its closure | as `:licenses` |

What they measured (both interpreters alike, except the GIL's state):

| distribution | GIL after the import, and after every extension module, on 3.14t | own-GIL sub-interpreter (3.14 and 3.14t) |
|---|---|---|
| cloudpickle | disabled | ok |
| numpy | disabled | `ImportError: module numpy._core._multiarray_umath does not support loading in subinterpreters` |
| pandas | disabled | fails on numpy's module, as numpy |
| pyarrow | disabled | `ImportError: module pyarrow.lib does not support loading in subinterpreters` |
| scikit-learn | disabled | `ImportError: module sklearn.__check_build._check_build does not support loading in subinterpreters` |
| scipy, joblib, narwhals, threadpoolctl, python-dateutil, six, tzdata | disabled | not measured |

No extension module of the 3.14t closure enables the GIL.
`scipy.linalg._matfuncs_sqrtm_triu` does not import alone, on either
interpreter (a circular import with `scipy.linalg`); that is part of the
pinned outcome.

The mutants each was seen red against are in the pull request that added
them.
