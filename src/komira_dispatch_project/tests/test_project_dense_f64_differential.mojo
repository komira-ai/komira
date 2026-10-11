# =============================================================================
# test_project_dense_f64_differential.mojo: the dense FLOAT64 evaluator answers
# the walker's bits, element for element, and serves nothing the walker did not
# =============================================================================
#
# SUBJECT: `project_dense_f64.try_eval_dense_f64` and its call site in
# `compute_project._eval_computed_column[float64]`, reached through
# `eval_project_exprs_over_batch`. The measured shape is TPC-H q9's aggregand
# `l_extendedprice * (1 - l_discount) - ps_supplycost * l_quantity`.
#
# The oracle is the walker itself, in the same process: each projection is
# evaluated twice, with `dense_f64 = False` (the
# `ExpressionExecutor.eval_to_list_f64_from_view` walker) and with the default
# (the dense evaluator), and the two FLOAT64 columns are compared by bit
# pattern. A tolerance would hide a reordered or FMA-contracted evaluation;
# `==` on doubles calls NaN unequal to itself and -0.0 equal to +0.0. The bit
# compare has neither blind spot.
#
# 6 is the route witness: it calls the dense entry directly and asserts it
# admits the expression, so an admission check that declined everything (and
# made every differential compare the walker with itself) fails there.
# 7 is the other direction: a shape outside the envelope is not admitted and
# is still served by the walker.
#
# Fixture sizes are not multiples of any SIMD width, so every kernel's scalar
# tail runs.
#
# 8 is the pooled form: a started runtime (a bare `LocalDispatcher()` has no
# workers and would run the serial form), the chunk-aligned task tiling, and
# `dense_par = False`.
# =============================================================================

from std.memory import bitcast
from std.testing import TestSuite, assert_true, assert_equal, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.string_array import StringArray
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_buffer.heap_region import HeapRegion
from komira_eval.expression_executor import DecimalSpec
from komira_kernels.runtime_expr import RuntimeExpr
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_SUB, BIN_MUL, BIN_DIV
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import ExprArray

from komira_dispatch_project.compute_project import (
    eval_project_exprs_over_batch,
    eval_project_exprs_over_batch_on_dispatcher,
)
from komira_dispatch_project.compute_project_routes import _build_col_maps
from komira_dispatch_project.lower_untyped_expr import translate_expr
from komira_dispatch_project.project_dense_f64 import (
    DENSE_PAR_MIN_ROWS,
    dense_par_task_rows,
    try_eval_dense_f64,
)


comptime _N: Int = 1003  # prime: never a multiple of a SIMD width


# -----------------------------------------------------------------------------
# A deterministic value stream (xorshift64*): no library RNG, so the fixture is
# the same bytes on every platform.
# -----------------------------------------------------------------------------
struct _Rng(Movable):
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def next(mut self) -> UInt64:
        var x = self.s
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        self.s = x
        return x * UInt64(2685821657736338717)

    def unit(mut self) -> Float64:
        """A double in [0, 1) with 53 random bits."""
        return Float64(self.next() >> 11) * (1.0 / 9007199254740992.0)


def _f64_col(var vals: List[Float64]) -> Column[HeapRegion]:
    var n = len(vals)
    var arr = PrimitiveArray[DType.float64].allocate(n)
    for i in range(n):
        arr.store[1](i, SIMD[DType.float64, 1](vals[i]))
    return Column.from_primitive[DType.float64](arr)


def _i64_col(var vals: List[Int64]) -> Column[HeapRegion]:
    var n = len(vals)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        arr.store[1](i, SIMD[DType.int64, 1](vals[i]))
    return Column.from_primitive[DType.int64](arr)


def _i32_col(var vals: List[Int32]) -> Column[HeapRegion]:
    var n = len(vals)
    var arr = PrimitiveArray[DType.int32].allocate(n)
    for i in range(n):
        arr.store[1](i, SIMD[DType.int32, 1](vals[i]))
    return Column.from_primitive[DType.int32](arr)


def _q9_batch(n: Int, seed: UInt64) raises -> RecordBatch:
    """The q9 aggregand's inputs plus the two passthrough group keys, with
    TPC-H-like magnitudes (prices to 1e5, discounts in [0, 0.1], quantities
    1..50, supply costs to 1e3) so the products carry real rounding."""
    var rng = _Rng(seed)
    var price = List[Float64](capacity=n)
    var disc = List[Float64](capacity=n)
    var cost = List[Float64](capacity=n)
    var qty = List[Float64](capacity=n)
    var year = List[Int64](capacity=n)
    var names = List[String](capacity=n)
    for i in range(n):
        price.append(900.0 + rng.unit() * 104000.0)
        disc.append(Float64(Int(rng.unit() * 11.0)) / 100.0)
        cost.append(1.0 + rng.unit() * 999.0)
        qty.append(Float64(1 + Int(rng.unit() * 50.0)))
        year.append(Int64(1992 + (i % 7)))
        names.append(String("NATION") + String(i % 25))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("n_name"), ArrowType.STRING, False))
    sb.add_field(Field(String("o_year"), ArrowType.INT64, False))
    sb.add_field(Field(String("l_extendedprice"), ArrowType.FLOAT64, False))
    sb.add_field(Field(String("l_discount"), ArrowType.FLOAT64, False))
    sb.add_field(Field(String("ps_supplycost"), ArrowType.FLOAT64, False))
    sb.add_field(Field(String("l_quantity"), ArrowType.FLOAT64, False))
    var rbb = RecordBatchBuilder.with_capacity(6)
    rbb.add_column(Column.from_string(StringArray.from_strings(names)))
    rbb.add_column(_i64_col(year^))
    rbb.add_column(_f64_col(price^))
    rbb.add_column(_f64_col(disc^))
    rbb.add_column(_f64_col(cost^))
    rbb.add_column(_f64_col(qty^))
    return rbb.build(sb.build())


def _c(name: StaticString) -> Expr:
    return Expr.col_ref(String(name))


def _lit_i(v: Int64) -> Expr:
    return Expr.literal(ScalarValue.from_int64(v))


def _lit_f(v: Float64) -> Expr:
    return Expr.literal(ScalarValue.from_float(v))


def _q9_profit() raises -> Expr:
    """`l_extendedprice * (1 - l_discount) - ps_supplycost * l_quantity`, with
    the SQL integer literal `1` exactly as the binder hands it over."""
    return Expr.binary(
        BIN_SUB,
        Expr.binary(
            BIN_MUL,
            _c("l_extendedprice"),
            Expr.binary(BIN_SUB, _lit_i(1), _c("l_discount")),
        ),
        Expr.binary(BIN_MUL, _c("ps_supplycost"), _c("l_quantity")),
    )


def _q9_exprs(var e: Expr) raises -> ExprArray:
    var exprs = ExprArray()
    exprs.append(_c("n_name"))
    exprs.append(_c("o_year"))
    exprs.append(Expr.alias(e^, String("profit")))
    return exprs^


def _q9_out_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("n_name"), ArrowType.STRING, False))
    sb.add_field(Field(String("o_year"), ArrowType.INT64, False))
    sb.add_field(Field(String("profit"), ArrowType.FLOAT64, True))
    return sb.build()


def _one_out_schema(name: String) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.FLOAT64, True))
    return sb.build()


def _one_expr(var e: Expr, name: String) raises -> ExprArray:
    var exprs = ExprArray()
    exprs.append(Expr.alias(e^, name))
    return exprs^


def _bits(v: Float64) -> UInt64:
    return bitcast[DType.uint64](v)


def _assert_f64_col_bit_identical(
    imm walker: RecordBatch, imm dense: RecordBatch, col: Int, what: String
) raises:
    assert_equal(walker.num_rows(), dense.num_rows(), what + ": row count")
    assert_true(
        walker.schema.field_arrow_type(col) == ArrowType.FLOAT64
        and dense.schema.field_arrow_type(col) == ArrowType.FLOAT64,
        what + ": FLOAT64 on both arms",
    )
    var w = walker.column_as_primitive_float64(col)
    var d = dense.column_as_primitive_float64(col)
    assert_equal(w.length, d.length, what + ": column length")
    for i in range(w.length):
        var wb = _bits(w.get(i))
        var db = _bits(d.get(i))
        if wb != db:
            assert_equal(
                db,
                wb,
                what + ": bit mismatch at row " + String(i) + " (walker "
                + String(w.get(i)) + ", dense " + String(d.get(i)) + ")",
            )
    assert_equal(
        walker.column_at(col).null_count(),
        dense.column_at(col).null_count(),
        what + ": null count",
    )


# =============================================================================
# 1. The q9 aggregand over a fixture that is not a multiple of any SIMD
#    width, with the two passthrough keys around it.
# =============================================================================


def test_q9_aggregand_is_bit_identical_to_the_walker() raises:
    var off_opt = eval_project_exprs_over_batch(
        _q9_batch(_N, UInt64(0x9E3779B97F4A7C15)),
        _q9_exprs(_q9_profit()),
        _q9_out_schema(),
        dense_f64=False,
    )
    var on_opt = eval_project_exprs_over_batch(
        _q9_batch(_N, UInt64(0x9E3779B97F4A7C15)),
        _q9_exprs(_q9_profit()),
        _q9_out_schema(),
    )
    assert_true(Bool(off_opt), "the WALKER arm serves the q9 projection")
    assert_true(Bool(on_opt), "the DENSE arm serves the q9 projection")
    var walker = off_opt.take()
    var dense = on_opt.take()
    assert_equal(dense.num_columns(), 3, "three outputs")
    _assert_f64_col_bit_identical(walker, dense, 2, "q9 profit")
    # The passthrough keys must be intact on both arms.
    var wk = walker.column_as_primitive_int64(1)
    var dk = dense.column_as_primitive_int64(1)
    for i in range(_N):
        assert_equal(Int(wk.get(i)), Int(dk.get(i)), "o_year passthrough")
    var ws = walker.column_as_string(0)
    var ds = dense.column_as_string(0)
    for i in range(_N):
        assert_equal(ws.get(i), ds.get(i), "n_name passthrough")


def test_every_chunk_boundary_is_bit_identical() raises:
    """The dense arm evaluates `_CHUNK` (2,048) rows at a time over one scratch
    buffer. Sizes on both sides of one and two chunk boundaries, and a
    many-chunk batch with a ragged tail: an off-by-one in the chunk walk, or a
    scratch region read before it is written, changes bits here."""
    var sizes = List[Int]()
    sizes.append(2047)
    sizes.append(2048)
    sizes.append(2049)
    sizes.append(4096)
    sizes.append(4101)
    sizes.append(10007)
    for si in range(len(sizes)):
        var n = sizes[si]
        var off_opt = eval_project_exprs_over_batch(
            _q9_batch(n, UInt64(7000 + n)), _q9_exprs(_q9_profit()),
            _q9_out_schema(),
            dense_f64=False,
        )
        var on_opt = eval_project_exprs_over_batch(
            _q9_batch(n, UInt64(7000 + n)), _q9_exprs(_q9_profit()),
            _q9_out_schema(),
        )
        assert_true(
            Bool(off_opt) and Bool(on_opt), "both arms serve n=" + String(n)
        )
        _assert_f64_col_bit_identical(
            off_opt.take(), on_opt.take(), 2, "q9 profit n=" + String(n)
        )


def test_every_size_through_two_simd_blocks_is_bit_identical() raises:
    """Row counts 0..33 exercise the empty batch, the tail-only case and every
    tail length for any SIMD width up to 16."""
    for n in range(0, 34):
        var off_opt = eval_project_exprs_over_batch(
            _q9_batch(n, UInt64(1000 + n)), _q9_exprs(_q9_profit()),
            _q9_out_schema(),
            dense_f64=False,
        )
        var on_opt = eval_project_exprs_over_batch(
            _q9_batch(n, UInt64(1000 + n)), _q9_exprs(_q9_profit()),
            _q9_out_schema(),
        )
        assert_true(Bool(off_opt) and Bool(on_opt), "both arms serve n=" + String(n))
        _assert_f64_col_bit_identical(
            off_opt.take(), on_opt.take(), 2, "q9 profit n=" + String(n)
        )


# =============================================================================
# 2. The four operators in each operand order (vector op vector, vector op
#    scalar, scalar op vector), including the IEEE edges of division.
# =============================================================================


def _ieee_batch() raises -> RecordBatch:
    """`a` holds ordinary values; `z` holds the divisors that make IEEE
    division interesting: +0.0, -0.0, NaN, +Inf, -Inf, subnormal, and ones."""
    var n = 41
    var rng = _Rng(UInt64(77))
    var a = List[Float64](capacity=n)
    var z = List[Float64](capacity=n)
    var inf = Float64(1.0) / Float64(0.0)
    var nan = inf - inf
    for i in range(n):
        a.append((rng.unit() - 0.5) * 1.0e6)
        var k = i % 8
        if k == 0:
            z.append(0.0)
        elif k == 1:
            z.append(-0.0)
        elif k == 2:
            z.append(nan)
        elif k == 3:
            z.append(inf)
        elif k == 4:
            z.append(-inf)
        elif k == 5:
            z.append(4.9406564584124654e-324)
        else:
            z.append(rng.unit() + 0.5)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.FLOAT64, False))
    sb.add_field(Field(String("z"), ArrowType.FLOAT64, False))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(_f64_col(a^))
    rbb.add_column(_f64_col(z^))
    return rbb.build(sb.build())


def _check_both_over(
    var mk: RecordBatch,
    var mk2: RecordBatch,
    var e1: Expr,
    var e2: Expr,
    what: String,
) raises:
    """Evaluate `e1` over `mk` on the walker arm and the identical `e2` over
    the identical `mk2` on the dense arm, and assert the output bits agree.
    (Two copies of each because both are consumed.)"""
    var off_opt = eval_project_exprs_over_batch(
        mk^, _one_expr(e1^, String("v")), _one_out_schema(String("v")),
        dense_f64=False,
    )
    var on_opt = eval_project_exprs_over_batch(
        mk2^, _one_expr(e2^, String("v")), _one_out_schema(String("v"))
    )
    assert_true(Bool(off_opt), what + ": walker arm serves it")
    assert_true(Bool(on_opt), what + ": dense arm serves it")
    _assert_f64_col_bit_identical(off_opt.take(), on_opt.take(), 0, what)


def test_each_operator_and_operand_order_matches_the_walker_including_ieee_edges() raises:
    var ops = List[Int]()
    ops.append(Int(BIN_ADD))
    ops.append(Int(BIN_SUB))
    ops.append(Int(BIN_MUL))
    ops.append(Int(BIN_DIV))
    for oi in range(len(ops)):
        var op = UInt8(ops[oi])
        # vector op vector
        _check_both_over(
            _ieee_batch(), _ieee_batch(),
            Expr.binary(op, _c("a"), _c("z")),
            Expr.binary(op, _c("a"), _c("z")),
            "a op z, op " + String(oi),
        )
        # vector op scalar
        _check_both_over(
            _ieee_batch(), _ieee_batch(),
            Expr.binary(op, _c("z"), _lit_f(3.5)),
            Expr.binary(op, _c("z"), _lit_f(3.5)),
            "z op 3.5, op " + String(oi),
        )
        # scalar op vector (and division by the edge divisors)
        _check_both_over(
            _ieee_batch(), _ieee_batch(),
            Expr.binary(op, _lit_f(-7.25), _c("z")),
            Expr.binary(op, _lit_f(-7.25), _c("z")),
            "-7.25 op z, op " + String(oi),
        )


def test_a_literal_only_subtree_folds_to_the_walkers_value() raises:
    """`(2 - 0.5) * a`: the left operand is literal op literal, which the
    dense arm keeps as one scalar; the walker materialises it per row."""
    _check_both_over(
        _ieee_batch(), _ieee_batch(),
        Expr.binary(BIN_MUL, Expr.binary(BIN_SUB, _lit_i(2), _lit_f(0.5)), _c("a")),
        Expr.binary(BIN_MUL, Expr.binary(BIN_SUB, _lit_i(2), _lit_f(0.5)), _c("a")),
        "(2 - 0.5) * a",
    )


# =============================================================================
# 3. An INT64 column is widened as the walker widens it, including values
#    above 2^53, where the conversion rounds. (Mixed INT64/FLOAT64 arithmetic
#    puts an INT64 leaf under an F64 operator; the translator refuses mixed
#    INT32/FLOAT64, so an INT32 leaf never reaches this arm.)
# =============================================================================


def _mixed_batch() raises -> RecordBatch:
    var n = 37
    var i64s = List[Int64](capacity=n)
    var i32s = List[Int32](capacity=n)
    var f64s = List[Float64](capacity=n)
    var big = Int64(9007199254740993)  # 2^53 + 1: NOT representable
    for i in range(n):
        var k = i % 5
        if k == 0:
            i64s.append(big + Int64(2 * i))
        elif k == 1:
            i64s.append(-big - Int64(i))
        elif k == 2:
            i64s.append(Int64(9223372036854775807) - Int64(i))
        else:
            i64s.append(Int64(i * 1000 - 17000))
        i32s.append(Int32(2147483647) - Int32(i * 3) if i % 2 == 0 else Int32(-i * 11))
        f64s.append(Float64(i) * 0.1 - 1.3)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("i"), ArrowType.INT64, False))
    sb.add_field(Field(String("j"), ArrowType.INT32, False))
    sb.add_field(Field(String("f"), ArrowType.FLOAT64, False))
    var rbb = RecordBatchBuilder.with_capacity(3)
    rbb.add_column(_i64_col(i64s^))
    rbb.add_column(_i32_col(i32s^))
    rbb.add_column(_f64_col(f64s^))
    return rbb.build(sb.build())


def test_an_int64_column_widens_identically_to_the_walker() raises:
    """`i * f + i / f`: mixed INT64/FLOAT64 arithmetic, so the INT64 leaf is
    widened under an F64 operator on both sides of the `+`."""
    _check_both_over(
        _mixed_batch(), _mixed_batch(),
        Expr.binary(
            BIN_ADD,
            Expr.binary(BIN_MUL, _c("i"), _c("f")),
            Expr.binary(BIN_DIV, _c("i"), _c("f")),
        ),
        Expr.binary(
            BIN_ADD,
            Expr.binary(BIN_MUL, _c("i"), _c("f")),
            Expr.binary(BIN_DIV, _c("i"), _c("f")),
        ),
        "i * f + i / f",
    )


# =============================================================================
# 4. A sliced input column (a non-zero element offset) reads the right rows.
# =============================================================================


def _sliced_batch() raises -> RecordBatch:
    var n = 5003  # three chunks, ragged tail
    var skip = 5
    var arr = PrimitiveArray[DType.float64].allocate(n + skip)
    var arr2 = PrimitiveArray[DType.float64].allocate(n + skip)
    for i in range(n + skip):
        arr.store[1](i, SIMD[DType.float64, 1](Float64(i) * 1.5 + 0.25))
        arr2.store[1](i, SIMD[DType.float64, 1](Float64(100 - i) / 3.0))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.FLOAT64, False))
    sb.add_field(Field(String("z"), ArrowType.FLOAT64, False))
    var rbb = RecordBatchBuilder.with_capacity(2)
    # `Column.slice` is a zero-copy row slice: the buffers are shared and the
    # window is carried in `_offset`, so a reader that ignores `_offset` reads
    # the wrong rows.
    var ca = Column.from_primitive[DType.float64](arr).slice(skip, n)
    var cz = Column.from_primitive[DType.float64](arr2).slice(skip, n)
    assert_true(ca._offset == skip, "the fixture really carries an offset")
    rbb.add_column(ca^)
    rbb.add_column(cz^)
    return rbb.build(sb.build())


def test_a_sliced_input_column_is_read_from_its_offset() raises:
    _check_both_over(
        _sliced_batch(), _sliced_batch(),
        Expr.binary(BIN_SUB, _c("a"), _c("z")),
        Expr.binary(BIN_SUB, _c("a"), _c("z")),
        "sliced a - z",
    )


# =============================================================================
# 5. A nullable input with no NULL: the walker ignores the bitmap and so does
#    the dense arm.
# =============================================================================


def _nullable_no_nulls_batch() raises -> RecordBatch:
    var n = 23
    var arr = PrimitiveArray[DType.float64].allocate_nullable(n)
    var arr2 = PrimitiveArray[DType.float64].allocate(n)
    for i in range(n):
        arr.store[1](i, SIMD[DType.float64, 1](Float64(i) + 0.5))
        arr2.store[1](i, SIMD[DType.float64, 1](Float64(i % 4) - 1.0))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.FLOAT64, True))
    sb.add_field(Field(String("z"), ArrowType.FLOAT64, False))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_primitive[DType.float64](arr))
    rbb.add_column(Column.from_primitive[DType.float64](arr2))
    return rbb.build(sb.build())


def test_a_nullable_but_null_free_input_answers_the_same() raises:
    _check_both_over(
        _nullable_no_nulls_batch(), _nullable_no_nulls_batch(),
        Expr.binary(BIN_DIV, _c("a"), _c("z")),
        Expr.binary(BIN_DIV, _c("a"), _c("z")),
        "nullable a / z",
    )


# =============================================================================
# 6. The route witness: the dense entry admits the q9 aggregand. Without this
#    case every differential above could be comparing the walker with itself.
# =============================================================================


def _translate(imm batch: RecordBatch, imm e: Expr, mut pool: List[RuntimeExpr]) raises -> Int:
    var name_to_idx = Dict[String, Int]()
    var name_to_dtype = Dict[String, Int]()
    _ = _build_col_maps(batch, name_to_idx, name_to_dtype)
    var string_pool = List[String]()
    var decimal_pool = List[DecimalSpec]()
    var in_list_pool = List[List[ScalarValue]]()
    var when_pool = List[List[Int]]()
    return translate_expr(
        e, pool, name_to_idx, name_to_dtype, string_pool, decimal_pool,
        in_list_pool, when_pool,
    )


def _names(imm batch: RecordBatch) -> List[String]:
    var out = List[String]()
    for i in range(batch.schema.num_columns()):
        out.append(batch.schema.field_name(i))
    return out^


def test_the_dense_entry_admits_the_q9_aggregand() raises:
    var batch = _q9_batch(_N, UInt64(5))
    var pool = List[RuntimeExpr]()
    var root = _translate(batch, _q9_profit(), pool)
    var got = try_eval_dense_f64(pool, root, _names(batch), batch)
    assert_true(
        Bool(got),
        "the q9 aggregand is inside the dense envelope; a decline here means"
        " every differential case compared the walker with itself",
    )
    var col = got.take()
    assert_equal(col.length(), _N, "one value per row")
    assert_equal(col.null_count(), 0, "a computed F64 column carries no nulls")


# =============================================================================
# 7. Outside the envelope the dense entry declines and the walker still
#    serves the projection.
# =============================================================================


def test_a_node_outside_the_envelope_is_declined_and_still_served() raises:
    """`sqrt(l_extendedprice) + l_discount`: EXPR_SQRT_F64 is a node the dense
    arm does not carry. The dense entry answers None, and the evaluator
    answers the same bits with `dense_f64` on and off. (`sqrt` is a
    domain-checked op, so this expression takes the column evaluator; every
    operand is positive, so it does not refuse.)"""
    var batch = _q9_batch(_N, UInt64(11))
    var e = Expr.binary(
        BIN_ADD, Expr.sqrt(_c("l_extendedprice")), _c("l_discount")
    )
    var pool = List[RuntimeExpr]()
    var root = _translate(batch, e, pool)
    assert_false(
        Bool(try_eval_dense_f64(pool, root, _names(batch), batch)),
        "sqrt is outside the dense envelope",
    )
    var off_opt = eval_project_exprs_over_batch(
        _q9_batch(_N, UInt64(11)),
        _one_expr(
            Expr.binary(
                BIN_ADD, Expr.sqrt(_c("l_extendedprice")), _c("l_discount")
            ),
            String("v"),
        ),
        _one_out_schema(String("v")),
        dense_f64=False,
    )
    var on_opt = eval_project_exprs_over_batch(
        _q9_batch(_N, UInt64(11)),
        _one_expr(
            Expr.binary(
                BIN_ADD, Expr.sqrt(_c("l_extendedprice")), _c("l_discount")
            ),
            String("v"),
        ),
        _one_out_schema(String("v")),
    )
    assert_true(Bool(off_opt) and Bool(on_opt), "served on both settings")
    _assert_f64_col_bit_identical(
        off_opt.take(), on_opt.take(), 0, "sqrt(price) + disc"
    )


# =============================================================================
# 8. The pooled form answers the walker's bits and fans out (a started
#    runtime, not a bare dispatcher with no workers, which would run the
#    serial form).
# =============================================================================


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _make_started_runtime(n_workers: Int) raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(n_workers, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


def test_the_task_tiling_is_chunk_aligned_and_exact() raises:
    """Every task boundary is a multiple of 2,048 rows (the serial form's
    chunk grid, the bit-identity argument), the tasks tile [0, n) with no gap
    or overlap, and a column above the floor splits into more than one task."""
    var ns = List[Int]()
    ns.append(DENSE_PAR_MIN_ROWS)
    ns.append(100003)
    ns.append(319404)
    ns.append(6001215)
    var nws = List[Int]()
    nws.append(2)
    nws.append(4)
    nws.append(20)
    nws.append(44)
    for i in range(len(ns)):
        for j in range(len(nws)):
            var n = ns[i]
            var nw = nws[j]
            var tr = dense_par_task_rows(n, nw)
            assert_equal(tr % 2048, 0, "task rows is a whole number of chunks")
            var n_tasks = (n + tr - 1) // tr
            assert_true(n_tasks >= 2, "a column above the floor fans out")
            assert_true(n_tasks <= nw, "never more tasks than workers")
            # The last task starts inside [0, n) and ends at n.
            assert_true((n_tasks - 1) * tr < n, "no empty trailing task")
            assert_true(n_tasks * tr >= n, "the tiling covers every row")


def test_the_pooled_arm_is_bit_identical_to_the_walker() raises:
    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    assert_true(
        disp.worker_count() >= 2,
        "the runtime has workers; a 1-worker pool would run the serial form",
    )
    var sizes = List[Int]()
    sizes.append(DENSE_PAR_MIN_ROWS - 1)  # below the floor: the serial form
    sizes.append(DENSE_PAR_MIN_ROWS)
    sizes.append(100003)  # a ragged last task AND a ragged last chunk
    sizes.append(319404)
    for si in range(len(sizes)):
        var n = sizes[si]
        var off_opt = eval_project_exprs_over_batch(
            _q9_batch(n, UInt64(31 + n)), _q9_exprs(_q9_profit()),
            _q9_out_schema(),
            dense_f64=False,
        )
        var par_opt = eval_project_exprs_over_batch_on_dispatcher(
            disp, _q9_batch(n, UInt64(31 + n)), _q9_exprs(_q9_profit()),
            _q9_out_schema(),
        )
        assert_true(
            Bool(off_opt) and Bool(par_opt), "both arms serve n=" + String(n)
        )
        var walker = off_opt.take()
        var pooled = par_opt.take()
        _assert_f64_col_bit_identical(
            walker, pooled, 2, "pooled q9 profit n=" + String(n)
        )
        # The passthrough keys ride the SAME impl on the pooled entry.
        var ws = walker.column_as_string(0)
        var ps = pooled.column_as_string(0)
        assert_equal(ws.get(n - 1), ps.get(n - 1), "n_name passthrough, last row")
    rt.shutdown()


def test_the_par_kill_switch_keeps_the_dense_arm_serial_and_identical() raises:
    """`dense_par = False` keeps the dense arm on the calling thread: same
    bits."""
    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var n = 100003
    var off_opt = eval_project_exprs_over_batch_on_dispatcher(
        disp, _q9_batch(n, UInt64(99)), _q9_exprs(_q9_profit()),
        _q9_out_schema(), dense_par=False,
    )
    var on_opt = eval_project_exprs_over_batch_on_dispatcher(
        disp, _q9_batch(n, UInt64(99)), _q9_exprs(_q9_profit()),
        _q9_out_schema(),
    )
    assert_true(Bool(off_opt) and Bool(on_opt), "both settings serve it")
    _assert_f64_col_bit_identical(
        off_opt.take(), on_opt.take(), 2, "dense_par off vs on"
    )
    rt.shutdown()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
