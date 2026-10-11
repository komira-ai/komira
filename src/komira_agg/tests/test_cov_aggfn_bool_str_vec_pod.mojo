# =============================================================================
# test_cov_aggfn_bool_str_vec_pod.mojo — COUNT over bool and string, the
# `*Vec` cells, and the PodState gate's predicates
# =============================================================================
#
# Oracles, worked out by hand over non-null values:
#   COUNT(x) over bool / string = the number of values (0 for no rows).
#   The `*Vec` cells are SUM / MIN / MAX / COUNT / AVG over Int64 or Float64
#   with the scalar bodies of their non-Vec siblings: the same SQL answers.
# Each cell runs through `update`, `update_scalar` and `merge` at every cut
# of its list, so every `merge` arm (unseen left, unseen right, both seen)
# runs. Empty-group answers of MIN / MAX / SUM / AVG (SQL NULL) are not
# pinned: the cells have no NULL output.
#
# `AnyBool` / `AllBool` are not driven here: their `update_scalar` and `merge`
# store `a or b` / `a and b` as a value, a shape the branch classifier
# refuses ("right operand not counted"), and a refused branch fails this
# library's coverage gate. They wait on that classifier issue.
#
# The PodState gate (`pod_state_gate.mojo`) is a comptime check; its
# predicates are ordinary functions, so they are called here at run time
# against the documented allowlist: the eleven scalar types, and
# `InlineArray[<scalar>, N]` for N in [1, MAX_INLINE_ARRAY_N]. A heap-owning
# type and an array one past the cap must answer False. (A State that fails
# the gate is a compile error, which a welded test cannot hold.)
# =============================================================================

from std.collections import Array
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_udf.agg_fn import AggFn, PodState
from komira_agg.builtin_agg_fns_states import RowBool, RowI64, RowF64
from komira_agg.builtin_agg_fns_bool import CountBool
from komira_agg.builtin_agg_fns_string import CountStr, RowStr
from komira_agg.builtin_agg_fns_vec import (
    SumI64Vec, SumF64Vec, MinI64Vec, MaxI64Vec, CountI64Vec, AvgF64Vec,
)
from komira_agg.pod_state_gate import (
    MAX_INLINE_ARRAY_N,
    _is_pod_scalar,
    _is_inline_array_of_elem,
    _is_pod_inline_array,
    _is_pod_field,
    assert_pod_state,
)


def _fold[
    dt: DType, F: AggFn
](f: F, vals: List[Scalar[dt]], lo: Int, hi: Int) -> F.State:
    var s = f.init()
    for i in range(lo, hi):
        f.update_scalar(s, vals[i])
    return s^


def _check_cuts[
    dt: DType, F: AggFn
](f: F, name: String, vals: List[Scalar[dt]], want: Scalar[F.OutType]) raises:
    var n = len(vals)
    assert_equal(f.finalize(_fold[dt, F](f, vals, 0, n)), want, name + " serial")
    for k in range(n + 1):
        var m = f.merge(_fold[dt, F](f, vals, 0, k), _fold[dt, F](f, vals, k, n))
        assert_equal(f.finalize(m), want, name + " merge at cut " + String(k))


def _fold_bool[F: AggFn](f: F, vals: List[Bool], lo: Int, hi: Int) -> F.State:
    var s = f.init()
    for i in range(lo, hi):
        f.update_scalar(s, vals[i])
    return s^


def _check_cuts_bool[
    F: AggFn
](f: F, name: String, vals: List[Bool], want: Scalar[F.OutType]) raises:
    var n = len(vals)
    assert_equal(f.finalize(_fold_bool[F](f, vals, 0, n)), want, name + " serial")
    for k in range(n + 1):
        var m = f.merge(_fold_bool[F](f, vals, 0, k), _fold_bool[F](f, vals, k, n))
        assert_equal(f.finalize(m), want, name + " merge at cut " + String(k))


# =============================================================================
# COUNT over bool
# =============================================================================



def test_count_bool() raises:
    """COUNT(bool) counts values, True and False alike; 0 for no rows."""
    var s = CountBool().init()
    assert_equal(CountBool().finalize(s), Int64(0))
    CountBool().update(s, RowBool(False))
    CountBool().update(s, RowBool(True))
    assert_equal(CountBool().finalize(s), Int64(2))
    _check_cuts_bool(CountBool(), "CountBool", [False, False, True], Int64(3))


# =============================================================================
# COUNT over string
# =============================================================================


def test_count_str() raises:
    """COUNT(string) counts values, including the empty string; 0 for no rows.
    `merge` adds the partial counts."""
    var f = CountStr()
    var a = f.init()
    assert_equal(f.finalize(a), Int64(0))
    f.update(a, RowStr(String("x")))
    f.update(a, RowStr(String("")))
    var b = f.init()
    f.update_scalar(b, String("long enough to live on the heap, not inline"))
    assert_equal(f.finalize(a), Int64(2))
    assert_equal(f.finalize(b), Int64(1))
    assert_equal(f.finalize(f.merge(a, b)), Int64(3))
    assert_equal(f.finalize(f.merge(f.init(), b)), Int64(1))


# =============================================================================
# The *Vec cells
# =============================================================================


def test_vec_cells() raises:
    """SUM/MIN/MAX/COUNT over Int64 [5, MIN+10, MAX-10, 3] (MIN is MIN+10, MAX is
    MAX-10, the sum is 7 with no partial sum outside Int64 at any cut), and
    SUM/AVG over Float64 [0.5, -3.0, 6.25, 0.25] (4.0 and 1.0, exact)."""
    var vi: List[Int64] = [Int64(5), Int64.MIN + 10, Int64.MAX - 10, Int64(3)]
    # (MIN + 10) + (MAX - 10) = -1, so the sum is 5 - 1 + 3 = 7.
    var s = SumI64Vec().init()
    SumI64Vec().update(s, RowI64(Int64(2)))
    assert_equal(SumI64Vec().finalize(s), Int64(2))
    _check_cuts[DType.int64](SumI64Vec(), "SumI64Vec", vi, Int64(7))

    var mn = MinI64Vec().init()
    MinI64Vec().update(mn, RowI64(Int64(2)))
    MinI64Vec().update(mn, RowI64(Int64(-2)))
    MinI64Vec().update(mn, RowI64(Int64(1)))
    assert_equal(MinI64Vec().finalize(mn), Int64(-2))
    _check_cuts[DType.int64](MinI64Vec(), "MinI64Vec", vi, Int64.MIN + 10)

    var mx = MaxI64Vec().init()
    MaxI64Vec().update(mx, RowI64(Int64(-2)))
    MaxI64Vec().update(mx, RowI64(Int64(2)))
    MaxI64Vec().update(mx, RowI64(Int64(1)))
    assert_equal(MaxI64Vec().finalize(mx), Int64(2))
    _check_cuts[DType.int64](MaxI64Vec(), "MaxI64Vec", vi, Int64.MAX - 10)

    var c = CountI64Vec().init()
    assert_equal(CountI64Vec().finalize(c), Int64(0))
    CountI64Vec().update(c, RowI64(Int64(0)))
    assert_equal(CountI64Vec().finalize(c), Int64(1))
    _check_cuts[DType.int64](CountI64Vec(), "CountI64Vec", vi, Int64(4))

    var vf: List[Float64] = [Float64(0.5), Float64(-3.0), Float64(6.25), Float64(0.25)]
    var sf = SumF64Vec().init()
    SumF64Vec().update(sf, RowF64(Float64(1.5)))
    assert_equal(SumF64Vec().finalize(sf), Float64(1.5))
    _check_cuts[DType.float64](SumF64Vec(), "SumF64Vec", vf, Float64(4.0))

    var av = AvgF64Vec().init()
    AvgF64Vec().update(av, RowF64(Float64(1.5)))
    AvgF64Vec().update(av, RowF64(Float64(2.5)))
    assert_equal(AvgF64Vec().finalize(av), Float64(2.0))
    _check_cuts[DType.float64](AvgF64Vec(), "AvgF64Vec", vf, Float64(1.0))


# =============================================================================
# The PodState gate's predicates
# =============================================================================


@fieldwise_init
struct _FlatState(PodState):
    var a: Int8
    var b: UInt64
    var c: Float32
    var d: Bool


@fieldwise_init
struct _ArrayState(PodState):
    var regs: Array[UInt8, 16]
    var n: Int64


def test_pod_scalar_allowlist() raises:
    """The eleven blessed scalar types are PodScalar; String, a List and the
    platform `Int` (not on the documented list) are not."""
    assert_true(_is_pod_scalar[Int8]())
    assert_true(_is_pod_scalar[Int16]())
    assert_true(_is_pod_scalar[Int32]())
    assert_true(_is_pod_scalar[Int64]())
    assert_true(_is_pod_scalar[UInt8]())
    assert_true(_is_pod_scalar[UInt16]())
    assert_true(_is_pod_scalar[UInt32]())
    assert_true(_is_pod_scalar[UInt64]())
    assert_true(_is_pod_scalar[Float32]())
    assert_true(_is_pod_scalar[Float64]())
    assert_true(_is_pod_scalar[Bool]())
    assert_false(_is_pod_scalar[String]())
    assert_false(_is_pod_scalar[List[Int64]]())
    assert_false(_is_pod_scalar[Int]())


def test_pod_inline_array_allowlist() raises:
    """`InlineArray[<scalar>, N]` passes for each scalar element and for N at
    both ends of [1, MAX_INLINE_ARRAY_N]; N one past the cap, a String element
    and a bare scalar do not."""
    assert_equal(MAX_INLINE_ARRAY_N, 256)
    assert_true(_is_pod_inline_array[Array[Int8, 1]]())
    assert_true(_is_pod_inline_array[Array[Int16, 2]]())
    assert_true(_is_pod_inline_array[Array[Int32, 3]]())
    assert_true(_is_pod_inline_array[Array[Int64, 4]]())
    assert_true(_is_pod_inline_array[Array[UInt8, 256]]())
    assert_true(_is_pod_inline_array[Array[UInt16, 5]]())
    assert_true(_is_pod_inline_array[Array[UInt32, 6]]())
    assert_true(_is_pod_inline_array[Array[UInt64, 7]]())
    assert_true(_is_pod_inline_array[Array[Float32, 8]]())
    assert_true(_is_pod_inline_array[Array[Float64, 9]]())
    assert_true(_is_pod_inline_array[Array[Bool, 10]]())
    assert_false(_is_pod_inline_array[Array[UInt8, 257]]())
    assert_false(_is_pod_inline_array[Array[String, 2]]())
    assert_false(_is_pod_inline_array[Int64]())
    # The element sweep matches the exact element type only.
    assert_true(_is_inline_array_of_elem[Array[Int32, 4], Int32]())
    assert_false(_is_inline_array_of_elem[Array[Int32, 4], UInt32]())


def test_pod_field_and_gate() raises:
    """A field is slab-safe iff it is a PodScalar or a PodScalar InlineArray;
    the gate accepts States made only of those."""
    assert_true(_is_pod_field[Float64]())
    assert_true(_is_pod_field[Array[Int64, 2]]())
    assert_false(_is_pod_field[String]())
    assert_false(_is_pod_field[List[Float64]]())
    assert_pod_state[_FlatState]()
    assert_pod_state[_ArrayState]()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
