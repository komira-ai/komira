# =============================================================================
# SQL three-valued logic in the BatchView filter walker
# (`ExpressionExecutor.select_expression_from_view`) and in the CASE
# condition of the BatchView project walker.
#
# A WHERE keeps a row only when its predicate is TRUE; a comparison with a
# NULL operand is UNKNOWN, `NOT UNKNOWN` is UNKNOWN, and AND/OR follow
# Kleene's tables: `FALSE AND UNKNOWN = FALSE`, `TRUE OR UNKNOWN = TRUE`.
#
# Every NULL cell in the fixture STORES a value that would pass the predicate
# under test if the walker read it, so a walker that ignores validity keeps
# the NULL row and the survivor list differs.
#
# | row | n (i64) | m (i64) | s     | b (bool) | d (dec 10,2) | f (f64) | k (i64) | e (dec 10,2) |
# |-----|---------|---------|-------|----------|--------------|---------|---------|--------------|
# | 0   | 5       | 1       | bob   | true     | 1.00         | 2.5     | 2       | 2.00         |
# | 1   | N/0     | 2       | NULL  | N/true   | N/0.00       | N/0.0   | 1       | 5.00         |
# | 2   | 3       | N/0     | alice | false    | -1.00        | -1.0    | 5       | 0.00         |
# | 3   | 1       | 0       | bob   | true     | 2.00         | 0.5     | 3       | 1.00         |
# | 4   | 4       | 7       | carol | false    | 0.00         | 4.0     | 8       | 0.00         |
#
# k and e hold no NULL, so a compare with k or e on the left leaves the NULL
# check to the right operand alone.
#
# Refs komira-ai/komira#932.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import batch_view_over
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.selection_vector_row import RowSelectionVector
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_eval.expression_executor import DecimalSpec, ExpressionExecutor
from komira_eval.filter_state import FilterState
from komira_kernels.runtime_expr import (
    EXPR_EQ_F64_MIXED,
    EXPR_GE_F64_MIXED,
    EXPR_REGEXP,
    RuntimeExpr,
    make_add_i32,
    make_add_i64,
    make_and,
    make_case_f64,
    make_case_i64,
    make_col,
    make_col_bool,
    make_col_decimal128,
    make_col_string,
    make_eq_string,
    make_ge_decimal128,
    make_ge_i64,
    make_gt_i64,
    make_gt_string,
    make_in_list,
    make_is_null_string,
    make_like_string,
    make_lit_bool,
    make_lit_decimal128,
    make_lit_f64,
    make_lit_i32,
    make_lit_i64,
    make_lit_string,
    make_lt_decimal128,
    make_lt_i64,
    make_not_bool,
    make_null,
    make_or,
    make_sqrt_f64,
)
from komira_plan_expr.scalar_value import ScalarValue


comptime N = 0
comptime M = 1
comptime S = 2
comptime B = 3
comptime D = 4
comptime F = 5
comptime K = 6
comptime E = 7


def _names() -> List[String]:
    var names: List[String] = ["n", "m", "s", "b", "d", "f", "k", "e"]
    return names^


def _batch() raises -> RecordBatch:
    """The fixture in the file header."""
    var n = PrimitiveArray[DType.int64].allocate_nullable(5)
    var m = PrimitiveArray[DType.int64].allocate_nullable(5)
    var f = PrimitiveArray[DType.float64].allocate_nullable(5)
    var kc = PrimitiveArray[DType.int64].allocate_nullable(5)
    var b = BooleanArray.allocate_nullable(5)
    var d = Decimal128Array.allocate_nullable(5, 10, 2)
    var e = Decimal128Array.allocate_nullable(5, 10, 2)
    var vn: List[Int] = [5, 0, 3, 1, 4]
    var vm: List[Int] = [1, 2, 0, 0, 7]
    var vf: List[Float64] = [2.5, 0.0, -1.0, 0.5, 4.0]
    var vb: List[Bool] = [True, True, False, True, False]
    var vd: List[Int] = [100, 0, -100, 200, 0]
    var vk: List[Int] = [2, 1, 5, 3, 8]
    var ve: List[Int] = [200, 500, 0, 100, 0]
    for r in range(5):
        n.set(r, Scalar[DType.int64](Int64(vn[r])))
        m.set(r, Scalar[DType.int64](Int64(vm[r])))
        f.set(r, Scalar[DType.float64](vf[r]))
        b.set(r, vb[r])
        d.set_i128(r, SIMD[DType.int128, 1](vd[r]))
        kc.set(r, Scalar[DType.int64](Int64(vk[r])))
        e.set_i128(r, SIMD[DType.int128, 1](ve[r]))
    n._set_null(1)
    m._set_null(2)
    f._set_null(1)
    b._set_null(1)
    d.set_null(1)
    var sv: List[String] = ["bob", "", "alice", "bob", "carol"]
    var sok: List[Bool] = [True, False, True, True, True]
    var fields = List[Field]()
    fields.append(Field("n", DType.int64, True))
    fields.append(Field("m", DType.int64, True))
    fields.append(Field("s", ArrowType.STRING, True))
    fields.append(Field("b", ArrowType.BOOL, True))
    fields.append(Field.decimal128("d", 10, 2, True))
    fields.append(Field("f", DType.float64, True))
    fields.append(Field("k", DType.int64, True))
    fields.append(Field.decimal128("e", 10, 2, True))
    var cols = Slab[Column[HeapRegion]]()
    cols.append(Column.from_primitive[DType.int64](n^))
    cols.append(Column.from_primitive[DType.int64](m^))
    cols.append(Column.from_string(StringArray.from_strings_with_validity(sv, sok)))
    cols.append(Column.from_boolean(b^))
    cols.append(Column.from_decimal128(d^))
    cols.append(Column.from_primitive[DType.float64](f^))
    cols.append(Column.from_primitive[DType.int64](kc^))
    cols.append(Column.from_decimal128(e^))
    var sb = SchemaBuilder()
    for i in range(len(fields)):
        sb.add_field(fields[i])
    return RecordBatch.from_typed_columns_slab(sb.build(), cols^)


def _run(exec: ExpressionExecutor, batch: RecordBatch) raises -> List[Int]:
    """Survivors of `select_expression_from_view`, in order (one conjunct:
    every test root below is a non-AND node)."""
    var fs = FilterState.with_conjunction(n_predicates=1, worker_id=0)
    var k = exec.select_expression_from_view(batch_view_over(batch), fs)
    var out = List[Int]()
    for i in range(k):
        out.append(Int(fs.sel.get(i)))
    return out^


def _expect(got: List[Int], want: List[Int], what: String) raises:
    var g = String("[")
    for v in got:
        g += String(v) + " "
    g += "]"
    assert_equal(len(got), len(want), what + ": survivor count, got " + g)
    for k in range(len(want)):
        assert_equal(got[k], want[k], what + ": survivor " + String(k) + ", got " + g)


def _exec(var pool: List[RuntimeExpr]) -> ExpressionExecutor:
    """Root = last slot. String pool: 0 'bob', 1 'b%'. Decimal pool: 0 = 0.00."""
    var root = len(pool) - 1
    var strings: List[String] = ["bob", "b%"]
    var decs = List[DecimalSpec]()
    decs.append(DecimalSpec(SIMD[DType.int128, 1](0), 10, 2))
    return ExpressionExecutor(pool^, root, _names(), strings^, decs^)


def _node(kind: Int, left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(kind, Int64(0), 0.0, False, 0, left, right)


# -----------------------------------------------------------------------------
# Leaves that read a NULL cell's stored value
# -----------------------------------------------------------------------------


def test_numeric_compare_drops_a_null_cell() raises:
    """`n >= 0`: row 1 is NULL, stored 0. SQL: [0, 2, 3, 4].
    `n >= m`, column against column: 5 >= 1, NULL, NULL, 1 >= 0, 4 >= 7.
    SQL: [0, 3]; the NULL rows store 0 >= 2 and 3 >= 0, so row 2 would pass.
    `k >= m`, NULL in the right column only: 2 >= 1, 1 >= 2, NULL, 3 >= 0,
    8 >= 7. SQL: [0, 3, 4]; row 2 stores 5 >= 0, so it would pass."""
    var batch = _batch()
    var p = List[RuntimeExpr]()
    p.append(make_col(N))
    p.append(make_lit_i64(0))
    p.append(make_ge_i64(0, 1))
    _expect(_run(_exec(p^), batch), [0, 2, 3, 4], "n >= 0")
    var q = List[RuntimeExpr]()
    q.append(make_col(N))
    q.append(make_col(M))
    q.append(make_ge_i64(0, 1))
    _expect(_run(_exec(q^), batch), [0, 3], "n >= m")
    var r = List[RuntimeExpr]()
    r.append(make_col(K))
    r.append(make_col(M))
    r.append(make_ge_i64(0, 1))
    _expect(_run(_exec(r^), batch), [0, 3, 4], "k >= m")


def test_bool_column_drops_a_null_cell_stored_true() raises:
    """`WHERE b`: row 1 is NULL, stored true. SQL: [0, 3]. (#932 item 2)"""
    var p = List[RuntimeExpr]()
    p.append(make_col_bool(B))
    _expect(_run(_exec(p^), _batch()), [0, 3], "b")


def test_decimal_compare_drops_a_null_cell() raises:
    """Row 1 is NULL, stored 0.00, which passes all three predicates if read.
    `d >= 0.00`: [0, 3, 4]. `0.00 >= d`: [2, 4]. `d >= d`: [0, 2, 3, 4].
    `e >= d`, column against column with the NULL in the right column only:
    2.00 >= 1.00, NULL, 0.00 >= -1.00, 1.00 >= 2.00, 0.00 >= 0.00.
    SQL: [0, 2, 4]; row 1 stores 5.00 >= 0.00, so it would pass.
    (#932 item 3)"""
    var batch = _batch()
    var p = List[RuntimeExpr]()
    p.append(make_col_decimal128(D))
    p.append(make_lit_decimal128(0))
    p.append(make_ge_decimal128(0, 1))
    _expect(_run(_exec(p^), batch), [0, 3, 4], "d >= 0.00")
    var q = List[RuntimeExpr]()
    q.append(make_lit_decimal128(0))
    q.append(make_col_decimal128(D))
    q.append(make_ge_decimal128(0, 1))
    _expect(_run(_exec(q^), batch), [2, 4], "0.00 >= d")
    var r = List[RuntimeExpr]()
    r.append(make_col_decimal128(D))
    r.append(make_col_decimal128(D))
    r.append(make_ge_decimal128(0, 1))
    _expect(_run(_exec(r^), batch), [0, 2, 3, 4], "d >= d")
    var t = List[RuntimeExpr]()
    t.append(make_col_decimal128(E))
    t.append(make_col_decimal128(D))
    t.append(make_ge_decimal128(0, 1))
    _expect(_run(_exec(t^), batch), [0, 2, 4], "e >= d")


def test_mixed_compare_drops_a_null_operand() raises:
    """F64-vs-I64 compares. (#932 item 4)
    `f >= 0` (i64 literal): row 1 NULL stored 0.0. SQL: [0, 3, 4].
    `(n + 1) = 1.0`: row 1 n is NULL, stored 0, so 0 + 1 = 1.0 would pass.
    SQL: [] (no present n is 0).
    The same two with the nullable operand on the right:
    `0 >= f`: row 1 stores 0.0, so 0 >= 0.0 would pass. SQL: [2].
    `1.0 = (n + 1)`: SQL: []."""
    var batch = _batch()
    var p = List[RuntimeExpr]()
    p.append(make_col(F))
    p.append(make_lit_i64(0))
    p.append(_node(EXPR_GE_F64_MIXED, 0, 1))
    _expect(_run(_exec(p^), batch), [0, 3, 4], "f >= 0")
    var q = List[RuntimeExpr]()
    q.append(make_col(N))                # 0
    q.append(make_lit_i64(1))            # 1
    q.append(make_add_i64(0, 1))         # 2: n + 1
    q.append(make_lit_f64(1.0))          # 3
    q.append(_node(EXPR_EQ_F64_MIXED, 2, 3))
    _expect(_run(_exec(q^), batch), List[Int](), "(n + 1) = 1.0")
    var r = List[RuntimeExpr]()
    r.append(make_lit_i64(0))
    r.append(make_col(F))
    r.append(_node(EXPR_GE_F64_MIXED, 0, 1))
    _expect(_run(_exec(r^), batch), [2], "0 >= f")
    var t = List[RuntimeExpr]()
    t.append(make_lit_f64(1.0))          # 0
    t.append(make_col(N))                # 1
    t.append(make_lit_i64(1))            # 2
    t.append(make_add_i64(1, 2))         # 3: n + 1
    t.append(_node(EXPR_EQ_F64_MIXED, 0, 3))
    _expect(_run(_exec(t^), batch), List[Int](), "1.0 = (n + 1)")


def test_mixed_compare_over_computed_operands() raises:
    """NULL through a math function and through a CASE branch.

    `sqrt(f) >= 0`: sqrt(-1.0) is NaN (FALSE); row 1 is NULL, stored 0.0, and
    sqrt(0.0) >= 0 would pass. SQL: [0, 3, 4].

    `(CASE WHEN n > 2 THEN f ELSE NULL END) >= 0`: n > 2 holds at 0, 2, 4, so
    rows 1 and 3 take the NULL branch, whose value reads 0.0. SQL: [0, 4]
    (row 2 is -1.0)."""
    var batch = _batch()
    var p = List[RuntimeExpr]()
    p.append(make_col(F))
    p.append(make_sqrt_f64(0))
    p.append(make_lit_i64(0))
    p.append(_node(EXPR_GE_F64_MIXED, 1, 2))
    _expect(_run(_exec(p^), batch), [0, 3, 4], "sqrt(f) >= 0")
    var q = List[RuntimeExpr]()
    q.append(make_col(N))            # 0
    q.append(make_lit_i64(2))        # 1
    q.append(make_gt_i64(0, 1))      # 2: n > 2
    q.append(make_col(F))            # 3
    q.append(make_null())            # 4
    q.append(make_case_f64(0))       # 5
    q.append(make_lit_i64(0))        # 6
    q.append(_node(EXPR_GE_F64_MIXED, 5, 6))
    var slots: List[Int] = [2, 3, 4]
    var when = List[List[Int]]()
    when.append(slots^)
    var exec = ExpressionExecutor(q^, 7, _names(), when_pool=when^)
    _expect(_run(exec, batch), [0, 4], "CASE ... ELSE NULL >= 0")


def test_case_null_follows_the_first_true_when() raises:
    """`(CASE WHEN n > 2 THEN f WHEN n > 0 THEN NULL ELSE f END) >= 0`.
    Rows 0, 2, 4 satisfy both WHENs; the first one decides, so they take f
    (2.5, -1.0, 4.0), not NULL. Row 1 (n NULL) takes the ELSE, f = NULL;
    row 3 takes the second WHEN, NULL. SQL: [0, 4].
    A NULL mark that lets a later TRUE WHEN override the first one marks
    rows 0, 2 and 4 NULL and keeps nothing."""
    var q = List[RuntimeExpr]()
    q.append(make_col(N))            # 0
    q.append(make_lit_i64(2))        # 1
    q.append(make_gt_i64(0, 1))      # 2: n > 2
    q.append(make_col(F))            # 3
    q.append(make_lit_i64(0))        # 4
    q.append(make_gt_i64(0, 4))      # 5: n > 0
    q.append(make_null())            # 6
    q.append(make_case_f64(0))       # 7
    q.append(make_lit_i64(0))        # 8
    q.append(_node(EXPR_GE_F64_MIXED, 7, 8))
    var slots: List[Int] = [2, 3, 5, 6, 3]
    var when = List[List[Int]]()
    when.append(slots^)
    var exec = ExpressionExecutor(q^, 9, _names(), when_pool=when^)
    _expect(_run(exec, _batch()), [0, 4], "CASE two WHENs >= 0")


# -----------------------------------------------------------------------------
# NOT over each leaf: the NULL row is excluded under both a predicate and its
# negation. (#932 item 1)
# -----------------------------------------------------------------------------


def _not_of(var leaf_pool: List[RuntimeExpr]) -> ExpressionExecutor:
    var child = len(leaf_pool) - 1
    leaf_pool.append(make_not_bool(child))
    return _exec(leaf_pool^)


def test_not_over_each_leaf_drops_the_null_row() raises:
    var batch = _batch()
    # NOT (s = 'bob'): s = 'bob' at 0, 3; NULL at 1. SQL: [2, 4].
    var p0 = List[RuntimeExpr]()
    p0.append(make_col_string(S))
    p0.append(make_lit_string(0))
    p0.append(make_eq_string(0, 1))
    _expect(_run(_not_of(p0^), batch), [2, 4], "NOT (s = 'bob')")
    # NOT (s > 'bob'): s > 'bob' at 4 (carol). SQL: [0, 2, 3].
    var p1 = List[RuntimeExpr]()
    p1.append(make_col_string(S))
    p1.append(make_lit_string(0))
    p1.append(make_gt_string(0, 1))
    _expect(_run(_not_of(p1^), batch), [0, 2, 3], "NOT (s > 'bob')")
    # NOT (s LIKE 'b%'). SQL: [2, 4].
    var p2 = List[RuntimeExpr]()
    p2.append(make_col_string(S))
    p2.append(make_lit_string(1))
    p2.append(make_like_string(0, 1))
    _expect(_run(_not_of(p2^), batch), [2, 4], "NOT (s LIKE 'b%')")
    # NOT (n > 2): n > 2 at 0, 2, 4. SQL: [3].
    var p3 = List[RuntimeExpr]()
    p3.append(make_col(N))
    p3.append(make_lit_i64(2))
    p3.append(make_gt_i64(0, 1))
    _expect(_run(_not_of(p3^), batch), [3], "NOT (n > 2)")
    # NOT b. SQL: [2, 4].
    var p4 = List[RuntimeExpr]()
    p4.append(make_col_bool(B))
    _expect(_run(_not_of(p4^), batch), [2, 4], "NOT b")
    # NOT (d < 0.00): d < 0 at 2. SQL: [0, 3, 4].
    var p5 = List[RuntimeExpr]()
    p5.append(make_col_decimal128(D))
    p5.append(make_lit_decimal128(0))
    p5.append(make_lt_decimal128(0, 1))
    _expect(_run(_not_of(p5^), batch), [0, 3, 4], "NOT (d < 0.00)")
    # NOT (f >= 0) mixed: f >= 0 at 0, 3, 4. SQL: [2].
    var p6 = List[RuntimeExpr]()
    p6.append(make_col(F))
    p6.append(make_lit_i64(0))
    p6.append(_node(EXPR_GE_F64_MIXED, 0, 1))
    _expect(_run(_not_of(p6^), batch), [2], "NOT (f >= 0)")
    # NOT (s IS NULL): IS NULL is never UNKNOWN. SQL: [0, 2, 3, 4].
    var p7 = List[RuntimeExpr]()
    p7.append(make_col_string(S))
    p7.append(make_is_null_string(0))
    _expect(_run(_not_of(p7^), batch), [0, 2, 3, 4], "NOT (s IS NULL)")
    # NOT FALSE keeps every row; NOT TRUE none.
    var p8 = List[RuntimeExpr]()
    p8.append(make_lit_bool(False))
    _expect(_run(_not_of(p8^), batch), [0, 1, 2, 3, 4], "NOT FALSE")
    var p9 = List[RuntimeExpr]()
    p9.append(make_lit_bool(True))
    _expect(_run(_not_of(p9^), batch), List[Int](), "NOT TRUE")


def _pq(combine_and: Bool) -> List[RuntimeExpr]:
    """Pool for `p AND q` / `p OR q`, p = (n < 2), q = (m > 0); root slot 6."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(N))         # 0
    pool.append(make_lit_i64(2))     # 1
    pool.append(make_lt_i64(0, 1))   # 2: p
    pool.append(make_col(M))         # 3
    pool.append(make_lit_i64(0))     # 4
    pool.append(make_gt_i64(3, 4))   # 5: q
    if combine_and:
        pool.append(make_and(2, 5))  # 6
    else:
        pool.append(make_or(2, 5))   # 6
    return pool^


def test_not_follows_kleene_over_and_or() raises:
    """p = (n < 2): F, N, F, T, F.   q = (m > 0): T, T, N, F, T.

    p AND q = F, N, F, F, F  -> NOT: T, N, T, T, T -> [0, 2, 3, 4]
      (row 2 is FALSE AND UNKNOWN = FALSE, so NOT keeps it.)
    p OR q  = T, T, N, T, T  -> NOT: F, F, N, F, F -> []
      (row 1 is UNKNOWN OR TRUE = TRUE; row 2 FALSE OR UNKNOWN = UNKNOWN.)
    NOT NOT p = p           -> [3]
    """
    var batch = _batch()

    _expect(_run(_not_of(_pq(True)), batch), [0, 2, 3, 4], "NOT (p AND q)")
    _expect(_run(_not_of(_pq(False)), batch), List[Int](), "NOT (p OR q)")
    var nn = List[RuntimeExpr]()
    nn.append(make_col(N))
    nn.append(make_lit_i64(2))
    nn.append(make_lt_i64(0, 1))
    nn.append(make_not_bool(2))
    nn.append(make_not_bool(3))
    _expect(_run(_exec(nn^), batch), [3], "NOT NOT p")


def _not_in_exec(var values: List[ScalarValue]) -> ExpressionExecutor:
    """NOT (n IN values)."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(N))
    pool.append(make_in_list(0, 0))
    pool.append(make_not_bool(1))
    var lists = List[List[ScalarValue]]()
    lists.append(values^)
    return ExpressionExecutor(pool^, 2, _names(), in_list_pool=lists^)


def test_not_in_list_with_a_null_entry_is_unknown() raises:
    """`n IN (5, NULL)` is TRUE at row 0 and UNKNOWN everywhere else (a
    non-matching value against a list holding NULL is UNKNOWN), so its
    negation keeps nothing. `NOT (n IN (5, 4))` keeps [2, 3]: row 1 is NULL.
    `NOT NOT (n IN (5, NULL))` keeps [0]: row 0 is TRUE although the list
    holds a NULL, so TRUE must win over the NULL mark."""
    var batch = _batch()

    var with_null = List[ScalarValue]()
    with_null.append(ScalarValue.from_int(5))
    with_null.append(ScalarValue.null(DType.int64))
    _expect(_run(_not_in_exec(with_null^), batch), List[Int](), "NOT (n IN (5, NULL))")
    var plain = List[ScalarValue]()
    plain.append(ScalarValue.from_int(5))
    plain.append(ScalarValue.from_int(4))
    _expect(_run(_not_in_exec(plain^), batch), [2, 3], "NOT (n IN (5, 4))")
    var pool = List[RuntimeExpr]()
    pool.append(make_col(N))
    pool.append(make_in_list(0, 0))
    pool.append(make_not_bool(1))
    pool.append(make_not_bool(2))
    var again = List[ScalarValue]()
    again.append(ScalarValue.from_int(5))
    again.append(ScalarValue.null(DType.int64))
    var lists = List[List[ScalarValue]]()
    lists.append(again^)
    var nn = ExpressionExecutor(pool^, 3, _names(), in_list_pool=lists^)
    _expect(_run(nn, batch), [0], "NOT NOT (n IN (5, NULL))")


# -----------------------------------------------------------------------------
# The NULL markers called directly, for the arms no filter reaches today.
# -----------------------------------------------------------------------------


def _all_rows() -> RowSelectionVector:
    var sel = RowSelectionVector(5)
    for r in range(5):
        sel.append(UInt32(r))
    return sel^


def _marker_exec() -> ExpressionExecutor:
    """Slots: 0 n, 1 I32 literal 1, 2 I32 `n + 1`, 3 a REGEXP node (no
    view-walker or marker arm serves it)."""
    var p = List[RuntimeExpr]()
    p.append(make_col(N))
    p.append(make_lit_i32(1))
    p.append(make_add_i32(0, 1))
    p.append(_node(EXPR_REGEXP, 0, 0))
    return _exec(p^)


def test_value_marker_i32_arithmetic() raises:
    """`n + 1` as I32 arithmetic is NULL where n is (row 1); the marker reads
    validity only, so the column's Int64 type does not matter."""
    var batch = _batch()
    var sel = _all_rows()
    var null_at = List[Bool](length=5, fill=False)
    _marker_exec()._mark_value_nulls_from_view(batch, 2, sel, null_at)
    for r in range(5):
        assert_equal(null_at[r], r == 1, "I32 n + 1 null at row " + String(r))


def test_value_marker_refuses_an_unsupported_kind() raises:
    """A value kind outside the marker's list raises rather than answer
    "not NULL"."""
    var batch = _batch()
    var sel = _all_rows()
    var null_at = List[Bool](length=5, fill=False)
    with assert_raises(
        contains="_mark_value_nulls_from_view: unsupported node kind 86 at pool slot 3"
    ):
        _marker_exec()._mark_value_nulls_from_view(batch, 3, sel, null_at)


def test_bool_leaf_marker_refuses_an_unsupported_kind() raises:
    """A Bool kind outside the leaf marker's list raises rather than answer
    "not UNKNOWN"."""
    var batch = _batch()
    var exec = _marker_exec()
    var sel = _all_rows()
    var null_at = List[Bool](length=5, fill=False)
    with assert_raises(
        contains="_mark_bool_leaf_nulls_from_view: unsupported node kind 86 at pool slot 3"
    ):
        exec._mark_bool_leaf_nulls_from_view(
            batch, exec.expression_pool[3], 3, sel, null_at
        )


# -----------------------------------------------------------------------------
# CASE WHEN NOT ... over a selection that is not ascending (#932 item 9)
# -----------------------------------------------------------------------------


def test_case_condition_not_over_a_non_ascending_selection() raises:
    """CASE WHEN NOT (n > 2) THEN 1 ELSE 0 over rows [3, 1, 0, 2]:
    n = 1, NULL, 5, 3 -> NOT (n > 2) = T, N, F, F -> [1, 0, 0, 0].
    A NOT that assumes an ascending selection keeps rows 0 and 2 too."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(N))         # 0
    pool.append(make_lit_i64(2))     # 1
    pool.append(make_gt_i64(0, 1))   # 2
    pool.append(make_not_bool(2))    # 3
    pool.append(make_lit_i64(1))     # 4
    pool.append(make_lit_i64(0))     # 5
    pool.append(make_case_i64(0))    # 6
    var slots: List[Int] = [3, 4, 5]
    var when = List[List[Int]]()
    when.append(slots^)
    var exec = ExpressionExecutor(pool^, 6, _names(), when_pool=when^)
    var batch = _batch()
    var sel = RowSelectionVector(4)
    var rows: List[Int] = [3, 1, 0, 2]
    for r in rows:
        sel.append(UInt32(r))
    var out = List[Scalar[DType.int64]]()
    exec.eval_to_list_i64_from_view(batch_view_over(batch), 6, sel, out)
    var want: List[Int] = [1, 0, 0, 0]
    assert_equal(len(out), 4)
    for k in range(4):
        assert_equal(Int(out[k]), want[k], "CASE value at sel index " + String(k))


def main() raises:
    var suite = TestSuite()
    suite.test[test_numeric_compare_drops_a_null_cell]()
    suite.test[test_bool_column_drops_a_null_cell_stored_true]()
    suite.test[test_decimal_compare_drops_a_null_cell]()
    suite.test[test_mixed_compare_drops_a_null_operand]()
    suite.test[test_mixed_compare_over_computed_operands]()
    suite.test[test_case_null_follows_the_first_true_when]()
    suite.test[test_not_over_each_leaf_drops_the_null_row]()
    suite.test[test_not_follows_kleene_over_and_or]()
    suite.test[test_not_in_list_with_a_null_entry_is_unknown]()
    suite.test[test_value_marker_i32_arithmetic]()
    suite.test[test_value_marker_refuses_an_unsupported_kind]()
    suite.test[test_bool_leaf_marker_refuses_an_unsupported_kind]()
    suite.test[test_case_condition_not_over_a_non_ascending_selection]()
    suite^.run()
