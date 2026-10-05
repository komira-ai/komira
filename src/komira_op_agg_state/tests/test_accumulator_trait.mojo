# =============================================================================
# Unit tests for Accumulator trait conformance
# =============================================================================

from std.memory import alloc

from komira_core.arrow import ArrowType, Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.accumulator_trait import Accumulator
from komira_op_agg_state.columnar_acc_typed import (
    SumI64Acc, CountI64Acc, MinI64Acc, MaxI64Acc, SumF64KahanAcc,
)
from komira_op_agg_state.columnar_acc_agg import CountDistinctAcc


def _gid_span(
    p: UnsafePointer[Int, MutUntrackedOrigin], n: Int
) -> Span[Int, MutUntrackedOrigin]:
    """The group-id buffer as the trait takes it: a span over `n` Ints."""
    return Span[Int, MutUntrackedOrigin](unsafe_ptr=p, length=n)


def _byte_span(
    p: UnsafePointer[UInt8, MutUntrackedOrigin], n_bytes: Int
) -> Span[UInt8, MutUntrackedOrigin]:
    """The value column's data buffer as the trait takes it: a span of bytes."""
    return Span[UInt8, MutUntrackedOrigin](unsafe_ptr=p, length=n_bytes)


def _make_gids(values: List[Int]) -> UnsafePointer[Int, MutUntrackedOrigin]:
    var buf = alloc[Int](len(values))
    for i in range(len(values)):
        (buf + i).unsafe_write(values[i])
    return buf


def _make_int64_data(values: List[Int64]) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """Allocate an Int64 data buffer. Caller must free."""
    var buf = alloc[Int64](len(values))
    for i in range(len(values)):
        (buf + i).unsafe_write(values[i])
    return buf.bitcast[UInt8]()


def _make_float64_data(values: List[Float64]) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    var buf = alloc[Float64](len(values))
    for i in range(len(values)):
        (buf + i).unsafe_write(values[i])
    return buf.bitcast[UInt8]()


def test_sum_i64_trait() raises:
    var acc = SumI64Acc()
    acc.ensure_capacity(3)
    var gl = List[Int]()
    gl.append(0)
    gl.append(1)
    gl.append(2)
    gl.append(0)
    gl.append(1)
    var gids = _make_gids(gl)
    var vl = List[Int64]()
    vl.append(Int64(10))
    vl.append(Int64(20))
    vl.append(Int64(30))
    vl.append(Int64(40))
    vl.append(Int64(50))
    var col_data = _make_int64_data(vl)
    acc.update_batch(_gid_span(gids, 5), _byte_span(col_data, 5 * 8), 0, 5)
    gids.free()
    col_data.free()
    if acc.state[0] != Int64(50) or acc.state[1] != Int64(70) or acc.state[2] != Int64(30):
        raise Error("T1 FAIL: SumI64 wrong state")
    print("    PASS test_sum_i64_trait")


def test_count_i64_trait() raises:
    var acc = CountI64Acc()
    acc.ensure_capacity(2)
    var gl = List[Int]()
    gl.append(0)
    gl.append(0)
    gl.append(1)
    var gids = _make_gids(gl)
    var vl = List[Int64]()
    vl.append(Int64(99))
    vl.append(Int64(99))
    vl.append(Int64(99))
    var col_data = _make_int64_data(vl)
    acc.update_batch(_gid_span(gids, 3), _byte_span(col_data, 3 * 8), 0, 3)
    gids.free()
    col_data.free()
    if acc.state[0] != Int64(2) or acc.state[1] != Int64(1):
        raise Error("T2 FAIL: CountI64 wrong state")
    print("    PASS test_count_i64_trait")


def test_min_i64_trait() raises:
    var acc = MinI64Acc()
    acc.ensure_capacity(2)
    var gl = List[Int]()
    gl.append(0)
    gl.append(0)
    gl.append(1)
    var gids = _make_gids(gl)
    var vl = List[Int64]()
    vl.append(Int64(30))
    vl.append(Int64(10))
    vl.append(Int64(50))
    var col_data = _make_int64_data(vl)
    acc.update_batch(_gid_span(gids, 3), _byte_span(col_data, 3 * 8), 0, 3)
    gids.free()
    col_data.free()
    if acc.state[0] != Int64(10) or acc.state[1] != Int64(50):
        raise Error("T3 FAIL: MinI64 wrong state")
    print("    PASS test_min_i64_trait")


def test_max_i64_trait() raises:
    var acc = MaxI64Acc()
    acc.ensure_capacity(2)
    var gl = List[Int]()
    gl.append(0)
    gl.append(0)
    gl.append(1)
    var gids = _make_gids(gl)
    var vl = List[Int64]()
    vl.append(Int64(10))
    vl.append(Int64(30))
    vl.append(Int64(5))
    var col_data = _make_int64_data(vl)
    acc.update_batch(_gid_span(gids, 3), _byte_span(col_data, 3 * 8), 0, 3)
    gids.free()
    col_data.free()
    if acc.state[0] != Int64(30) or acc.state[1] != Int64(5):
        raise Error("T4 FAIL: MaxI64 wrong state")
    print("    PASS test_max_i64_trait")


def test_sum_f64_kahan_trait() raises:
    var acc = SumF64KahanAcc()
    acc.ensure_capacity(1)
    var gl = List[Int]()
    gl.append(0)
    gl.append(0)
    gl.append(0)
    var gids = _make_gids(gl)
    var vl = List[Float64]()
    vl.append(Float64(1.5))
    vl.append(Float64(2.5))
    vl.append(Float64(3.0))
    var col_data = _make_float64_data(vl)
    acc.update_batch(_gid_span(gids, 3), _byte_span(col_data, 3 * 8), 0, 3)
    gids.free()
    col_data.free()
    var diff = acc.sum[0] - Float64(7.0)
    if diff > Float64(0.0001) or diff < Float64(-0.0001):
        raise Error("T5 FAIL: SumF64Kahan wrong sum")
    print("    PASS test_sum_f64_kahan_trait")


def test_count_distinct_trait() raises:
    var acc = CountDistinctAcc()
    acc.ensure_capacity(2)
    var gl = List[Int]()
    gl.append(0)
    gl.append(0)
    gl.append(0)
    gl.append(1)
    gl.append(1)
    var gids = _make_gids(gl)
    var vl = List[Int64]()
    vl.append(Int64(10))
    vl.append(Int64(10))
    vl.append(Int64(20))
    vl.append(Int64(30))
    vl.append(Int64(30))
    var col_data = _make_int64_data(vl)
    acc.update_batch(_gid_span(gids, 5), _byte_span(col_data, 5 * 8), 0, 5)
    gids.free()
    col_data.free()
    var result = acc.finalize()
    if result[0] != Int64(2) or result[1] != Int64(1):
        raise Error("T6 FAIL: CountDistinct wrong result")
    print("    PASS test_count_distinct_trait")


def main() raises:
    print("Running Accumulator trait tests...")
    test_sum_i64_trait()
    test_count_i64_trait()
    test_min_i64_trait()
    test_max_i64_trait()
    test_sum_f64_kahan_trait()
    test_count_distinct_trait()
    print("All Accumulator trait tests passed (6/6)")
