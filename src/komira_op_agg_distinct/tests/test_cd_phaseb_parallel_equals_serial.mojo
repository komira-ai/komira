# =============================================================================
# CDPPARB — the PARALLEL Phase B emits byte-identical output to the SERIAL one,
# INCLUDING the dict-id NUMBERING
# =============================================================================
#
# Phase B of the STRING-key encode assigns a dict id per row. It is the single
# largest serial item in the grouped count-distinct driver (the dominant cost of
# a large string-key encode), and `_assign_dict_ids_parallel` now shards it.
#
# ⛔ WHAT THIS FILE IS ACTUALLY GUARDING IS NOT "the same set of values". It is
# **THE NUMBERING**. The ids feed a hash table whose ITERATION ORDER becomes the
# output group order, so a Phase B that finds the same 6M values but numbers
# them differently emits the same rows in a DIFFERENT ORDER — a change no perf
# commit can justify and one that a "did we get the right distinct values" test
# would sail straight past. Sharding by hash and offsetting each shard's ids by
# a prefix sum is the four-line parallelisation that does exactly that, and it
# is the numbering these tests reject:
#
#     test_parallel_matches_serial_encoded_exactly     <- fails on prefix-sum ids
#     test_parallel_matches_serial_reverse_map_exactly <- fails on prefix-sum ids
#
# ⚠ NON-VACUITY IS A REAL RISK HERE AND IS ASSERTED, NOT ASSUMED. If every row
# landed in one shard, or if the parallel driver silently ran one shard, the
# equivalence tests above would pass while proving nothing.
# `test_the_fixture_spreads_across_every_shard` reads the shard selector the
# driver itself uses and asserts every shard gets rows;
# `test_first_appearance_order_is_scattered_across_shards` asserts that the
# global first-seen order really does INTERLEAVE the shards (if shard 0 owned
# every early value the merge would be trivially correct).
#
# ⚠ THE ROW COUNT IS DELIBERATELY BELOW `_PHASEB_MIN_ROWS`. The routing
# threshold is in `_phaseb_shard_count`, not in `_assign_dict_ids_parallel`, so
# this file drives the parallel body DIRECTLY at 60,000 rows instead of putting
# a million-row fixture inside a welded build gate.
# `test_the_routing_thresholds_still_select_the_two_arms` covers the routing.

from std.collections import Dict, List
from std.testing import TestSuite, assert_equal, assert_not_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_counters.keyeq_census import KEYEQ_AGGCD_STRENC

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_agg_distinct.agg_count_distinct_strenc import (
    _assign_dict_ids_from_hashes,
)
# The sharded Phase B moved to its own module on 2026-09-24 (L2/L3).
from komira_op_agg_distinct.agg_cd_strenc_parb import (
    _PHASEB_MIN_ROWS,
    _assign_dict_ids_parallel,
    _phaseb_shard_count,
    _phaseb_shard_of,
)


# =============================================================================
# Fixture
# =============================================================================

comptime _N_ROWS: Int = 60_000
comptime _N_VALS: Int = 4_001
comptime _P_SHARDS: Int = 4


def _value_index(r: Int) -> Int:
    """Which distinct value row `r` carries.

    A multiplicative step coprime with `_N_VALS` so first-appearance order is
    SCATTERED rather than 0,1,2,... — a merge bug that just concatenated the
    shards would still look right on an in-order fixture.
    """
    return (r * 2_654_435_761) % _N_VALS


def _value_text(v: Int) -> String:
    """Deliberately varied: one EMPTY value, a multi-byte UTF-8 value whose
    byte length exceeds its character count, prefix-sharing values, and lengths
    on both sides of the 16-byte compare threshold."""
    if v == 0:
        return String("")
    if v % 97 == 0:
        return String("ÄÖÜ-многобайт-") + String(v)
    if v % 5 == 0:
        return String("shared-prefix-value-") + String(v)
    return String("v") + String(v)


def _rows() raises -> List[String]:
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
    """FNV-1a 64 with the production length-mix. It does not have to BE the
    production hash — both arms are handed the same vector — but it has to have
    live HIGH bits, because `_phaseb_shard_of` selects on `h >> 48`."""
    comptime BASIS = Int64(-3750763034362895579)
    comptime PRIME = Int64(1099511628211)
    var h = BASIS
    for b in s.as_bytes():
        h = (h ^ Int64(b)) * PRIME
    return h ^ (Int64(s.byte_length()) * PRIME)


def _hashes(imm vals: List[String]) raises -> List[Int64]:
    var out = List[Int64](capacity=len(vals))
    for i in range(len(vals)):
        out.append(_hash_of(vals[i]))
    return out^


struct _Encoded(Movable):
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


def _encode_serial(
    imm batch: RecordBatch, imm hashes: List[Int64]
) raises -> _Encoded:
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
    return _Encoded(encoded^, rev_bytes^, rev_starts^, rev_lens^)


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _encode_parallel(
    imm batch: RecordBatch, var hashes: List[Int64], workers: Int
) raises -> _Encoded:
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
        workers,
        rev_starts,
        rev_lens,
    )
    # ⚠ L3 (2026-09-24): the sharded arm builds NO arena — its spans index the
    # column's own value buffer — so the decode `value_at` performs reads a
    # copy of THAT buffer. The equivalence below is unchanged: same id per
    # row, same bytes per id.
    for b in data_view.into_span():
        rev_bytes.append(b)
    _ = hashes^
    _ = batch
    return _Encoded(encoded^, rev_bytes^, rev_starts^, rev_lens^)


# =============================================================================
# §1 ⭐ — THE EQUIVALENCE, INCLUDING THE NUMBERING
# =============================================================================


def test_parallel_matches_serial_encoded_exactly() raises:
    """⭐ THE CENTRAL CHECK. Row for row, the two arms must assign the SAME id.

    Rejects numbering each shard from a prefix-sum offset instead of merging
    the shards' first-appearance rows (the obvious parallelisation).
    """
    var vals = _rows()
    var batch = _string_batch(vals)
    var hs = _hashes(vals)
    var ser = _encode_serial(batch, hs)
    var par = _encode_parallel(batch, hs.copy(), _P_SHARDS)

    assert_equal(
        len(par.encoded), len(ser.encoded), "encoded length differs"
    )
    for r in range(len(ser.encoded)):
        assert_equal(
            par.encoded[r],
            ser.encoded[r],
            "row "
            + String(r)
            + ' (value "'
            + vals[r]
            + '"): the parallel Phase B assigned a different dict id.'
            + " The NUMBERING is the contract, not just the value set.",
        )


def test_parallel_matches_serial_reverse_map_exactly() raises:
    """The reverse map must decode id-for-id to the same bytes, so the emitted
    group-key column is byte-identical.

    Rejects the same prefix-sum numbering, and an arena concatenation that gets
    a shard's base offset wrong.
    """
    var vals = _rows()
    var batch = _string_batch(vals)
    var hs = _hashes(vals)
    var ser = _encode_serial(batch, hs)
    var par = _encode_parallel(batch, hs.copy(), _P_SHARDS)

    assert_equal(
        len(par.rev_starts),
        len(ser.rev_starts),
        "distinct-value COUNT differs between the two arms",
    )
    assert_equal(
        len(par.rev_lens), len(ser.rev_lens), "rev_lens length differs"
    )
    for d in range(len(ser.rev_starts)):
        assert_equal(
            par.rev_lens[d],
            ser.rev_lens[d],
            "dict id " + String(d) + ": byte LENGTH differs",
        )
        assert_equal(
            par.value_at(d),
            ser.value_at(d),
            "dict id " + String(d) + ": decoded VALUE differs",
        )


def test_every_row_decodes_to_its_own_text_through_the_parallel_arm() raises:
    """End to end, independent of the serial arm: id -> arena -> the string the
    row actually carried. Catches an arena base or span that is wrong in BOTH
    arms, which the equivalence tests cannot see."""
    var vals = _rows()
    var batch = _string_batch(vals)
    var hs = _hashes(vals)
    var par = _encode_parallel(batch, hs^, _P_SHARDS)
    for r in range(len(vals)):
        assert_equal(
            par.value_at(par.encoded[r]),
            vals[r],
            "row " + String(r) + " decoded to the wrong value",
        )


def test_distinct_count_is_the_fixtures_own() raises:
    """A merge that dropped or duplicated a shard entry changes this count, and
    it is known from the row generator rather than from either arm."""
    var vals = _rows()
    var seen = Dict[String, Int]()
    for i in range(len(vals)):
        seen[vals[i]] = 1
    var batch = _string_batch(vals)
    var hs = _hashes(vals)
    var par = _encode_parallel(batch, hs^, _P_SHARDS)
    assert_equal(
        len(par.rev_starts),
        len(seen),
        "the parallel arm's distinct count is not the fixture's",
    )


def test_one_shard_is_still_the_serial_answer() raises:
    """P=1 exercises the merge's degenerate arm (one list, no interleaving) and
    must still reproduce the serial numbering exactly."""
    var vals = _rows()
    var batch = _string_batch(vals)
    var hs = _hashes(vals)
    var ser = _encode_serial(batch, hs)
    var par = _encode_parallel(batch, hs.copy(), 1)
    for r in range(len(ser.encoded)):
        assert_equal(par.encoded[r], ser.encoded[r], "row " + String(r))


# =============================================================================
# §2 — NON-VACUITY: the fixture really does exercise the sharding
# =============================================================================


def test_the_fixture_spreads_across_every_shard() raises:
    """If one shard owned every row, §1 would pass while proving nothing. Reads
    the driver's OWN selector so a change to the selector shows up here."""
    var vals = _rows()
    var hs = _hashes(vals)
    var per_shard = List[Int](length=_P_SHARDS, fill=0)
    for r in range(len(hs)):
        per_shard[_phaseb_shard_of(hs[r], _P_SHARDS - 1)] += 1
    for p in range(_P_SHARDS):
        assert_true(
            per_shard[p] > 0,
            "shard " + String(p) + " got NO rows — the fixture is vacuous",
        )


def test_first_appearance_order_is_scattered_across_shards() raises:
    """The merge is only load-bearing if the global first-seen order
    INTERLEAVES the shards. Asserts the shard of consecutive first-appearances
    actually changes — if every early value belonged to shard 0 a concatenating
    'merge' would pass §1."""
    var vals = _rows()
    var hs = _hashes(vals)
    var seen = Dict[String, Int]()
    var order = List[Int]()
    for r in range(len(vals)):
        if vals[r] in seen:
            continue
        seen[vals[r]] = 1
        order.append(_phaseb_shard_of(hs[r], _P_SHARDS - 1))
    var switches = 0
    for i in range(1, len(order)):
        if order[i] != order[i - 1]:
            switches += 1
    assert_true(
        switches > len(order) // 4,
        "first-appearance order barely changes shard ("
        + String(switches)
        + " switches over "
        + String(len(order))
        + " values) — the merge is not being exercised",
    )


def test_the_routing_thresholds_still_select_the_two_arms() raises:
    """`_assign_dict_ids_parallel` is driven directly above, so the ROUTING is
    covered here instead. Fails if a threshold change makes one arm
    unreachable."""
    assert_equal(
        _phaseb_shard_count(_PHASEB_MIN_ROWS, 1),
        1,
        "one worker must take the SERIAL Phase B",
    )
    assert_equal(
        _phaseb_shard_count(_PHASEB_MIN_ROWS - 1, 16),
        1,
        "below the row floor the SERIAL Phase B must win",
    )
    assert_equal(
        _phaseb_shard_count(_PHASEB_MIN_ROWS, 4),
        4,
        "4 workers above the floor must shard 4 ways",
    )
    assert_equal(
        _phaseb_shard_count(_PHASEB_MIN_ROWS, 6),
        4,
        "the shard count must be a POWER OF TWO — the shard index is a mask",
    )
    assert_true(
        _phaseb_shard_count(_PHASEB_MIN_ROWS, 64) <= 16,
        "the shard count must stay capped: the serial merge is O(distinct * P)",
    )


def test_the_shard_selector_reads_the_high_bits() raises:
    """The intra-shard probe masks the LOW bits, so the shard must come from
    the HIGH ones or every value in a shard lands in one probe region. Two
    hashes differing ONLY in the low 48 bits must share a shard."""
    var a = Int64(0x0123_4567_89AB_CDEF)
    var b = Int64(0x0123_0000_0000_0000)
    assert_equal(
        _phaseb_shard_of(a, 15),
        _phaseb_shard_of(b, 15),
        "the shard selector is reading bits below 48",
    )
    var c = Int64(0x0124_4567_89AB_CDEF)
    assert_not_equal(
        _phaseb_shard_of(a, 15),
        _phaseb_shard_of(c, 15),
        "the shard selector ignores bit 48 — every row would share a shard",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
