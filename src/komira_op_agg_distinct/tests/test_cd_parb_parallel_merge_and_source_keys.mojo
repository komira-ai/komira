# =============================================================================
# L2 + L3 — the sharded Phase B's MERGE runs on W tasks
# with the numbering unchanged, and its reverse map indexes the SOURCE buffer
# =============================================================================
#
# L2 split the single-threaded P-way merge of the shards' first-appearance
# lists into W rank ranges merged in
# parallel. L3 deleted the byte arena: a dict id's bytes are the span of the
# row that minted it, in the column's own value buffer. See
# `agg_cd_strenc_parb.mojo` for both arguments.
#
# WHAT THIS FILE PROVES:
#   §1  a merge PLAN that duplicates, skips, reorders or unbalances a rank
#       range — asserted on the pure plan function, at W values that do not
#       divide the list lengths (an off-by-one lives at a split);
#   §2  a parallel merge whose numbering differs from the SERIAL Phase B at
#       ANY task count, W in {1, 2, 3, 7} — the numbering is the contract,
#       because it is the output group order;
#   §3  an L3 reverse map that does not point at the minting row's span, and
#       a verify-on-hit that no longer separates two values sharing a hash —
#       through BOTH of its arms: the bounded verify cache (early values) and
#       the source (values minted after the cache filled).
#
# The same encode through the grouped COUNT(DISTINCT) driver (the key emit
# reading a SOURCE-backed reverse map) is tested with the driver.
#
# NON-VACUITY is asserted, not assumed: §2 checks that W > 1 really ran more
# than one merge task's worth of values per shard.

from std.collections import Dict, List, Optional
from std.math import max, min
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
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

from komira_op_agg_distinct.agg_cd_strenc_parb import (
    _PARB_VCACHE_BYTES,
    _PHASEB_MIN_ROWS,
    _assign_dict_ids_parallel,
    _parb_merge_plan,
    _parb_merge_tasks,
    _phaseb_shard_count,
    _phaseb_shard_of,
)
from komira_op_agg_distinct.agg_count_distinct_strenc import (
    _assign_dict_ids_from_hashes,
    _should_use_parallel_strenc,
)


# =============================================================================
# §1 — THE MERGE PLAN (pure)
# =============================================================================

comptime _PLAN_P: Int = 4
comptime _PLAN_ROWS: Int = 20_000


def _plan_first_rows() -> List[List[Int]]:
    """Ascending first-appearance rows per shard, CROWDED EARLY (every row
    below 2,000 is one, then one row in eleven) — the shape a real table has,
    and the one on which a row-even split is badly unbalanced."""
    var out = List[List[Int]]()
    for _ in range(_PLAN_P):
        out.append(List[Int]())
    for r in range(_PLAN_ROWS):
        if r < 2_000 or r % 11 == 0:
            var p = ((r * 2_654_435_761) >> 7) % _PLAN_P
            out[p].append(r)
    return out^


def _plan_total(imm fr: List[List[Int]]) -> Int:
    var t = 0
    for p in range(len(fr)):
        t += len(fr[p])
    return t


def test_merge_plan_partitions_every_list_at_every_width() raises:
    """Every task's slices hold exactly its id range, the ranges tile
    [0, total), and task w's rows all lie below task w+1's."""
    var fr = _plan_first_rows()
    var total = _plan_total(fr)
    var widths = List[Int]()
    widths.append(1)
    widths.append(2)
    widths.append(3)
    widths.append(5)
    widths.append(7)
    widths.append(16)
    for wi in range(len(widths)):
        var W = widths[wi]
        var lo = List[Int]()
        var g0 = List[Int]()
        _parb_merge_plan(fr, total, _PLAN_ROWS, W, lo, g0)
        var tag = "W=" + String(W)
        assert_equal(len(g0), W + 1, tag + ": g0 length")
        assert_equal(len(lo), (W + 1) * _PLAN_P, tag + ": plan length")
        assert_equal(g0[0], 0, tag + ": first task must start at id 0")
        assert_equal(g0[W], total, tag + ": last task must end at total")
        var prev_max_row = -1
        for w in range(W):
            var cnt = 0
            var min_row = _PLAN_ROWS + 1
            var max_row = -1
            for p in range(_PLAN_P):
                var a = lo[w * _PLAN_P + p]
                var b = lo[(w + 1) * _PLAN_P + p]
                assert_true(a <= b, tag + ": a slice runs backwards")
                cnt += b - a
                if a < b:
                    min_row = min(min_row, fr[p][a])
                    max_row = max(max_row, fr[p][b - 1])
            assert_equal(
                cnt,
                g0[w + 1] - g0[w],
                tag + " task " + String(w)
                + ": slice lengths do not add up to its id range",
            )
            # Balanced by VALUES: the targets are total*w/W.
            assert_equal(
                g0[w], (total * w) // W, tag + ": rank target of task " + String(w)
            )
            if cnt > 0:
                assert_true(
                    min_row > prev_max_row,
                    tag + " task " + String(w)
                    + ": holds a row at or below the previous task's last row"
                    " -- the global order would be broken",
                )
                prev_max_row = max_row


def test_merge_task_count_respects_its_floor_and_cap() raises:
    assert_equal(_parb_merge_tasks(165, 20, 16_384), 1, "few-valued: one task")
    assert_equal(
        _parb_merge_tasks(6_019_102, 20, 16_384), 20, "high-cardinality: capped"
    )
    assert_equal(_parb_merge_tasks(40_000, 20, 16_384), 2, "floor-limited")
    assert_equal(_parb_merge_tasks(0, 20, 16_384), 1, "empty: still one task")
    assert_equal(_parb_merge_tasks(10, 7, 1), 7, "test floor of 1")


# =============================================================================
# §2 / §3 fixture — a real STRING column, hashed as production hashes it
# =============================================================================

comptime _N_ROWS: Int = 60_000
comptime _N_VALS: Int = 4_001
comptime _P_SHARDS: Int = 4


def _value_index(r: Int) -> Int:
    """Scattered first-appearance order (a multiplicative step coprime with
    `_N_VALS`), so the merge really interleaves the shards."""
    return (r * 2_654_435_761) % _N_VALS


def _value_text(v: Int) -> String:
    if v == 0:
        return String("")
    if v % 97 == 0:
        return String("ÄÖÜ-многобайт-") + String(v)
    if v % 5 == 0:
        return String("shared-prefix-value-") + String(v)
    return String("v") + String(v)


def _rows() -> List[String]:
    var out = List[String](capacity=_N_ROWS)
    for r in range(_N_ROWS):
        out.append(_value_text(_value_index(r)))
    return out^


def _string_batch(imm vals: List[String]) raises -> RecordBatch:
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_string(StringArray.from_strings(vals)))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, False))
    return rbb.build(sb.build())


def _hash_of(imm s: String) -> Int64:
    comptime BASIS = Int64(-3750763034362895579)
    comptime PRIME = Int64(1099511628211)
    var h = BASIS
    for b in s.as_bytes():
        h = (h ^ Int64(b)) * PRIME
    return h ^ (Int64(s.byte_length()) * PRIME)


def _hashes(imm vals: List[String]) -> List[Int64]:
    var out = List[Int64](capacity=len(vals))
    for i in range(len(vals)):
        out.append(_hash_of(vals[i]))
    return out^


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


struct _Par(Movable):
    """What the sharded Phase B produced, plus a COPY of the source value
    buffer its reverse map indexes (L3) and the source offsets."""

    var encoded: List[Int]
    var rev_starts: List[Int]
    var rev_lens: List[Int]
    var src: List[UInt8]
    var offs: List[Int]

    def __init__(
        out self,
        var encoded: List[Int],
        var rev_starts: List[Int],
        var rev_lens: List[Int],
        var src: List[UInt8],
        var offs: List[Int],
    ):
        self.encoded = encoded^
        self.rev_starts = rev_starts^
        self.rev_lens = rev_lens^
        self.src = src^
        self.offs = offs^

    def value_at(self, d: Int) -> String:
        """Decode dict id `d` out of the SOURCE buffer — L3's contract."""
        var s = self.rev_starts[d]
        return String(
            StringSlice(unsafe_from_utf8=Span(self.src)[s : s + self.rev_lens[d]])
        )


def _encode_parallel(
    imm batch: RecordBatch,
    var hashes: List[Int64],
    workers: Int,
    remap_workers: Int,
    merge_min_per_task: Int,
) raises -> _Par:
    var n = batch.num_rows()
    ref col_ptr = batch.column_at(0)
    var data_view = col_ptr._data.view_ro()
    var data_ptr = data_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
    var offs_view = col_ptr._offsets.value().view_ro()
    var offs_ptr = offs_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()

    var encoded = List[Int]()
    var rev_starts = List[Int]()
    var rev_lens = List[Int]()

    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(workers, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()

    _assign_dict_ids_parallel[DType.int32](
        disp,
        hashes,
        encoded,
        data_ptr,
        offs_ptr,
        n,
        KEYEQ_AGGCD_STRENC,
        _P_SHARDS,
        remap_workers,
        rev_starts,
        rev_lens,
        merge_min_per_task,
    )
    var src = List[UInt8]()
    for b in data_view.into_span():
        src.append(b)
    var offs = List[Int](capacity=n + 1)
    for r in range(n + 1):
        offs.append(Int((offs_ptr + r)[]))
    _ = hashes^
    _ = batch
    return _Par(encoded^, rev_starts^, rev_lens^, src^, offs^)


struct _Ser(Movable):
    var encoded: List[Int]
    var rev_bytes: List[UInt8]
    var rev_starts: List[Int]
    var rev_lens: List[Int]

    def __init__(
        out self,
        var encoded: List[Int],
        var rev_bytes: List[UInt8],
        var rev_starts: List[Int],
        var rev_lens: List[Int],
    ):
        self.encoded = encoded^
        self.rev_bytes = rev_bytes^
        self.rev_starts = rev_starts^
        self.rev_lens = rev_lens^

    def value_at(self, d: Int) -> String:
        var s = self.rev_starts[d]
        return String(
            StringSlice(
                unsafe_from_utf8=Span(self.rev_bytes)[s : s + self.rev_lens[d]]
            )
        )


def _encode_serial(imm batch: RecordBatch, imm hashes: List[Int64]) raises -> _Ser:
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
    _assign_dict_ids_from_hashes[DType.int32](
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
    return _Ser(encoded^, rev_bytes^, rev_starts^, rev_lens^)


# =============================================================================
# §2 — THE NUMBERING, AT EVERY MERGE WIDTH
# =============================================================================


def test_parallel_merge_matches_serial_at_every_width() raises:
    """REGRESSION TEST for L2. Row for row the same dict id, and id for id
    the same bytes, as the SERIAL Phase B — at W = 1, 2, 3 and 7 merge tasks
    (7 > the 4 runtime workers: tasks outnumber workers)."""
    var vals = _rows()
    var batch = _string_batch(vals)
    var hs = _hashes(vals)
    var ser = _encode_serial(batch, hs)
    var widths = List[Int]()
    widths.append(1)
    widths.append(2)
    widths.append(3)
    widths.append(7)
    for wi in range(len(widths)):
        var W = widths[wi]
        var tag = "W=" + String(W)
        # Non-vacuity: with a floor of 1 value per task the width is W.
        assert_equal(
            _parb_merge_tasks(len(ser.rev_starts), W, 1), W, tag + ": width"
        )
        var par = _encode_parallel(batch, hs.copy(), _P_SHARDS, W, 1)
        assert_equal(len(par.encoded), len(ser.encoded), tag + ": encoded length")
        for r in range(len(ser.encoded)):
            assert_equal(
                par.encoded[r],
                ser.encoded[r],
                tag + " row " + String(r)
                + ": the parallel merge assigned a different dict id",
            )
        assert_equal(
            len(par.rev_starts), len(ser.rev_starts), tag + ": distinct count"
        )
        for d in range(len(ser.rev_starts)):
            assert_equal(
                par.value_at(d),
                ser.value_at(d),
                tag + " id " + String(d) + ": decoded value differs",
            )


def test_production_floor_merges_a_small_dictionary_on_one_task() raises:
    """At the production floor this fixture's 4,001 values take ONE merge
    task — and the answer is still the serial one."""
    var vals = _rows()
    var batch = _string_batch(vals)
    var hs = _hashes(vals)
    var ser = _encode_serial(batch, hs)
    var par = _encode_parallel(batch, hs.copy(), _P_SHARDS, _P_SHARDS, 16_384)
    for r in range(len(ser.encoded)):
        assert_equal(par.encoded[r], ser.encoded[r], "row " + String(r))


# =============================================================================
# §3 — L3: THE REVERSE MAP IS THE MINTING ROW'S SOURCE SPAN
# =============================================================================


def test_reverse_map_is_the_minting_rows_source_span() raises:
    """For every dict id, `(rev_starts, rev_lens)` is EXACTLY the span of the
    first row that carries it, in the source value buffer — not an arena."""
    var vals = _rows()
    var batch = _string_batch(vals)
    var hs = _hashes(vals)
    var par = _encode_parallel(batch, hs^, _P_SHARDS, 3, 1)
    var seen = List[Bool](length=len(par.rev_starts), fill=False)
    var minted = 0
    for r in range(_N_ROWS):
        var d = par.encoded[r]
        if seen[d]:
            continue
        seen[d] = True
        minted += 1
        assert_equal(
            par.rev_starts[d], par.offs[r], "id " + String(d) + ": start"
        )
        assert_equal(
            par.rev_lens[d],
            par.offs[r + 1] - par.offs[r],
            "id " + String(d) + ": length",
        )
    assert_equal(minted, len(par.rev_starts), "every id is minted by a row")
    for r in range(_N_ROWS):
        assert_equal(
            par.value_at(par.encoded[r]), vals[r], "row " + String(r) + " decode"
        )


def test_all_rows_share_one_hash_parallel_arm_separates_every_value() raises:
    """Every hash 0: one shard (high bits 0), one probe chain, and the ONLY
    thing that can tell values apart is the byte compare — which since L3
    reads the minting row in the SOURCE. Two values must never merge."""
    var vals = List[String]()
    for r in range(3_000):
        vals.append(_value_text((r * 7) % 211))
    var batch = _string_batch(vals)
    var zeros = List[Int64](length=len(vals), fill=Int64(0))
    var ser = _encode_serial(batch, zeros)
    var par = _encode_parallel(batch, zeros.copy(), _P_SHARDS, 2, 1)
    assert_equal(len(par.rev_starts), 211, "distinct values under one hash")
    assert_equal(len(ser.rev_starts), 211, "serial oracle's distinct count")
    for r in range(len(vals)):
        assert_equal(par.encoded[r], ser.encoded[r], "row " + String(r))
        assert_equal(par.value_at(par.encoded[r]), vals[r], "row decode")


def _long_value(v: Int) -> String:
    """~1 KB, sharing a long common prefix, so a verify must compare deep
    before it can tell two values apart; distinct by their TAIL."""
    var s = String("")
    for _ in range(62):
        s += String("common-prefix-16")
    return s + String("|tail-") + String(v)


def test_verify_cache_overflow_both_arms_separate_values() raises:
    """600 distinct ~1 KB values overflow the per-shard verify cache
    (`_PARB_VCACHE_BYTES`), so the early ids verify against the CACHE and the
    late ids against the SOURCE. Every hash 0 puts all of them on one probe
    chain, so each probe byte-compares against every earlier value it passes:
    a wrong answer from either arm merges two values or splits one."""
    var n_vals = 600
    assert_true(
        n_vals * 1000 > 2 * _PARB_VCACHE_BYTES,
        "PRECONDITION: the fixture must overflow the verify cache",
    )
    var vals = List[String]()
    for r in range(4 * n_vals):
        vals.append(_long_value((r * 7) % n_vals))
    var batch = _string_batch(vals)
    var zeros = List[Int64](length=len(vals), fill=Int64(0))
    var ser = _encode_serial(batch, zeros)
    var par = _encode_parallel(batch, zeros.copy(), _P_SHARDS, 3, 1)
    assert_equal(len(par.rev_starts), n_vals, "distinct values under one hash")
    for r in range(len(vals)):
        assert_equal(par.encoded[r], ser.encoded[r], "row " + String(r))
        assert_equal(par.value_at(par.encoded[r]), vals[r], "row decode")
    # And with the REAL hashes: the same two arms, spread over the shards.
    var hs = _hashes(vals)
    var ser2 = _encode_serial(batch, hs)
    var par2 = _encode_parallel(batch, hs.copy(), _P_SHARDS, 3, 1)
    for r in range(len(vals)):
        assert_equal(par2.encoded[r], ser2.encoded[r], "hashed row " + String(r))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
