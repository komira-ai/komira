# komira_parquet_scan

The engine side of the Parquet scan: what a scan's morsel source drives to
read a Parquet file's row groups as Arrow batches, prune them, and decode
only the rows and columns a query needs. The format itself (the decoders,
the footer, the page indexes) is in `komira_parquet`; this package adds the
per-worker reading, the pushed filter's decode and the engine hand-offs. It
depends on no operator package.

- `parquet_reader`: `ParquetReader[FS]`, the scan's per-(worker, file)
  reader, a `komira_scan_planning` `Reader`. It holds the file, the parsed
  footer (shared by every worker's reader of the file), a page-index cache
  and a reusable decode context (per worker). It answers footer questions
  without I/O (row counts, byte ranges, whether a column's selective decode
  pays, statistics and bloom-filter prunes) and decodes a row group's
  columns: whole, by name into a result schema, for the rows a mask keeps,
  as dictionary codes counted or filtered without building values
  (`fused_dict_count`, `fused_dict_survivors`), for a single-INT64-key hash
  aggregate with the key's hashes, and after a page-index prune
  (`decode_columns_subset_with_filter`, `decode_filter_and_payload`, in
  `parquet_reader_prune`). Every batch passes through `arrow_hint_refine`,
  which applies a footer's `ARROW:schema` offset widths (LARGE_STRING,
  LARGE_BINARY). Its switches (`numeric_dict_vec`, `recycle_codes`) are
  constructor arguments.
- `parquet_reader_factory`: `ParquetReaderFactory`, which builds worker 0's
  reader of a file from the session footer cache (no storage I/O on a hit),
  every other worker's by sharing it (`clone_reader_for_worker`), and a
  footer-only reader for a file the scan will not decode.
- `prefetch`: the read-ahead hint for the next row group, scoped to the
  chunks the scan will decode; the advised bytes are counted.
- `payload_sel_decode`: a row group's columns for only the rows a mask
  keeps, all or nothing.
- `parquet_codes_feed`: one row group for a grouped aggregate, each key as
  dictionary codes when its chunk is an INT32 / INT64 dictionary chunk.
- `staged_filter`: a pushed conjunction decoded conjunct by conjunct: the
  lead conjuncts' columns in full, each later column only for the rows still
  alive, with three-valued logic kept (an UNKNOWN row never survives) and
  conjunct order never changed.
- `subrg_filter_gather`: for the sub-row-group aggregate, when a selection
  computed over a dictionary-preserved chunk is the answer, the survivors'
  gather, and a predicate over the group key evaluated once per dictionary
  entry into a keep-table that compacts the codes.
- `topn_rg_bounds`: per-row-group key bounds for a running top-N boundary
  and the claim order that tightens it, or no plan on any doubt.
- `parked_morsel_share`: the pool through which idle workers take a decoded
  row group's parked sub-morsels, each exactly once, for a consumer that
  opts in.
- `rg_prune_counter`: counters of the row-group statistics prune.
- `flat_schema`: whether a footer is flat.

The leaf-to-schema mapping (`schema[c + 1]` is leaf `c`) holds only for a
flat footer, which is the planner's contract for a flat read; the decisions
this package makes for itself (the selection class, the row-selective decode,
the dictionary-codes paths) decline on a footer that is not flat. The
dictionary-codes paths also decline for UINT_32 and UINT_64 chunks (their
entries would be sign-extended) and, in the codes feed, for a key with a
null (its codes are not row aligned).

The sub-row-group layer decodes a row group a chunk at a time into fixed
per-worker buffers through resumable column cursors (`subrg_cursor_feed`;
`subrg_columns` builds each chunk's flat columns, keeping each column's own
type for a scan and widening for an aggregate):

- `subrg_scan_executor`: `run_subrg_scan` / `run_subrg_scan_multi`, a
  SELECT / filter / project scan of one or several leaves in one fork over a
  `LocalDispatcher`, every row in file order (the collect sink,
  `scan_chunk_sink`, sorts the chunks back), a predicate applied per chunk
  (`batch_filter`), row groups the statistics or bloom filters disprove
  skipped, and a row group the cursors refuse decoded whole, after the chunks
  it already handed over are retracted.
- `subrg_split_decode`: one row range of a row group, alone or over
  dictionaries decoded once per (row group, column).
- `subrg_agg_plan`: the read plan of a grouped aggregate over a reader.
- `band_producer`: `run_band_agg`, a grouped aggregate with dictionary
  string keys folded band by band from reused buffers into a `BandSink`
  (`komira_engine_runtime`), the band width a function of the host profile.
- `cursor_grain_feed`: a claimed row group decoded one cache-sized grain per
  call, with the grain's split into morsels (`cursor_grain_split_emit`) and a
  move arm for flat columns (`grain_decode_move`).

The morsel source:

- `parquet_source`: `ParquetSource`, the `komira_morsel` `MorselSourceImpl`
  over the row groups of one or several files (a `FileDiscovery`). Workers
  claim row groups from one atomic cursor; a top-N boundary, the pushed
  predicate's statistics (evaluated once at construction) and bloom filters
  skip row groups; a decode filter, a dynamic join filter or a count-only
  consumer take the filtered decodes (`parquet_source_claim`,
  `parquet_source_arms`, `parquet_source_late_mat`: footer counts, counts
  and survivors from dictionary codes, the staged filter, then the
  late-materialized decode); otherwise the row group is decoded whole (by
  name across files, a filter column a file lacks read as NULL), through the
  cursor-grain route (`parquet_source_grain`), or as row ranges
  (`parquet_source_subrg`; a range a cursor refuses is cut from the whole
  decode of its row group, which the worker keeps for its next range of that
  row group, so a worker holds at most one whole decode; a row group that
  would need more than `SUB_SLOT_STRIDE` ranges is not split). Morsels
  larger than `morsel_rows` are cut (`parquet_source_emit`) and their
  partition ids sort into file order; a coarse range-split morsel takes the
  id of the first range it holds, so coarse morsels are ordered only
  approximately. `ParquetScanOptions.validate` runs at construction and
  refuses a `subrg_mode` outside 0..2, `subrg_units_per_rg` below 1 in mode
  2, and a negative `subrg_emit_rows`. Not covered at the source level: the
  declined selective decode (`decode_rows_of` returning None) is never
  reached through the source's routes; the reordered-projection test pins
  only the projection order of the survivors.
- `parquet_source_options`: `ParquetScanOptions`, the source's switches, and
  its pure decisions (claim stride, selection-pipeline deferral, partition
  ids, hooks to capabilities, projection names to indices).

The worker count is the caller's (its host profile's), so the source probes
no machine. Every switch is a constructor or call argument or a process setter
(`set_cursor_grain_enabled`, `set_grain_decode_move_enabled`,
`set_cursor_grain_split_enabled`); nothing reads the environment.

The package root re-exports nothing; import from the modules.

## Examples

The decode grain of the cursor-grain route: half the L3 cache split across
the workers, bounded by the morsel size, as a power of two:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_parquet_scan.cursor_grain_feed import cursor_grain_rows

# 16-byte rows, 20 workers, a 16,384-row morsel, a 55 MiB L3.
assert_equal(cursor_grain_rows(16, 20, 16_384, 55 << 20), 16_384)
# No morsel bound: the cache bound, rounded down to a power of two.
assert_equal(cursor_grain_rows(16, 20, 0, 55 << 20), 32_768)
```

A filter's conjuncts, in the order the staged decode evaluates them, and the
first one whose new column is worth decoding only for the rows still alive:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_parquet_scan.staged_filter import SelectionPlan, first_deferred_conjunct
from komira_parquet_scan.staged_filter import split_and_conjuncts, staged_filter_worthwhile
from komira_plan_expr.expr import BIN_AND, BIN_EQ, BIN_GT, Expr
from komira_plan_expr.scalar_value import ScalarValue

# a > 10 AND (b = 'x' AND c > 0)
var pred = Expr.binary(
    BIN_AND,
    Expr.binary(BIN_GT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(10))),
    Expr.binary(
        BIN_AND,
        Expr.binary(BIN_EQ, Expr.col_ref("b"), Expr.literal(ScalarValue.from_string("x"))),
        Expr.binary(BIN_GT, Expr.col_ref("c"), Expr.literal(ScalarValue.from_int(0))),
    ),
)
var conjuncts = List[Expr]()
split_and_conjuncts(pred, conjuncts)
assert_equal(len(conjuncts), 3)

# Columns 0 (a), 1 (b, a string) and 2 (c); only b's selective decode pays.
var cols: List[List[Int]] = [[0], [1], [2]]
var plan = SelectionPlan([1])
assert_equal(first_deferred_conjunct(cols, plan), 1)
assert_true(staged_filter_worthwhile(cols, plan))
assert_false(staged_filter_worthwhile(cols, SelectionPlan(List[Int]())))
```
