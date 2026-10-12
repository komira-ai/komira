# komira_op_typed_source_api

The contract of the engine's typed sources. A typed source is the
compile-time handle that rides from READ to MATERIALIZE next to the
source-erased plan: it carries one concrete file system as a type, so a
binary names only the file systems and formats it reads. The package root
re-exports nothing; import from the modules.

- `komira_op_typed_source_api.typed_source`:
  - `trait TypedSource`: `comptime Fs: FileSystem`,
    `comptime supports_fused_join_probe` (False by default), `clone`,
    `descriptor`, the collect leaf `materialize_into_source`, the grouped-agg
    leaves `resolve_agg_scan_schema` and `materialize_agg_into_source`, and
    three decline-returning hooks whose default bodies return None
    (`try_materialize_extended_agg_sink_source`, `try_clone_fs`,
    `try_materialize_agg_over_join_into_source`), plus
    `contribute_flat_plan`, whose default returns a Flat placeholder scan of
    `descriptor()`.
  - `trait SourceReader`: `comptime Fs`, `comptime Source: TypedSource`,
    `build_source` (consumes the reader, returns the live source) and
    `build_scan_plan(path)` (the lazy scan node).
  - `FlatContribution`: a contributed flat `LogicalPlan`, or a decline with a
    reason.
  - The leaf aggregation's RADIX-by-rows decision:
    `_leaf_agg_radix_by_rows_decision(total_rows, group_estimate, min_rows,
    min_groups)` is true when `total_rows >= min_rows` and the group estimate
    is not provably low (`0 <= group_estimate < min_groups`; -1 means
    unknown and admits). The defaults are `_LEAF_AGG_RADIX_MIN_ROWS_DEFAULT`
    (500,000) and `_UNTYPED_AGG_RADIX_DOMAIN_CROSSOVER` (5,000).
- `komira_op_typed_source_api.csv_typed_source`: `CsvSource[FS]`,
  `CsvReader[FS]` and `default_local_csv_reader`.
- `komira_op_typed_source_api.jsonl_typed_source`: `JsonlSource[FS]`,
  `JsonlReader[FS]` and `default_local_jsonl_reader`.
- `komira_op_typed_source_api.avro_typed_source`: `AvroFileSource[FS]`,
  `AvroReader[FS]` and `default_local_avro_reader`.

The three row-format readers build a lazy scan plan from the file's header
or a bounded sample (CSV: header and sample; JSONL: a 256 KiB leading prefix
snapped to the last newline; Avro: the OCF header) and never decode the whole
file at read time. CSV and JSONL inputs may be compressed (`.gz`, `.zst`,
`.lz4`). Their sources raise from the column collect and grouped-agg leaves:
a row-format scan is executed by the row-streaming driver, not by those
leaves.

The parquet conformer (`TypedParquetSource`, `ParquetReader`) is not in this
package; it depends on this one.

## Examples

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_op_typed_source_api.typed_source import FlatContribution, _leaf_agg_radix_by_rows_decision

# RADIX by rows: 6M rows with an unknown group count (-1) engage; 10 provable
# groups decline; below the rows threshold stays FLAT.
assert_true(_leaf_agg_radix_by_rows_decision(6_000_000, -1))
assert_false(_leaf_agg_radix_by_rows_decision(6_000_000, 10))
assert_false(_leaf_agg_radix_by_rows_decision(499_999, -1))
# The thresholds are parameters.
assert_true(_leaf_agg_radix_by_rows_decision(1_000, -1, min_rows=1_000))
assert_true(_leaf_agg_radix_by_rows_decision(6_000_000, 10, min_groups=5))

# A source that cannot be flattened declines, with a reason.
var c = FlatContribution.decline("residual SEMI join")
assert_true(c.is_declined())
assert_equal(c.reason(), "residual SEMI join")
```
