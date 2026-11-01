# =============================================================================
# tpch_q1 -- TPC-H Q1 as a hand-built plan, and a lineitem-shaped table for it
# =============================================================================
#
#   SELECT l_returnflag, l_linestatus,
#          SUM(l_quantity), SUM(l_extendedprice),
#          SUM(l_extendedprice * (1 - l_discount)),
#          SUM(l_extendedprice * (1 - l_discount) * (1 + l_tax)),
#          AVG(l_quantity), AVG(l_extendedprice), AVG(l_discount), COUNT(*)
#   FROM lineitem
#   WHERE l_shipdate <= DATE '1998-09-02'       -- 1998-12-01 less 90 days
#   GROUP BY l_returnflag, l_linestatus
#   ORDER BY l_returnflag, l_linestatus
#
# Two segments. Segment 0: SOURCE_PARQUET over the seven columns the query
# reads, OP_FILTER on the ship date, OP_PROJECT carrying the two keys, the
# three measures and the two computed products, and a SINK_AGG keyed by the
# two strings (DICT_ENCODED or COLUMNAR, the caller's choice). Segment 1:
# SOURCE_SINK_OUTPUT of segment 0 and SINK_SORT by the two keys.
#
# Output types: the sums are DECIMAL(38, s) with s the scale of the input
# expression (2 for the quantity and the price, 4 for the discounted price,
# 6 for the charge), the averages are FLOAT64, the count INT64, as DuckDB
# types them.
#
# The table has the real column types: the two flags are strings, the money
# and the quantity are DECIMAL(15,2) held as unscaled cents, the ship date is
# DATE32. Rows come in blocks of four that each hold the four (flag, status)
# pairs TPC-H has (A F, N F, N O, R F), the order rotating from block to
# block, so every block of four rows has two or three distinct flags and two
# distinct statuses: written in row groups of four, both key columns fall back
# to plain encoding (the Parquet writer dictionary-encodes a string column only
# when its distinct values are at most 40 percent of the rows), and written in
# row groups of 256 both are dictionary encoded, with the dictionary's order
# differing from row group to row group. The other columns come from a fixed
# generator, and the dates straddle the cut-off.

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
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_physical_plan.physical_plan import (
    AggSinkData,
    MorselOp,
    SegmentDescPod,
    SortSinkData,
)
from komira_plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_MEAN,
    AGG_SUM,
    AggExpr,
)
from komira_plan_expr.expr import BIN_ADD, BIN_LE, BIN_MUL, BIN_SUB, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_scalar_arithmetic.decimal_arith import I128

from .plan_harness import (
    chain,
    grouped_agg_data,
    output_segment,
    parquet_segment,
    with_sort_sink,
    with_string_group_sink,
)

# The cut-off, 1998-12-01 less 90 days, as days since the epoch.
comptime Q1_CUTOFF: Int = 10471


struct Q1Table(Movable):
    """The columns of the fixture, one list each. Money is in cents."""

    var flag: List[String]
    var status: List[String]
    var quantity: List[Int]
    var price: List[Int]
    var discount: List[Int]
    var tax: List[Int]
    var shipdate: List[Int]

    def __init__(out self):
        self.flag = List[String]()
        self.status = List[String]()
        self.quantity = List[Int]()
        self.price = List[Int]()
        self.discount = List[Int]()
        self.tax = List[Int]()
        self.shipdate = List[Int]()

    def add(
        mut self,
        flag: String,
        status: String,
        quantity: Int,
        price: Int,
        discount: Int,
        tax: Int,
        shipdate: Int,
    ):
        self.flag.append(flag)
        self.status.append(status)
        self.quantity.append(quantity)
        self.price.append(price)
        self.discount.append(discount)
        self.tax.append(tax)
        self.shipdate.append(shipdate)

    def rows(self) -> Int:
        return len(self.flag)


def _pair_flag(p: Int) -> String:
    if p == 0:
        return "A"
    if p == 3:
        return "R"
    return "N"


def _pair_status(p: Int) -> String:
    return "O" if p == 2 else "F"


def q1_table(rows: Int) -> Q1Table:
    """`rows` rows (a multiple of four is the clean case), in blocks of four
    that each hold the four (flag, status) pairs."""
    var t = Q1Table()
    var x = 4242
    for i in range(rows):
        x = (x * 1103515245 + 12345) % 2147483648
        var a = x // 65536
        x = (x * 1103515245 + 12345) % 2147483648
        var b = x // 65536
        x = (x * 1103515245 + 12345) % 2147483648
        var c = x // 65536
        var pair = (i + i // 4) % 4
        t.add(
            _pair_flag(pair),
            _pair_status(pair),
            100 * (1 + b % 50),
            90000 + (a * 7919 + c * 104729) % 9000000,
            b % 11,
            c % 9,
            8035 + (a * 31 + c) % 2600,
        )
    return t^


def _i128(v: Int) -> I128:
    return Scalar[DType.int64](v).cast[DType.int128]()


def q1_batch(ref t: Q1Table, start: Int, rows: Int) raises -> RecordBatch:
    """Rows `start .. start + rows - 1` of `t` as a batch."""
    var flags = List[String](capacity=rows)
    var statuses = List[String](capacity=rows)
    var qty = Decimal128Array.allocate_nullable(rows, 15, 2)
    var price = Decimal128Array.allocate_nullable(rows, 15, 2)
    var disc = Decimal128Array.allocate_nullable(rows, 15, 2)
    var tax = Decimal128Array.allocate_nullable(rows, 15, 2)
    var day = PrimitiveArray[DType.int32].allocate(rows)
    for i in range(rows):
        var r = start + i
        flags.append(t.flag[r])
        statuses.append(t.status[r])
        qty.set_i128(i, _i128(t.quantity[r]))
        price.set_i128(i, _i128(t.price[r]))
        disc.set_i128(i, _i128(t.discount[r]))
        tax.set_i128(i, _i128(t.tax[r]))
        day.set(i, Int32(t.shipdate[r]))
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder()
    sb.add_field(Field("l_returnflag", ArrowType.STRING, False))
    builder.add_column(Column.from_string(StringArray.from_strings(flags)))
    sb.add_field(Field("l_linestatus", ArrowType.STRING, False))
    builder.add_column(Column.from_string(StringArray.from_strings(statuses)))
    sb.add_field(Field.decimal128("l_quantity", 15, 2, True))
    builder.add_column(Column.from_decimal128(qty^))
    sb.add_field(Field.decimal128("l_extendedprice", 15, 2, True))
    builder.add_column(Column.from_decimal128(price^))
    sb.add_field(Field.decimal128("l_discount", 15, 2, True))
    builder.add_column(Column.from_decimal128(disc^))
    sb.add_field(Field.decimal128("l_tax", 15, 2, True))
    builder.add_column(Column.from_decimal128(tax^))
    sb.add_field(Field("l_shipdate", ArrowType.DATE32, False))
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](
            day^, ArrowType.DATE32
        )
    )
    return builder.build(sb.build())


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _one() -> Expr:
    """The literal 1.00 of `1 - l_discount` and `1 + l_tax`."""
    return Expr.literal(ScalarValue.decimal128_i128(_i128(100), 4, 2))


def q1_predicate() -> Expr:
    return Expr.binary(
        BIN_LE,
        _col("l_shipdate"),
        Expr.literal(ScalarValue.date32(Int32(Q1_CUTOFF))),
    )


def q1_projection() -> List[String]:
    """The seven columns Q1 reads."""
    var out = List[String]()
    out.append("l_returnflag")
    out.append("l_linestatus")
    out.append("l_quantity")
    out.append("l_extendedprice")
    out.append("l_discount")
    out.append("l_tax")
    out.append("l_shipdate")
    return out^


def q1_project_names() -> List[String]:
    var out = List[String]()
    out.append("l_returnflag")
    out.append("l_linestatus")
    out.append("l_quantity")
    out.append("l_extendedprice")
    out.append("l_discount")
    out.append("disc_price")
    out.append("charge")
    return out^


def _disc_price() -> Expr:
    return Expr.binary(
        BIN_MUL,
        _col("l_extendedprice"),
        Expr.binary(BIN_SUB, _one(), _col("l_discount")),
    )


def _charge() -> Expr:
    return Expr.binary(
        BIN_MUL,
        _disc_price(),
        Expr.binary(BIN_ADD, _one(), _col("l_tax")),
    )


def q1_exprs() -> Slab[Expr]:
    """The projection: the keys and measures through, then the two products."""
    var exprs = Slab[Expr]()
    exprs.append(_col("l_returnflag"))
    exprs.append(_col("l_linestatus"))
    exprs.append(_col("l_quantity"))
    exprs.append(_col("l_extendedprice"))
    exprs.append(_col("l_discount"))
    exprs.append(_disc_price())
    exprs.append(_charge())
    return exprs^


def _sum(name: String) -> AggExpr:
    return AggExpr(AGG_SUM, Optional(_col(name)), None)


def _avg(name: String) -> AggExpr:
    return AggExpr(AGG_MEAN, Optional(_col(name)), None)


def q1_sink_data() raises -> AggSinkData:
    """GROUP BY the two flags: eight aggregates after the two keys."""
    var keys = Slab[Expr]()
    keys.append(_col("l_returnflag"))
    keys.append(_col("l_linestatus"))
    var aggs = Slab[AggExpr]()
    aggs.append(_sum("l_quantity"))
    aggs.append(_sum("l_extendedprice"))
    aggs.append(_sum("disc_price"))
    aggs.append(_sum("charge"))
    aggs.append(_avg("l_quantity"))
    aggs.append(_avg("l_extendedprice"))
    aggs.append(_avg("l_discount"))
    aggs.append(AggExpr(AGG_COUNT, None, None))
    var sb = SchemaBuilder()
    sb.add_field(Field("l_returnflag", ArrowType.STRING, True))
    sb.add_field(Field("l_linestatus", ArrowType.STRING, True))
    sb.add_field(Field.decimal128("sum_qty", 38, 2, True))
    sb.add_field(Field.decimal128("sum_base_price", 38, 2, True))
    sb.add_field(Field.decimal128("sum_disc_price", 38, 4, True))
    sb.add_field(Field.decimal128("sum_charge", 38, 6, True))
    sb.add_field(Field("avg_qty", ArrowType.FLOAT64, True))
    sb.add_field(Field("avg_price", ArrowType.FLOAT64, True))
    sb.add_field(Field("avg_disc", ArrowType.FLOAT64, True))
    sb.add_field(Field("count_order", ArrowType.INT64, False))
    return grouped_agg_data(keys^, aggs^, sb.build())


def q1_sort_data() -> SortSinkData:
    """ORDER BY l_returnflag, l_linestatus, both ascending."""
    var keys = List[String]()
    keys.append("l_returnflag")
    keys.append("l_linestatus")
    var descending = List[Bool]()
    descending.append(False)
    descending.append(False)
    return SortSinkData(keys^, descending^, 0, List[Bool]())


def q1_plan(
    var path: String,
    agg_param_id: Int,
    sort_param_id: Int,
    dict_encoded: Bool,
    morsel_rows: Int = 0,
) -> List[SegmentDescPod]:
    """Q1 over the Parquet file or glob `path`: segment 0 scans, filters,
    projects and groups, segment 1 sorts. The ids are what
    `RealBuilder.add_agg_sink(q1_sink_data())` and
    `add_sort_sink(q1_sort_data())` returned."""
    var ops = chain(
        MorselOp.filter(q1_predicate()),
        MorselOp.project(q1_exprs(), q1_project_names()),
    )
    var descs = List[SegmentDescPod]()
    descs.append(
        with_string_group_sink(
            parquet_segment(
                0,
                path^,
                Optional(q1_projection()),
                None,
                ops^,
                morsel_rows,
            ),
            agg_param_id,
            dict_encoded,
        )
    )
    descs.append(with_sort_sink(output_segment(1, 0), sort_param_id))
    return descs^
