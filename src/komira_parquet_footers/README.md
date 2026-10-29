# komira_parquet_footers

The one Parquet footer cache, and the footer reader the SQL binder and
lowering both read from. A file's footer is read from storage once; the plan
the binder saw and the plan the host lowers are built from that one read
(`docs/design/lowering_and_pipeline.md`, section 6.2).

| module | does |
|---|---|
| `footer_cache` | `FooterCache`: a locked cache of parsed footers over `komira_parquet.ParquetMetadataCache`. A copy is another handle on the same cache. Its errors name the file. It stamps each file's identity (size, modification time, inode, device) before reading it, so `changed_since_read` says whether the file at a path is still the one whose footer was cached |
| `parquet_footers` | `ParquetFooters`: `komira_sql.SqlParquetFooters` over a `FooterCache`, so `bind_statement(stmt, catalog, footers)` binds off real footers. `register_parquet_table` takes a table's schema from the footer; `check_registered_schema` and `check_catalog_table` refuse, by table, file and column, a registered schema that disagrees with the file |
| `lowering_facts` | `add_parquet_scan`, `add_read_parquet_scan`, `add_catalog_scan`: append one scan's facts to `komira_lowering.LoweringInputs` from the same cache |

```text
from komira_parquet_footers.parquet_footers import ParquetFooters, register_parquet_table
from komira_parquet_footers.lowering_facts import add_catalog_scan
from komira_lowering.lowered_plan import LoweringInputs
from komira_sql.sql_binder import bind_statement
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import tokenize

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

## Why a package of its own

The design puts `ParquetFooters` and the footer cache in `komira_sdk_exec`
beside `EngineContext`. The context is not written yet, and a cache that the
context will hold must exist before it. So the cache lives here, in a package
that depends on `komira_sql` and `komira_lowering` and on neither the context
nor the executor. When `EngineContext` lands it holds a `FooterCache` (or a
`ParquetFooters`, whose `cache()` returns a handle on the same cache) and
passes `ctx.footers` to `bind_statement` and the same cache to
`lowering_facts`.

## Limits

- A glob path is refused by name (`footer_schema` of `data/*.parquet`): a
  glob's footers are not unioned by name yet. A table naming several files is
  not checked by `check_catalog_table`, and lowering refuses a scan of several
  files.
- `ScanFacts.dict_encoded_columns` is left empty. The footer reader does not
  parse the page encoding statistics that tell a column stored entirely
  dictionary encoded from one that fell back to plain pages, so no column is
  claimed; every column lowers by value, which is correct.
- The cache has no size cap or eviction yet (`ParquetMetadataCache` keeps one
  entry per path for its life), and a hit does not re-stat the file.
  `changed_since_read` is the check, and the source's check at open (design
  section 3.4) is the engine's.
- Flat files only: a nested or repeated column is refused by name.

## Tests

The tests run when the package is built.

- `test_footer_cache`: the footer of a written file (schema, row count, row
  groups), one read for many lookups and handles, two files cached apart,
  named errors for a missing, text and short file, no cached failure, change
  detection, invalidation, null counts summed over every row group (unknown
  when one records none), a glob refused.
- `test_bind_and_lower`: `bind_statement` and `lower` over a real footer for a
  registered table and for `read_parquet(...)`, one read for both, the
  statistics in the inputs, a registered schema that disagrees refused by
  name (count, name, type, nullability), a missing or text file named at bind.
