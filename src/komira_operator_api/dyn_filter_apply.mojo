# =============================================================================
# dyn_filter_apply -- apply a build-side DynamicJoinFilter inline to an
# in-memory RecordBatch (probe-side scan).
# =============================================================================
#
# LIGHTWEIGHT-DF v4.2 §3.6.1 (Slot B.i). The parquet probe path consumes a
# build-side `DynamicJoinFilter` (Bloom + range + in-list tiers) at RG-prune
# + decode-mask time inside `parquet_morsel_source`. The in-memory probe path
# (`SOURCE_BATCH` in `morsel_executor._resolve_source`) had no equivalent --
# the resident batch was returned whole and only the *logical* filter chain
# (deferred `OP_FILTER`) ran later, never the join-key Bloom.
#
# This module is the in-memory analog: given the resolved probe batch, the
# probe-side join-key column name, and the materialized build's
# `DynamicJoinFilter`, build a surviving-row index list by probing the filter
# per row (`might_contain_int64` -- range -> in-list -> bloom, cheapest-first)
# and compact the batch via `gather_batch`. NULL probe keys never match a
# join key (SQL: NULL != anything in an equi-join), so they are dropped too.
#
# COST GUARDS (Slot PERF-REGRESSION-FIX-2)
# ---------------------------------------------------
# The original B.i `apply_dyn_filter_int64` had NO cost model: it did an
# unconditional `as_primitive` copy of the join-key column + a full-batch
# `might_contain_int64` probe + (whenever pass-rate < 100%) a `gather_batch`
# rebuild of every column -- on the *whole* resolved probe batch. For TPC-H
# q8/q9/q11/q3/q10/q7 the probe segment's in-memory intermediate is the
# 6M-row `lineitem`-shaped batch; the dyn-filter cost there was ~26-29ms of
# pure overhead (q8 went 24->45ms, PASS->FAIL on the v4.2 scoreboard). Unlike
# the parquet path -- where the dyn-filter saves *decode* work, so its O(n)
# probe cost is amortized into a decode pass that would happen anyway -- the
# in-memory path's rows are already resident: the dyn-filter's only payoff is
# a smaller batch into the downstream op chain, and a single downstream
# hash-join probe is *cheaper per row* than the bloom probe + gather it
# replaces. So for a large probe batch the in-memory dyn-filter is a net loss.
# See an internal agent note.
#
# Two guards, both inexpensive checks before any per-row work:
#
#   1. PROBE-BATCH SIZE CAP. If `batch.num_rows() > _IN_MEM_DYN_FILTER_PROBE_CAP`
#      (= `DYNAMIC_FILTER_BUILD_CAP`, 65_536) the dyn-filter is not applied --
#      the batch is returned unchanged and the downstream op chain (including
#      the actual hash-join) runs on the full batch. This is the in-memory
#      analog of the build-side cap the prepass already enforces: above the
#      threshold the O(n) probe + gather overhead exceeds any downstream
#      saving. (`morsel_executor._build_dynamic_filter_for_probe` also checks
#      this for SOURCE_BATCH probes, so for a large probe batch no filter is
#      even built.) Conservative for v0.4: small in-memory probes still get
#      the narrowing; large ones don't.
#
#   2. SELECTIVITY GUARD (the parquet bloom tier's `SelectivityTracker`
#      first-batch fast-pause, ported to a one-shot first-N-row sample). Even
#      for a sub-cap batch, probe the first `_SAMPLE_ROWS` (1024) rows first;
#      if the sample pass-rate is >= `BLOOM_SELECTIVITY_THRESHOLD` (0.50 --
#      the exact constant the parquet bloom tier uses) the filter isn't
#      pruning enough to be worth the full-batch probe + gather: return the
#      batch UNCHANGED, skip the rest of the probe AND the gather. The sample
#      probe is O(1024) microseconds; the full probe + gather is the cost we
#      avoid. (`apply_dyn_filter_int64` is a one-shot per-batch call here --
#      there is no persistent per-worker tracker to carry across batches, so
#      the first-N-row sample is the right shape for v0.4; the
#      stateful-across-batches tracker shape would only matter once the
#      in-memory source becomes a streaming `MorselSourceImpl` operator. See
#      the v4.2 §6.2 long-term shape note in the A.8 / B.i closure memos.)
#
# Scope (matches the single-key INT64 DynamicJoinFilter typed builder):
#   * Single-key only -- `dyn_filter_key` is one column name.
#   * INT64 keys only -- mirrors `DynamicJoinFilter.build_int64_from_list`.
#     A non-INT64 column (or a missing column) returns the batch unchanged
#     (the caller falls through to the unfiltered scan, identical to the
#     parquet path's "skip this RG" behavior on a mismatched key column).
#
# Step 0 reference findings:
#   * DataFusion `DynamicFilterPhysicalExpr` (physical-expr/.../dynamic_filters.rs)
#     + `shared_bounds.rs` -- the build side publishes a min/max + InList
#     `PhysicalExpr` into a shared `RwLock<PhysicalExprRef>` that the probe
#     scan re-evaluates per batch. DataFusion's filter is an Arrow `Expr`
#     applied via `filter_record_batch`; ours is the three-tier
#     `DynamicJoinFilter` applied per row -- same "build publishes, probe
#     consumes inline" shape, different filter representation.
#   * DuckDB `JoinFilterPushdownInfo` (physical_hash_join.cpp:864-963):
#     `CanUseBloomFilter` / `PushBloomFilter` install a `BlockedBloomFilter`
#     into the scan's `DynamicTableFilterSet`; the scan applies it inline in
#     its chunk loop. Same primitive; DuckDB's is a scan-side filter object,
#     ours is applied at `_resolve_source` time before `_apply_operators`.
#   * v0.3 Rust `VecMorselSource` (morsel_sources.rs:53-67) does NOT override
#     the `MorselSource::set_dynamic_filter` trait default (a no-op), so v0.3
#     had NO in-memory dyn-filter pushdown -- this is genuinely new in v4.2.
#     The parquet side (`InlineScanSource.set_dynamic_filter`) was the only
#     consumer; B.i closes the in-memory gap. The parquet path's
#     `SelectivityTracker` (`bloom_filter.rs:44-164`) is the guard B.i missed.
#
# Mojo discipline:
#   * No `UnsafePointer` in the public signature -- takes `var RecordBatch`,
#     a `String` key name, and an `ArcPointer[DynamicJoinFilter]` (the exact
#     shape `materialize_parquet_collect`'s `dyn_filter_arc` param uses).
#   * The internal per-row pointer read is `Column._data._typed_ptr_ro[T]()`
#     -- an origin/mut-poly typed pointer tied to the column's own buffer
#     origin (no deep copy of the key column; the same in-place read the
#     agg/join kernels use, e.g. `compiler_flat_agg.mojo:379`). The `# SAFETY:`
#     note pins it to `batch` which outlives the loop.
# =============================================================================

from std.memory import ArcPointer

from komira_arrow.schema import RecordBatch
from komira_arrow.arrow_types import ArrowType
from komira_dynamic_filter.selectivity_tracker import BLOOM_SELECTIVITY_THRESHOLD
from komira_column_kernels.compiler_helpers import gather_batch
from komira_morsel.dynamic_join_filter import (
    DYNAMIC_FILTER_BUILD_CAP,
    DynamicJoinFilter,
)


# Probe-batch row-count cap for the in-memory dyn-filter. Above this the
# O(n) bloom probe + gather overhead exceeds any downstream saving (the
# rows are already resident; a downstream hash-join probe is cheaper per
# row than the bloom probe + gather it would replace). Matches the
# build-side cap the prepass enforces.
comptime _IN_MEM_DYN_FILTER_PROBE_CAP: Int = DYNAMIC_FILTER_BUILD_CAP

# First-N-row sample size for the selectivity guard. 1024 mirrors the
# parquet bloom tier's per-batch granularity (a Parquet morsel batch is
# 1024-8192 rows; sampling 1024 is one batch's worth of probe cost).
comptime _SAMPLE_ROWS: Int = 1024


def apply_dyn_filter_int64(
    var batch: RecordBatch,
    key_col_name: String,
    df_arc: ArcPointer[DynamicJoinFilter],
) raises -> RecordBatch:
    """Apply a build-side `DynamicJoinFilter` to an in-memory probe batch.

    Probes the filter (range -> in-list -> bloom, cheapest-first) for the
    value of `key_col_name` in every row, keeping only rows that may be in
    the build set. NULL probe keys are always dropped (NULL never equi-joins).

    Cost guards (both checked before any per-row work):
      * Probe-batch size cap -- if `batch.num_rows() > _IN_MEM_DYN_FILTER_PROBE_CAP`
        (65_536) the filter is not applied (the downstream op chain runs on
        the full batch).
      * Selectivity guard -- probes a leading `_SAMPLE_ROWS`-row sample; if the
        sample pass-rate is >= `BLOOM_SELECTIVITY_THRESHOLD` (0.50), the filter
        isn't pruning enough to be worth the full-batch probe + gather, so the
        batch is returned UNCHANGED. Mirrors the parquet bloom tier's
        `SelectivityTracker` first-batch fast-pause.

    Returns the batch unchanged when:
      * `key_col_name` is empty (no single-key join key -- e.g. JOIN_CROSS).
      * the column is not present in the batch schema.
      * the column's arrow type is not INT64 (the only typed builder wired
        in `DynamicJoinFilter` today).
      * the batch has zero rows.
      * the batch has more than `_IN_MEM_DYN_FILTER_PROBE_CAP` rows.
      * the leading-sample pass-rate is >= `BLOOM_SELECTIVITY_THRESHOLD`.

    On a real (selective-enough, sub-cap) narrowing it materializes the
    surviving rows into a fresh RecordBatch via `gather_batch` (the same
    compaction primitive used by `_apply_single_op`'s OP_FILTER path). The
    result preserves the input schema (column names / types / arity) even
    when zero rows survive.

    Args:
        batch: The resolved probe-side RecordBatch (consumed).
        key_col_name: The probe-side join-key column name (one column).
        df_arc: Shared handle to the build-side `DynamicJoinFilter`. Read-only
            after the build's combine() completes; we only call the immutable
            `might_contain_int64` method through the Arc's `[]` ref.

    Returns:
        The (possibly narrowed) RecordBatch.
    """
    ref df = df_arc[]
    if key_col_name.byte_length() == 0:
        return batch^

    var nrows = batch.num_rows()
    if nrows == 0:
        return batch^
    # Cost guard 1: probe-batch size cap. Above this the in-memory dyn-filter
    # is a net loss (O(n) probe + gather on already-resident rows costs more
    # than the downstream join saves). The prepass also enforces this for
    # SOURCE_BATCH probes, so usually no filter reaches here; this is the
    # belt-and-braces enforcement at the application site.
    if nrows > _IN_MEM_DYN_FILTER_PROBE_CAP:
        return batch^

    # Resolve the probe-side key column. A missing column or a non-INT64
    # type means "we can't apply this filter here" -- return unchanged so
    # the caller's downstream logical filter chain still runs (no rows lost).
    var col_idx: Int
    try:
        col_idx = batch.schema.column_index(key_col_name)
    except:
        return batch^
    if col_idx < 0:
        return batch^
    if batch.schema.field_arrow_type(col_idx) != ArrowType.INT64:
        return batch^

    ref key_col = batch.column_at(col_idx)
    var has_validity = key_col._validity.__bool__()
    # SAFETY: `key_data` is now derived from `key_col._data.view_ro()` --
    # an origin-tied ByteView whose origin is `origin_of(key_col._data)`
    # (a sub-origin of `batch`). `key_col` is borrowed from `batch` and
    # outlives every read below. No deep copy of the key column (the
    # original B.i path did `as_primitive` which copied; this is the
    # in-place read the agg/join kernels use). The two loops below are
    # the only consumers; the `_ = key_col` keepalive at the tail pins
    # the borrow chain past the last read.
    # R3.2c.28: replace BANNED `_typed_ptr_ro[DType.int64]()` with
    # `view_ro()._unsafe_ptr().bitcast[Scalar[DType.int64]]()`. Function-
    # scope `key_view` keeps the borrow alive across both per-loop
    # consumers (sample-pass + remainder-pass).
    var key_view = key_col._data.view_ro()
    var key_data = key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    var col_offset = key_col._offset

    # Cost guard 2: selectivity sample. Probe the first `min(nrows, _SAMPLE_ROWS)`
    # rows; if the sample pass-rate is >= BLOOM_SELECTIVITY_THRESHOLD the filter
    # isn't worth the full pass. (NULLs are counted as drops -- a batch that's
    # mostly NULL keys IS being pruned, so we should take the full path.)
    var sample_n = min(nrows, _SAMPLE_ROWS)
    var keep = List[Int](capacity=nrows)
    if has_validity:
        ref validity_s = key_col._validity.value()
        for r in range(sample_n):
            if not validity_s.test(col_offset + r):
                continue  # NULL key never equi-joins -- drop.
            if df.might_contain_int64(Int64(key_data[r])):
                keep.append(r)
    else:
        for r in range(sample_n):
            if df.might_contain_int64(Int64(key_data[r])):
                keep.append(r)

    var sample_pass_rate = Float64(len(keep)) / Float64(sample_n)
    if sample_pass_rate >= BLOOM_SELECTIVITY_THRESHOLD:
        # Filter is not selective enough on the leading sample -- skip the
        # rest of the probe AND the gather. Return the batch untouched; the
        # downstream logical filter chain still runs. In-memory analog of the
        # parquet `SelectivityTracker` first-batch fast-pause.
        _ = key_col
        return batch^

    # --- Selective enough: finish the probe over the remaining rows ---------
    if has_validity:
        ref validity = key_col._validity.value()
        for r in range(sample_n, nrows):
            if not validity.test(col_offset + r):
                continue  # NULL key never equi-joins -- drop.
            if df.might_contain_int64(Int64(key_data[r])):
                keep.append(r)
    else:
        for r in range(sample_n, nrows):
            if df.might_contain_int64(Int64(key_data[r])):
                keep.append(r)
    # Keepalive: pin `key_col` past the last `key_data` read.
    _ = key_col

    if len(keep) == nrows:
        # Full-pass: every probe row may be in the build set. Skip the
        # gather entirely -- return the batch untouched.
        return batch^

    # Narrowed (incl. the zero-survivor case). `gather_batch` rebuilds each
    # column from the schema, so a zero-length result keeps the right arity.
    return gather_batch(batch, keep)
