# =============================================================================
# The `mut RecordBatch` walker of `ExpressionExecutor` (`select_expression`,
# `select_expression_adaptive`, `_eval_bool`, `_dispatch_comparison`) and
# `bare_col_name_at`.
#
# Every comparison kind the walker serves is run once against a literal and
# column-against-column, with the survivor list worked by hand; the kinds it
# does not serve (IN-list, OR, a non-Bool root) and a literal on the left
# must raise. The adaptive entry point is run with one to three conjuncts,
# with a conjunction state of the wrong length, and over more rows than a
# default selection holds.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.selection_vector_row import RowSelectionVector
from komira_eval.expression_executor import ExpressionExecutor
from komira_eval.filter_state import FilterState
from komira_kernels.runtime_expr import (
    EXPR_EQ_F64,
    EXPR_EQ_I64,
    EXPR_GE_F64,
    EXPR_GE_I64,
    EXPR_GT_F64,
    EXPR_GT_I64,
    EXPR_LE_F64,
    EXPR_LE_I64,
    EXPR_LT_F64,
    EXPR_LT_I64,
    EXPR_NE_F64,
    EXPR_NE_I64,
    RuntimeExpr,
    make_and,
    make_col,
    make_ge_i64,
    make_in_list,
    make_le_i64,
    make_lit_f64,
    make_lit_i64,
    make_lt_i64,
    make_or,
)


def _batch(i: List[Int], j: List[Int], f: List[Float64], g: List[Float64]) raises -> RecordBatch:
    var li = List[Scalar[DType.int64]]()
    var lj = List[Scalar[DType.int64]]()
    var lf = List[Scalar[DType.float64]]()
    var lg = List[Scalar[DType.float64]]()
    for r in range(len(i)):
        li.append(Scalar[DType.int64](Int64(i[r])))
        lj.append(Scalar[DType.int64](Int64(j[r])))
        lf.append(Scalar[DType.float64](f[r]))
        lg.append(Scalar[DType.float64](g[r]))
    var sb = SchemaBuilder()
    sb.add_field(Field("i", DType.int64, False))
    sb.add_field(Field("j", DType.int64, False))
    sb.add_field(Field("f", DType.float64, False))
    sb.add_field(Field("g", DType.float64, False))
    return RecordBatch.from_typed_columns_4(
        sb.build(),
        Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(li^)),
        Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(lj^)),
        Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(lf^)),
        Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(lg^)),
    )


def _fixture() raises -> RecordBatch:
    """i = [5, 1, 4, 2, 3], j = [5, 2, 3, 2, 9],
    f = [0.5, 1.5, 2.5, 3.5, 4.5], g = [0.5, 2.0, 2.0, 3.5, 1.0]."""
    return _batch(
        [5, 1, 4, 2, 3], [5, 2, 3, 2, 9],
        [0.5, 1.5, 2.5, 3.5, 4.5], [0.5, 2.0, 2.0, 3.5, 1.0],
    )


comptime I = 0
comptime J = 1
comptime F = 2
comptime G = 3


def _names() -> List[String]:
    var names: List[String] = ["i", "j", "f", "g"]
    return names^


def _node(kind: Int, left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(kind, Int64(0), 0.0, False, 0, left, right)


def _cmp(kind: Int, var lhs: RuntimeExpr, var rhs: RuntimeExpr) -> ExpressionExecutor:
    var pool = List[RuntimeExpr]()
    pool.append(lhs)
    pool.append(rhs)
    pool.append(_node(kind, 0, 1))
    return ExpressionExecutor(pool^, 2, _names())


def _select(exec: ExpressionExecutor) raises -> List[Int]:
    var batch = _fixture()
    var sel = RowSelectionVector(batch.num_rows())
    var n = exec.select_expression(batch, sel)
    var out = List[Int]()
    for k in range(n):
        out.append(Int(sel.get(k)))
    return out^


def _expect(got: List[Int], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": survivor count")
    for k in range(len(want)):
        assert_equal(got[k], want[k], what + ": survivor " + String(k))


def test_every_int64_operator_against_a_literal() raises:
    """i <op> 3 over i = [5, 1, 4, 2, 3]."""
    var kinds: List[Int] = [EXPR_GT_I64, EXPR_GE_I64, EXPR_LT_I64, EXPR_LE_I64, EXPR_EQ_I64, EXPR_NE_I64]
    var want: List[List[Int]] = [[0, 2], [0, 2, 4], [1, 3], [1, 3, 4], [4], [0, 1, 2, 3]]
    for k in range(6):
        _expect(_select(_cmp(kinds[k], make_col(I), make_lit_i64(3))), want[k], "i op 3, kind " + String(kinds[k]))


def test_every_float64_operator_against_a_literal() raises:
    """f <op> 2.5 over f = [0.5, 1.5, 2.5, 3.5, 4.5]."""
    var kinds: List[Int] = [EXPR_GT_F64, EXPR_GE_F64, EXPR_LT_F64, EXPR_LE_F64, EXPR_EQ_F64, EXPR_NE_F64]
    var want: List[List[Int]] = [[3, 4], [2, 3, 4], [0, 1], [0, 1, 2], [2], [0, 1, 3, 4]]
    for k in range(6):
        _expect(_select(_cmp(kinds[k], make_col(F), make_lit_f64(2.5))), want[k], "f op 2.5, kind " + String(kinds[k]))


def test_column_against_column() raises:
    _expect(_select(_cmp(EXPR_LT_I64, make_col(I), make_col(J))), [1, 4], "i < j")
    _expect(_select(_cmp(EXPR_GT_F64, make_col(F), make_col(G))), [2, 4], "f > g")


def test_shapes_this_walker_does_not_serve_are_refused() raises:
    with assert_raises(contains="comparison at pool slot 2 expects EXPR_COL on the LEFT"):
        _ = _select(_cmp(EXPR_GT_I64, make_lit_i64(3), make_col(I)))
    var p_in = List[RuntimeExpr]()
    p_in.append(make_col(I))
    p_in.append(make_in_list(0, 0))
    with assert_raises(contains="_eval_bool: EXPR_IN_LIST is wired in the ref-batch `_eval_bool_from_view` arm only"):
        _ = _select(ExpressionExecutor(p_in^, 1, _names()))
    var p_or = List[RuntimeExpr]()
    p_or.append(make_col(I))
    p_or.append(make_lit_i64(3))
    p_or.append(make_lt_i64(0, 1))
    p_or.append(make_or(2, 2))
    with assert_raises(contains="_eval_bool: EXPR_OR not supported"):
        _ = _select(ExpressionExecutor(p_or^, 3, _names()))
    var p_lit = List[RuntimeExpr]()
    p_lit.append(make_lit_i64(3))
    with assert_raises(contains="_eval_bool: unsupported node kind 1 at pool slot 0"):
        _ = _select(ExpressionExecutor(p_lit^, 0, _names()))


def test_and_over_an_empty_batch() raises:
    """`select_expression` walks a root AND itself; over zero rows it keeps
    nothing."""
    var empty = List[Int]()
    var none = List[Float64]()
    var batch = _batch(empty, empty, none, none)
    var exec = _chain(2)
    var sel = RowSelectionVector(1)
    assert_equal(exec.select_expression(batch, sel), 0)


def _chain(k: Int) -> ExpressionExecutor:
    """The first `k` of i >= 2, i <= 4, j >= 3 as a left-leaning AND."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(I))          # 0
    pool.append(make_lit_i64(2))      # 1
    pool.append(make_ge_i64(0, 1))    # 2
    pool.append(make_lit_i64(4))      # 3
    pool.append(make_le_i64(0, 3))    # 4
    pool.append(make_col(J))          # 5
    pool.append(make_lit_i64(3))      # 6
    pool.append(make_ge_i64(5, 6))    # 7
    var preds: List[Int] = [2, 4, 7]
    var root = preds[0]
    for p in range(1, k):
        pool.append(make_and(root, preds[p]))
        root = len(pool) - 1
    return ExpressionExecutor(pool^, root, _names())


def _adaptive(exec: ExpressionExecutor, var batch: RecordBatch, n_pred: Int) raises -> List[Int]:
    var fs = FilterState.with_conjunction(n_predicates=n_pred, worker_id=0)
    var n = exec.select_expression_adaptive(batch, fs)
    var out = List[Int]()
    for k in range(n):
        out.append(Int(fs.sel.get(k)))
    return out^


def test_adaptive_chains() raises:
    """i >= 2 -> [0, 2, 3, 4]; and i <= 4 -> [2, 3, 4]; and j >= 3 -> [2, 4]."""
    _expect(_adaptive(_chain(1), _fixture(), 1), [0, 2, 3, 4], "one conjunct")
    _expect(_adaptive(_chain(2), _fixture(), 2), [2, 3, 4], "two conjuncts")
    _expect(_adaptive(_chain(3), _fixture(), 3), [2, 4], "three conjuncts")


def test_adaptive_refuses_a_conjunction_state_of_another_length() raises:
    with assert_raises(contains="select_expression_adaptive: conjunction state n_predicates=1 does not match flattened chain length 3"):
        _ = _adaptive(_chain(3), _fixture(), 1)


def test_adaptive_grows_a_default_capacity_selection() raises:
    """3000 rows: more than the 2048 slots of a default selection."""
    var n = 3000
    var i = List[Int]()
    var f = List[Float64]()
    for r in range(n):
        i.append(r)
        f.append(0.0)
    var got = _adaptive(_chain(1), _batch(i, i, f, f), 1)
    assert_equal(len(got), n - 2)
    assert_equal(got[0], 2)
    assert_equal(got[n - 3], n - 1)


def test_bare_col_name_at() raises:
    """Pool: 0 col 1 (j), 1 literal, 2 col 4 (one past the four names),
    3 col -1, 4 col 3 (g, the last name). Slots 5 and -1 are outside."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(J))
    pool.append(make_lit_i64(1))
    pool.append(make_col(4))
    pool.append(make_col(-1))
    pool.append(make_col(G))
    var exec = ExpressionExecutor(pool^, 0, _names())
    assert_equal(exec.bare_col_name_at(0), "j")
    assert_equal(exec.bare_col_name_at(1), "")
    assert_equal(exec.bare_col_name_at(2), "")
    assert_equal(exec.bare_col_name_at(3), "")
    assert_equal(exec.bare_col_name_at(4), "g")
    assert_equal(exec.bare_col_name_at(5), "")
    assert_equal(exec.bare_col_name_at(-1), "")


def main() raises:
    var suite = TestSuite()
    suite.test[test_every_int64_operator_against_a_literal]()
    suite.test[test_every_float64_operator_against_a_literal]()
    suite.test[test_column_against_column]()
    suite.test[test_shapes_this_walker_does_not_serve_are_refused]()
    suite.test[test_and_over_an_empty_batch]()
    suite.test[test_adaptive_chains]()
    suite.test[test_adaptive_refuses_a_conjunction_state_of_another_length]()
    suite.test[test_adaptive_grows_a_default_capacity_selection]()
    suite.test[test_bare_col_name_at]()
    suite^.run()
