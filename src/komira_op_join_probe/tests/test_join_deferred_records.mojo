# The deferred-output records and their 4-byte index narrowing, checked
# against a plain oracle (the lists the caller passed): both store arms and
# the single-list form narrow exactly the indices in 0..IDX32_MAX and refuse
# the rest, at and around the bound; `deferred_chunk` keeps the 8-byte lists
# on a refusal, clears them on a narrowing, and refuses each inconsistent
# argument set by name (including build and probe lists of different
# lengths); the narrowing and verdict counters count and reset; the gather's
# layout assertion agrees, or names what disagrees.

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_collections.slab import Slab

from komira_op_join_probe.join_deferred import (
    DeferredJoinChunk,
    assert_records_agree_on_layout,
    deferred_probe_retained_bytes,
    build_join_deferred_state,
)
from komira_op_join_probe.join_defer_verdict import (
    DEFER_VERDICT_COUNT,
    defer_verdict_count,
    defer_verdict_note,
    reset_defer_verdict_counters,
)
from komira_op_join_probe.join_deferred_idx import (
    IDX32_MAX,
    join_nt_declined_records,
    join_nt_index_bytes,
    join_nt_out_bytes,
    join_nt_out_declined_items,
    note_nt_declined,
    note_nt_index_write,
    note_nt_out_declined,
    note_nt_out_write,
    reset_join_nt_counters,
    try_narrow_index_pair,
    try_narrow_index_single,
)


def _batch(n: Int) raises -> RecordBatch:
    var iv = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        iv.set(i, Int64(i))
    var sb = SchemaBuilder()
    sb.add_field(Field("i", ArrowType.INT64, False))
    var bb = RecordBatchBuilder()
    bb.add_column(Column.from_primitive[DType.int64](iv^))
    return bb.build(sb.build())


def _vals() -> List[Int]:
    return [0, 1, 7, IDX32_MAX, 12345]


def test_narrow_pair_both_arms() raises:
    for nt in [True, False]:
        reset_join_nt_counters()
        var p = _vals()
        var b: List[Int] = [IDX32_MAX, 3, 2, 1, 0]
        var r = try_narrow_index_pair(p, b, 5, nt)
        assert_true(r.ok, "ok")
        var p32 = r.probe32.take()
        var b32 = r.build32.take()
        assert_equal(len(p32), 5, "len")
        for i in range(5):
            assert_equal(Int(p32[i]), p[i], "p")
            assert_equal(Int(b32[i]), b[i], "b")
        if nt:
            assert_equal(join_nt_index_bytes(), 40, "nt bytes")
            assert_equal(join_nt_declined_records(), 0, "nt declined")
        else:
            assert_equal(join_nt_index_bytes(), 0, "nt bytes off")
            assert_equal(join_nt_declined_records(), 1, "ordinary arm counted")


def test_narrow_refusals() raises:
    for nt in [True, False]:
        for which in range(4):
            var p: List[Int] = [0, 1, 2]
            var b: List[Int] = [0, 1, 2]
            if which == 0:
                p[2] = IDX32_MAX + 1
            elif which == 1:
                b[1] = -1
            elif which == 2:
                p[0] = -5
            else:
                b[2] = 4294967296
            var r = try_narrow_index_pair(p, b, 3, nt)
            assert_false(r.ok, "refuse pair " + String(which))
            var s = try_narrow_index_single(p, 3, nt)
            if which == 1 or which == 3:
                assert_true(s.ok, "single ignores build list")
            else:
                assert_false(s.ok, "refuse single " + String(which))
    var e = try_narrow_index_pair(List[Int](), List[Int](), 0)
    assert_false(e.ok, "n=0")


def test_single_counters() raises:
    reset_join_nt_counters()
    var p = _vals()
    var r = try_narrow_index_single(p, 5, True)
    assert_true(r.ok, "single ok")
    assert_equal(join_nt_index_bytes(), 20, "single nt bytes")
    var q = r.probe32.take()
    for i in range(5):
        assert_equal(Int(q[i]), p[i], "q")


def test_chunk_pair_narrowed() raises:
    var p: List[Int] = [3, 1, 2]
    var b: List[Int] = [9, 8, 7]
    var c = DeferredJoinChunk.deferred_chunk(_batch(4), p^, b^, 1, 2, 3, True)
    assert_true(c.deferred, "deferred")
    assert_true(c.idx32, "idx32")
    assert_equal(c.num_rows, 3, "rows")
    assert_equal(len(c.probe_idx), 0, "8-byte probe list cleared")
    assert_equal(len(c.build_idx), 0, "8-byte build list cleared")
    assert_equal(Int(c.probe_idx32[0]), 3, "p0")
    assert_equal(Int(c.build_idx32[2]), 7, "b2")


def test_chunk_pair_wide_keeps_8byte() raises:
    var p: List[Int] = [3, IDX32_MAX + 5]
    var b: List[Int] = [9, 8]
    var c = DeferredJoinChunk.deferred_chunk(_batch(4), p^, b^, 0, 0, 0, True)
    assert_false(c.idx32, "wide stays 8-byte")
    assert_equal(len(c.probe_idx), 2, "kept")
    assert_equal(c.probe_idx[1], IDX32_MAX + 5, "value kept")
    assert_equal(c.build_idx[1], 8, "build kept")


def _refusal_of(
    var probe: List[Int],
    var build: List[Int],
    var pay: List[Int64],
    pay_col: Int,
    var elide_map: List[Int32],
    elided: Bool,
) -> String:
    try:
        var x = DeferredJoinChunk.deferred_chunk(
            _batch(4), probe^, build^, 0, 0, 0, True, pay^, pay_col, elide_map^, elided
        )
        _ = x^
    except e:
        return String(e)
    return String("")


def test_chunk_elide_rules() raises:
    # elided, payload present, alias vector covering all build columns
    var p: List[Int] = [3, 1, 2]
    var pay: List[Int64] = [10, 20, 30]
    var ali: List[Int32] = [-1, 0]
    var c = DeferredJoinChunk.deferred_chunk(
        _batch(4), p^, List[Int](), 0, 0, 0, True, pay^, 0, ali^, True
    )
    assert_true(c.idx32, "elided narrowed")
    assert_equal(len(c.probe_idx32), 3, "probe32")
    assert_equal(len(c.build_idx32), 0, "no build32")
    assert_equal(len(c.build_pay), 3, "pay")
    var m = _refusal_of([1], List[Int](), List[Int64](), -1, List[Int32](), True)
    assert_true(m.find("no inlined payload") >= 0, "no payload: " + m)
    m = _refusal_of([1], [1], [5], 0, [-1], True)
    assert_true(m.find("build index list holds 1") >= 0, "build list: " + m)
    m = _refusal_of([1], List[Int](), [5], 1, [-1], True)
    assert_true(m.find("does not cover pay_col 1") >= 0, "short alias: " + m)
    m = _refusal_of([1], List[Int](), [5], 0, [-1, -1], True)
    assert_true(m.find("build column 1 has no probe-side alias") >= 0, "uncovered: " + m)
    m = _refusal_of([1, 2], [1, 2], [5], 0, List[Int32](), False)
    assert_true(m.find("build_pay length 1 != retained match count 2") >= 0, "pay length: " + m)


def test_retained_bytes_and_state() raises:
    assert_equal(deferred_probe_retained_bytes(_batch(10)), 80, "10 x int64")
    var st = build_join_deferred_state(3, 16, 2)
    assert_equal(len(st[].buckets), 3, "buckets")


def test_layout_assert() raises:
    var slab = Slab[DeferredJoinChunk].create(2)
    var p: List[Int] = [0, 1]
    var b: List[Int] = [0, 1]
    slab.append(DeferredJoinChunk.deferred_chunk(_batch(4), p^, b^, 0, 0, 0, True))
    var ty: List[ArrowType] = [ArrowType.INT64]
    var dp: List[Int] = [0]
    var ds: List[Int] = [0]
    assert_records_agree_on_layout(slab, ty, dp, ds, 1)  # agrees
    var wrong: List[ArrowType] = [ArrowType.INT32]
    var raised = False
    try:
        assert_records_agree_on_layout(slab, wrong, dp, ds, 1)
    except e:
        raised = True
    assert_true(raised, "type disagreement raises")
    raised = False
    try:
        assert_records_agree_on_layout(slab, ty, dp, ds, 2)
    except e:
        raised = True
    assert_true(raised, "too few probe columns raises")
    # staged record with the wrong column count
    var s2 = Slab[DeferredJoinChunk].create(1)
    s2.append(DeferredJoinChunk.staged_chunk(_batch(3), 0, 0, 0, True))
    raised = False
    try:
        assert_records_agree_on_layout(s2, ty, dp, ds, 1)  # num_cols 1 == staged cols 1 -> agrees
    except e:
        raised = True
    assert_false(raised, "staged agrees")
    var two: List[ArrowType] = [ArrowType.INT64, ArrowType.INT64]
    raised = False
    try:
        assert_records_agree_on_layout(s2, two, dp, ds, 1)
    except e:
        raised = True
    assert_true(raised, "staged width mismatch raises")


def _message_of(e: Error) -> String:
    return String(e)


def test_narrowing_at_and_around_the_bound() raises:
    for nt in [True, False]:
        # IDX32_MAX itself narrows, on either list and in any position.
        var p: List[Int] = [IDX32_MAX, 0, IDX32_MAX - 1]
        var b: List[Int] = [IDX32_MAX - 1, IDX32_MAX, 0]
        var r = try_narrow_index_pair(p, b, 3, nt)
        assert_true(r.ok, "IDX32_MAX narrows")
        var p32 = r.probe32.take()
        var b32 = r.build32.take()
        for i in range(3):
            assert_equal(Int(p32[i]), p[i], "probe value")
            assert_equal(Int(b32[i]), b[i], "build value")
        # One past it is refused, wherever it sits, and a refusal hands back
        # no half-built lists.
        for slot in range(3):
            for on_build in [False, True]:
                var pp: List[Int] = [1, 2, 3]
                var bb: List[Int] = [1, 2, 3]
                if on_build:
                    bb[slot] = IDX32_MAX + 1
                else:
                    pp[slot] = IDX32_MAX + 1
                var q = try_narrow_index_pair(pp, bb, 3, nt)
                assert_false(q.ok, "IDX32_MAX + 1 refused")
                assert_false(Bool(q.probe32), "no probe list on refusal")
                assert_false(Bool(q.build32), "no build list on refusal")
            var s: List[Int] = [1, 2, 3]
            s[slot] = IDX32_MAX + 1
            assert_false(try_narrow_index_single(s, 3, nt).ok, "single refuses")
            s[slot] = IDX32_MAX
            assert_true(try_narrow_index_single(s, 3, nt).ok, "single bound")


def test_narrowing_counts_only_what_it_wrote() raises:
    reset_join_nt_counters()
    var p: List[Int] = [1, 2, 3, 4]
    var b: List[Int] = [4, 3, 2, 1]
    assert_true(try_narrow_index_pair(p, b, 4, True).ok, "nt pair")
    assert_equal(join_nt_index_bytes(), 32, "2 lists x 4 x 4 bytes")
    assert_true(try_narrow_index_single(p, 4, True).ok, "nt single")
    assert_equal(join_nt_index_bytes(), 48, "+ 4 x 4 bytes")
    assert_equal(join_nt_declined_records(), 0, "no ordinary-arm record")
    # A refused NT narrowing writes nothing counted.
    p[3] = IDX32_MAX + 1
    assert_false(try_narrow_index_pair(p, b, 4, True).ok, "refused")
    assert_equal(join_nt_index_bytes(), 48, "a refusal adds no bytes")
    # The ordinary arm counts a record, accepted or refused, and no bytes.
    assert_false(try_narrow_index_pair(p, b, 4, False).ok, "refused")
    assert_equal(join_nt_declined_records(), 1, "refused ordinary record")
    assert_false(try_narrow_index_single(p, 4, False).ok, "refused")
    assert_equal(join_nt_declined_records(), 2, "refused single record")
    assert_equal(join_nt_index_bytes(), 48, "ordinary arm adds no NT bytes")
    reset_join_nt_counters()


def test_reset_clears_all_four_nt_counters() raises:
    reset_join_nt_counters()
    note_nt_index_write(11)
    note_nt_declined(12)
    note_nt_out_write(13)
    note_nt_out_declined(14)
    assert_equal(join_nt_index_bytes(), 11, "index bytes")
    assert_equal(join_nt_declined_records(), 12, "declined records")
    assert_equal(join_nt_out_bytes(), 13, "out bytes")
    assert_equal(join_nt_out_declined_items(), 14, "out declined")
    reset_join_nt_counters()
    assert_equal(join_nt_index_bytes(), 0, "index bytes reset")
    assert_equal(join_nt_declined_records(), 0, "declined records reset")
    assert_equal(join_nt_out_bytes(), 0, "out bytes reset")
    assert_equal(join_nt_out_declined_items(), 0, "out declined reset")


def test_reset_clears_every_verdict_counter() raises:
    reset_defer_verdict_counters()
    for c in range(DEFER_VERDICT_COUNT):
        for _ in range(c + 1):
            defer_verdict_note(c)
    for c in range(DEFER_VERDICT_COUNT):
        assert_equal(defer_verdict_count(c), c + 1, "counted")
    reset_defer_verdict_counters()
    for c in range(DEFER_VERDICT_COUNT):
        assert_equal(defer_verdict_count(c), 0, "reset code " + String(c))


def _refusal_reasons(build_lens: List[Int]) raises -> List[String]:
    var reasons = List[String]()
    for k in range(len(build_lens)):
        var p: List[Int] = [3, 1, 2]
        var b = List[Int]()
        for i in range(build_lens[k]):
            b.append(i)
        try:
            var c = DeferredJoinChunk.deferred_chunk(
                _batch(4), p^, b^, 0, 0, 0, True
            )
            _ = c^
        except e:
            reasons.append(_message_of(e))
    return reasons^


def _assert_named_reasons(reasons: List[String], expected: Int) raises:
    assert_equal(len(reasons), expected, "every length mismatch is refused")
    for i in range(len(reasons)):
        assert_true(
            reasons[i].find("build_idx holds") >= 0
            and reasons[i].find("probe_idx holds 3") >= 0,
            "named reason: " + reasons[i],
        )


def test_chunk_refuses_longer_build_list() raises:
    # A longer build list would narrow without reading out of bounds, so only
    # the length check can refuse it.
    var lens: List[Int] = [4]
    _assert_named_reasons(_refusal_reasons(lens), 1)


def test_chunk_refuses_shorter_build_lists() raises:
    var lens: List[Int] = [0, 1, 2]
    _assert_named_reasons(_refusal_reasons(lens), 3)
    # Equal lengths, including empty ones, are accepted.
    var e0 = DeferredJoinChunk.deferred_chunk(
        _batch(4), List[Int](), List[Int](), 0, 0, 0, True
    )
    assert_equal(e0.num_rows, 0, "empty record")


def main() raises:
    var suite = TestSuite()
    suite.test[test_narrow_pair_both_arms]()
    suite.test[test_narrow_refusals]()
    suite.test[test_single_counters]()
    suite.test[test_chunk_pair_narrowed]()
    suite.test[test_chunk_pair_wide_keeps_8byte]()
    suite.test[test_chunk_refuses_longer_build_list]()
    suite.test[test_chunk_refuses_shorter_build_lists]()
    suite.test[test_narrowing_at_and_around_the_bound]()
    suite.test[test_narrowing_counts_only_what_it_wrote]()
    suite.test[test_reset_clears_all_four_nt_counters]()
    suite.test[test_reset_clears_every_verdict_counter]()
    suite.test[test_chunk_elide_rules]()
    suite.test[test_retained_bytes_and_state]()
    suite.test[test_layout_assert]()
    suite^.run()
