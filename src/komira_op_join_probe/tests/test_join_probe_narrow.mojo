# `join_probe_narrow`, the deferred drain's 4-byte match index, as units:
#   * `narrow_marshal_admits` refuses each disqualifying condition alone (the
#     setting off, a selection mask, an inlined payload, a probe or build row
#     count beyond `Int32`) and admits otherwise;
#   * `NarrowMatchSink` keeps every pair, in order, on the ordinary and the
#     non-temporal store arm, for a length that is not a multiple of the SIMD
#     width, and across growths;
#   * the sink never offers the kernel less than `NARROW_HEADROOM`, nor more
#     than a chunk;
#   * `finish` raises on an index outside `Int32` (a negative one, and 2^31)
#     instead of publishing a truncated one;
#   * the record `deferred_chunk_narrowed` builds, and the widen back;
#   * the setting is on by default and follows `join_narrow_marshal_configure`.

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.record_batch import RecordBatch
from komira_op_join_build.join import PROBE_CHUNK_SIZE
from komira_op_join_probe.join_deferred_idx import IDX32_MAX
from komira_op_join_probe.join_probe_narrow import (
    NARROW_HEADROOM,
    NarrowMatchSink,
    deferred_chunk_narrowed,
    join_narrow_marshal_configure,
    join_narrow_marshal_enabled,
    join_narrow_marshal_reset_config,
    narrow_marshal_admits,
    widen_narrow_index,
)


def test_admits_refuses_each_condition_alone() raises:
    assert_true(narrow_marshal_admits(True, False, False, 100, 100), "admits")
    assert_false(narrow_marshal_admits(False, False, False, 100, 100), "setting off")
    assert_false(narrow_marshal_admits(True, True, False, 100, 100), "selection mask")
    assert_false(narrow_marshal_admits(True, False, True, 100, 100), "inlined payload")
    assert_false(narrow_marshal_admits(True, False, False, IDX32_MAX + 1, 100), "probe rows")
    assert_false(narrow_marshal_admits(True, False, False, 100, IDX32_MAX + 1), "build rows")
    assert_true(narrow_marshal_admits(True, False, False, IDX32_MAX, IDX32_MAX), "the edge")
    assert_true(narrow_marshal_admits(True, False, False, 10, 0), "an empty build side")


def _pairs(n: Int, base: Int) -> Tuple[List[Int], List[Int]]:
    """Probe indices base.., build indices 100 + base.."""
    var p = List[Int]()
    var b = List[Int]()
    for i in range(n):
        p.append(base + i)
        b.append(100 + base + i)
    return (p^, b^)


def _absorb_and_check(nt: Bool, lengths: List[Int]) raises:
    """Absorb chunks of `lengths` pairs, offering at most `chunk_capacity`,
    then check every pair in order."""
    var sink = NarrowMatchSink(10, nt)
    var total = 0
    for k in range(len(lengths)):
        var n = lengths[k]
        assert_true(sink.chunk_capacity() >= n, "the fixture fits the room")
        var pb0 = _pairs(n, total)[0].copy()
        var pb1 = _pairs(n, total)[1].copy()
        sink.absorb(Span(pb0), Span(pb1), n)
        total += n
    sink.finish()
    assert_equal(sink.n, total, "pairs kept")
    var p = sink.take_probe()
    var b = sink.take_build()
    assert_equal(len(p), total, "probe list length")
    assert_equal(len(b), total, "build list length")
    for i in range(total):
        assert_equal(Int(p[i]), i, "probe index " + String(i))
        assert_equal(Int(b[i]), 100 + i, "build index " + String(i))


def test_sink_keeps_every_pair_in_order() raises:
    # 13 = one SIMD block of 8 and a scalar tail of 5.
    _absorb_and_check(False, [13])
    _absorb_and_check(True, [13])
    _absorb_and_check(False, [3, 8, 1])


def test_sink_grows_without_losing_pairs() raises:
    """Reserved for 10 + NARROW_HEADROOM; four chunks of NARROW_HEADROOM pairs
    force growths between absorbs."""
    var lengths = List[Int]()
    for _ in range(4):
        lengths.append(NARROW_HEADROOM)
    _absorb_and_check(False, lengths)
    _absorb_and_check(True, lengths)


def test_capacity_bounds() raises:
    var sink = NarrowMatchSink(1)
    for _ in range(6):
        var room = sink.chunk_capacity()
        assert_true(room >= NARROW_HEADROOM, "never below the headroom")
        assert_true(room <= PROBE_CHUNK_SIZE, "never above a chunk")
        var pb0 = _pairs(room, sink.n)[0].copy()
        var pb1 = _pairs(room, sink.n)[1].copy()
        sink.absorb(Span(pb0), Span(pb1), room)
    sink.finish()


def test_absorb_refuses_more_than_the_room() raises:
    var sink = NarrowMatchSink(1)
    var room = sink.chunk_capacity()
    var pb0 = _pairs(sink.cap + 1, 0)[0].copy()
    var pb1 = _pairs(sink.cap + 1, 0)[1].copy()
    var raised = False
    try:
        sink.absorb(Span(pb0), Span(pb1), sink.cap + 1)
    except:
        raised = True
    assert_true(raised, "more pairs than the reserved room")
    _ = room


def _finish_raises(bad: Int, nt: Bool) raises -> Bool:
    var sink = NarrowMatchSink(4, nt)
    var p: List[Int] = [0, 1, bad, 3]
    var b: List[Int] = [0, 1, 2, 3]
    _ = sink.chunk_capacity()
    sink.absorb(Span(p), Span(b), 4)
    try:
        sink.finish()
    except:
        return True
    return False


def test_finish_refuses_an_index_outside_int32() raises:
    assert_true(_finish_raises(IDX32_MAX + 1, False), "2^31, ordinary stores")
    assert_true(_finish_raises(IDX32_MAX + 1, True), "2^31, non-temporal")
    assert_true(_finish_raises(-1, False), "a negative index")
    assert_false(_finish_raises(IDX32_MAX, False), "2^31 - 1 fits")


def test_the_narrowed_record_and_the_widen_back() raises:
    var p: List[Int32] = [0, 2, 5]
    var b: List[Int32] = [7, 7, 1]
    var rec = deferred_chunk_narrowed(RecordBatch(), p.copy(), b.copy(), 3, 9, 4, True)
    assert_true(rec.idx32 and rec.deferred and rec.cse_ok, "flags")
    assert_equal(rec.num_rows, 3, "rows")
    assert_equal(rec.pay_col, -1, "no payload")
    assert_equal(len(rec.probe_idx), 0, "no wide probe list")
    assert_equal(len(rec.build_idx), 0, "no wide build list")
    assert_equal(rec.partition_id, 3)
    assert_equal(rec.origin_hint, 9)
    assert_equal(rec.seq, 4)
    var w = widen_narrow_index(b, 3)
    assert_equal(w[0], 7)
    assert_equal(w[2], 1)
    var raised = False
    try:
        _ = deferred_chunk_narrowed(RecordBatch(), p.copy(), [1], 0, 0, 0, False)
    except:
        raised = True
    assert_true(raised, "lists of different lengths")


def test_the_setting() raises:
    join_narrow_marshal_reset_config()
    assert_true(join_narrow_marshal_enabled(), "on by default")
    join_narrow_marshal_configure(False)
    assert_false(join_narrow_marshal_enabled(), "configured off")
    join_narrow_marshal_configure(True)
    assert_true(join_narrow_marshal_enabled(), "configured on")
    join_narrow_marshal_reset_config()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
