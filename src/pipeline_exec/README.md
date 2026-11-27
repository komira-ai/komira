# pipeline_exec

The driver that runs the segments of a physical plan. A plan is a list of
`SegmentDescPod` (`physical_plan`): each segment is a source, a chain of
operators and a sink, with dependencies on other segments. `run_plan` runs the
segments in dependency order, and `run_segment` runs one segment on the workers
of a `ParallelDispatch` (`async_api`), over the source, operator and sink
traits of `morsel`.

Import each module by name; the package root exports nothing.

- `run_plan`: `run_plan(descs, builder, dispatch, num_workers, token)` checks
  the plan, then repeats: take the ready set, start its lowest segment id,
  publish its output. It returns the outputs no dependent took, by segment id.
  A segment that raises ends the run and the segments not started do not start.
  `run_plan(descs, builder, dispatch, num_workers, token, progress)` also
  counts into a `RunProgress`: the plan's segment count once `check_plan`
  passed, then one per finished segment.
- `run_progress`: `RunProgress`, two atomic counts behind a shared handle
  (`share()`): the segments counted by the runs given it (`start`) and those
  finished (`finish_segment`). `snapshot()` reads `done` before `total`, so a
  reading on another thread never shows more done than counted; a cancelled or
  failed run leaves done below total.
- `run_segment`: build the members, size the sink for the workers, run one
  `SegmentTask` per worker, then combine once, finalize and take the output. A
  recorded error, or a cancellation by the caller's `CancellationToken`, is
  raised after the workers joined, and the sink is never combined or read. After
  the workers join and before the combine, each operator's tail (the rows it
  owes once every worker has finished: the build rows a RIGHT or FULL join
  probe found no partner for) is asked of the builder (`op_tail`) and pushed on
  the calling thread through the operators after it and into the sink as worker
  0, at a partition position after every source position; a spent limit
  after an operator ends that operator's tail (the tails of operators after
  the limit still run), and a cancel during them is raised after them.
- `segment_task`: `SegmentRun`, the state the workers share, and `SegmentTask`,
  the worker body. A worker reads the cancel flag and the token at every morsel
  boundary, claims a morsel (`None` at the end of input, never asked again by
  that worker), runs the operator chain and hands the rest to the sink. An
  operator returning HAVE_MORE_OUTPUT is executed again on the same morsel, each
  chunk pushed on before the next is asked for; FILTERED_EMPTY drops the morsel;
  FINISHED lets the rows it held go on and stops the worker's claims. A raise is
  recorded in the pipeline's first-error slot, which keeps the first error, and
  cancels the pipeline so the other workers stop at their next boundary.
- `plan_check`: `check_plan` refuses, by name and before any segment is built,
  a plan the driver cannot run; `ready_set` lists the segments that may start.
- `edge_policy`: what the driver does with each edge tag and order key. E1, E2
  and E3 make a consumer wait for its producer, E5 does not, E4 is refused;
  ORDER_NONE, ORDER_PARTITION_ID and ORDER_ROW_RANGE are served, and
  `check_plan` refuses ORDER_ROW_RANGE on any sink but an aggregation sink.
- `published_outputs`: `PublishedOutputs`, the batch each finished segment left.
  `run_plan` builds it from the plan, counting as a reader of a segment every
  SOURCE_SINK_OUTPUT and SOURCE_CONCAT spec that names it (a concatenation
  that names it twice reads it twice). `take` gives every reader but the last
  a copy and the last the batch itself, so a segment several others read (a
  shared subplan) hands each the same rows; what no reader took, the result,
  is what `run_plan` returns.
- `segment_builder`: the `SegmentBuilder` trait through which a plan's members
  are constructed from a descriptor. `build_source` is given the worker count
  (a source that sizes per-worker state at construction needs it) and
  `build_sink` the schema of the source's morsels (a sink that must name its
  output when no morsel reaches it needs it).
- `source_variant`, `op_variant`, `pipeline_sink`: the closed variants. Each
  holds one of its member types, fixed where the variant is named (three for a
  source, four for an operator and for a sink: the fourth slot defaults to
  `NoOperator` or `NoSink` and is read as `fourth()` under `OP_TAG_FOURTH` or
  `SINK_TAG_FOURTH`), and a tag;
  its trait methods test the tag and call the member. `unused_members` fills
  the slots a list leaves empty with members that refuse to run.
- `source_parquet`, `source_batch`, `source_sink_output`, `source_csv`,
  `source_iceberg`: the
  sources of a plan. `build_parquet_source` makes a `parquet_scan` `ParquetSource` on
  the local file system from the Parquet arm of a `SourceSpecPod`: it refuses a
  spec that is not total, resolves the projection names through the footer of
  the first file the path lists (a path may be a file, a directory or a glob;
  a spec that lists its files, `parquet_paths`, reads exactly those files in
  that order and appends their constant partition columns after the data
  columns),
  and installs the filter as the decode filter (every conjunct is applied; a row
  whose predicate is UNKNOWN is dropped) and as the pushed predicate that
  row-group statistics are checked against. The source borrows the caller's
  footer cache and expression pool. `build_parquet_source_on` is the same over
  any file system: a spec whose store (`parquet_fs`) is a bucket is read
  through the file system the builder's `ScanFsOpener` (fs) opens on it, its
  paths object keys and its one path never listed; `build_parquet_source`
  refuses such a spec, and so does a builder made without an opener, with
  `SCAN_FS_UNSERVED` naming the store (`LocalOnlyScanFs`, the default opener,
  opens nothing). `BatchSource` serves a copy of a resident
  batch and `SinkOutputSource` the batch a finished segment published, each as
  morsels claimed from one shared cursor. `build_csv_source` reads the file
  of the CSV arm of a `SourceSpecPod` (a `.csv.gz`, `.csv.zst` or `.csv.lz4`
  decompressed by its extension), decodes it with the spec's dialect at the
  column types the plan bound it at (no second inference), refuses a file whose
  column names are not the bound ones (`CSV_SOURCE_SCHEMA_MISMATCH`) and serves
  the decoded file as a `BatchSource`; the whole file is decoded before the
  first morsel. `build_iceberg_source` reads the Iceberg arm of a
  `SourceSpecPod` with `iceberg_scan.scan_reader.read_iceberg_scan`: every data
  file the spec lists, in that order, at the spec's bound columns, minus the
  rows the position and equality deletes that apply to the file remove; it
  serves the result as a `BatchSource`, and the files are read before the first
  morsel. The scan's filter and projection are operators of the segment.
- `source_jsonl`: `build_jsonl_source` reads the newline-delimited JSON file a
  SOURCE_JSONL spec names, at the spec's schema (the keys it names, in its
  order, at its types; a missing key is NULL, a key it does not name is
  skipped), through `jsonl`: a plain file in chunks of whole lines, one batch
  each, a `.jsonl.gz`/`.zst`/`.lz4` (and `.ndjson`, `.json`) file decompressed
  whole. The batches are served as a `BatchSource`; a file of no row is one
  empty batch at the schema. A read that fails names the file.
- `op_filter`, `op_project`, `op_limit`: the operators. A filter evaluates its
  predicate and records the rows it keeps as the batch's selection mask instead
  of gathering them; all rows kept leaves no mask, none kept is FILTERED_EMPTY,
  a batch that arrives with a mask is gathered first, and a predicate whose NULL
  scope the evaluator cannot derive is refused by name, when the first non-empty
  batch reaches the filter (a query in which no row arrives is not refused). A projection is
  `operator_api.MapOp` over expressions registered once and shared by the
  workers; it honours the mask as that package states. A limit counts the
  selected rows of every worker against one atomic budget, cuts the morsel that
  crosses it, and reports FINISHED once it is spent. With several workers which
  rows survive depends on the claim order; how many does not.
- `position_order`: sorts source positions (partition id, origin hint) into
  source order, for the collect sink and the aggregation sinks.
- `sink_collect`: `CollectSink` keeps each worker's morsels (gathered if masked)
  in the worker's own slot, orders them at `combine` by (partition id, origin
  hint) so a scan collects in file order whatever the schedule, and concatenates
  them. With no row it returns no rows under the schema the segment would have
  had.
- `sink_agg`, `agg_fold`, `agg_output`: the ungrouped aggregation sink
  `(SINK_AGG, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR)`: SUM, COUNT, COUNT(*),
  COUNT(DISTINCT), MIN, MAX and AVG (`count_distinct` below). The aggregate arguments (`AggSinkData.agg_exprs`) are run by each
  worker as a projection over the morsel, under its selection mask; the state
  of a worker is one cell per aggregate, a count, one 128-bit integer and one
  double. The folds over signed integers, DECIMAL128 (the unscaled value; the
  scale rides beside it) and, for MIN and MAX, DATE32 are exact integer
  folds, so the merge in worker order does not depend on the schedule. SUM
  over a decimal is a DECIMAL128 of the input's scale in the declared
  precision, over an integer an INT64 (or the DECIMAL(38, 0) a plan declares
  for the SQL integer sum); a sum that leaves 128 bits, has more digits than
  the declared precision, or leaves INT64 is refused rather than wrapped. AVG
  is a DOUBLE: one conversion of the exact sum (`decimal_to_float64` for a
  decimal) divided by the count. Over no non-NULL row SUM, MIN, MAX and AVG
  are NULL and COUNT is zero, in one row of the declared schema.
  `AggSinkData.presorted` and `estimated_groups` belong to grouped sinks and
  are ignored.

  FLOAT32 and FLOAT64 arguments fold into the double, as DuckDB's `sum`,
  `avg`, `min` and `max` of a DOUBLE do (a FLOAT is widened first, exactly).
  SUM is a FLOAT64: the values added from +0.0 in row order within a worker,
  then the workers' sums added in worker order (or, for an ORDER_ROW_RANGE
  segment, in source position order, below), with no overflow refused (a
  sum past the double range is an infinity, +inf plus -inf and any NaN give
  NaN); AVG is that sum divided by the count; MIN and MAX keep the input's
  type and use DuckDB's order, NaN above +inf (query_semantics 2.7). The
  tolerance rule, which `tests/test_sink_float_agg_duckdb.mojo` holds the
  sink to against the pinned DuckDB:

  - MIN, MAX, COUNT and NULL are exact: MIN and MAX return one of the input
    values, the same one DuckDB returns, except that which of -0.0 and 0.0 a
    tie keeps depends on the order the rows are met.
  - NaN matches any NaN (its sign and payload are not part of the answer),
    and +inf and -inf match only themselves.
  - A finite SUM or AVG is within 1e-9 relative of DuckDB's:
    `|got - want| <= 1e-9 * max(|got|, |want|)`, whenever the sum is well
    conditioned. Both are double sums in an order of their own
    (query_semantics 2.10), and a sum of `n` values in any order is within
    about `(n - 1) * 2^-53 * sum(|x|)` of the exact one, so the two answers are
    within `(n - 1) * 2^-52 * sum(|x|)` of each other: the rule holds while
    that is at most `1e-9 * |sum(x)|`, for 4096 values while `sum(|x|)` is
    at most about 1,100 times `|sum(x)|`. A cancelling sum past that bound, and
    a sum whose partial sums leave the double range in one order but not in
    another, can differ by more; DuckDB's own answer to such a sum changes with
    its thread count too.

  A sum is not compensated (DuckDB's `sum` is not; its `fsum` is). Folded by
  worker, a float SUM or AVG depends on which worker took which morsel, so
  `lowering` cuts an ungrouped float SUM or AVG with `ORDER_ROW_RANGE`, and
  `RealBuilder` then builds the sink `by_position`: a worker keeps one set of
  cells per source position (the partition id and origin hint its source
  stamped on the morsel; the chunks of one morsel fold into one), each
  position's rows added from +0.0 in row order, and `combine` adds the
  positions' sums in position order. The answer is then the same bits on
  every worker count and schedule, given the same morsels: a resident batch
  and a producer's output are cut by the segment's morsel size alone, and so
  is each Parquet row group with the scan options `RealBuilder` gives (no
  row-range split); the Parquet source's cursor-grain route, which sizes its
  grains from the worker count, is a process-wide switch that is off by
  default, and an ORDER_ROW_RANGE Parquet segment is refused by name while it
  is on. The morsel size comes from the host profile's cache sizes, not from
  the worker count, so one plan lowered on one host is the same bits on any
  number of workers; another host, or another morsel size, can change the
  last bits. Two morsels at one position are refused by name at `combine`.
  Each position's cells (one `AggCell` per aggregate) are drawn from the
  segment pool when it is first seen, so the state grows with the number of
  morsels the segment reads. The grouped sinks fold their float aggregates by
  position the same way, per group (`group_positions`, below).
- `sink_group_agg`, `group_table`, `group_keys`, `sink_agg_any`: the grouped
  aggregation sinks `(SINK_AGG, KEY_DTYPE_I64 | I32 | F64 | F32 | DATE32 |
  BOOL | DECIMAL128, SINK_ORIENT_COLUMNAR)`, over one or more keys that are
  integer columns (the I64 and I32 rows), float columns (F64 and F32), DATE32,
  BOOL or DECIMAL128 columns (one row each), with the aggregates and the
  folds of the ungrouped sink (`agg_fold`, `agg_output`), FLOAT32 and FLOAT64
  arguments included (below); an argument of a type no fold serves is
  refused by name, naming the type. The output
  schema lists the key columns, in the input's types, then the aggregates. Each
  worker folds into a hash table of its own (`group_table`: a 64-bit cell and a
  NULL flag per key, two cells for a decimal key at its declared scale, a
  count and a 128-bit integer per aggregate); a NULL key is a group of its own, and 0.0 and -0.0, and all NaNs, are one group each
  (`group_keys`). `combine` merges the tables in worker order with the same
  overflow rule, per group, so a sum that overflows only when the workers'
  partials are added is refused; the order of the output groups is not
  specified. Each doubling of a table is charged to the worker's reservation
  before it is made, the merged table to the sink's own, and a denial fails
  the query by name; a worker's table is freed and its memory returned as soon
  as it is merged. The table is not `op_agg_hash`'s: those entries hold
  Int64 keys without a NULL flag and 64-bit or float accumulators, with no exact
  128-bit decimal fold. Memory outside the pool, as a known limit: the buffers
  of the morsel being folded (about 9 bytes per row per key and 17 per row per
  aggregate argument, freed when `consume` returns) and the old arrays of a
  table while it doubles (at most half the bytes charged for that table). A
  table holds at most 2^30 groups (a 32-bit group index) and refuses more by
  name. The merge is serial, and there is no dense table for a
  small key domain and no partitioned parallel finalize yet.
  Given a spill directory (`RealBuilder.set_spill_directory`), the fixed-width
  grouped sink does not refuse a table the pool cannot grow: the worker writes
  the table to disk (`group_spill`: one chunk per partition of 16, by the top
  bits of the key hash, through `engine_runtime`'s `LocalDiskSpillStorage`
  and THSPLC column codec, under a sub-directory made by
  `op_spill_rows.spill_root`), returns its memory and folds on into a new
  table. `combine` then merges one partition at a time from the workers'
  tables and the chunks, keeping each partition's output rows (charged) and
  freeing its table, and writes the workers' remaining tables to disk when the
  pool denies a partition's merge. The integer folds are exact, and a float
  MIN or MAX is up to which of -0.0 and 0.0 is kept, so the groups and their
  values are the ones without a spill; a float SUM or AVG can differ in its
  last bits, as between worker counts. The spill files are deleted at the end
  of `combine` or when the sink is dropped. A sink with COUNT(DISTINCT) does
  not spill and says so in its refusal; the string-keyed sinks and the sort do
  not spill. `AnyAggSink` is the
  one slot of the sink variant that holds the grouped or the ungrouped sink.
- `group_positions`: the grouped sinks' float folds by source position. A
  FLOAT32 or FLOAT64 argument folds into a double as in the ungrouped sink
  (SUM from +0.0, MIN and MAX in DuckDB's order of floats). Folded into each
  worker's table and merged in worker order, a group's float SUM or AVG
  depends on which worker took which morsel, so `lowering` cuts a grouped
  float SUM or AVG with `ORDER_ROW_RANGE` too, and `RealBuilder` builds the
  fixed-width and the string-keyed sinks `by_position`: a worker keeps, per
  source position it folded, a float cell (a count and a double) for each
  group that position's rows reached and each float SUM, AVG, MIN and MAX,
  folded from empty in row order, and `combine` merges those cells into the
  merged groups in source position order after the workers' tables. Each
  group's answer is then the same bits on every worker count and schedule,
  under the same conditions as the ungrouped sink's (above), and a MIN or MAX
  that meets -0.0 and 0.0 keeps the one first in source order. The other
  aggregates fold into the worker's table as without a position. Each entry
  is charged to the segment pool before it is made (a denial fails the query
  by name), two morsels at one position are refused by name, and a sink that
  folds by position does not spill (its refusal says why when a spill
  directory is set).
- `sink_string_group_agg`, `string_keys`: the grouped aggregation sinks keyed by
  strings, `(SINK_AGG, KEY_DTYPE_STRING, SINK_ORIENT_DICT_ENCODED | SINK_ORIENT_COLUMNAR)`,
  over one or more STRING key columns (a fixed-width key beside a string key is
  the COMPOSITE row's and refused by name here). They use slice 5's
  `group_table`, folds (`agg_fold`), merge rule, refusals and charging. A worker
  keeps an `InternTable` (`string_keys`): each distinct key string once, in a byte
  arena, with its 64-bit content hash computed once when the entry is made; the
  group table is keyed by the string's id there, and a group's hash mixes the
  content hashes of its strings, so it is the same in every worker. The two rows
  differ only in how a DICTIONARY column reaches the table: DICT_ENCODED interns
  a dictionary code on first use in a morsel (one hash, probe and byte compare per
  code however many rows carry it), COLUMNAR hashes and interns every row; a flat
  STRING column is interned per row by both, so a Parquet chunk that fell back
  to plain encoding gives the answer a dictionary chunk does. `RealBuilder` makes
  the Parquet source keep dictionaries (`preserve_dict`) only for the
  DICT_ENCODED row. NULL is a group of its own and the empty string is another.
  The same sink built `composite` is `(SINK_AGG, KEY_DTYPE_COMPOSITE,
  SINK_ORIENT_COLUMNAR)`: a key of several columns of mixed types (GROUP BY an
  integer, a string and a date). A STRING column is interned as above and
  takes one cell; any other column takes the cells of the fixed-width row that
  keys its type (`group_keys.fixed_key_dtype`: a decimal two, every other one),
  with that row's NULL, float and decimal-scale rules, and must arrive in its
  declared type. The cells lie column by column in one `group_table` row; a
  group's hash mixes, in column order, each string's content hash and each
  fixed-width cell, and the merge remaps the string cells by value and copies
  the others.
  A group exists when a selected row reached it; the intern table only names
  strings, and a dictionary entry no selected row used is never interned.
  `combine` merges by value, in worker order: each string of a worker's groups
  (its carried hash and its bytes) is interned in a merge table, and the merged
  group table is keyed by those merge ids, so one string met as id 3 in one worker
  and id 9 in another is one group; nothing is re-hashed. Both tables of a worker
  are charged to its reservation as they grow, before they grow, and freed and
  returned once merged; the merge's tables are charged to the sink's own. A
  dictionary's per-morsel code-to-id array and the merge's worker-to-merge id
  array (4 bytes an entry each) are drawn from the pool before they are made and
  given back after. Memory the pool does not see: the morsel buffers (17 bytes a
  row per key column, 16 and a flag per aggregate argument, a flat key column
  copied once), the old arrays while a table doubles, and the output. The order
  of the output groups is first-seen in the merge and not specified. Limits: a table holds at
  most 2^30 groups and 2^30 distinct strings, and a string key column in the
  output at most 2 GiB of bytes. The merge is serial, as the fixed-width sink's.
  `string_harness` is the test table, with dictionary columns that are rotated
  per morsel and hold unused entries and a second copy of a string.
- `count_distinct`: COUNT(DISTINCT x) in all three aggregation sinks, beside
  their other aggregates. A worker keeps one `GroupTable` of (aggregate, worker
  group, value) entries with no cells, and an `InternTable` for string values;
  a value is one or two 64-bit cells (a signed integer or DATE32 as the integer,
  a float by the grouped sinks' key rule so every NaN is one value and -0.0
  equals 0.0, a DECIMAL128 as its two words, a string or a string dictionary by
  the id of its bytes). A NULL value adds no entry, so a group whose values are
  all NULL counts 0. `combine` moves each worker's entries under the merged
  group of their worker group (and a string under its id in the merge's own
  intern table); an entry new in the merged table adds one to the group's
  count, which is written as COUNT's INT64. Any other argument type, and a type
  that changes between morsels or workers, is refused by name. The tables are
  charged to the worker's reservation as they grow, and the merge's to one of
  its own, freed when the merge ends; a denial fails the query by name. With
  no aggregate at all, the grouped sinks emit one row per distinct key: this
  is SELECT DISTINCT, which `lowering` cuts to a `SINK_AGG` grouped by every
  column.
- `segment_pool`: `SegmentPool`, an atomic byte count with an optional budget
  that any number of handles share, and `WorkerReservation`, a worker's plain
  tally inside the blocks it drew (a grant is a compare-and-swap, so the count
  never passes the budget and a request that fits is not refused). A
  reservation returns its blocks when it is dropped. The aggregation sink's
  state is fixed in size, so it draws once per worker; the grouped sink draws as
  its tables grow.
- `sink_sort`, `sort_nulls`, `sort_range`: the in-memory sort `(SINK_SORT, KEY_DTYPE_NONE,
  SINK_ORIENT_COLUMNAR)` and the top-N `(SINK_TOPN, KEY_DTYPE_NONE,
  SINK_ORIENT_COLUMNAR)`, which is the same sink built from a `TopNSinkData`; the
  sort is for a small result (TPC-H Q1's ORDER BY over its
  grouped rows). It collects with a `CollectSink` (morsels in position order),
  then sorts the one batch by `SortSinkData`: keys, directions and per-key
  NULL placement (an empty `nulls_first` means the engine's default, NULLS
  LAST). `op_sort.sort_batch_by_keys` is the sort and is stable, so tied
  rows keep the collected order. It does not read a NULL placement and orders a
  dictionary by index, so `sort_nulls` hands it a key batch of its own: string
  dictionaries decoded, and for each key with a NULL an INT32 rank column and
  the key with its NULL slots overwritten by a valid value; the input is then
  gathered by the sorted row numbers. Key types the kernel does not order
  (DECIMAL, DATE, FLOAT32 ...) are refused by name when the sink is built.
  Memory: the sink draws, as each exists, the morsels it keeps, the
  concatenation, then the sorted copy plus an estimate of the key batch and the
  kernel's temporaries (`sort_scratch_bytes`), from the segment pool and from a
  pool sized by `SortSinkData.memory_budget` (when positive). The budget bounds
  the estimated peak, and the consume that takes the input past it fails. There is no
  spill. `sort_harness` is the table and the oracle of its tests.
  The top-N answers rows [offset, offset + n) of the full sort's order (ties keep
  the collected order: morsel position, then worker slot, then arrival) and holds
  about `offset + n` rows per worker, not every row. A worker tags each morsel's
  rows with three hidden INT64 columns (`sort_range`: partition id, origin hint,
  and worker * 2^40 + the rows it tagged before; named so that no input column
  has their name) and, once it holds `max(2 * (offset + n), 2048)` rows, sorts
  them by the keys and then the three columns and keeps the first `offset + n`.
  `combine` sorts what every worker kept the same way, slices the range and drops
  the hidden columns, so the answer is the full sort's slice on any number of
  workers and any schedule. A count of zero, or an offset past the rows, answers
  no row under the input's schema; a negative count or offset is refused by name
  when the sink is built. The top-N has no memory budget of its own and draws on
  the segment pool alone, as each batch is about to exist.
- `sink_window`: the window functions `(SINK_PARTITION_BY, KEY_DTYPE_NONE,
  SINK_ORIENT_COLUMNAR)`, from a `PartitionBySinkData` (partition keys, order
  keys, directions, window expressions and the output schema). It collects with
  a `CollectSink` (morsels in source position order), then runs `op_window`'s
  `_execute_partition_by_sink` on the one batch: sorted by the partition and
  order keys (NULLs last in both directions), the sorted input columns followed
  by one column per expression under the plan's output schema. The sort is
  stable over the collected order, so rows tied on every key come out in source
  position order and ROW_NUMBER over them is the same on every worker count
  (`op_window`'s own `PartitionBySink` folds in worker order, so it is not
  used). The kernel runs on the calling thread in `combine`: the sink trait
  gives `combine` no dispatcher for `op_window`'s parallel driver. No input
  gives a batch of no rows under the output schema. Memory: the sink draws, as
  each exists, the morsels it keeps, the concatenation, then an estimate of
  what the kernel adds (a sorted copy, 16 bytes per row per expression and the
  argument column of a STRING value function), from the segment pool; when the
  kernel is done it draws the output's bytes and holds them until the output is
  taken. A denied draw fails by name, its message beginning with the code `MEMORY_BUDGET_EXCEEDED: `; there is no spill. Refused when built: a
  direction list that does not match the order keys, an output schema with
  fewer columns than expressions. A kernel refusal surfaces from `combine`.
- `spike/intern_spike.mojo` (target `intern_spike`, not part of the library): the
  dictionary-interning spike of the string group-by. A standalone program that times
  interned dictionary codes, hashing every row, the fragment merge and the string-table
  memory on a synthetic workload and checks each layout's counts; its numbers and what
  they decided are in `docs/design/lowering_and_pipeline.md` (section 4.3).
- `real_builder`: `RealBuilder`, the `SegmentBuilder` over these members. It
  serves SOURCE_PARQUET, SOURCE_BATCH, SOURCE_SINK_OUTPUT, SOURCE_CSV,
  SOURCE_ICEBERG, SOURCE_JSONL, SOURCE_CONCAT (a UNION ALL: it takes the output of every producer the spec
  names, after checking each is a dependency, and concatenates them in the
  spec's order into one batch it serves as a `SinkOutputSource`, with each
  column nullable when any producer's is; a concatenation of no segment is
  refused), OP_FILTER,
  OP_PROJECT, OP_LIMIT, OP_JOIN_PROBE (a `HashProbeOp`, whose index
  `build_source` makes from the rows the build segment published; a build
  segment that is not among the segment's dependencies is refused; for a RIGHT
  or FULL probe `op_tail` gives the unmatched build rows, probe columns NULL at
  the types the chain gives the rows before the probe, in batches of the
  segment's morsel size, `DEFAULT_MORSEL_ROWS` when it names none) and the
  sinks `(SINK_COLLECT, KEY_DTYPE_NONE,
  SINK_ORIENT_COLUMNAR)`, `(SINK_HASH_BUILD, KEY_DTYPE_NONE,
  SINK_ORIENT_COLUMNAR)` (a `CollectSink`), `(SINK_AGG, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR)`,
  the grouped rows I64, I32, F64, F32, DATE32, BOOL and DECIMAL128,
  `(SINK_AGG, KEY_DTYPE_STRING, SINK_ORIENT_DICT_ENCODED)`, `(SINK_AGG, KEY_DTYPE_STRING,
  SINK_ORIENT_COLUMNAR)`, `(SINK_AGG, KEY_DTYPE_COMPOSITE, SINK_ORIENT_COLUMNAR)`,
  `(SINK_SORT, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR)`, `(SINK_TOPN, KEY_DTYPE_NONE,
  SINK_ORIENT_COLUMNAR)` and `(SINK_PARTITION_BY, KEY_DTYPE_NONE,
  SINK_ORIENT_COLUMNAR)` (a `WindowSink`), and refuses every other kind by name. It keeps the
  resident batches (`add_resident`), the aggregation sink data a descriptor's
  `sink_param_id` indexes (`add_agg_sink`), the sort sink data (`add_sort_sink`), the top-N data (`add_topn_sink`), the window sink data (`add_window_sink`) and the segment pool
  (`set_memory_budget`, unbounded until set) and the spill directory of the
  fixed-width grouped sinks (`set_spill_directory`, none until set), shares one set of operator parts among the
  workers of a segment run, and derives the empty-output schema by running the
  chain's projections over a batch of no rows. Three origins name the borrows of
  the Parquet source (the footer cache, the expression pool, an absent dynamic
  filter), and a fourth parameter `R` the `ScanFsOpener` of the remote store a
  Parquet spec may name (`LocalOnlyScanFs` by default): a builder made with an
  opener (`RealBuilder(cache, pool, opener)`) reads a spec on a bucket through
  the file system the opener opens on it, beside the local ones, with one
  footer cache keyed per file system.
- `op_hash_probe`: `HashProbeShared` and `HashProbeOp`, OP_JOIN_PROBE for
  INNER, LEFT, RIGHT, FULL, SEMI, ANTI and CROSS joins, the join type being the
  probe's view (probe left, build right; `lowering` exchanges LEFT and RIGHT
  when the plan builds its left child). The probe segment's builder takes the
  rows the build segment published and makes one composite hash index over the
  build key columns (`op_join_probe`'s `MultiKeyHashJoinBuilder`), once and on
  the calling thread before any worker starts; a CROSS join has no key and no
  index. Each worker's `HashProbeOp` reads the index and the build rows. A
  morsel with a selection mask is gathered first; a morsel with no row or no
  row to emit is FILTERED_EMPTY. The output is the probe columns then the
  build columns, a build name the probe side uses suffixed `_right`, the
  columns of a side an outer join pads nullable; SEMI and ANTI give the probe
  columns only. LEFT and FULL pad a probe row without partner with NULL build
  columns. RIGHT and FULL mark the build rows that found a partner in one
  atomic byte each, shared by the workers (the only thing the workers write of
  the shared part), and `unmatched_build_rows` gives the rest, probe columns
  NULL, as the operator's tail. A CROSS morsel is emitted in chunks of whole
  probe rows of about 65536 output rows (HAVE_MORE_OUTPUT between them). A NULL
  key on either side matches nothing; the key types are the kernel's (INT64 and
  INT32, FLOAT64, STRING). An INT64 key equal to the value the kernel uses for
  NULL is refused by name (`JOIN_KEY_RESERVED`) rather than silently unmatched.
- `plan_harness`: segment descriptors for the four sources with an operator
  chain and a collect sink (`with_agg_sink` turns one into an aggregation),
  `project_columns`, and a sample table with readers, for plans written by hand
  (`with_sort_sink` and `with_topn_sink` for the sorts, `with_group_sink`, `with_string_group_sink` and `grouped_agg_data` for the
  grouped sinks).
- `group_harness`: a table with NULL integer keys, a DECIMAL and a high-cardinality
  column, and one with float keys, whose every cell is a function of its row
  number.
- `tpch_q6`: TPC-H Q6 as such a plan (scan, filter, project, SUM into a
  DECIMAL(38,4)) and a lineitem-shaped table with the types of the real files
  (DECIMAL(15,2), DATE32) whose first rows sit on every predicate's boundary.
- `tpch_q1`: TPC-H Q1 as a two-segment plan (scan, filter, project and the
  string-keyed grouped sink; then the sort of its output) over a lineitem-shaped
  table whose two flag columns are dictionary encoded in row groups of 256 and
  fall back to plain encoding in row groups of four.
- `fake_support`, `fake_members`, `fake_builder`, `fake_dispatch`: sources,
  an operator, sinks, a builder and dispatchers that record what the driver does
  in shared counters, and run the workers one after another in an order a test
  chooses.

Per-worker state lives in a typed `List`, never in a byte-backed `Slab`
reached through `get_mut_interior`: a value that holds heap (a `List`, an
`ArcPointer`, a `CancellationToken`) must be owned by an element the compiler
tracks. `SegmentRun.ops` is a `List` of operators (one chain per worker, index
`worker * n_ops + op`) mutated through the run's `mut` borrow; a sink keeps its
slots as `List[ArcPointer[Slot]]`, each worker touching only the slot of its own
task id. Atomics-only cells (the fakes' tally) may stay in a `Slab`. The task id
that `ParallelDispatch` passes selects the slot, not the worker id, which only
names the thread that runs the task; a dispatcher may run more tasks than it has
workers.

The combine order is a property of the sink. `CollectSink` merges its per-worker
slots at `combine` into one order by (partition id, origin hint), and morsels
that tie keep the order of the worker slots (worker id, then arrival within the
slot); a sink without such a key (the fakes) concatenates the slots in worker id
order. Either way the order is decided after every worker has joined. A
memory budget is a property of the sink too: a sink that cannot grow raises, and
the raise fails the query through the first-error slot.

## Known limits

- **A limit does not stop the other workers' scans.** `LimitOp` reports FINISHED
  to the worker that sees the budget run out, and `SegmentTask` stops only that
  worker's claims. A worker whose morsels are all FILTERED_EMPTY by an operator
  upstream of the limit never reaches it, so it keeps draining the source after
  the budget is spent. The result stays exact (no morsel past the budget
  reaches the sink); the scan work is wasted. A pipeline-level stop (a shared
  "finished" flag in `PipelineExecution` that every worker reads at the morsel
  boundary, set by the first FINISHED) is the follow-up.
- **The filter gathers a masked morsel first.** A morsel that reaches `op_filter`
  with a selection mask is materialized (fully copied) before the predicate is
  evaluated. Whether a mask-aware evaluation is worth it is for slice 3 to
  measure.
- **A grouped float fold by position grows with (position, group) pairs.**
  `group_positions` keeps one entry (a group id and 16 bytes per float
  aggregate) for each group each morsel reaches, charged to the pool: a few
  groups cost little, but many groups spread over many morsels cost up to one
  entry per row, and a denial fails the query by name where a fold by worker
  would have fit. Such a sink does not spill. The dense grouped sink and the
  byte cap of the design (lowering_and_pipeline §3.3) are not built.
- **The collect sink holds every chunk until `take_output`.** Chunks stay in the
  worker slots, then in the merged list, and `take_output` concatenates them
  into the output batch, so a segment's peak memory is about twice its output.

- **The join build is serial and unmeasured.** The index over the build rows
  is made at the start of the probe segment, on one thread, before its workers
  start. The build rows and the index are not charged to the segment pool, so
  the memory budget does not see them. There is no runtime filter: the probe
  side's scan reads every row.
- **A keyed join morsel gives one output batch.** A probe morsel whose rows
  each match many build rows yields one batch as large as the fan-out, because
  the keyed probes do not return HAVE_MORE_OUTPUT to split it; only CROSS does.
- **The unmatched-row tail is pushed on one thread, after the workers.** A
  RIGHT or FULL join's tail rows go through the rest of the segment's chain and
  into the sink on the calling thread, so a long tail is not spread over the
  workers.
- **One INT64 key value is refused.** The kernel stands for NULL by one INT64
  value; a join key equal to it raises `JOIN_KEY_RESERVED`.

## Example

Two segments over fake members. The first produces twelve rows; the second reads
them back and counts them. The workers run one after another, so the result does
not depend on a schedule.

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from async_api.token import CancellationToken
from physical_plan.physical_plan import (
    EDGE_E3_PUBLISH_WAIT,
    SegmentDescPod,
)
from pipeline_exec.fake_builder import (
    FROM_CURSOR,
    FROM_DEP,
    TO_COUNT,
    FakeBuilder,
    FakeScript,
    fake_desc,
)
from pipeline_exec.fake_dispatch import InlineDispatch
from pipeline_exec.fake_support import batch_values
from pipeline_exec.run_plan import run_plan

var descs = List[SegmentDescPod]()
descs.append(fake_desc(0))
var deps = List[Int]()
deps.append(0)
var tags = List[UInt8]()
tags.append(EDGE_E3_PUBLISH_WAIT)
descs.append(fake_desc(1, deps^, tags^))

var builder = FakeBuilder()
_ = builder.add(FakeScript(FROM_CURSOR, n_morsels=4, rows=3))
_ = builder.add(FakeScript(FROM_DEP, rows=5, dep=0, to_kind=TO_COUNT))

var dispatch = InlineDispatch()
var out = run_plan(descs, builder, dispatch, 2, CancellationToken.new())
assert_false(out.has(0))  # the consumer took it
var counted = batch_values(out.take(1))
assert_equal(counted[0], Int64(12))
```

A SOURCE_CSV spec through `source_csv` and `plan_harness`; reading a file is
in the welded tests (`test_source_csv`):

```mojo
from std.testing import assert_equal, assert_true

from arrow.arrow_types import ArrowType
from physical_plan.csv_source_spec import CsvSourceSpec
from physical_plan.physical_plan import SOURCE_CSV, SourceSpecPod
from pipeline_exec.plan_harness import csv_segment
from pipeline_exec.source_csv import (
    build_csv_source,
    csv_read_options,
    read_csv_spec,
)

var names = List[String]()
names.append("code")
var types = List[ArrowType]()
types.append(ArrowType.STRING)
var spec = SourceSpecPod.csv(
    CsvSourceSpec("codes.csv", UInt8(ord(";")), True, 0, names^, types^)
)
# The reader gets the spec's dialect and parses each column at its bound
# type, so a cell `0001` of this column stays the string `0001`.
var options = csv_read_options(spec)
assert_equal(Int(options.delimiter), ord(";"))
assert_true(options.declared_column_types[0] == ArrowType.STRING)
# A segment that reads the file and collects (plan_harness).
var seg = csv_segment(0, spec^)
assert_equal(seg.source_kind, SOURCE_CSV)
# A spec that names no file is refused before anything is read.
var refused = String("")
try:
    _ = read_csv_spec(SourceSpecPod())
except e:
    refused = String(e)
assert_equal(refused, "pipeline_exec: a SOURCE_CSV spec names no file")
refused = String("")
try:
    _ = build_csv_source(SourceSpecPod(), 1024)
except e:
    refused = String(e)
assert_equal(refused, "pipeline_exec: a SOURCE_CSV spec names no file")
```

A SOURCE_ICEBERG spec through `source_iceberg` and `plan_harness`; reading the
files is in the welded tests (`test_source_iceberg`):

```mojo
from std.testing import assert_equal, assert_true

from arrow.arrow_types import ArrowType
from physical_plan.iceberg_scan_spec import (
    IcebergDataFileSpec,
    IcebergDeleteSpec,
    IcebergScanSpec,
)
from physical_plan.physical_plan import SOURCE_ICEBERG, SourceSpecPod
from pipeline_exec.plan_harness import iceberg_segment
from pipeline_exec.source_iceberg import build_iceberg_source

var names = List[String]()
names.append("id")
var types = List[ArrowType]()
types.append(ArrowType.INT64)
var ids = List[Int]()
ids.append(1)
var files = List[IcebergDataFileSpec]()
files.append(
    IcebergDataFileSpec(
        "no_such_dir/a.parquet",
        "file:///warehouse/orders/a.parquet",
        List[Int](),
        List[Int](),
    )
)
var spec = SourceSpecPod.iceberg(
    IcebergScanSpec(
        names^, types^, ids^, files^, List[IcebergDeleteSpec]()
    )
)
# A file the spec lists that cannot be opened is the source's error.
var failed = False
try:
    _ = build_iceberg_source(spec, 1024)
except e:
    failed = String(e).byte_length() > 0
assert_true(failed)
# A segment that reads the files and collects (plan_harness).
var seg = iceberg_segment(0, spec^)
assert_equal(seg.source_kind, SOURCE_ICEBERG)
```
