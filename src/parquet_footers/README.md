# parquet_footers

The one Parquet footer cache, and the footer reader the SQL binder and
lowering both read from. A file's footer is read from storage once; the plan
the binder saw and the plan the host lowers are built from that one read
(`docs/design/lowering_and_pipeline.md`, section 6.2).

| module | does |
|---|---|
| `footer_cache` | `FooterCache`: a locked cache of parsed footers over `parquet.ParquetMetadataCache`. A copy is another handle on the same cache. Its errors name the file. It stamps each file's identity (size, modification time, inode, device) before reading it, so `changed_since_read` says whether the file at a path is still the one whose footer was cached |
| `parquet_footers` | `ParquetFooters`: `sql.SqlParquetFooters` over a `FooterCache`, so `bind_statement(stmt, catalog, footers)` binds off real footers; `parquet_relation(path, hive_partitioning)` is the source a `read_parquet(path)` scans. `register_parquet_table` registers a file, a glob or a directory; `check_registered_schema` and `check_catalog_table` refuse, by table, file and column, a registered schema that disagrees with any file of the table |
| `parquet_files` | `resolve_parquet_source`: the files a path names (a file, a glob, or with `allow_directory` every `.parquet` file below a directory), each checked against the first file's schema, with Hive partition columns |
| `lowering_facts` | `add_parquet_scan`, `add_read_parquet_scan`, `add_parquet_files_scan`, `add_catalog_scan`: append one scan's facts to `lowering.LoweringInputs` from the same cache; over several files the facts are folded |

```text
from parquet_footers.parquet_footers import ParquetFooters, register_parquet_table
from parquet_footers.lowering_facts import add_catalog_scan
from lowering.lowered_plan import LoweringInputs
from sql.sql_binder import bind_statement
from sql.sql_catalog import SqlCatalog
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize

def run(path: String) raises:
    var footers = ParquetFooters()
    var catalog = SqlCatalog()
    register_parquet_table(catalog, "t", path, footers)
    var bound = bind_statement(
        parse_sql(tokenize("SELECT sum(x) FROM t WHERE y < 5")), catalog, footers
    )
    var plan = bound.take_plan()
    var inputs = LoweringInputs()
    add_catalog_scan(inputs, catalog, "t", footers)
    # lower(plan, host_profile, inputs): the footer was read once.
```

## Several files and Hive partitions

`resolve_parquet_source(footers, path, hive_partitioning, allow_directory)`
lists the files of `path` with `fs.file_discovery.EagerGlobDiscovery` (glob
syntax of `fs.glob`: `*`, `?`, `[...]`, `{a,b}`, one `**`), sorted byte-wise.
A directory is the glob `<dir>/**/*.parquet` and skips a file or directory whose
name starts with `.`; it is allowed for registration and refused in SQL. A glob
whose braces have no wildcard (`{a,b}.parquet`) lists nothing, as `fs.glob`
lists only below a static prefix.

| refusal | when |
|---|---|
| `PARQUET_GLOB_NO_MATCH` | no file matches |
| `PARQUET_PATH_IS_DIRECTORY` | a directory where directories are not allowed |
| `PARQUET_FILES_SCHEMA_MISMATCH` | a file's names, order, Arrow type, decimal precision and scale, time zone or nullability differ from the first file's |
| `HIVE_PARTITION_LAYOUT_MISMATCH` | `hive_partitioning = true` and a file's key set differs from the first file's |
| `HIVE_PARTITION_VALUE_UNSUPPORTED` | a repeated key, a malformed escape, an empty value, `NULL`, `__HIVE_DEFAULT_PARTITION__`, or a value DuckDB's cast might read as a date, timestamp or integer that the strict forms do not |
| `HIVE_PARTITION_COLUMN_IN_FILE` | a partition key equals, ignoring case, a data column |

Hive detection follows DuckDB over the whole path: a `key=value` component
ends in `/` (the file name never counts), holds one `=` that is not its first
byte, and no `?` or newline. AUTO makes partition columns when the first file
has a key and every file has the same keys; ON also refuses a file with other
keys; OFF makes none. Columns follow the data columns, ordered by key, not
nullable. Their type is DATE, TIMESTAMP or BIGINT by the first value and falls
to VARCHAR at the first later value that does not parse as that type. The
values kept are the decoded text.

`lowering_facts` folds the statistics of every file: row counts and null counts
are summed (unknown if any file's is), the minimum is the smallest and the
maximum the largest (unknown if any file's is), and the distinct count is the
largest of the files' lower bounds. The file list is fixed when the table is
registered; each query reads the footers again and checks every file.

Refusals read as values: a glob that matches nothing, and a directory where
SQL does not allow one, in an empty temporary directory the example creates:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from std.tempfile import mkdtemp
from parquet_footers.parquet_files import resolve_parquet_source
from parquet_footers.parquet_footers import ParquetFooters
from sql.sql_ast import HIVE_PARTITIONING_OFF

var footers = ParquetFooters()
var root = mkdtemp(prefix="komira_footers_readme_")

var no_match = String()
try:
    _ = resolve_parquet_source(footers, root + "/*.parquet", HIVE_PARTITIONING_OFF, False)
except e:
    no_match = String(e)
assert_equal(no_match, "PARQUET_GLOB_NO_MATCH: no file matches '" + root + "/*.parquet'")

# `ParquetFooters.parquet_relation` is the same call with directories refused.
var is_dir = String()
try:
    _ = footers.parquet_relation(root, HIVE_PARTITIONING_OFF)
except e:
    is_dir = String(e)
assert_true(is_dir.startswith("PARQUET_PATH_IS_DIRECTORY: "))

# Registration allows a directory; one with no `.parquet` file matches nothing.
var empty_dir = String()
try:
    _ = resolve_parquet_source(footers, root, HIVE_PARTITIONING_OFF, True)
except e:
    empty_dir = String(e)
assert_equal(empty_dir, "PARQUET_GLOB_NO_MATCH: the directory '" + root + "' holds no .parquet file")
```

The facts of a scan are appended only when every footer reads. A source naming
a file that does not exist is refused naming the file and adds no scan, and a
table the catalog does not hold is refused by name:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from std.tempfile import mkdtemp
from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema
from lowering.lowered_plan import LoweringInputs
from parquet_footers.lowering_facts import add_catalog_table_scan, add_parquet_files_scan
from parquet_footers.parquet_footers import ParquetFooters
from scan_source.parquet_source import ParquetSource
from sql.sql_catalog import SqlCatalog

var footers = ParquetFooters()
var inputs = LoweringInputs()
var absent = mkdtemp(prefix="komira_footers_readme_") + "/absent.parquet"
var source = ParquetSource(absent.copy(), Schema.from_fields_1(Field("x", ArrowType.INT64, False)))

var no_file = String()
try:
    add_parquet_files_scan(inputs, footers, source)
except e:
    no_file = String(e)
assert_true(no_file.find(absent) >= 0)  # the error names the file
assert_equal(len(inputs.scans), 0)  # and no scan was added

var no_table = String()
try:
    add_catalog_table_scan(inputs, SqlCatalog(), "nope", footers, source)
except e:
    no_table = String(e)
assert_equal(no_table, "SQL bind error: unknown table 'nope'")
assert_equal(len(inputs.scans), 0)
```

## Why a package of its own

The design puts `ParquetFooters` and the footer cache in `sdk_exec`
beside `EngineContext`. The context is not written yet, and a cache that the
context will hold must exist before it. So the cache lives here, in a package
that depends on `sql` and `lowering` and on neither the context
nor the executor. When `EngineContext` lands it holds a `FooterCache` (or a
`ParquetFooters`, whose `cache()` returns a handle on the same cache) and
passes `ctx.footers` to `bind_statement` and the same cache to
`lowering_facts`.

## Limits

- `footer_schema` reads one file and refuses a glob path by name;
  `parquet_relation` reads a glob.
- Hive NULL partitions (`__HIVE_DEFAULT_PARTITION__`) are refused, not read.
- `ScanFacts.dict_encoded_columns` is left empty. The footer reader does not
  parse the page encoding statistics that tell a column stored entirely
  dictionary encoded from one that fell back to plain pages, so no column is
  claimed; every column lowers by value, which is correct.
- **The cache is unbounded.** It keeps one full `FileMetaData` per path for
  its life and finds a path by a linear scan under the lock. Design section 5.1
  asks every context cache to be capped; eviction conflicts with one version
  per path, so a cap needs a different shape (a per-query pin is the likely
  one). `sdk_exec.EngineContext` takes the per-query pin: `run_sql`
  replaces the cache with an empty one at the start of each call, so the
  context holds the files of one query only.
- **The lock is held across the file read and the parse**, so a lookup waits
  behind another path's slow read.
- **The identity check is a field comparison** (size, modification time, inode,
  device) and does not apply the settle rule of `byte_buffer.file_identity`:
  a same-size rewrite inside the timestamp tick of a file younger than the
  settle window can go unseen. Tests vary size, modification time and removal;
  the inode is not varied (no rename is available to a test).
- **The identity is checked here, not at open.** `ParquetFooters` and
  `lowering_facts` refuse a file whose identity differs from the stamp when
  they are asked for its footer. `ScanFacts` does not carry the stamp, and the
  scan reads through `parquet`'s revalidating metadata cache, so a file
  replaced after the last call here is not refused by this package. The
  check at open (design section 3.4) is planned.
  **This is a wrong-result risk, not only a missing refusal:** a file
  replaced between lowering and the scan is read with the old plan's schema
  and min/max (pruning and sink choice from version 1, data from version 2).
  The stamp is to be carried into `ScanFacts` by the `lowering` owner
  and checked by the Parquet source at open, a follow-up to slice 2b of
  section 7.3 (`SOURCE_PARQUET` checks the stamp at open), tracked in #2024;
  slice 2b landed without the check.
- The cache reads footers itself rather than through
  `ParquetMetadataCache`'s shared surface, which revalidates each hit and would
  let bind and lowering see two versions of one file. The alternative, a
  no-revalidate lookup added to `ParquetMetadataCache` under a lock wrapper,
  would give one footer cache per process; it is a change to `parquet`
  and is left for the engine context slice.
- Flat files only: a nested or repeated column is refused by name.
- A registered schema must equal the file's: names and order, Arrow type,
  decimal precision and scale, time zone and nullability in both directions.

## Tests

The tests run when the package is built.

- `test_footer_cache`: the footer of a written file (schema, row count, row
  groups), one read for many lookups and handles, two files cached apart,
  named errors for a missing, text and short file, no cached failure, change
  detection, invalidation, null counts summed over every row group (unknown
  when one records none), a glob refused.
- `test_footer_refusals`: footers built byte by byte (no schema, negative
  `num_rows`, a nested column, a repeated leaf) refused naming the file.
- `test_bind_and_lower`: `bind_statement` and `lower` over a real footer for a
  registered table and for `read_parquet(...)`, one read for both, the
  statistics in the inputs, a registered schema that disagrees refused by
  name (count, name, type, nullability), a two-file table checked file by
  file, a missing or text file named at bind.
- `test_multifile_scan`: globs, directories and their hidden and non-Parquet
  files, the named refusals above, Hive partitions (modes, key order, value
  types, refused values), a table registered over a directory and over a Hive
  tree, a disagreeing or replaced second file refused by name, and the facts
  folded over three files.
