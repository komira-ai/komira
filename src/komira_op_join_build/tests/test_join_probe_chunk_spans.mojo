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
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_op_join_build.join import HashJoinBuilder, ProbeInnerState


def _keys(values: List[Int]) -> PrimitiveArray[DType.int64]:
    var arr = PrimitiveArray[DType.int64].allocate(len(values))
    for i in range(len(values)):
        arr.store[1](i, SIMD[DType.int64, 1](Int64(values[i])))
    return arr^


def _drain(
    b: HashJoinBuilder,
    probe: PrimitiveArray[DType.int64],
    cap: Int,
    mut pay_out: List[Int64],
) raises -> List[Int]:
    """Every pair, flattened [build, probe, build, probe, ...]."""
    var out = List[Int]()
    var bb = List[Int]()
    bb.resize(cap, 0)
    var pb = List[Int]()
    pb.resize(cap, 0)
    var payb = List[Int64]()
    payb.resize(cap, Int64(0))
    var st = ProbeInnerState()
    var trips = 0
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
        trips += 1
        if trips > 10_000:
            raise Error("chunked probe made no progress")
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
