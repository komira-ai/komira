# =============================================================================
# test_map_op_total_eval_compact — MapOp evaluates a TOTAL projection over the
# physical rows, then compacts only its OUTPUT (lane G, L1)
# =============================================================================
#
# WHAT CHANGED. A batch carrying an unapplied selection mask used to be
# gathered BEFORE any value-observing projection ran (`needs_dense`), so
# `SELECT length(url) ... WHERE url <> ''` copied every surviving `url` byte
# into a fresh batch to feed a kernel whose output is 8 bytes a row. When every
# projected expression is TOTAL (`expr_is_total_over_rows`), MapOp now
# evaluates over the physical batch and gathers the narrow output instead
# (`bench/results/worst10_0923/PLAN.md` §2 G; cbq27's C-gather was 6.4% of its
# CPU).
#
# WHAT THIS FILE PINS
#   T1  the admission predicate, both polarities (allowlist, fail-safe).
#   T2  the new arm FIRES (arming counter `total_eval_compacts` == 1) and its
#       output is the dense batch the gather-first order produced: the same
#       rows, the same values, NULL in -> NULL out, non-ASCII counted right.
#   T3  a NON-total projection still gathers first (counter stays 0).
#   T4  a pure pass-through projection still FORWARDS the mask (counter 0).
#
# MUTATIONS (each verified RED by hand before landing):
#   M1  `compact_after = True` deleted              -> T2 RED (counter 0).
#   M2  `expr_is_total_over_rows` admits every expr -> T1 RED; T3 RED.
#   M3  the final `materialize_selection_if_present` deleted -> T2 RED
#       (10 physical rows + a mask come out instead of 7 dense rows).
#   M4  `_rows_in = new_batch.num_rows()` deleted -> T2 RED (rows_processed
#       reports the 10 physical rows).
# =============================================================================

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_plan_expr.expr import (
    Expr,
    STRFN_LENGTH,
    STRFN_STRLEN,
    STRFN_UPPER,
)
from komira_plan_expr.expr_id import ExprId
from komira_plan_expr.expr_pool import ExprPool
from komira_operator_api.map_op import (
    MapOp,
    expr_is_total_over_rows,
)
from komira_morsel.morsel import Morsel
from komira_name_registry import name_id_of


comptime N: Int = 10


def _batch_with_mask() raises -> RecordBatch:
    """`k` = 0..9, `s` = the strings below, and a mask keeping 7 of 10 rows.

        row  s              kept   length  strlen
        0    "abc"          yes    3       3
        1    ""             no
        2    "Straße"       yes    6       7      (multi-byte: length != strlen)
        3    NULL           yes    NULL    NULL   (a kept NULL)
        4    "😀x"          yes    2       5
        5    "hello world"  yes    11      11
        6    ""             no
        7    "é"            yes    1       2
        8    NULL           no                    (a rejected NULL)
        9    "zz"           yes    2       2
    """
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("s"), ArrowType.STRING, True))

    var karr = PrimitiveArray[DType.int64].allocate(N)
    for i in range(N):
        karr.set(i, Scalar[DType.int64](i))

    var vals: List[String] = [
        "abc", "", "Straße", "", "😀x", "hello world", "", "é", "", "zz",
    ]
    var valid = List[Bool]()
    for i in range(N):
        valid.append(i != 3 and i != 8)

    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](karr))
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(vals, valid))
    )
    var batch = rb.build(sb.build())

    var mask = BooleanArray.allocate(N)
    for i in range(N):
        if i != 1 and i != 6 and i != 8:
            mask.set(i, True)
    batch.set_selection_mask(mask^)
    return batch^


def _map_op(var exprs: List[Expr], var names: List[String]) raises -> MapOp:
    var pool = ExprPool()
    var ids = List[ExprId]()
    for i in range(len(exprs)):
        ids.append(pool.register(exprs[i].copy()))
    return MapOp(ids^, names^, ArcPointer[ExprPool](pool^))


def _counter(op: MapOp, name_id: UInt32) -> Int:
    var got = op.metrics_snapshot().lookup(name_id)
    if not got:
        return -1
    return Int(got.value())


def _compacts(op: MapOp) -> Int:
    return _counter(op, name_id_of("total_eval_compacts"))


# =============================================================================
# T1 — the admission predicate
# =============================================================================


def test_total_predicate_admits_only_the_allowlist() raises:
    var s = Expr.col_ref(String("s"))
    assert_true(expr_is_total_over_rows(s), "a column pass-through is total")
    assert_true(
        expr_is_total_over_rows(Expr.string_fn(STRFN_LENGTH, s.copy())),
        "length(col) is total",
    )
    assert_true(
        expr_is_total_over_rows(Expr.string_fn(STRFN_STRLEN, s.copy())),
        "strlen(col) is total",
    )
    assert_true(
        expr_is_total_over_rows(
            Expr.alias(Expr.string_fn(STRFN_LENGTH, s.copy()), String("l"))
        ),
        "an alias of a total expression is total",
    )
    assert_false(
        expr_is_total_over_rows(Expr.string_fn(STRFN_UPPER, s.copy())),
        "upper() is not on the allowlist -- fail-safe, not a claim it raises",
    )
    assert_false(
        expr_is_total_over_rows(
            Expr.string_fn(
                STRFN_LENGTH, Expr.string_fn(STRFN_UPPER, s.copy())
            )
        ),
        "length() over a NON-pass-through child is not admitted",
    )
    assert_false(
        expr_is_total_over_rows(Expr.hamming(s.copy(), s.copy())),
        "hamming() -- the measured raising op -- must never be admitted",
    )


# =============================================================================
# T2 — the new arm fires, and its output is the gather-first output
# =============================================================================


def test_total_projection_evaluates_then_compacts() raises:
    var exprs = List[Expr]()
    exprs.append(Expr.col_ref(String("k")))
    exprs.append(Expr.string_fn(STRFN_LENGTH, Expr.col_ref(String("s"))))
    exprs.append(Expr.string_fn(STRFN_STRLEN, Expr.col_ref(String("s"))))
    var names: List[String] = ["k", "l", "b"]
    var op = _map_op(exprs^, names^)

    var morsel = Morsel(_batch_with_mask(), 0, 0)
    _ = op.execute(morsel)

    assert_equal(
        _compacts(op), 1,
        "the evaluate-then-compact arm did not fire on an all-TOTAL projection",
    )
    assert_false(
        morsel.batch.has_selection_mask(),
        "the output must be COMPACTED, not forwarded with the mask",
    )
    assert_equal(morsel.num_rows(), 7, "7 of 10 rows survive the mask")
    assert_equal(
        _counter(op, name_id_of("rows_processed")), 7,
        "rows_processed must report the DENSE count, as the gather-first arm"
        + " did -- not the 10 physical rows the arm evaluated over",
    )

    var want_k: List[Int] = [0, 2, 3, 4, 5, 7, 9]
    var want_l: List[Int] = [3, 6, -1, 2, 11, 1, 2]
    var want_b: List[Int] = [3, 7, -1, 5, 11, 2, 2]
    var k = morsel.batch.column_at(0).as_primitive[DType.int64]()
    var l = morsel.batch.column_at(1).as_primitive[DType.int64]()
    var b = morsel.batch.column_at(2).as_primitive[DType.int64]()
    for i in range(7):
        assert_equal(Int(k.get(i)), want_k[i], "k @" + String(i))
        if want_l[i] < 0:
            assert_true(l.is_null(i), "length(NULL) must be NULL @" + String(i))
            assert_true(b.is_null(i), "strlen(NULL) must be NULL @" + String(i))
        else:
            assert_false(l.is_null(i), "length not NULL @" + String(i))
            assert_equal(Int(l.get(i)), want_l[i], "length @" + String(i))
            assert_equal(Int(b.get(i)), want_b[i], "strlen @" + String(i))


# =============================================================================
# T3 — a non-total projection keeps the gather-first order
# =============================================================================


def test_non_total_projection_still_gathers_first() raises:
    var exprs = List[Expr]()
    exprs.append(Expr.col_ref(String("k")))
    exprs.append(Expr.string_fn(STRFN_UPPER, Expr.col_ref(String("s"))))
    var names: List[String] = ["k", "u"]
    var op = _map_op(exprs^, names^)

    var morsel = Morsel(_batch_with_mask(), 0, 0)
    _ = op.execute(morsel)

    assert_equal(_compacts(op), 0, "upper() must not take the compact arm")
    assert_false(morsel.batch.has_selection_mask(), "gathered, so no mask")
    assert_equal(morsel.num_rows(), 7, "7 of 10 rows survive the mask")
    var k = morsel.batch.column_at(0).as_primitive[DType.int64]()
    var want_k: List[Int] = [0, 2, 3, 4, 5, 7, 9]
    for i in range(7):
        assert_equal(Int(k.get(i)), want_k[i], "k @" + String(i))


# =============================================================================
# T4 — a pure pass-through projection still forwards the mask
# =============================================================================


def test_passthrough_projection_forwards_the_mask() raises:
    var exprs = List[Expr]()
    exprs.append(Expr.col_ref(String("k")))
    exprs.append(Expr.col_ref(String("s")))
    var names: List[String] = ["k", "s"]
    var op = _map_op(exprs^, names^)

    var morsel = Morsel(_batch_with_mask(), 0, 0)
    _ = op.execute(morsel)

    assert_equal(_compacts(op), 0, "a pass-through projection never compacts")
    assert_true(
        morsel.batch.has_selection_mask(),
        "the zero-copy mask forward for pass-throughs must survive",
    )
    assert_equal(morsel.num_rows(), N, "physical rows are forwarded")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
