# =============================================================================
# CDP-ROWDICT — the string-key encode on ROW
# RANGES: one small dictionary per range, merged in row order
# =============================================================================
#
# `_encode_string_key_parallel` now tries `_assign_dict_ids_rowdict` first: each
# task hashes and dictionary-encodes its OWN contiguous rows, the driver numbers
# the values in (task, mint) order, a parallel remap rewrites local ids to
# global ones. It replaces, for a key with few distinct values, the hash-SHARDED
# Phase B whose one shard owned a value holding nearly every row. See
# `agg_cd_strenc_rowdict.mojo`.
#
# WHAT THIS FILE PINS:
#   §1  a numbering that differs from the SERIAL Phase B at ANY task count —
#       the numbering is the output group ORDER, so the same SET is not
#       enough. The fixture's first appearances are scattered over every task
#       and include values that first appear only in the LAST task;
#   §2  a verify-on-hit that merges two values sharing a hash — forced by
#       masking the row hash down to 1 and 2 bits — including values minted
#       after the bounded verify cache filled (verified against the SOURCE);
#   §3  a decline that leaks partial output, and a decline that does not
#       happen past `max_local`;
#   §4  the ROUTE: the entry point serves a low-cardinality key through this
#       arm (a value oracle cannot see which Phase B ran — the served / decline
#       counters can), falls back for a high-cardinality one, and the LARGE_
#       STRING (Int64 offsets) instantiation answers the same.
#
# The same key through the grouped COUNT(DISTINCT) driver is tested with the
# driver.

from std.collections import Dict, List, Optional, Set
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_counters.keyeq_census import KEYEQ_AGGCD_STRENC

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_agg_distinct.agg_cd_strenc_parb import _PARB_VCACHE_BYTES
from komira_op_agg_distinct.agg_cd_strenc_rowdict import (
    _ROWDICT_MAX_LOCAL,
    _assign_dict_ids_rowdict,
    cd_strenc_rowdict_decline_count,
    cd_strenc_rowdict_served_count,
    reset_cd_strenc_rowdict_counters,
)
from komira_op_agg_distinct.agg_count_distinct_strenc import (
    _assign_dict_ids_from_hashes,
    _encode_string_key_parallel,
    _should_use_parallel_strenc,
)


comptime _WORKERS: Int = 4
# At or above `_PARALLEL_STRENC_MIN_ROWS` (65,536), so the ENTRY POINT takes
# its parallel arm; below `_PHASEB_MIN_ROWS` (1,048,576), so what it ran before
# this arm existed was the SERIAL Phase B.
comptime _N_SKEW: Int = 70_000


# =============================================================================
# Fixtures
# =============================================================================


def _skew_value(r: Int) -> String:
    """The skewed shape: nine rows in ten are ONE value; the rest scatter over
    211 values in a multiplicative order (so first appearances land in every
    task), an EMPTY value, multi-byte UTF-8, a shared prefix; and 70 values
    that first appear only in the last seventh of the rows."""
    if r % 10 != 0:
        return String("iPad")
    if r >= 60_000 and r % 140 == 0:
        return String("late-") + String(r)
    var v = ((r // 10) * 2_654_435_761) % 211
    if v == 0:
        return String("")
    if v % 17 == 0:
        return String("ÄÖÜ-многобайт-") + String(v)
    if v % 5 == 0:
        return String("shared-prefix-model-") + String(v)
    return String("m") + String(v)


def _skew_rows(n: Int) -> List[String]:
    var out = List[String](capacity=n)
    for r in range(n):
        out.append(_skew_value(r))
    return out^


def _wide_rows(n: Int, n_vals: Int) -> List[String]:
    """`n_vals` distinct values, scattered — a HIGH-cardinality key."""
    var out = List[String](capacity=n)
    for r in range(n):
        out.append(String("w") + String((r * 2_654_435_761) % n_vals))
    return out^


def _long_rows(n: Int) -> List[String]:
    """400 distinct values of ~1 KB each: ~400 KB of distinct bytes, past the
    256 KB verify cache, so the later values are verified against the SOURCE.
    The distinguishing digits come LAST, after a shared 1,000-byte body, so a
    verify really walks the bytes instead of failing on the first one."""
    var body = String()
    for _ in range(100):
        body += String("0123456789")
    var out = List[String](capacity=n)
    for r in range(n):
        var v = (r * 2_654_435_761) % 400
        out.append(String("L-") + body + String(v))
    return out^


def _string_batch(imm vals: List[String], large: Bool) raises -> RecordBatch:
    var rbb = RecordBatchBuilder.with_capacity(1)
    if large:
        rbb.add_column(
            Column.from_large_string(LargeStringArray.from_strings(vals))
        )
    else:
        rbb.add_column(Column.from_string(StringArray.from_strings(vals)))
    var sb = SchemaBuilder()
    sb.add_field(
        Field("k", ArrowType.LARGE_STRING if large else ArrowType.STRING, False)
    )
    return rbb.build(sb.build())


def _hash_of(imm s: String) -> Int64:
    """An INDEPENDENT spelling of the production row hash (FNV-1a 64 +
    length mix), for the serial oracle."""
    comptime BASIS = Int64(-3750763034362895579)
    comptime PRIME = Int64(1099511628211)
    var h = BASIS
    for b in s.as_bytes():
        h = (h ^ Int64(b)) * PRIME
    return h ^ (Int64(s.byte_length()) * PRIME)


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# =============================================================================
# The two arms, with what they produced
# =============================================================================


struct _Enc(Movable):
    """An encode's output plus a COPY of the source value buffer (a
    source-backed reverse map indexes it) and, for the serial arm, its arena."""

    var served: Bool
    var encoded: List[Int]
    var rev_starts: List[Int]
    var rev_lens: List[Int]
    var bytes: List[UInt8]

    def __init__(
        out self,
        served: Bool,
        var encoded: List[Int],
        var rev_starts: List[Int],
        var rev_lens: List[Int],
        var bytes: List[UInt8],
    ):
        self.served = served
        self.encoded = encoded^
        self.rev_starts = rev_starts^
        self.rev_lens = rev_lens^
        self.bytes = bytes^

    def value_at(self, d: Int) -> String:
        var s = self.rev_starts[d]
        return String(
            StringSlice(
                unsafe_from_utf8=Span(self.bytes)[s : s + self.rev_lens[d]]
            )
        )


def _source_copy(imm batch: RecordBatch) raises -> List[UInt8]:
    ref col_ptr = batch.column_at(0)
    var out = List[UInt8]()
    for b in col_ptr._data.view_ro().into_span():
        out.append(b)
    return out^


def _rowdict[
    OT: DType
](
    imm batch: RecordBatch,
    n_tasks: Int,
    max_local: Int = _ROWDICT_MAX_LOCAL,
    hash_and: Int64 = Int64(-1),
) raises -> _Enc:
    var n = batch.num_rows()
    ref col_ptr = batch.column_at(0)
    var data_view = col_ptr._data.view_ro()
    var data_ptr = data_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
    var offs_view = col_ptr._offsets.value().view_ro()
    var offs_ptr = offs_view._unsafe_ptr().bitcast[Scalar[OT]]()
    var encoded = List[Int]()
    var rev_starts = List[Int]()
    var rev_lens = List[Int]()
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_WORKERS, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var served = _assign_dict_ids_rowdict[OT](
        disp,
        data_ptr,
        offs_ptr,
        n,
        KEYEQ_AGGCD_STRENC,
        n_tasks,
        encoded,
        rev_starts,
        rev_lens,
        max_local,
        hash_and,
    )
    var src = _source_copy(batch)
    _ = batch
    return _Enc(served, encoded^, rev_starts^, rev_lens^, src^)


def _entry(imm batch: RecordBatch) raises -> _Enc:
    """`_encode_string_key_parallel` itself — the production entry point."""
    var n = batch.num_rows()
    ref col_ptr = batch.column_at(0)
    var data_view = col_ptr._data.view_ro()
    var data_ptr = data_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
    var offs_view = col_ptr._offsets.value().view_ro()
    var offs_ptr = offs_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var encoded = List[Int]()
    var rev_bytes = List[UInt8]()
    var rev_starts = List[Int]()
    var rev_lens = List[Int]()
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_WORKERS, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var on_src = _encode_string_key_parallel(
        disp,
        CancellationToken.never(),
        data_ptr,
        offs_ptr,
        n,
        encoded,
        rev_bytes,
        rev_starts,
        rev_lens,
    )
    var bytes = List[UInt8]()
    if on_src:
        bytes = _source_copy(batch)
    else:
        bytes = rev_bytes^
    _ = batch
    return _Enc(on_src, encoded^, rev_starts^, rev_lens^, bytes^)


def _serial[OT: DType](imm batch: RecordBatch, imm vals: List[String]) raises -> _Enc:
    """The SERIAL Phase B over the independent hashes — the oracle."""
    var n = batch.num_rows()
    var hashes = List[Int64](capacity=n)
    for i in range(n):
        hashes.append(_hash_of(vals[i]))
    ref col_ptr = batch.column_at(0)
    var data_view = col_ptr._data.view_ro()
    var data_ptr = data_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
    var offs_view = col_ptr._offsets.value().view_ro()
    var offs_ptr = offs_view._unsafe_ptr().bitcast[Scalar[OT]]()
    var encoded = List[Int]()
    var rev_bytes = List[UInt8]()
    var rev_starts = List[Int]()
    var rev_lens = List[Int]()
    _assign_dict_ids_from_hashes[OT](
        hashes,
        data_ptr,
        offs_ptr,
        n,
        KEYEQ_AGGCD_STRENC,
        encoded,
        rev_bytes,
        rev_starts,
        rev_lens,
    )
    _ = batch
    return _Enc(False, encoded^, rev_starts^, rev_lens^, rev_bytes^)


def _assert_same_numbering(
    imm got: _Enc, imm want: _Enc, imm vals: List[String], imm tag: String
) raises:
    """Row for row the same dict id, id for id the same bytes. (The message is
    built only on a mismatch: an eager one per row is most of the runtime.)"""
    assert_equal(len(got.encoded), len(want.encoded), tag + ": encoded length")
    assert_equal(
        len(got.rev_starts), len(want.rev_starts), tag + ": distinct count"
    )
    for r in range(len(want.encoded)):
        if got.encoded[r] != want.encoded[r]:
            assert_equal(
                got.encoded[r],
                want.encoded[r],
                tag + " row " + String(r) + ": a different dict id",
            )
    for d in range(len(want.rev_starts)):
        if got.rev_lens[d] != want.rev_lens[d] or got.value_at(d) != want.value_at(d):
            assert_equal(
                got.value_at(d),
                want.value_at(d),
                tag + " id " + String(d) + ": decoded value differs",
            )
    # And the id decodes to the ROW's own value (independent of either arm).
    for r in range(0, len(vals), 97):
        if got.value_at(got.encoded[r]) != vals[r]:
            assert_equal(got.value_at(got.encoded[r]), vals[r], tag + " decode")


# =============================================================================
# §1 — THE NUMBERING, AT EVERY TASK COUNT
# =============================================================================


def test_rowdict_numbering_matches_serial_at_every_task_count() raises:
    """⭐ THE CENTRAL CHECK. T = 1, 2, 3, 7 and 16 row ranges (16 > the 4 runtime
    workers: tasks outnumber workers), on the skewed key."""
    var vals = _skew_rows(_N_SKEW)
    var batch = _string_batch(vals, False)
    var want = _serial[DType.int32](batch, vals)
    # Non-vacuity: late-only values exist, and the heavy value dominates.
    assert_true(len(want.rev_starts) > 211, "fixture: late values minted")
    var tasks: List[Int] = [1, 2, 3, 7, 16]
    for i in range(len(tasks)):
        var T = tasks[i]
        var got = _rowdict[DType.int32](batch, T)
        assert_true(got.served, "T=" + String(T) + ": must SERVE (few values)")
        _assert_same_numbering(got, want, vals, "T=" + String(T))


# =============================================================================
# §2 — VERIFY-ON-HIT, INCLUDING PAST THE VERIFY CACHE
# =============================================================================


def test_rowdict_separates_values_that_share_a_hash() raises:
    """The row hash masked to 0, 1 and 2 bits: every value collides with most
    others, in the task tables AND in the merge's global table. (20,000 rows:
    a one-hash chain makes every probe walk ~200 candidates.)"""
    var vals = _skew_rows(20_000)
    var batch = _string_batch(vals, False)
    var want = _serial[DType.int32](batch, vals)
    var masks: List[Int] = [0, 1, 3]
    for i in range(len(masks)):
        var tag = "hash_and=" + String(masks[i])
        var got = _rowdict[DType.int32](
            batch, 3, _ROWDICT_MAX_LOCAL, Int64(masks[i])
        )
        assert_true(got.served, tag + ": must SERVE")
        _assert_same_numbering(got, want, vals, tag)


def test_rowdict_verifies_against_the_source_past_the_cache() raises:
    """~400 KB of distinct values fill the 256 KB verify cache; with the hash
    masked to 6 bits the late values are verified against their minting rows
    in the SOURCE, and must still separate."""
    var vals = _long_rows(2_000)
    var batch = _string_batch(vals, False)
    var want = _serial[DType.int32](batch, vals)
    var distinct_bytes = 0
    for d in range(len(want.rev_lens)):
        distinct_bytes += want.rev_lens[d]
    assert_true(
        distinct_bytes > _PARB_VCACHE_BYTES,
        "fixture: the distinct bytes must overflow the verify cache",
    )
    var got = _rowdict[DType.int32](batch, 3, _ROWDICT_MAX_LOCAL, Int64(63))
    assert_true(got.served, "must SERVE")
    _assert_same_numbering(got, want, vals, "long values")


# =============================================================================
# §3 — THE DECLINE
# =============================================================================


def test_rowdict_declines_past_max_local_and_leaves_outputs_untouched() raises:
    reset_cd_strenc_rowdict_counters()
    var vals = _wide_rows(20_000, 500)
    var batch = _string_batch(vals, False)
    var got = _rowdict[DType.int32](batch, 2, 64)
    assert_false(got.served, "500 values per task > max_local=64: DECLINE")
    assert_equal(len(got.encoded), 0, "a decline must leave `encoded` empty")
    assert_equal(len(got.rev_starts), 0, "a decline must leave rev_starts empty")
    assert_equal(len(got.rev_lens), 0, "a decline must leave rev_lens empty")
    assert_equal(cd_strenc_rowdict_decline_count(), 1, "decline witness")
    assert_equal(cd_strenc_rowdict_served_count(), 0, "served witness")
    # Exactly AT the bound it serves.
    var want = _serial[DType.int32](batch, vals)
    var at = _rowdict[DType.int32](batch, 2, 500)
    assert_true(at.served, "500 values, max_local=500: SERVE")
    _assert_same_numbering(at, want, vals, "at the bound")


# =============================================================================
# §4 — THE ROUTE, THROUGH THE ENTRY POINT
# =============================================================================


def test_entry_point_serves_a_low_cardinality_key_through_rowdict() raises:
    """Before CDP-ROWDICT a 70,000-row key ran the SERIAL Phase B here (below
    `_PHASEB_MIN_ROWS`) and returned an ARENA (False); a 5.5M-row one ran the
    hash-sharded arm. Now both run this arm and return SOURCE spans (True)."""
    assert_true(
        _should_use_parallel_strenc(_N_SKEW, _WORKERS),
        "PRECONDITION: the parallel encode must be chosen",
    )
    reset_cd_strenc_rowdict_counters()
    var vals = _skew_rows(_N_SKEW)
    var batch = _string_batch(vals, False)
    var want = _serial[DType.int32](batch, vals)
    var got = _entry(batch)
    assert_equal(cd_strenc_rowdict_served_count(), 1, "ROWDICT must serve it")
    assert_equal(cd_strenc_rowdict_decline_count(), 0, "and not decline it")
    assert_true(got.served, "a ROWDICT encode is SOURCE-backed")
    _assert_same_numbering(got, want, vals, "entry point")


def test_entry_point_falls_back_for_a_high_cardinality_key() raises:
    """~30,000 distinct values: every task passes `_ROWDICT_MAX_LOCAL`, the arm
    declines, and the previous arm answers — the same numbering."""
    reset_cd_strenc_rowdict_counters()
    var vals = _wide_rows(_N_SKEW, 30_011)
    var batch = _string_batch(vals, False)
    var want = _serial[DType.int32](batch, vals)
    var got = _entry(batch)
    assert_equal(cd_strenc_rowdict_decline_count(), 1, "ROWDICT must decline")
    assert_equal(cd_strenc_rowdict_served_count(), 0, "and not serve")
    _assert_same_numbering(got, want, vals, "fallback")


def test_rowdict_large_string_offsets() raises:
    """The Int64-offset (LARGE_STRING) instantiation — a mis-strided offsets
    read would decode wrong spans and merge values."""
    var vals = _skew_rows(_N_SKEW)
    var batch = _string_batch(vals, True)
    var want = _serial[DType.int64](batch, vals)
    var got = _rowdict[DType.int64](batch, 5)
    assert_true(got.served, "must SERVE")
    _assert_same_numbering(got, want, vals, "LARGE_STRING")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
