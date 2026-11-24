# =============================================================================
# test_plan_wire_rel_goldens_join.mojo - the relational goldens, part two.
# =============================================================================
#
# Freezes the bytes of four plans built with the engine's own plan factories:
#
#   rel_join_inner  an inner equi-join with a residual whose references name
#                   their side; the right key is renamed `c_id_right`.
#   rel_join_kinds  an anti join over a semi join over a left join: the left
#                   join makes its right side nullable, the semi and anti joins
#                   keep only their left input.
#   rel_join_outer  a full join of a right join and a cross join: the right
#                   join makes its left side nullable, the full join both.
#   rel_window      a projection over seventeen partition-by nodes, one per
#                   window item as the SQL binder stacks them: every window
#                   function, partitioned and not, ordered both ways, with the
#                   binder's default frames and explicit ROWS and RANGE frames;
#                   the last window is named like an input column, so it is
#                   computed as `_w_shadow_17_price` and renamed above.
#
# These goldens are what the Python plan encoder's test
# (python/tests/test_plan_rel_goldens.py) compares its bytes to: the same plans,
# built as komira._ops nodes and encoded from Python, must equal
# `<stem>.canonical.hex`. The Python plans are the source of truth for what each
# golden holds. The sibling file test_plan_wire_rel_goldens.mojo holds the
# scan, filter, projection, aggregate, sort, limit and union goldens.
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
from plan_expr.expr import Expr, BIN_AND, BIN_GT, BIN_MUL, BIN_NE
from plan_expr.partition_expr import (
    PartitionExpr,
    PF_AVG,
    PF_COUNT,
    PF_CUME_DIST,
    PF_DENSE_RANK,
    PF_FIRST_VALUE,
    PF_LAG,
    PF_LAST_VALUE,
    PF_LEAD,
    PF_MAX,
    PF_MIN,
    PF_NTH_VALUE,
    PF_NTILE,
    PF_PERCENT_RANK,
    PF_RANK,
    PF_ROW_NUMBER,
    PF_SUM,
)
from plan_expr.partition_frame import (
    PartitionFrame,
    FRAME_BOUND_CURRENT_ROW,
    FRAME_BOUND_FOLLOWING,
    FRAME_BOUND_PRECEDING,
    FRAME_BOUND_UNBOUNDED_FOLLOWING,
    FRAME_BOUND_UNBOUNDED_PRECEDING,
    FRAME_UNITS_RANGE,
    FRAME_UNITS_ROWS,
)
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import (
    ExprArray,
    LogicalPlan,
    JOIN_ALGO_AUTO,
    JOIN_ANTI,
    JOIN_CROSS,
    JOIN_FULL,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_SEMI,
)
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


# The scans: `orders` as in test_plan_wire_rel_goldens.mojo, and three
# tables to join it with.


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


def _customers_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("c_id", ArrowType.INT64, False))
    sb.add_field(Field("name", ArrowType.STRING, True))
    sb.add_field(Field("region", ArrowType.STRING, True))
    return sb.build()


def _regions_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("r_name", ArrowType.STRING, False))
    sb.add_field(Field("r_code", ArrowType.INT32, False))
    return sb.build()


def _nations_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("n_name", ArrowType.STRING, False))
    sb.add_field(Field("n_code", ArrowType.INT64, True))
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


def _customers() raises -> LogicalPlan:
    return _parquet(String("/data/customers.parquet"), _customers_schema())


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _keys(name: String) -> List[String]:
    return [String(name)]


def _join(
    var left: LogicalPlan,
    var right: LogicalPlan,
    left_on: String,
    right_on: String,
    join_type: UInt8,
) raises -> LogicalPlan:
    return LogicalPlan.join(
        left^, right^, _keys(left_on), _keys(right_on), join_type, JOIN_ALGO_AUTO
    )


# =============================================================================
# rel_join_inner, rel_join_kinds, rel_join_outer
# =============================================================================


def _rel_join_inner() raises -> LogicalPlan:
    var residual = Expr.binary(
        BIN_AND,
        Expr.binary(
            BIN_GT,
            Expr.left("price"),
            Expr.literal(ScalarValue.from_float(10.0)),
        ),
        Expr.binary(
            BIN_NE,
            Expr.right("region"),
            Expr.literal(ScalarValue.from_string(String("x"))),
        ),
    )
    return LogicalPlan.join(
        _orders(),
        _customers(),
        _keys("c_id"),
        _keys("c_id"),
        JOIN_INNER,
        JOIN_ALGO_AUTO,
        Optional(OwnedPointer(residual^)),
    )


def _rel_join_kinds() raises -> LogicalPlan:
    var left = _join(_orders(), _customers(), "c_id", "c_id", JOIN_LEFT)
    var semi = _join(left^, _customers(), "c_id", "c_id", JOIN_SEMI)
    return _join(semi^, _customers(), "c_id_right", "c_id", JOIN_ANTI)


def _rel_join_outer() raises -> LogicalPlan:
    var right = _join(_orders(), _customers(), "c_id", "c_id", JOIN_RIGHT)
    var cross = LogicalPlan.join(
        _parquet(String("/data/regions.parquet"), _regions_schema()),
        _parquet(String("/data/nations.parquet"), _nations_schema()),
        List[String](),
        List[String](),
        JOIN_CROSS,
        JOIN_ALGO_AUTO,
    )
    return _join(right^, cross^, "c_id", "n_code", JOIN_FULL)


# =============================================================================
# rel_window
# =============================================================================


def _ordered() -> PartitionFrame:
    """The frame the SQL binder gives an ordered window without a frame."""
    return PartitionFrame(
        FRAME_UNITS_RANGE,
        FRAME_BOUND_UNBOUNDED_PRECEDING,
        Int64(0),
        FRAME_BOUND_CURRENT_ROW,
        Int64(0),
    )


def _unordered() -> PartitionFrame:
    """The frame the SQL binder gives an unordered window: the partition."""
    return PartitionFrame(
        FRAME_UNITS_ROWS,
        FRAME_BOUND_UNBOUNDED_PRECEDING,
        Int64(0),
        FRAME_BOUND_UNBOUNDED_FOLLOWING,
        Int64(0),
    )


def _window(
    var child: LogicalPlan,
    partition: List[String],
    order: List[String],
    descending: List[Bool],
    func: UInt8,
    column: String,
    offset: Int,
    var frame: PartitionFrame,
    name: String,
) raises -> LogicalPlan:
    """One partition-by node of one window expression with a NULL default."""
    var xs = List[PartitionExpr]()
    xs.append(
        PartitionExpr(
            func, String(column), offset, ScalarValue(), False, frame^, String(name)
        )
    )
    return LogicalPlan.partition_by(
        partition.copy(), order.copy(), descending.copy(), xs^, child^
    )


def _rel_window() raises -> LogicalPlan:
    var by_c: List[String] = [String("c_id")]
    var none = List[String]()
    var by_o: List[String] = [String("o_id")]
    var asc: List[Bool] = [False]
    var no_dir = List[Bool]()
    var p = _orders()
    p = _window(p^, by_c, by_o, asc, PF_ROW_NUMBER, "", 0, _ordered(), "rn")
    var by_price: List[String] = [String("price")]
    var desc: List[Bool] = [True]
    p = _window(p^, none, by_price, desc, PF_RANK, "", 0, _ordered(), "rk")
    var by_qty: List[String] = [String("qty")]
    p = _window(p^, by_c, by_qty, asc, PF_DENSE_RANK, "", 0, _ordered(), "drk")
    p = _window(p^, none, by_o, asc, PF_PERCENT_RANK, "", 0, _ordered(), "pr")
    p = _window(p^, none, by_o, asc, PF_CUME_DIST, "", 0, _ordered(), "cd")
    p = _window(p^, none, by_o, asc, PF_NTILE, "", 4, _ordered(), "nt")
    p = _window(p^, by_c, by_o, asc, PF_LAG, "price", 1, _ordered(), "prev")
    p = _window(p^, none, by_o, asc, PF_LEAD, "amount", 2, _ordered(), "next2")
    p = _window(p^, by_c, by_o, asc, PF_FIRST_VALUE, "s", 0, _ordered(), "fv")
    p = _window(
        p^, by_c, by_o, asc, PF_LAST_VALUE, "ts", 0, _unordered(), "lv"
    )
    var around = PartitionFrame(
        FRAME_UNITS_ROWS,
        FRAME_BOUND_PRECEDING,
        Int64(1),
        FRAME_BOUND_FOLLOWING,
        Int64(1),
    )
    p = _window(p^, none, by_o, asc, PF_NTH_VALUE, "o_id", 2, around^, "nv")
    var last3 = PartitionFrame(
        FRAME_UNITS_ROWS,
        FRAME_BOUND_PRECEDING,
        Int64(2),
        FRAME_BOUND_CURRENT_ROW,
        Int64(0),
    )
    p = _window(p^, by_c, by_o, asc, PF_SUM, "qty", 0, last3^, "run_qty")
    p = _window(
        p^, by_c, none, no_dir, PF_SUM, "price", 0, _unordered(), "tot_price"
    )
    p = _window(p^, by_c, by_o, asc, PF_AVG, "price", 0, _ordered(), "avg_p")
    p = _window(p^, by_c, none, no_dir, PF_COUNT, "s", 0, _unordered(), "cnt")
    p = _window(p^, by_c, none, no_dir, PF_MIN, "ts", 0, _unordered(), "min_ts")
    p = _window(
        p^,
        by_c,
        none,
        no_dir,
        PF_MAX,
        "price",
        0,
        _unordered(),
        "_w_shadow_17_price",
    )
    var xs = ExprArray()
    xs.append(_col("o_id"))
    var windows: List[String] = [
        String("rn"),
        String("rk"),
        String("drk"),
        String("pr"),
        String("cd"),
        String("nt"),
        String("prev"),
        String("next2"),
        String("fv"),
        String("lv"),
        String("nv"),
        String("run_qty"),
        String("tot_price"),
        String("avg_p"),
        String("cnt"),
        String("min_ts"),
    ]
    for i in range(len(windows)):
        xs.append(_col(windows[i]))
    xs.append(Expr.alias(_col("_w_shadow_17_price"), String("price")))
    xs.append(
        Expr.alias(
            Expr.binary(BIN_MUL, _col("price"), _col("qty")), String("total")
        )
    )
    return LogicalPlan.project(xs^, p^)


def test_rel_join_inner_bytes_are_frozen() raises:
    _assert_frozen(String("rel_join_inner"), _rel_join_inner())


def test_rel_join_kinds_bytes_are_frozen() raises:
    _assert_frozen(String("rel_join_kinds"), _rel_join_kinds())


def test_rel_join_outer_bytes_are_frozen() raises:
    _assert_frozen(String("rel_join_outer"), _rel_join_outer())


def test_rel_window_bytes_are_frozen() raises:
    _assert_frozen(String("rel_window"), _rel_window())


def main() raises:
    var suite = TestSuite()
    suite.test[test_rel_join_inner_bytes_are_frozen]()
    suite.test[test_rel_join_kinds_bytes_are_frozen]()
    suite.test[test_rel_join_outer_bytes_are_frozen]()
    suite.test[test_rel_window_bytes_are_frozen]()
    suite^.run()
