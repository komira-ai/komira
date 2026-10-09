# =============================================================================
# Boolean composition templates of expr_kernel_templates.mojo: AND, OR, NOT
# over Bool (ids 57..59).
#
# An eleven-row column holding every pairing of the two operands is cut into
# chunks of W lanes (`eval[W]`, lane-wise `&`, `|`, `~`); the rows left over
# go through `eval_row` (Mojo's short-circuit `and` / `or` / `not`). W runs
# over 1, 4, 8 and 16 (16: every row scalar), so every pairing reaches both
# paths. These two-valued templates carry no NULL: Kleene logic for nullable
# operands is kleene.mojo's.
#
# This file is apart from the other template tests because `eval_row`'s
# `row.a and row.b` stores the short-circuit result straight into a field,
# a shape the branch classifier refuses today (a refused test writes no
# branch records at all), so the refusal costs only this test's records.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_kernels.simd_of import SimdOf
from komira_kernels.expr_kernel_templates import (
    BoolPairRow,
    BoolRow,
    GenBool_And,
    GenBool_Not,
    GenBool_Or,
)


comptime T = True
comptime F = False


def _bvec[W: Int](xs: List[Bool], off: Int) -> SIMD[DType.bool, W]:
    var v = SIMD[DType.bool, W](fill=xs[off])
    for l in range(W):
        v[l] = xs[off + l]
    return v


def _blanes[W: Int](
    got: SIMD[DType.bool, W], want: List[Bool], off: Int, what: String
) raises:
    for l in range(W):
        assert_equal(Bool(got[l]), want[off + l], what + " row " + String(off + l))


def _run_bool[W: Int]() raises:
    var a: List[Bool] = [T, T, F, F, T, F, T, F, T, T, F]
    var b: List[Bool] = [T, F, T, F, F, F, T, T, T, F, F]
    var and_: List[Bool] = [T, F, F, F, F, F, T, F, T, F, F]
    var or_: List[Bool] = [T, T, T, F, T, F, T, T, T, T, F]
    var not_: List[Bool] = [F, F, T, T, F, T, F, T, F, F, T]
    var n = len(a)
    var i = 0
    while i + W <= n:
        var s = SimdOf[BoolPairRow, W].zero()
        s.set_bool[0](_bvec[W](a, i))
        s.set_bool[1](_bvec[W](b, i))
        var u = SimdOf[BoolRow, W].zero()
        u.set_bool[0](_bvec[W](a, i))
        _blanes(GenBool_And.eval[W](s).get_bool[0](), and_, i, "and")
        _blanes(GenBool_Or.eval[W](s).get_bool[0](), or_, i, "or")
        _blanes(GenBool_Not.eval[W](u).get_bool[0](), not_, i, "not")
        i += W
    while i < n:
        var r = BoolPairRow(a=a[i], b=b[i])
        var t = " row " + String(i)
        assert_equal(GenBool_And.eval_row(r).a, and_[i], "and" + t)
        assert_equal(GenBool_Or.eval_row(r).a, or_[i], "or" + t)
        assert_equal(GenBool_Not.eval_row(BoolRow(a=a[i])).a, not_[i], "not" + t)
        i += 1


def test_bool_composition() raises:
    """IDs 57..59: the truth tables, lane by lane and row by row."""
    _run_bool[1]()
    _run_bool[4]()
    _run_bool[8]()
    _run_bool[16]()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
