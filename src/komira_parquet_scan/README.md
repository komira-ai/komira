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

The package root re-exports nothing; import from the modules.

## Example

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
