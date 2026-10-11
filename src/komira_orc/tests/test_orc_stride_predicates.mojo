# =============================================================================
# test_orc_stride_predicates.mojo — which strides the stride-skip reader
# keeps, for every predicate shape its statistics and bloom levels read.
# =============================================================================
#
# One stripe of 30 rows, 3 strides of 10, a bloom filter on every column:
#   k  bigint   = r
#   c  bigint   = 7 for r in 10..19 (stride 1 is constant), else r
#   e  bigint   = 2r (odd values are absent but inside each stride's range)
#   t  smallint = r
#   f  double   = r / 2
#   s  string   = "s<r>"
#   b  boolean  = r is even
#
# Each case states the strides that must survive; the test checks the skip
# count and that the surviving rows are exactly those strides' rows, in order
# (a skipped stride that could hold a matching row is a wrong answer; a kept
# stride the statistics or bloom disprove is a missed skip).
#
#   T1  statistics level: <, <=, >, >=, =, != (a constant stride equal to the
#       literal is the only != skip), the literal on the left (the operator
#       mirrored), AND / OR, and every shape it cannot judge (a non-integer
#       literal, a column the file lacks, column-vs-column, arithmetic, a bare
#       column) kept.
#   T2  bloom level: = on bigint, smallint, double (double and integer
#       literals), string; IN lists (an absent list skips, a list with one
#       present value keeps; a non-column child, an unknown column, an empty
#       list keep); OR of two equalities; AND whose left equality is
#       absent; a literal of the wrong type, a boolean column, an unknown
#       column, column-vs-column kept.
#   T3  a file with no ROW_INDEX: one stride per stripe, nothing skipped.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder, Field

from komira_plan_expr.expr import (
    Expr,
    BIN_ADD,
    BIN_AND,
    BIN_OR,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
)
from komira_plan_expr.scalar_value import ScalarValue

from komira_orc import (
    OrcWriterOptions,
    write_orc_bytes,
    read_orc_bytes_filtered,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
)


comptime N = 30
comptime STRIDE = 10


def _batch() raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("c", ArrowType.INT64, True))
    sb.add_field(Field("e", ArrowType.INT64, True))
    sb.add_field(Field("t", ArrowType.INT16, True))
    sb.add_field(Field("f", ArrowType.FLOAT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("b", ArrowType.BOOL, True))
    var k = PrimitiveArray[DType.int64].allocate(N)
    var c = PrimitiveArray[DType.int64].allocate(N)
    var e = PrimitiveArray[DType.int64].allocate(N)
    var t = PrimitiveArray[DType.int16].allocate(N)
    var f = PrimitiveArray[DType.float64].allocate(N)
    var b = BooleanArray.allocate(N)
    var ss = List[String]()
    for r in range(N):
        k.set(r, Int64(r))
        c.set(r, Int64(7) if r >= 10 and r < 20 else Int64(r))
        e.set(r, Int64(2 * r))
        t.set(r, Int16(r))
        f.set(r, Float64(r) * 0.5)
        b.set(r, r % 2 == 0)
        ss.append(String("s") + String(r))
    var rb = RecordBatchBuilder.with_capacity(7)
    rb.add_column(Column.from_primitive_with_arrow_type[DType.int64](k^, ArrowType.INT64))
    rb.add_column(Column.from_primitive_with_arrow_type[DType.int64](c^, ArrowType.INT64))
    rb.add_column(Column.from_primitive_with_arrow_type[DType.int64](e^, ArrowType.INT64))
    rb.add_column(Column.from_primitive_with_arrow_type[DType.int16](t^, ArrowType.INT16))
    rb.add_column(Column.from_primitive[DType.float64](f^))
    rb.add_column(Column.from_string(StringArray.from_strings(ss)))
    rb.add_column(Column.from_boolean(b^))
    return rb.build(sb.build())


def _all_names() -> List[String]:
    var n = List[String]()
    n.append("k"); n.append("c"); n.append("e"); n.append("t")
    n.append("f"); n.append("s"); n.append("b")
    return n^


# -----------------------------------------------------------------------------
# Expression helpers.
# -----------------------------------------------------------------------------


def _i(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int64(Int64(v)))


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _cmp(op: UInt8, name: String, v: Int) -> Expr:
    return Expr.binary(op, _col(name), _i(v))


def _cmp_left(op: UInt8, v: Int, name: String) -> Expr:
    """`literal <op> column`."""
    return Expr.binary(op, _i(v), _col(name))


def _cmp_lit(op: UInt8, name: String, var lit: ScalarValue) -> Expr:
    return Expr.binary(op, _col(name), Expr.literal(lit^))


def _in(var child: Expr, vals: List[Int]) -> Expr:
    var l = List[ScalarValue]()
    for i in range(len(vals)):
        l.append(ScalarValue.from_int64(Int64(vals[i])))
    return Expr.in_list_node(child^, l^)


def _kept(*strides: Int) -> List[Int]:
    var out = List[Int]()
    for i in range(len(strides)):
        out.append(strides[i])
    return out^


def _check(file: List[UInt8], pred: Expr, kept: List[Int], label: String) raises:
    var res = read_orc_bytes_filtered(Span(file), pred)
    assert_equal(res.strides_total, 3, label + ": strides")
    assert_equal(res.strides_skipped, 3 - len(kept), label + ": strides skipped")
    if len(kept) == 3:
        assert_equal(res.batch.num_rows(), N, label + ": all rows")
        return
    assert_equal(res.batch.num_rows(), len(kept) * STRIDE, label + ": surviving rows")
    var k = res.batch.column_as_primitive_int64(0)
    var row = 0
    for i in range(len(kept)):
        for r in range(kept[i] * STRIDE, (kept[i] + 1) * STRIDE):
            assert_equal(Int(k.get(row)), r, label + ": surviving row " + String(row))
            row += 1


# -----------------------------------------------------------------------------
# T1 — statistics level.
# -----------------------------------------------------------------------------


def _stats_cases(file: List[UInt8], label: String) raises:
    _check(file, _cmp(BIN_LE, "k", 5), _kept(0), label + " k<=5")
    _check(file, _cmp(BIN_LE, "k", 10), _kept(0, 1), label + " k<=10")
    _check(file, _cmp(BIN_LT, "k", 10), _kept(0), label + " k<10")
    _check(file, _cmp(BIN_GT, "k", 24), _kept(2), label + " k>24")
    _check(file, _cmp(BIN_GT, "k", 19), _kept(2), label + " k>19")
    _check(file, _cmp(BIN_GE, "k", 19), _kept(1, 2), label + " k>=19")
    _check(file, _cmp(BIN_EQ, "k", 15), _kept(1), label + " k=15")
    _check(file, _cmp(BIN_NE, "c", 7), _kept(0, 2), label + " c!=7")
    _check(file, _cmp(BIN_NE, "c", 8), _kept(0, 1, 2), label + " c!=8")
    _check(file, _cmp(BIN_NE, "k", 3), _kept(0, 1, 2), label + " k!=3")
    # Stride 0's minimum is 0, but it is not constant: k != 0 keeps it.
    _check(file, _cmp(BIN_NE, "k", 0), _kept(0, 1, 2), label + " k!=0")
    # Literal on the left: the operator is mirrored.
    _check(file, _cmp_left(BIN_LT, 25, "k"), _kept(2), label + " 25<k")
    _check(file, _cmp_left(BIN_LE, 20, "k"), _kept(2), label + " 20<=k")
    _check(file, _cmp_left(BIN_GT, 5, "k"), _kept(0), label + " 5>k")
    _check(file, _cmp_left(BIN_GE, 10, "k"), _kept(0, 1), label + " 10>=k")
    _check(file, _cmp_left(BIN_EQ, 15, "k"), _kept(1), label + " 15=k")
    _check(file, _cmp_left(BIN_NE, 7, "c"), _kept(0, 2), label + " 7!=c")
    # AND / OR.
    _check(
        file, Expr.binary(BIN_OR, _cmp(BIN_LT, "k", 3), _cmp(BIN_GT, "k", 27)),
        _kept(0, 2), label + " k<3 or k>27",
    )
    _check(
        file, Expr.binary(BIN_OR, _cmp(BIN_GT, "k", 27), _cmp(BIN_LT, "k", 3)),
        _kept(0, 2), label + " k>27 or k<3",
    )
    _check(
        file, Expr.binary(BIN_AND, _cmp(BIN_GE, "k", 10), _cmp(BIN_LT, "k", 20)),
        _kept(1), label + " 10<=k<20",
    )
    # Shapes the statistics cannot judge: kept.
    _check(file, _cmp_lit(BIN_LT, "k", ScalarValue.from_string("x")), _kept(0, 1, 2), label + " k<'x'")
    _check(file, Expr.binary(BIN_LT, Expr.literal(ScalarValue.from_float(1.5)), _col("k")), _kept(0, 1, 2), label + " 1.5<k")
    _check(file, _cmp(BIN_LT, "s", 5), _kept(0, 1, 2), label + " s<5 (no int stats)")
    _check(file, _cmp(BIN_LT, "zz", 5), _kept(0, 1, 2), label + " unknown column")
    _check(file, _cmp_left(BIN_LT, 5, "zz"), _kept(0, 1, 2), label + " 5<unknown column")
    _check(file, Expr.binary(BIN_LT, _col("k"), _col("t")), _kept(0, 1, 2), label + " k<t")
    _check(file, Expr.binary(BIN_ADD, _col("k"), _i(1)), _kept(0, 1, 2), label + " k+1")
    _check(file, _col("b"), _kept(0, 1, 2), label + " bare column")


# -----------------------------------------------------------------------------
# T2 — bloom level.
# -----------------------------------------------------------------------------


def _bloom_cases(file: List[UInt8], label: String) raises:
    # e holds only even values: 15 is inside stride 0's [min, max] (the
    # statistics keep it) but absent (its bloom skips it). The literals below
    # are chosen so no bloom answers "maybe" for an absent one: a bloom has
    # false positives (13 is one, in stride 0's filter), so an absent literal
    # that tests positive keeps its stride, which is correct, not a skip.
    _check(file, _cmp(BIN_EQ, "e", 15), _kept(), label + " e=15")
    _check(file, _cmp_left(BIN_EQ, 15, "e"), _kept(), label + " 15=e")
    _check(file, _cmp(BIN_EQ, "e", 14), _kept(0), label + " e=14")
    _check(file, _cmp(BIN_EQ, "t", 15), _kept(1), label + " t=15 (smallint)")
    _check(file, _cmp_lit(BIN_EQ, "f", ScalarValue.from_float(2.5)), _kept(0), label + " f=2.5")
    _check(file, _cmp_lit(BIN_EQ, "f", ScalarValue.from_float(2.25)), _kept(), label + " f=2.25")
    _check(file, _cmp(BIN_EQ, "f", 12), _kept(2), label + " f=12 (integer literal)")
    _check(file, _cmp_lit(BIN_EQ, "s", ScalarValue.from_string("s7")), _kept(0), label + " s='s7'")
    _check(file, _cmp_lit(BIN_EQ, "s", ScalarValue.from_string("s77")), _kept(), label + " s='s77'")
    # OR of equalities: the bloom keeps a stride for either side.
    _check(
        file, Expr.binary(BIN_OR, _cmp(BIN_EQ, "e", 15), _cmp(BIN_EQ, "e", 22)),
        _kept(1), label + " e=15 or e=22",
    )
    _check(
        file, Expr.binary(BIN_OR, _cmp(BIN_EQ, "e", 22), _cmp(BIN_EQ, "e", 15)),
        _kept(1), label + " e=22 or e=15",
    )
    # AND: an absent left equality skips without consulting the right.
    _check(
        file, Expr.binary(BIN_AND, _cmp(BIN_EQ, "e", 15), _cmp(BIN_GE, "k", 0)),
        _kept(), label + " e=15 and k>=0",
    )
    _check(
        file, Expr.binary(BIN_AND, _cmp(BIN_GE, "k", 0), _cmp(BIN_EQ, "e", 15)),
        _kept(), label + " k>=0 and e=15",
    )
    # IN lists (the statistics level keeps every IN; the bloom judges it).
    _check(file, _in(_col("e"), [15, 17]), _kept(), label + " e in (15,17)")
    _check(file, _in(_col("e"), [15, 44]), _kept(2), label + " e in (15,44)")
    _check(file, _in(_col("e"), [44, 15]), _kept(2), label + " e in (44,15)")
    _check(file, _in(_i(1), [13]), _kept(0, 1, 2), label + " 1 in (13)")
    _check(file, _in(_col("zz"), [13]), _kept(0, 1, 2), label + " unknown in (13)")
    _check(file, _in(_col("e"), List[Int]()), _kept(0, 1, 2), label + " e in ()")
    # Shapes the bloom cannot judge: kept.
    _check(file, _cmp_lit(BIN_EQ, "e", ScalarValue.from_string("13")), _kept(0, 1, 2), label + " e='13'")
    _check(file, _cmp_lit(BIN_EQ, "f", ScalarValue.from_string("x")), _kept(0, 1, 2), label + " f='x'")
    _check(file, _cmp(BIN_EQ, "s", 5), _kept(0, 1, 2), label + " s=5")
    _check(file, _cmp_lit(BIN_EQ, "b", ScalarValue.from_bool(True)), _kept(0, 1, 2), label + " b=true")
    _check(file, _cmp(BIN_EQ, "zz", 5), _kept(0, 1, 2), label + " zz=5")
    _check(file, _cmp_left(BIN_EQ, 5, "zz"), _kept(0, 1, 2), label + " 5=zz")
    _check(file, Expr.binary(BIN_EQ, _col("k"), _col("t")), _kept(0, 1, 2), label + " k=t")


def test_stride_predicates() raises:
    var batch = _batch()
    for i in range(2):
        var codec = ORC_COMPRESSION_NONE if i == 0 else ORC_COMPRESSION_ZSTD
        var label = String("NONE") if i == 0 else String("ZSTD")
        var opts = OrcWriterOptions.with_bloom(codec, STRIDE, N, _all_names())
        var file = write_orc_bytes(batch, opts)
        _stats_cases(file, label)
        _bloom_cases(file, label)


# -----------------------------------------------------------------------------
# T3 — no ROW_INDEX.
# -----------------------------------------------------------------------------


def test_no_row_index_keeps_every_stripe() raises:
    # Stripe = stride = 10 rows, no ROW_INDEX: 3 stripes, one stride each.
    var file = write_orc_bytes(_batch(), OrcWriterOptions(ORC_COMPRESSION_NONE, STRIDE, "UTC"))
    var res = read_orc_bytes_filtered(Span(file), _cmp(BIN_LE, "k", 5))
    assert_equal(res.strides_total, 3)
    assert_equal(res.strides_skipped, 0)
    assert_equal(res.batch.num_rows(), N)


def main() raises:
    test_stride_predicates()
    test_no_row_index_keeps_every_stripe()
    print("test_orc_stride_predicates: ALL PASS")
