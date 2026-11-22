# =============================================================================
# test_plan_wire_rel_goldens.mojo - the relational goldens, part one.
# =============================================================================
#
# Freezes the bytes of four plans built with the engine's own plan factories,
# over Parquet and CSV scans:
#
#   rel_filter_project  a projection (a column under its own name, renames, an
#                       expression, a literal) over a filter over a Parquet
#                       scan whose first column carries metadata.
#   rel_aggregate       a sort, one key descending with NULLs first, over an
#                       aggregate with two keys and one aggregate of each
#                       result-type family: counts, sums over every input type
#                       that changes the result, an expression argument, the
#                       picks, the float64 statistics, the two-argument
#                       functions whose slots hold x before y, and the
#                       boolean ones.
#   rel_sort_limit      a limit with an offset over a distinct over a top-n
#                       over a projection.
#   rel_union           a limit over a union of a filtered Parquet scan, a CSV
#                       scan and a filtered CSV scan of one schema.
#
# These goldens are what the Python plan encoder's test
# (python/tests/test_plan_rel_goldens.py) compares its bytes to: the same plans,
# built as komira._ops nodes and encoded from Python, must equal
# `<stem>.canonical.hex`. The Python plans are the source of truth for what each
# golden holds. The sibling file test_plan_wire_rel_goldens_join.mojo holds the
# joins and the windows.
#
# The hex helpers and the four legs are copied from
# test_plan_wire_expr_goldens.mojo: a welded test cannot import another test
# file.
#
# Each case checks four things:
#   LEG A  the encoder's bytes equal `<stem>.hex`, byte for byte.
#   LEG B  the bytes of `<stem>.hex` decode to the plan, its hash and its
#          output schema.
#   LEG C  the bytes are longer than an envelope alone.
#   LEG D  plan_wire decodes `<stem>.canonical.hex`, protoc's canonical
#          serialization of the plan, back to the engine-built plan.
#
# Regolding: every case prints a `GOLDEN-BEGIN`/`GOLDEN-END` block holding the
# bytes it encoded, on pass as well as on fail. Copy the block into
# `tests/fixtures/golden/<stem>.hex` and re-derive `<stem>.canonical.hex` with
# protoc (`--decode` then `--encode`).
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.agg_expr import (
    AggExpr,
    AGG_ANY_VALUE,
    AGG_BOOL_AND,
    AGG_BOOL_OR,
    AGG_CORR,
    AGG_COUNT,
    AGG_COUNT_DISTINCT,
    AGG_COUNT_IF,
    AGG_COVAR_POP,
    AGG_FIRST,
    AGG_KAHAN_AVG,
    AGG_KURTOSIS,
    AGG_LARGEST_K,
    AGG_LAST,
    AGG_MAX,
    AGG_MEAN,
    AGG_MEDIAN,
    AGG_MIN,
    AGG_PRODUCT,
    AGG_REGR_COUNT,
    AGG_REGR_SLOPE,
    AGG_STDDEV_SAMP,
    AGG_SUM,
)
from plan_expr.expr import Expr, BIN_AND, BIN_GT, BIN_MUL, UN_IS_NOT_NULL
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import AggExprArray, ExprArray, LogicalPlan
from scan_source.csv_source import CsvSource
from scan_source.parquet_source import ParquetSource
from scan_source.source_variant import SourceVariant

from plan_wire import plan_to_bytes, plan_from_bytes




comptime _FIXTURE_DIR: String = "src/plan_wire/tests/fixtures/golden/"
comptime _HEX_BYTES_PER_LINE: Int = 32


def _hex_nibble(v: UInt8) -> String:
    comptime DIGITS = String("0123456789abcdef")
    return String(DIGITS[byte=Int(v)])


def _to_hex_lines(bytes: List[UInt8]) -> String:
    """The canonical `.hex` rendering: lowercase, 32 bytes per line, newline
    terminated, no offsets and no ASCII column."""
    var out = String("")
    for i in range(len(bytes)):
        out += _hex_nibble(bytes[i] >> 4)
        out += _hex_nibble(bytes[i] & 0xF)
        if (i % _HEX_BYTES_PER_LINE) == (_HEX_BYTES_PER_LINE - 1):
            out += "\n"
    if len(bytes) % _HEX_BYTES_PER_LINE != 0:
        out += "\n"
    return out^


def _hex_value(c: UInt8) raises -> UInt8:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return c - UInt8(ord("a")) + UInt8(10)
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return c - UInt8(ord("A")) + UInt8(10)
    raise Error(
        "plan_wire golden: a `.hex` fixture holds a non-hex character (byte "
        + String(Int(c))
        + "). The fixtures are copied from the GOLDEN block this test prints;"
        + " they are not hand-editable."
    )


def _from_hex(text: String) raises -> List[UInt8]:
    """Parse a `.hex` fixture. Whitespace is skipped, so the line width is a
    review convention and not part of the format."""
    var nibbles = List[UInt8]()
    var b = text.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if (
            c == UInt8(ord(" "))
            or c == UInt8(ord("\n"))
            or c == UInt8(ord("\r"))
            or c == UInt8(ord("\t"))
        ):
            continue
        nibbles.append(_hex_value(c))
    if len(nibbles) % 2 != 0:
        raise Error(
            "plan_wire golden: a `.hex` fixture has an ODD number of hex"
            + " digits ("
            + String(len(nibbles))
            + "). Half a byte is not a byte."
        )
    var out = List[UInt8]()
    for i in range(0, len(nibbles), 2):
        out.append((nibbles[i] << 4) | nibbles[i + 1])
    return out^


def _read_fixture(name: String) raises -> String:
    """Read `tests/fixtures/golden/<name>.hex`, declared test data staged at
    its repository path under the test's working directory."""
    var path = _FIXTURE_DIR + name + ".hex"
    try:
        with open(path, "r") as f:
            return f.read()
    except:
        pass
    raise Error(
        "plan_wire golden: fixture `"
        + path
        + "` is MISSING. If this is a NEW corpus member, the GOLDEN block this"
        + " test just printed is its content: write it to that path and"
        + " declare it as test data."
    )


# The scan under every projection: ten columns, one per type the expression
# factories derive a result type from.



def _schema_text(s: Schema) raises -> String:
    """The schema rendering LEG B and LEG D compare: the whole `Field`, so
    children, zone, decimal parameters and metadata are compared too."""
    var out = String("[")
    for i in range(s.num_columns()):
        if i > 0:
            out += ", "
        out += String(s.field_at_unchecked(i))
    out += "]"
    return out^


def _assert_frozen(name: String, var plan: LogicalPlan) raises:
    """LEG A (freeze), LEG B (meaning), LEG C (non-trivial), LEG D (decoding
    protoc's canonical bytes) for one plan."""
    var text = String(plan)
    var h = plan.structural_hash()
    var sch = _schema_text(plan.output_schema)

    var bytes = plan_to_bytes(plan)

    # Printed on pass and on fail: regolding copies exactly this block.
    print("GOLDEN-BEGIN " + name)
    print(_to_hex_lines(bytes), end="")
    print("GOLDEN-END " + name)

    # --- LEG C: non-trivial -------------------------------------------------
    assert_true(
        len(bytes) > 16,
        name
        + ": LEG C - the encoder produced only "
        + String(len(bytes))
        + " bytes, at most an envelope with no plan in it.",
    )

    # --- LEG A: freeze ------------------------------------------------------
    var want = _from_hex(_read_fixture(name))
    assert_equal(
        len(bytes),
        len(want),
        name
        + ": LEG A - the encoder now produces "
        + String(len(bytes))
        + " bytes; the frozen fixture is "
        + String(len(want))
        + ". A byte-length change is a wire format change. If it was"
        + " deliberate, regold the fixture from the GOLDEN block above and"
        + " commit the diff; if it was not, the diff is the bug report.",
    )
    var first_diff = -1
    for i in range(len(want)):
        if bytes[i] != want[i]:
            first_diff = i
            break
    assert_equal(
        first_diff,
        -1,
        name
        + ": LEG A - the encoder's bytes diverge from the frozen fixture at"
        + " offset "
        + String(first_diff)
        + " (encoder wrote "
        + String(Int(bytes[first_diff if first_diff >= 0 else 0]))
        + ", fixture holds "
        + String(Int(want[first_diff if first_diff >= 0 else 0]))
        + ").",
    )

    # --- LEG B: the frozen bytes still mean this plan -----------------------
    # Decoded from the fixture, not from `bytes`: this leg is about the bytes
    # on disk.
    var back = plan_from_bytes(want^)
    assert_equal(
        String(back),
        text,
        name
        + ": LEG B - the checked-in bytes decode into a plan that renders"
        + " differently from the plan of the same name.",
    )
    assert_equal(
        String(back.structural_hash()),
        String(h),
        name
        + ": LEG B - the decoded plan's text matches but its structural_hash"
        + " does not.",
    )
    assert_equal(
        _schema_text(back.output_schema),
        sch,
        name
        + ": LEG B - the decoded plan promises different output columns.",
    )

    # --- LEG D: plan_wire reads bytes protoc wrote --------------------------
    # `<name>.canonical.hex` is protoc's own serialization of the plan; it is
    # also what the Python plan encoder must produce.
    var canonical = _from_hex(_read_fixture(name + ".canonical"))
    assert_true(
        len(canonical) > 16,
        name
        + ": LEG D - `"
        + name
        + ".canonical.hex` is empty or a stub. Re-derive it with protoc from"
        + " `" + name + ".hex`.",
    )
    var foreign = plan_from_bytes(canonical^)
    assert_equal(
        String(foreign),
        text,
        name
        + ": LEG D - the decoder cannot reconstruct this plan from the bytes"
        + " the reference protobuf implementation produces for it.",
    )
    assert_equal(
        String(foreign.structural_hash()),
        String(h),
        name
        + ": LEG D - the plan decoded from the reference implementation's"
        + " bytes renders identically but hashes differently.",
    )
    assert_equal(
        _schema_text(foreign.output_schema),
        sch,
        name
        + ": LEG D - the plan decoded from the reference implementation's"
        + " bytes promises different output columns.",
    )
    _ = plan^


# The scans. `orders` has one column of each type a node's derived field
# depends on; its first column carries metadata, which a filter keeps and a
# projection drops.


def _orders_schema() raises -> Schema:
    var sb = SchemaBuilder()
    var o = Field("o_id", ArrowType.INT64, False)
    o._metadata_keys = [String("unit")]
    o._metadata_values = [String("id")]
    sb.add_field(o^)
    sb.add_field(Field("c_id", ArrowType.INT64, True))
    sb.add_field(Field("qty", ArrowType.INT32, True))
    sb.add_field(Field("price", ArrowType.FLOAT64, True))
    var amount = Field("amount", ArrowType.DECIMAL128, True)
    amount.decimal_precision = 12
    amount.decimal_scale = 2
    sb.add_field(amount^)
    sb.add_field(Field("flag", ArrowType.BOOL, True))
    sb.add_field(Field("u", ArrowType.UINT16, True))
    sb.add_field(Field("f32", ArrowType.FLOAT32, True))
    var ts = Field("ts", ArrowType.TIMESTAMP_US, True)
    ts._tz = String("UTC")
    sb.add_field(ts^)
    sb.add_field(Field("s", ArrowType.STRING, True))
    return sb.build()


def _events_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("v", ArrowType.FLOAT64, True))
    sb.add_field(Field("t", ArrowType.STRING, True))
    return sb.build()


def _parquet(path: String, var schema: Schema) raises -> LogicalPlan:
    """A scan of a Parquet file as the SQL catalog binds a registered one: no
    name, mtime 0, no projection, filter or row count."""
    return LogicalPlan.scan_from_source(
        SourceVariant(ParquetSource(String(path), schema.copy(), None)),
        schema^,
    )


def _orders() raises -> LogicalPlan:
    return _parquet(String("/data/orders.parquet"), _orders_schema())


def _events_csv() raises -> LogicalPlan:
    var source = CsvSource(
        String("/data/events.csv"),
        _events_schema(),
        mtime_ns=UInt64(1234567890),
    )
    return LogicalPlan.scan_from_source(SourceVariant(source^), _events_schema())


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _int(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int64(Int64(v)))


def _flt(v: Float64) -> Expr:
    return Expr.literal(ScalarValue.from_float(v))


def _named(name: String, var e: Expr) -> Expr:
    return Expr.alias(e^, name)


def _times(a: String, b: String) -> Expr:
    return Expr.binary(BIN_MUL, _col(a), _col(b))


def _agg(func: UInt8, arg: String, name: String) -> AggExpr:
    return AggExpr(func, Optional(_col(arg)), Optional(String(name)))


def _agg2(func: UInt8, slot0: String, slot1: String, name: String) -> AggExpr:
    return AggExpr(
        func, Optional(_col(slot0)), Optional(_col(slot1)), Optional(String(name))
    )


# =============================================================================
# rel_filter_project
# =============================================================================


def _rel_filter_project() raises -> LogicalPlan:
    var pred = Expr.binary(
        BIN_AND,
        Expr.binary(BIN_GT, _col("qty"), _int(0)),
        Expr.unary(UN_IS_NOT_NULL, _col("c_id")),
    )
    var kept = LogicalPlan.filter(pred^, _orders())
    var xs = ExprArray()
    xs.append(_col("o_id"))
    xs.append(_named("cid", _col("c_id")))
    xs.append(_named("total", _times("price", "qty")))
    xs.append(_named("amt", _col("amount")))
    xs.append(_named("one", _int(1)))
    return LogicalPlan.project(xs^, kept^)


# =============================================================================
# rel_aggregate
# =============================================================================


def _rel_aggregate() raises -> LogicalPlan:
    var gb = ExprArray()
    gb.append(_col("c_id"))
    gb.append(_col("flag"))
    var ax = AggExprArray()
    ax.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional(String("n"))))
    ax.append(_agg(AGG_COUNT, "s", "n_s"))
    ax.append(_agg(AGG_SUM, "qty", "sum_qty"))
    ax.append(_agg(AGG_SUM, "u", "sum_u"))
    ax.append(_agg(AGG_SUM, "f32", "sum_f32"))
    ax.append(_agg(AGG_SUM, "amount", "sum_amt"))
    ax.append(_agg(AGG_SUM, "price", "sum_price"))
    ax.append(_agg(AGG_SUM, "flag", "sum_flag"))
    ax.append(
        AggExpr(
            AGG_SUM,
            Optional(_times("price", "qty")),
            Optional(String("sum_expr")),
        )
    )
    ax.append(_agg(AGG_MEAN, "price", "avg_price"))
    ax.append(_agg(AGG_MIN, "ts", "min_ts"))
    ax.append(_agg(AGG_MAX, "amount", "max_amt"))
    ax.append(_agg(AGG_FIRST, "s", "first_s"))
    ax.append(_agg(AGG_LAST, "s", "last_s"))
    ax.append(_agg(AGG_ANY_VALUE, "o_id", "any_o"))
    ax.append(_agg(AGG_COUNT_DISTINCT, "s", "nd"))
    ax.append(_agg(AGG_MEDIAN, "price", "med"))
    ax.append(_agg(AGG_STDDEV_SAMP, "price", "sd"))
    ax.append(_agg(AGG_KAHAN_AVG, "price", "kavg"))
    ax.append(_agg(AGG_KURTOSIS, "price", "kurt"))
    ax.append(_agg(AGG_PRODUCT, "price", "prod"))
    ax.append(_agg(AGG_LARGEST_K, "price", "top2"))
    # CORR takes its arguments in order; the regression and covariance
    # functions hold x (SQL's second argument) in slot 0.
    ax.append(_agg2(AGG_CORR, "price", "qty", "corr"))
    ax.append(_agg2(AGG_REGR_SLOPE, "qty", "price", "slope"))
    ax.append(_agg2(AGG_COVAR_POP, "qty", "price", "cov"))
    ax.append(_agg2(AGG_REGR_COUNT, "qty", "price", "rc"))
    ax.append(_agg(AGG_COUNT_IF, "flag", "n_flag"))
    ax.append(_agg(AGG_BOOL_AND, "flag", "all_flag"))
    ax.append(_agg(AGG_BOOL_OR, "flag", "any_flag"))
    var grouped = LogicalPlan.aggregate(gb^, ax^, _orders())
    var keys: List[String] = [String("c_id"), String("n")]
    var desc: List[Bool] = [False, True]
    var nf: List[Bool] = [False, True]
    return LogicalPlan.sort(keys^, desc^, grouped^, Optional(nf^))


# =============================================================================
# rel_sort_limit
# =============================================================================


def _rel_sort_limit() raises -> LogicalPlan:
    var xs = ExprArray()
    xs.append(_col("c_id"))
    xs.append(_col("price"))
    xs.append(_col("s"))
    var picked = LogicalPlan.project(xs^, _orders())
    var keys: List[String] = [String("price"), String("c_id")]
    var desc: List[Bool] = [True, False]
    var nf: List[Bool] = [False, True]
    var top = LogicalPlan.topn(keys^, desc^, 100, picked^, Optional(nf^))
    var unique = LogicalPlan.distinct(Optional[List[String]](), top^)
    return LogicalPlan.limit(10, unique^, 5)


# =============================================================================
# rel_union
# =============================================================================


def _rel_union() raises -> LogicalPlan:
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(
        OwnedPointer(
            LogicalPlan.filter(
                Expr.binary(BIN_GT, _col("v"), _flt(1.5)),
                _parquet(String("/data/events.parquet"), _events_schema()),
            )
        )
    )
    kids.append(OwnedPointer(_events_csv()))
    kids.append(
        OwnedPointer(
            LogicalPlan.filter(
                Expr.unary(UN_IS_NOT_NULL, _col("t")), _events_csv()
            )
        )
    )
    return LogicalPlan.limit(3, LogicalPlan.union(kids^, _events_schema()))


def test_rel_filter_project_bytes_are_frozen() raises:
    _assert_frozen(String("rel_filter_project"), _rel_filter_project())


def test_rel_aggregate_bytes_are_frozen() raises:
    _assert_frozen(String("rel_aggregate"), _rel_aggregate())


def test_rel_sort_limit_bytes_are_frozen() raises:
    _assert_frozen(String("rel_sort_limit"), _rel_sort_limit())


def test_rel_union_bytes_are_frozen() raises:
    _assert_frozen(String("rel_union"), _rel_union())


def main() raises:
    var suite = TestSuite()
    suite.test[test_rel_filter_project_bytes_are_frozen]()
    suite.test[test_rel_aggregate_bytes_are_frozen]()
    suite.test[test_rel_sort_limit_bytes_are_frozen]()
    suite.test[test_rel_union_bytes_are_frozen]()
    suite^.run()
