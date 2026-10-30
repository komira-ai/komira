# =============================================================================
# tpch_q6 -- TPC-H Q6 as a hand-built plan, and a lineitem-shaped table for it
# =============================================================================
#
#   SELECT SUM(l_extendedprice * l_discount) AS revenue
#   FROM lineitem
#   WHERE l_shipdate >= DATE_FROM AND l_shipdate < DATE_TO (a one-year range)
#     AND l_discount BETWEEN 0.05 AND 0.07 AND l_quantity < 24
#
# One segment: SOURCE_PARQUET over the columns the query reads, OP_FILTER with
# the five conjuncts, OP_PROJECT computing the product, and an ungrouped SUM
# whose output is DECIMAL(38,4), the type DuckDB gives a sum of a
# DECIMAL(15,2) product.
#
# The table has the column types of the real files: l_quantity,
# l_extendedprice and l_discount are DECIMAL(15,2) and l_shipdate is DATE32,
# plus an INT64 l_orderkey the query does not read. Money is held as the
# unscaled integer (cents), which is also how the test computes its expected
# answer. The first rows sit on the boundary of every predicate; the rest come
# from a fixed generator and cover both sides of each. Every 37th row has a
# NULL discount and every 53rd a NULL price.

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_collections.slab import Slab
from komira_physical_plan.physical_plan import (
    AggSinkData,
    MorselOp,
    SegmentDescPod,
)
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import (
    BIN_AND,
    BIN_GE,
    BIN_LE,
    BIN_LT,
    BIN_MUL,
    Expr,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_scalar_arithmetic.decimal_arith import I128

from .plan_harness import (
    agg_list,
    chain,
    parquet_segment,
    ungrouped_agg_data,
    with_agg_sink,
)

# Day numbers (days since the epoch) of the first day of the range and of the
# first day after it.
comptime Q6_DATE_FROM: Int = 8766
comptime Q6_DATE_TO: Int = 9131


struct LineitemTable(Movable):
    """The columns of the fixture, one list each. Money is in cents; a NULL
    discount or price is flagged and its list entry is unused."""

    var shipdate: List[Int]
    var quantity: List[Int]
    var price: List[Int]
    var discount: List[Int]
    var discount_null: List[Bool]
    var price_null: List[Bool]

    def __init__(out self):
        self.shipdate = List[Int]()
        self.quantity = List[Int]()
        self.price = List[Int]()
        self.discount = List[Int]()
        self.discount_null = List[Bool]()
        self.price_null = List[Bool]()

    def add(
        mut self,
        shipdate: Int,
        quantity: Int,
        price: Int,
        discount: Int,
        discount_null: Bool = False,
        price_null: Bool = False,
    ):
        self.shipdate.append(shipdate)
        self.quantity.append(quantity)
        self.price.append(price)
        self.discount.append(discount)
        self.discount_null.append(discount_null)
        self.price_null.append(price_null)

    def rows(self) -> Int:
        return len(self.shipdate)


def q6_boundary_table() -> LineitemTable:
    """Rows on each side of each predicate. Qualifying rows are marked."""
    var t = LineitemTable()
    #       shipdate        quantity  price    discount
    t.add(Q6_DATE_FROM, 2399, 100000, 5)  # first day, lowest discount, qty < 24: in
    t.add(Q6_DATE_TO - 1, 100, 234567, 7)  # last day, highest discount: in
    t.add(Q6_DATE_FROM - 1, 1000, 100000, 6)  # a day too early
    t.add(Q6_DATE_TO, 1000, 100000, 6)  # the exclusive end date
    t.add(Q6_DATE_FROM + 10, 1000, 100000, 4)  # discount just below
    t.add(Q6_DATE_FROM + 10, 1000, 100000, 8)  # discount just above
    t.add(Q6_DATE_FROM + 10, 2400, 100000, 6)  # quantity 24.00 is not below 24
    t.add(Q6_DATE_FROM + 20, 1, 5, 6)  # smallest quantity and price: in
    t.add(Q6_DATE_FROM + 200, 2300, 1234567, 6)  # an ordinary row: in
    t.add(Q6_DATE_FROM + 30, 1000, 0, 6, price_null=True)  # passes, price NULL
    t.add(Q6_DATE_FROM + 30, 1000, 100000, 0, discount_null=True)  # discount NULL
    return t^


def q6_table(random_rows: Int) -> LineitemTable:
    """The boundary rows, then `random_rows` generated ones."""
    var t = q6_boundary_table()
    var x = 12345
    for i in range(random_rows):
        x = (x * 1103515245 + 12345) % 2147483648
        var a = x // 65536
        x = (x * 1103515245 + 12345) % 2147483648
        var b = x // 65536
        x = (x * 1103515245 + 12345) % 2147483648
        var c = x // 65536
        t.add(
            8400 + a % 1000,
            100 * (1 + b % 50) - (c % 2),
            90000 + (a * 7919 + c * 104729) % 9000000,
            b % 12,
            discount_null=(i % 37 == 36),
            price_null=(i % 53 == 52),
        )
    return t^


def _i128(v: Int) -> I128:
    return Scalar[DType.int64](v).cast[DType.int128]()


def lineitem_batch(ref t: LineitemTable, start: Int, rows: Int) raises -> RecordBatch:
    """Rows `start .. start + rows - 1` of `t` as a batch."""
    var key = PrimitiveArray[DType.int64].allocate(rows)
    var qty = Decimal128Array.allocate_nullable(rows, 15, 2)
    var price = Decimal128Array.allocate_nullable(rows, 15, 2)
    var disc = Decimal128Array.allocate_nullable(rows, 15, 2)
    var day = PrimitiveArray[DType.int32].allocate(rows)
    for i in range(rows):
        var r = start + i
        key.set(i, Int64(r))
        qty.set_i128(i, _i128(t.quantity[r]))
        if t.price_null[r]:
            price.set_null(i)
        else:
            price.set_i128(i, _i128(t.price[r]))
        if t.discount_null[r]:
            disc.set_null(i)
        else:
            disc.set_i128(i, _i128(t.discount[r]))
        day.set(i, Int32(t.shipdate[r]))
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder()
    sb.add_field(Field("l_orderkey", ArrowType.INT64, False))
    builder.add_column(Column.from_primitive[DType.int64](key^))
    sb.add_field(Field.decimal128("l_quantity", 15, 2, True))
    builder.add_column(Column.from_decimal128(qty^))
    sb.add_field(Field.decimal128("l_extendedprice", 15, 2, True))
    builder.add_column(Column.from_decimal128(price^))
    sb.add_field(Field.decimal128("l_discount", 15, 2, True))
    builder.add_column(Column.from_decimal128(disc^))
    sb.add_field(Field("l_shipdate", ArrowType.DATE32, False))
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](day^, ArrowType.DATE32)
    )
    return builder.build(sb.build())


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _dec(unscaled: Int) -> Expr:
    return Expr.literal(ScalarValue.decimal128_i128(_i128(unscaled), 4, 2))


def _date(days: Int) -> Expr:
    return Expr.literal(ScalarValue.date32(Int32(days)))


def q6_predicate() -> Expr:
    """The five conjuncts of Q6's WHERE clause, left to right."""
    var p = Expr.binary(BIN_GE, _col("l_shipdate"), _date(Q6_DATE_FROM))
    p = Expr.binary(
        BIN_AND, p^, Expr.binary(BIN_LT, _col("l_shipdate"), _date(Q6_DATE_TO))
    )
    p = Expr.binary(
        BIN_AND, p^, Expr.binary(BIN_GE, _col("l_discount"), _dec(5))
    )
    p = Expr.binary(
        BIN_AND, p^, Expr.binary(BIN_LE, _col("l_discount"), _dec(7))
    )
    return Expr.binary(
        BIN_AND, p^, Expr.binary(BIN_LT, _col("l_quantity"), _dec(2400))
    )


def q6_sink_data() raises -> AggSinkData:
    """SUM(revenue) with a DECIMAL(38,4) output column named revenue."""
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal128("revenue", 38, 4, True))
    return ungrouped_agg_data(
        agg_list(AggExpr(AGG_SUM, Optional(_col("revenue")), None)), sb.build()
    )


def q6_projection() -> List[String]:
    """The four columns Q6 reads."""
    var projection = List[String]()
    projection.append("l_shipdate")
    projection.append("l_discount")
    projection.append("l_quantity")
    projection.append("l_extendedprice")
    return projection^


def q6_segment(
    seg_id: Int,
    var path: String,
    sink_param_id: Int,
    morsel_rows: Int = 0,
    push_predicate: Bool = False,
) -> SegmentDescPod:
    """Q6 over the Parquet file or glob `path`: scan the four columns the query
    reads, filter, project the product, sum. `sink_param_id` is the id
    `RealBuilder.add_agg_sink(q6_sink_data())` returned. With `push_predicate`
    the scan also gets the predicate as its decode filter, and the filter
    operator still applies it."""
    var pushed: Optional[Expr] = None
    if push_predicate:
        pushed = Optional(q6_predicate())
    var exprs = Slab[Expr]()
    exprs.append(
        Expr.binary(BIN_MUL, _col("l_extendedprice"), _col("l_discount"))
    )
    var names = List[String]()
    names.append("revenue")
    var ops = chain(
        MorselOp.filter(q6_predicate()), MorselOp.project(exprs^, names^)
    )
    return with_agg_sink(
        parquet_segment(
            seg_id, path^, Optional(q6_projection()), pushed^, ops^, morsel_rows
        ),
        sink_param_id,
    )
