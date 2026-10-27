# =============================================================================
# test_join_probe_chunk_spans -- the chunked INNER probe writes into caller
# spans: it returns every pair `probe_inner_into` returns, in the same order,
# across many short chunks; it refuses a span shorter than `chunk_capacity`;
# and on a payload-inline index it fills the payload span with the build
# payload of each pair.
# =============================================================================
#
# What each test catches:
#   * `test_chunks_reassemble_probe_inner_into`: a resume that loses or repeats
#     a pair at a chunk boundary (capacity 3 over chains of length 4).
#   * `test_short_spans_are_refused`: a kernel writing `chunk_capacity` entries
#     past the end of a shorter caller span. (With the length checks removed
#     this file dies with SIGSEGV, exit 139: the kernel writes past the span.)
#   * `test_payload_inline_fills_the_payload_span`: the payload word riding with
#     the wrong pair, or not written at all.
#   * `test_null_keys_match_nothing`: a NULL build key linked into a chain, or
#     a NULL probe row walking a chain, in `probe_inner_into`,
#     `count_inner_matches` and the chunked probe. NULL rows carry the value 0
#     and the other side holds a real 0, so a missed skip emits a pair.
#   * `test_phase_split_resumes_mid_chain`: the phase-split walk cutting a
#     chain at the end of a chunk and resuming it in the next call, which
#     would lose or repeat the pairs of the cut chain.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_op_join_build.join import HashJoinBuilder, ProbeInnerState
from komira_op_join_build.join_probe_phase_split import (
    JOIN_PS_BATCH,
    JOIN_PS_MIN_HEADROOM,
    join_phase_split_configure,
    join_phase_split_fired,
    join_phase_split_reset_config,
    reset_join_phase_split_counters,
)


def _keys(values: List[Int]) -> PrimitiveArray[DType.int64]:
    var arr = PrimitiveArray[DType.int64].allocate(len(values))
    for i in range(len(values)):
        arr.store[1](i, SIMD[DType.int64, 1](Int64(values[i])))
    return arr^


def _nullable_keys(
    values: List[Int], nulls: List[Bool]
) raises -> PrimitiveArray[DType.int64]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(values))
    for i in range(len(values)):
        arr.set(i, Int64(values[i]))
        if nulls[i]:
            arr._set_null(i)
    return arr^


def _drain(
    b: HashJoinBuilder,
    probe: PrimitiveArray[DType.int64],
    cap: Int,
    mut pay_out: List[Int64],
    expected_pairs: Int = -1,
) raises -> List[Int]:
    """Every pair, flattened [build, probe, build, probe, ...]. With
    `expected_pairs >= 0`, stops once more pairs than that came out: a
    resume that repeats pairs then fails the caller's count check."""
    var out = List[Int]()
    var bb = List[Int]()
    bb.resize(cap, 0)
    var pb = List[Int]()
    pb.resize(cap, 0)
    var payb = List[Int64]()
    payb.resize(cap, Int64(0))
    var st = ProbeInnerState()
    while True:
        var got = b.probe_inner_chunk(
            probe, st, Span(bb), Span(pb), Span(payb), cap
        )
        if got == 0:
            break
        for i in range(got):
            out.append(bb[i])
            out.append(pb[i])
            pay_out.append(payb[i])
        if expected_pairs >= 0 and len(out) // 2 > expected_pairs:
            break
    return out^


def test_chunks_reassemble_probe_inner_into() raises:
    # Four build rows per key, so every probe row's chain is 4 long and a
    # capacity of 3 cuts chains mid-walk.
    var bv = List[Int]()
    for k in range(10):
        for _ in range(4):
            bv.append(k)
    var pv: List[Int] = [3, 11, 0, 9, 3, 5]
    var b = HashJoinBuilder.build(_keys(bv))
    var probe = _keys(pv)
    var bm = List[Int]()
    var pm = List[Int]()
    b.probe_inner_into(probe, bm, pm)
    var want = List[Int]()
    for i in range(len(bm)):
        want.append(bm[i])
        want.append(pm[i])
    var pays = List[Int64]()
    var got = _drain(b, probe, 3, pays)
    assert_equal(len(got), len(want), "same number of pairs")
    assert_equal(len(want), 2 * 4 * 5, "five matching probe rows, four each")
    for i in range(len(want)):
        assert_equal(got[i], want[i], "pair word " + String(i))


def test_short_spans_are_refused() raises:
    var bv: List[Int] = [1, 2, 3]
    var b = HashJoinBuilder.build(_keys(bv))
    var probe = _keys(bv)
    var short_b = List[Int]()
    short_b.resize(2, 0)
    var ok_p = List[Int]()
    ok_p.resize(8, 0)
    var pay1 = List[Int64]()
    pay1.resize(1, Int64(0))
    var st = ProbeInnerState()
    var raised = False
    try:
        _ = b.probe_inner_chunk(
            probe, st, Span(short_b), Span(ok_p), Span(pay1), 8
        )
    except:
        raised = True
    assert_true(raised, "a build span shorter than chunk_capacity is refused")
    # On an index with no inlined payload, a one-element payload span is fine.
    var ok_b = List[Int]()
    ok_b.resize(8, 0)
    var st2 = ProbeInnerState()
    var got = b.probe_inner_chunk(
        probe, st2, Span(ok_b), Span(ok_p), Span(pay1), 8
    )
    assert_equal(got, 3)

    # A payload-inline index needs the payload span too.
    var pv: List[Int64] = [10, 20, 30]
    var bp = HashJoinBuilder.build(_keys(bv), pay_values=pv^, pay_build_col=1)
    assert_true(bp.pay_inline())
    var st3 = ProbeInnerState()
    raised = False
    try:
        _ = bp.probe_inner_chunk(
            probe, st3, Span(ok_b), Span(ok_p), Span(pay1), 8
        )
    except:
        raised = True
    assert_true(raised, "a payload span shorter than chunk_capacity is refused")


def test_payload_inline_fills_the_payload_span() raises:
    var bv: List[Int] = [5, 7, 5, 9]
    var pv: List[Int64] = [500, 700, 501, 900]
    var b = HashJoinBuilder.build(_keys(bv), pay_values=pv^, pay_build_col=2)
    assert_equal(b.pay_build_col(), 2)
    var probe_vals: List[Int] = [5, 9, 8, 7]
    var pays = List[Int64]()
    var got = _drain(b, _keys(probe_vals), 2, pays)
    assert_equal(len(got), 2 * 4, "build rows 0 and 2 for 5, 3 for 9, 1 for 7")
    var expect_pay: List[Int64] = [500, 700, 501, 900]
    for i in range(len(got) // 2):
        var build_row = got[2 * i]
        assert_equal(pays[i], expect_pay[build_row], "payload rides its pair")


def test_null_keys_match_nothing() raises:
    # Build rows: 0 (real), 0 (NULL, value 0), 5, 5 (NULL), 5 (real).
    var bv: List[Int] = [0, 0, 5, 5, 5]
    var bn: List[Bool] = [False, True, False, True, False]
    # Probe rows: 0 (real), 0 (NULL), 5 (real), 5 (NULL), 9 (real, absent).
    var pv: List[Int] = [0, 0, 5, 5, 9]
    var pn: List[Bool] = [False, True, False, True, False]
    var b = HashJoinBuilder.build(_nullable_keys(bv, bn))
    var probe = _nullable_keys(pv, pn)

    # Real matches only: probe 0 -> build 0; probe 2 -> build 2 and 4.
    var want_b: List[Int] = [0, 4, 2]
    var want_p: List[Int] = [0, 2, 2]
    var bm = List[Int]()
    var pm = List[Int]()
    b.probe_inner_into(probe, bm, pm)
    assert_equal(len(bm), 3, "pairs from probe_inner_into")
    var seen = 0
    for i in range(len(bm)):
        for j in range(3):
            if bm[i] == want_b[j] and pm[i] == want_p[j]:
                seen += 1
    assert_equal(seen, 3, "exactly the real pairs")
    assert_equal(b.count_inner_matches(probe), 3, "count_inner_matches")

    var pays = List[Int64]()
    var flat = _drain(b, probe, 2, pays)
    assert_equal(len(flat), 2 * 3, "pairs from the chunked probe")
    for i in range(3):
        var ok = False
        for j in range(3):
            if flat[2 * i] == want_b[j] and flat[2 * i + 1] == want_p[j]:
                ok = True
        assert_true(ok, "chunked pair " + String(i) + " is a real match")

    # A build side that is all NULL matches nothing, even a real 0 probe.
    var allnull = HashJoinBuilder.build(
        _nullable_keys([0, 0], [True, True])
    )
    var bm2 = List[Int]()
    var pm2 = List[Int]()
    allnull.probe_inner_into(_keys([0, 0]), bm2, pm2)
    assert_equal(len(bm2), 0, "all-NULL build")


def test_phase_split_resumes_mid_chain() raises:
    # 64 distinct keys, eight build rows each, plus one key with 1500 build
    # rows; 600 probe rows over 80 keys so some miss. The chunk capacity is the smallest the phase-split walk
    # accepts, far below the pair total, so chains are cut at chunk ends.
    var bv = List[Int]()
    for k in range(64):
        for _ in range(8):
            bv.append(k)
    # One key with a chain longer than a whole chunk, so a probe row's chain
    # is cut inside that single row and resumed from the saved chain position.
    for _ in range(1500):
        bv.append(100)
    var pv = List[Int]()
    for i in range(600):
        if i % 97 == 0:
            pv.append(100)
        else:
            pv.append((i * 7) % 80)
    var b = HashJoinBuilder.build(_keys(bv))
    var probe = _keys(pv)
    var bm = List[Int]()
    var pm = List[Int]()
    b.probe_inner_into(probe, bm, pm)
    var want = List[Int]()
    for i in range(len(bm)):
        want.append(bm[i])
        want.append(pm[i])
    assert_true(len(bm) > 2 * JOIN_PS_MIN_HEADROOM, "several chunks are needed")
    assert_true(len(pv) >= JOIN_PS_BATCH, "the probe fills a batch")

    join_phase_split_configure(True, 1)
    reset_join_phase_split_counters()
    var pays = List[Int64]()
    var got = _drain(b, probe, JOIN_PS_MIN_HEADROOM, pays, len(bm))
    var fired = join_phase_split_fired()
    join_phase_split_reset_config()
    reset_join_phase_split_counters()
    assert_true(fired, "the phase-split walk ran")
    assert_equal(len(got), len(want), "same number of pairs")
    # Each pair appears once: compare as multisets via a per-pair tally.
    var tally = Dict[Int, Int]()
    for i in range(len(want) // 2):
        var key = want[2 * i] * 1_000_000 + want[2 * i + 1]
        tally[key] = tally.get(key, 0) + 1
    for i in range(len(got) // 2):
        var key = got[2 * i] * 1_000_000 + got[2 * i + 1]
        var left = tally.get(key, 0)
        assert_true(left > 0, "pair " + String(i) + " is expected")
        tally[key] = left - 1


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
