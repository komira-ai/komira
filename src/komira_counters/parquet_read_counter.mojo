# =============================================================================
# parquet_read_counter — HOW MANY TIMES DID WE READ A PARQUET SOURCE?
# =============================================================================
#
# WHY THIS EXISTS. Scan dedup's entire reason for being is that two identical
# scans in one plan read the file ONCE. That is a pure PERFORMANCE property:
# the rows are byte-identical whether the file was read once or twice, so
# **no value assertion can see it break.** Losing dedup is a silent
# regression by construction.
#
# `ScanDedupCache.miss_count()` is a proxy, not a measurement: it counts CACHE
# INSERTS, so a pass that stopped materializing and a pass that materialized
# twice without caching are indistinguishable to it. This counts the READS.
#
# WHAT IT COUNTS, EXACTLY: **one increment per `ParquetSourceData` this
# process opens and scans** -- never per `fs.open`, per row-group fetch or per
# footer read. Those are per-read implementation detail whose count varies with
# parallelism, and a falsifier whose expected value moves with the scheduler is
# not a falsifier. One increment = one read of one source.
#
# IT MUST COVER *BOTH* SHAPES OF READ. There are TWO ways the engine reads a
# parquet source:
#
#   RESIDENT  -- `materialize_parquet_collect` /
#               `materialize_parquet_collect_batches` (`komira_parquet`):
#               decode the source into a whole Arrow batch. This is the read
#               the scan-dedup pass itself issues for a shared group.
#   STREAMING -- the parquet JOIN leaves in the engine dispatch package: the
#               build side of `materialize_parquet_join`, and the probe side
#               of every fused parquet probe and multi-key cascade probe.
#               These decode morsel-by-morsel and NEVER materialize the source
#               resident, so none of them passes through the RESIDENT entry
#               points above.
#
# WHY COVERING ONLY ONE WOULD NOT BE A DETAIL: it inverts the sign of the very
# measurement this counter exists for. A self-join whose sides carry a
# scan-pushed filter is exactly the shape that goes to the STREAMING leaf -- so
# a RESIDENT-only counter reports **0** with scan dedup DISABLED (two real
# reads of one file) and **1** with it ENABLED (one read). The un-deduped arm
# looks CHEAPER than the deduped one. A counter that covers only some read
# paths does not under-report; it reports the wrong ORDER.
#
# NOT COVERED, deliberately: the single-source breaker leaves that build their
# own `ParquetMultiConsumerSource_Single` -- `materialize_sort`,
# `materialize_partition_by`, `materialize_parquet_typed_join`, and the
# streaming arm inside `komira_parquet`'s materialize path itself. Add the
# increment there the day a test needs to count a read through one of them; do
# NOT quote this counter as a whole-engine read count until then.
# `materialize_topn` IS covered: the planless Top-N route serves most
# `ORDER BY ... LIMIT n` scans.
#
# THEREFORE: a test asserting a count here MUST carry a POSITIVE CONTROL -- an
# arm that makes the count go UP (dedup on reads ONCE, dedup off reads TWICE).
# An assertion of "1" alone would pass just as happily against an instrument
# that is wired to nothing.
#
# COST. One relaxed `fetch_add` in front of a parquet decode. Not measurable.
#
# Same `GlobalCounter` primitive (`global_counter.mojo`) as
# `planner_scale_counter.mojo` and `join_index_window_counter.mojo` -- no
# environment read, no `unsafe_from_address` laundering, no wildcard-origin
# field.
# =============================================================================

from komira_counters.global_counter import GlobalCounter


comptime _PQ_SOURCE_READS = GlobalCounter[
    "komira_counters_parquet_source_reads"
]


@always_inline
def parquet_note_source_read() raises:
    """Record ONE read of one parquet source.

    Called at the TOP of each parquet source-materialize entry point, before
    any early return, so a read that produces zero rows still counts as a
    read — the cost this measures is the read, not its result."""
    _PQ_SOURCE_READS.incr()


def parquet_source_reads() raises -> Int:
    """Parquet source reads since process start.

    ⚠ PROCESS-GLOBAL AND MONOTONE. A test must take a DELTA across the
    operation it is measuring, never read an absolute — a gated test shares its
    process with whatever ran before it."""
    return _PQ_SOURCE_READS.read()


# =============================================================================
# HOW MANY LEAF COLUMNS DID THE RESIDENT COLLECT DECODE?
# =============================================================================
#
# WHY A SECOND COUNTER, AND WHY HERE. Projection pushdown has the SAME
# shape of invisibility as scan dedup, which is why it lives beside it: the
# ROWS AND THE ANSWER ARE IDENTICAL whether the scan decoded the two columns
# the query names or all twenty-five the file holds. **No value assertion can
# see a lost projection**, so a route that builds its own
# `ParquetSourceData(path, None, ...)` reads the whole file and every test
# still passes. A `count(DISTINCT c)` that decodes every column of a wide
# table because one caller passed a `None` projection is visible only in peak
# memory.
#
# ⚠ WHAT IT COUNTS, EXACTLY: leaf columns per RESIDENT
# `materialize_parquet_collect` call — `ColumnSet.num_projected(file_cols)`,
# i.e. what the source was CONFIGURED to decode, read at the one point where
# both the projection and the file's own schema are in scope. It is a SUM
# across calls, so a test must pair it with `parquet_source_reads()` to know
# how many calls the number is spread over.
#
# IT DOES NOT COVER THE STREAMING LEAVES. `materialize_parquet_collect` and
# nothing else -- the join/topn/sort leaves build their own source and are NOT
# instrumented. Do not quote this as a whole-engine decode count; widen it the
# day a test needs one of those paths, as the read counter was widened.
#
# ⛔ AND A TEST ASSERTING A NUMBER HERE NEEDS A POSITIVE CONTROL — an arm that
# makes the count go UP. "It decoded 2" passes just as happily against an
# instrument wired to nothing.
# =============================================================================


comptime _PQ_COLUMNS_DECODED = GlobalCounter[
    "komira_counters_parquet_columns_decoded"
]


@always_inline
def parquet_note_columns_decoded(n: Int) raises:
    """Record that a resident parquet collect was configured to decode `n`
    leaf columns."""
    _PQ_COLUMNS_DECODED.add(n)


def parquet_columns_decoded() raises -> Int:
    """Leaf columns decoded by resident parquet collects since process start.

    ⚠ PROCESS-GLOBAL, MONOTONE AND A SUM. A test must take a DELTA across the
    operation it is measuring, and must also delta `parquet_source_reads()` so
    the number can be divided by the calls it came from."""
    return _PQ_COLUMNS_DECODED.read()


# =============================================================================
# HOW MANY COLUMN CHUNKS — AND HOW MANY COMPRESSED BYTES — DID WE ACTUALLY
# DECODE, ON ANY ROUTE?
# =============================================================================
#
# WHY A THIRD COUNTER RATHER THAN A WIDER SECOND ONE. The pair above answers
# "what was the resident collect CONFIGURED to decode": it reads
# `ColumnSet.num_projected(...)` inside `materialize_parquet_collect` and
# nothing else. That gap is not a corner: the parquet **aggregate** leaf
# (`materialize_parquet_untyped_agg`) is the route every grouped aggregate
# over a parquet file takes, and it is on the far side of it. So "the
# projection counter said nothing" and "the projection was correct" would be
# the same output.
#
# IT IS ROUTE-BLIND BY ENUMERATION, NOT BY FUNNEL -- AND THE LIST IS THE
# CONTRACT. There is no single decode funnel in this engine. There are FOUR
# sites (all in `komira_parquet`), each one a place that turns a
# `ColumnChunk`'s compressed byte range into a Column without passing through
# any of the others:
#
#   1. `bytes_decode._decode_column_chunk_from_bytes` -- the byte-range decode
#      funnel (`decode_row_group_from_bytes`,
#      `decode_row_group_columns_subset`, and the public
#      `decode_column_chunk_from_bytes` alias all bottom out here): the
#      resident collect, the band producer, the codes feed.
#   2. `subrg_cursor_feed._read_column_chunk_bytes` -- the sub-row-group
#      cursor / vector-decode leaf.
#   3. `parquet_source_helpers._decode_numeric_dict_codes_one_col` -- the
#      fused dict-count. Counted at the CALLER, not inside
#      `decode_numeric_dict_codes_from_bytes`, so both the mmap and the
#      non-mmap arm increment exactly once.
#   4. `morsel_reader.ParquetMorselReader._read_column_chunk` -- every
#      `ParquetMorselReader` decode: `decode_columns_for_rg` (the
#      late-materialisation filter/payload split) and `_decode_row_group` <-
#      `next_morsel` / `decode_row_group_shared`. This site is PRE-EMPTIVE:
#      the late-materialisation route that calls it is not wired into
#      production plans, so do NOT quote site 4 as evidence that such a route
#      is covered; it is the reason the count will not silently read ZERO on
#      the day that route is wired up.
#
# ⚠ SO A NEW DECODE ENTRY POINT DOES NOT INHERIT THE COUNT — it reports ZERO,
# which is the same output as a perfect projection. Before trusting a zero,
# check that the route you are asking about is on the list above. The
# discipline that keeps the list honest: every site's test carries a POSITIVE
# CONTROL over the SAME fixture, so "wired to nothing" and "correctly narrow"
# cannot both print the same number.
#
# AND DO NOT ADD A FIFTH SITE THAT SITS UNDER AN EXISTING ONE. Each entry
# above is chosen so that no two can fire for the same (row group, leaf
# column): counting inside `decode_numeric_dict_codes_from_bytes` AND at its
# caller, or inside `_read_column_chunk` AND at `read_raw_column_chunk`, would
# DOUBLE-COUNT. A count that over-counts is worse than one that under-counts,
# because the over-count looks like the defect it is supposed to detect.
#
# It needs no denominator: a query's chunk count is
# `row_groups x columns_decoded`, and the BYTE count is the thing a wide-file
# scan actually pays.
#
# ⚠ WHAT IT COUNTS, EXACTLY:
#   * `parquet_column_chunks_decoded()` — ONE increment per (row group, leaf
#     column) pair whose bytes were handed to the decoder. Not per page, not
#     per `pread`, not per morsel.
#   * `parquet_column_chunk_bytes()` — the sum of those chunks'
#     `total_compressed_size`, i.e. the compressed byte volume the scan
#     touched. This is the number to compare against the FILE's size when
#     asking "did we read a column nobody named".
#
# ⛔ A TEST ASSERTING EITHER NUMBER NEEDS A POSITIVE CONTROL — an arm that
# makes it go UP (a `SELECT *`-shaped query over the same fixture). "It decoded
# 2 chunks" passes just as happily against an instrument wired to nothing.
#
# ⚠ PROCESS-GLOBAL AND MONOTONE, like the two above: delta, never absolute.
#
# COST. Two relaxed `fetch_add`s per column chunk -- i.e. per row group per
# projected column, against a decode that costs milliseconds per chunk. Not
# measurable.
# =============================================================================


comptime _PQ_CHUNKS_DECODED = GlobalCounter[
    "komira_counters_parquet_chunks_decoded"
]

comptime _PQ_CHUNK_BYTES = GlobalCounter["komira_counters_parquet_chunk_bytes"]


@always_inline
def parquet_note_column_chunk_decoded(compressed_bytes: Int) raises:
    """Record ONE (row group, leaf column) chunk decode of
    `compressed_bytes` compressed bytes."""
    _PQ_CHUNKS_DECODED.incr()
    _PQ_CHUNK_BYTES.add(compressed_bytes)


def parquet_column_chunks_decoded() raises -> Int:
    """(row group, leaf column) chunk decodes since process start.

    ⚠ PROCESS-GLOBAL AND MONOTONE — delta across the operation, never read an
    absolute."""
    return _PQ_CHUNKS_DECODED.read()


def parquet_column_chunk_bytes() raises -> Int:
    """Compressed bytes of every column chunk decoded since process start.

    ⚠ PROCESS-GLOBAL AND MONOTONE — delta across the operation, never read an
    absolute."""
    return _PQ_CHUNK_BYTES.read()
