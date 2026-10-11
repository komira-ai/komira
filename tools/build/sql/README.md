# SQL oracles

[`defs.bzl`](defs.bzl) holds `sql_oracle`: SQL run by the pinned DuckDB CLI
as one build action, whose declared result files are test data for other
targets (expected query results, Parquet and CSV inputs). The binary is
pinned in [`third_party/duckdb`](../../../third_party/duckdb/README.md).
This directory is not a Buck2 package: it holds only the rules, which BUCK
files load as `@komira//tools/build/sql:defs.bzl`.

The action's executable is the `duckdb` binary itself: no wrapper script,
no interpreter, nothing from the worker but glibc (the host floor,
[toolchains](../toolchains/README.md#host-floor)). DuckDB is test-only.
Nothing built with these rules is shipped.

## Rules

| rule | what it builds |
|---|---|
| `sql_oracle(name, srcs, inputs, outputs)` | runs `srcs` (one `.sql` file, or a list run in order in one session) with the pinned DuckDB. `inputs` are the files the SQL reads: a list of sources, each staged at its path in the package, or `{path: source}`, where a build output is allowed (`{"a/rows.csv": ":write[rows.csv]"}`). `outputs` are the file names the SQL writes with `COPY ... TO '<name>'`, each ending in `.parquet`, `.csv` or `.tsv`; each is a sub-target `[<name>]`, and all of them are the default outputs. |
| `duckdb_dist(name, binary, native_libs, version)` | the pinned binary, the directory whose `lib/` holds the C++ runtime it links (`libstdc++.so.6`, `libgcc_s.so.1`), and the version it must report. `sql_oracle` takes `komira//third_party/duckdb:duckdb`. |

The macro sets `exec_compatible_with` to the linux x86_64 execution
platform: the pinned binary is the linux amd64 build.

## What an action runs

```
LC_ALL=C TZ=UTC LD_LIBRARY_PATH=<native_libs>/lib \
duckdb -no-init -batch -bail \
    -cmd ".cd <work>" \
    -cmd ".mode trash" \
    -cmd "SET threads = 1; SET TimeZone = 'UTC'; SET autoinstall_known_extensions = false;
          SET autoload_known_extensions = false; SET temp_directory = '';
          SET enable_progress_bar = false; SET allowed_paths = [<inputs>, <outputs>]" \
    -cmd "SELECT CASE WHEN version() <> 'v<version>' THEN error(...) END" \
    -cmd ".safe_mode" \
    -cmd ".mode duckbox" \
    -f ../sql/0_<src> -f ../sql/1_<src> ... \
    -cmd ".mode trash" \
    -cmd "<per output: SELECT CASE WHEN (SELECT count(*) FROM glob('<output>')) = 0 THEN error(...) END>" \
    :memory:
```

- **The database** is in memory (`:memory:`), and nothing persists between
  actions. `-no-init` skips `~/.duckdbrc`.
- **The working directory**, `<work>`, is the directory of the action's
  declared outputs; every input is copied there at its path first, and the
  SQL is copied beside it (`../sql/`). The SQL names files by their path
  there: `read_csv('data.csv')`, `COPY ... TO 'expected.tsv'`.
- **Settings.** One thread, so a result's row order and a Parquet file's
  bytes do not depend on the worker; the session time zone is UTC; no
  extension is installed or loaded on demand (the CLI's built-in Parquet,
  CSV and ICU are there); no spilling to a temp
  directory.
- **The version check**: the binary must report the version
  `komira//third_party/duckdb:duckdb` pins
  (`sql_oracle: this duckdb is <got>, the pin says v<version>`).
- **`.safe_mode`** sets `enable_external_access = false` and
  `lock_configuration = true` before any of the SQL runs. From then on:
  - the SQL can open only the paths in `allowed_paths`, its inputs and
    outputs, named exactly as staged. A `COPY` to any other file, a read of
    a file that is not an input (in the package or not), an absolute path
    and a glob pattern all fail: `Permission Error: Cannot access file
    "<path>" - file system operations are disabled by configuration`;
  - the SQL can change no setting (`Cannot change configuration option
    "threads" - the configuration has been locked`);
  - the SQL can run no dot command that reaches the system (`.shell`,
    `.system`, `.read`, `.output`, `.cd`, `.open`, `.import`).
- **`-bail`**: the first error stops the run with exit status 1, and buck2
  shows DuckDB's message.
- **Missing outputs**: after the SQL, each declared output must exist
  (`sql_oracle: the SQL wrote no <name>, a declared output`); buck2 also
  fails an action that leaves a declared output unwritten.
- The rule's own statements print nothing (`.mode trash`); the SQL's own
  results print in DuckDB's batch default, and buck2 shows them when the
  action fails.

Analysis refuses: no `srcs`, a src that is not a `.sql` file, no `outputs`,
an output that is not a plain file name (no directory, no glob character)
or does not end in `.parquet`, `.csv` or `.tsv`, an output named twice or
also an input path, an input path with an empty, `.` or `..` segment, an
input that is both a file and another input's directory, and a build output
in the list form of `inputs`.

## Expected results and row order

An oracle writes an expected query result with one `COPY` of the query,
ordered:

```sql
COPY (SELECT name, amount FROM t ORDER BY name, amount)
TO 'expected.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
```

The rule does not read the SQL, so it cannot see whether a copied query has
an `ORDER BY`, or whether that `ORDER BY` decides every row's place. One
thread makes an unordered result repeat from run to run, which hides the
gap instead of closing it. Ordering is the fixture author's duty; the
oracle datasets' own discipline check (`json_serialize_sql` over each
query) is where it is enforced.

## Tests

- [`tests//functional/sql_oracle`](../tests/functional/sql_oracle/BUCK):
  `write` writes a Parquet file, a CSV file and an expected TSV from a CSV
  input, and asserts the settings (`threads`, `TimeZone`) in force; `check`
  holds the CSV and TSV byte for byte to committed goldens, every output
  byte for byte to `write_twin`'s (the same SQL in another target: another
  action key, so another execution, which is the determinism check), and
  the Parquet rows and column types to the input. `check` runs two srcs in
  order in one session. The pull request check builds `tests//functional/...`.
- [`tests//negative/sql_oracle`](../tests/negative/sql_oracle/BUCK): the
  planted defects. The self-test scenario
  [`sql_oracle`](../selftest/sql_oracle.zig) builds the working `check`
  first, then requires each analysis refusal's message and each build's
  failure in its `sql_oracle` action with its message: an undeclared
  output, a missing output, a SQL error, a read of a package file that is
  not an input, a read of an absolute path, a changed setting and a dot
  command. A failed action is never cached, so each red is a fresh run on
  the farm.

Mutants seen red when the rule was written: `.safe_mode` dropped (five reds
of the scenario fail, four of them because the target built: `/etc/passwd`
was readable and `.shell` ran on the worker); the existence check dropped
(`missing_output` fails with buck2's message instead); `SET threads = 1`
dropped (`write` fails: `threads is 88, not 1`); a golden byte changed
(`check` fails: `differ: a/expected.tsv vs golden/expected.tsv (golden)`);
`random()` added to the Parquet query (`check` fails: `differ:
a/rows.parquet vs b/rows.parquet (twin)`); the pinned version string
changed (`this duckdb is v1.5.6, the pin says v1.5.5`).
