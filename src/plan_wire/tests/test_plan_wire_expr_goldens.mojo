# =============================================================================
# test_plan_wire_expr_goldens.mojo - the expression goldens, part one.
# =============================================================================
#
# Freezes the bytes of three projections over one wide scan, built with the
# engine's own expression factories:
#
#   expr_literals   one literal of every kind the engine can project, each
#                   under its own alias (plan_wire's reader refuses to project
#                   a uint64, binary, time-of-day or interval literal).
#   expr_operators  comparisons, arithmetic over every numeric result type,
#                   the boolean and unary operators, and three bare column
#                   references.
#   expr_cast_when  casts to a primitive type, an Arrow type and a decimal, with
#                   and without `try`; CASE over int, float, NULL, string,
#                   decimal and bool results, and a CASE inside a CASE.
#
# These goldens are what the Python plan encoder's test
# (python/tests/test_plan_expr_goldens.py) compares its bytes to: the same
# expressions, in the same order and under the same aliases, encoded from
# Python, must equal `<stem>.canonical.hex`. The Python lists are the source of
# truth for what each plan holds. The sibling file
# test_plan_wire_expr_goldens_fns.mojo holds the string, math and temporal
# projections over the same scan.
#
# The scan, the hex helpers and the four legs are copied in both files: a
# welded test cannot import another test file, and the two files are split to
# stay under 1000 lines.
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

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.dtype_sentinel import DTYPE_NONE
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.expr import (
    Expr,
    WhenCaseData,
    BIN_ADD,
    BIN_AND,
    BIN_DIV,
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_MOD,
    BIN_MUL,
    BIN_NE,
    BIN_OR,
    BIN_SUB,
    UN_ABS,
    UN_BIT_COUNT,
    UN_IS_NOT_NULL,
    UN_IS_NULL,
    UN_NEGATE,
    UN_NOT,
    UN_ROUND,
    UN_SIGN,
    UN_TRUNC,
    STR_STARTS_WITH,
)
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import LogicalPlan, ExprArray
from scan_source.pushdown_gate import PushdownGate
from scan_source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SNAPSHOT_PINNED,
)
from scan_source.scan_params import ScanParams
from scan_source.source_variant import SourceVariant, SOURCE_VARIANT_ORC

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


def _schema() raises -> Schema:
    var sb = SchemaBuilder()
    var a = Field("a", ArrowType.INT64, False)
    a._metadata_keys = [String("unit")]
    a._metadata_values = [String("cents")]
    sb.add_field(a^)
    sb.add_field(Field("b", ArrowType.INT64, True))
    sb.add_field(Field("i", ArrowType.INT32, True))
    sb.add_field(Field("f", ArrowType.FLOAT64, True))
    var d = Field("d", ArrowType.DECIMAL128, True)
    d.decimal_precision = 12
    d.decimal_scale = 2
    sb.add_field(d^)
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("dt", ArrowType.DATE32, True))
    var ts = Field("ts", ArrowType.TIMESTAMP_US, True)
    ts._tz = String("UTC")
    sb.add_field(ts^)
    sb.add_field(Field("iv", ArrowType.INTERVAL_MONTH_DAY_NANO, True))
    var st = Field("st", ArrowType.STRUCT, True)
    st.add_child("k", ArrowType.INT64, False)
    st.add_child("v", ArrowType.STRING, True)
    sb.add_field(st^)
    return sb.build()


def _binding(name: String, path: String) raises -> ScanBinding:
    var p = ScanParams()
    p.put_str(String("path"), String(path))
    p.put_i64(String("stripe_count"), Int64(7))
    p.put_bool(String("has_footer"), True)
    return ScanBinding(
        kind_id=scan_kind_id(String("komira.orc")),
        kind_name=String("komira.orc"),
        name=name,
        params=p^,
        schema=_schema(),
        fingerprint=UInt64(0xDEADBEEF),
        structural_id=UInt64(0xFEEDFACE),
        gate=PushdownGate.conjunctive_comparison(),
        snapshot_policy=SNAPSHOT_PINNED,
        snapshot_token=UInt64(1234567890),
    )


def _scan() raises -> LogicalPlan:
    return LogicalPlan.scan_from_source(
        SourceVariant(
            tag=SOURCE_VARIANT_ORC,
            binding=_binding(String("wide"), String("/data/wide.orc")),
        ),
        _schema(),
    )


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _lit(var v: ScalarValue) -> Expr:
    return Expr.literal(v^)


def _int(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int64(Int64(v)))


def _str(v: String) -> Expr:
    return Expr.literal(ScalarValue.from_string(v))


def _flt(v: Float64) -> Expr:
    return Expr.literal(ScalarValue.from_float(v))


def _project(var xs: ExprArray) raises -> LogicalPlan:
    return LogicalPlan.project(xs^, _scan())


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


def _named(name: String, var e: Expr) -> Expr:
    return Expr.alias(e^, name)


def _bin(op: UInt8, var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(op, l^, r^)


def _gt(name: String, v: Int) -> Expr:
    return Expr.binary(BIN_GT, _col(name), _int(v))


# =============================================================================
# expr_literals
# =============================================================================


def _expr_literals() raises -> LogicalPlan:
    var xs = ExprArray()
    xs.append(_named("l_int", _int(42)))
    xs.append(_named("l_neg", _int(-7)))
    xs.append(_named("l_float", _flt(2.5)))
    xs.append(_named("l_true", _lit(ScalarValue.from_bool(True))))
    xs.append(_named("l_false", _lit(ScalarValue.from_bool(False))))
    xs.append(_named("l_str", _str("text")))
    xs.append(_named("l_empty", _str("")))
    xs.append(
        _named(
            "l_dec", _lit(ScalarValue.decimal128(Int64(-1), Int64(-123450), 6, 2))
        )
    )
    xs.append(
        _named(
            "l_bigdec",
            _lit(
                ScalarValue.decimal128(
                    Int64(6), Int64(-5670419503621182407), 21, 1
                )
            ),
        )
    )
    xs.append(_named("l_date", _lit(ScalarValue.date32(Int32(19782)))))
    xs.append(
        _named(
            "l_ts",
            _lit(ScalarValue.timestamp_micros(Int64(1709209815000250))),
        )
    )
    xs.append(_named("l_null", _lit(ScalarValue.null(DType.int64))))
    return _project(xs^)


# =============================================================================
# expr_operators
# =============================================================================


def _expr_operators() raises -> LogicalPlan:
    var xs = ExprArray()
    xs.append(_named("cmp_eq", _bin(BIN_EQ, _col("a"), _col("b"))))
    xs.append(_named("cmp_ne", _bin(BIN_NE, _col("a"), _int(1))))
    xs.append(_named("cmp_lt", _bin(BIN_LT, _col("f"), _flt(0.5))))
    xs.append(_named("cmp_le", _bin(BIN_LE, _col("s"), _str("m"))))
    xs.append(
        _named(
            "cmp_gt",
            _bin(
                BIN_GT,
                _col("d"),
                _lit(ScalarValue.decimal128(Int64(0), Int64(999), 3, 2)),
            ),
        )
    )
    xs.append(
        _named(
            "cmp_ge",
            _bin(
                BIN_GE,
                _col("dt"),
                _lit(ScalarValue.date32(Int32(19782))),
            ),
        )
    )
    xs.append(_named("ar_add", _bin(BIN_ADD, _col("a"), _col("b"))))
    xs.append(_named("ar_sub", _bin(BIN_SUB, _col("f"), _col("a"))))
    xs.append(_named("ar_mul", _bin(BIN_MUL, _col("i"), _int(3000000000))))
    xs.append(_named("ar_div", _bin(BIN_DIV, _col("i"), _int(2))))
    xs.append(_named("ar_mod", _bin(BIN_MOD, _col("a"), _int(7))))
    xs.append(_named("dec_add", _bin(BIN_ADD, _col("d"), _col("d"))))
    xs.append(_named("dec_mul", _bin(BIN_MUL, _col("d"), _col("a"))))
    xs.append(_named("dec_div", _bin(BIN_DIV, _col("d"), _flt(2.0))))
    xs.append(_named("dec_mod", _bin(BIN_MOD, _col("d"), _col("d"))))
    xs.append(_named("dec_sub_int", _bin(BIN_SUB, _col("d"), _col("a"))))
    xs.append(_named("dec_div_int", _bin(BIN_DIV, _col("a"), _col("d"))))
    xs.append(_named("iv_add", _bin(BIN_ADD, _col("iv"), _col("iv"))))
    xs.append(
        _named(
            "bool_and",
            _bin(BIN_AND, _gt("a", 1), Expr.unary(UN_IS_NULL, _col("b"))),
        )
    )
    xs.append(
        _named(
            "bool_or",
            _bin(
                BIN_OR,
                _bin(BIN_LT, _col("a"), _int(0)),
                _lit(ScalarValue.from_bool(True)),
            ),
        )
    )
    xs.append(_named("un_not", Expr.unary(UN_NOT, _gt("a", 1))))
    xs.append(_named("un_neg", Expr.unary(UN_NEGATE, _col("a"))))
    xs.append(_named("un_is_null", Expr.unary(UN_IS_NULL, _col("b"))))
    xs.append(_named("un_is_not_null", Expr.unary(UN_IS_NOT_NULL, _col("b"))))
    xs.append(_named("un_abs", Expr.unary(UN_ABS, _col("f"))))
    xs.append(_named("un_sign", Expr.unary(UN_SIGN, _col("i"))))
    xs.append(_named("un_trunc", Expr.unary(UN_TRUNC, _col("f"))))
    xs.append(_named("un_round", Expr.unary(UN_ROUND, _col("d"))))
    xs.append(_named("un_bit_count", Expr.unary(UN_BIT_COUNT, _col("a"))))
    xs.append(_col("a"))
    xs.append(_col("ts"))
    xs.append(_col("st"))
    return _project(xs^)


# =============================================================================
# expr_cast_when
#
# A CASE whose result or default is FLOAT64 carries its integer results as
# float literals and its untyped NULLs as float64 NULLs; conditions are never
# changed, and an inner CASE's type counts for the outer one. The CASEs below
# are written in that form.
# =============================================================================


def _case(var cond: Expr, var result: Expr) -> WhenCaseData:
    return WhenCaseData(cond^, result^)


def _when1(var cond: Expr, var result: Expr, var default: Expr) -> Expr:
    var cs = List[WhenCaseData]()
    cs.append(_case(cond^, result^))
    return Expr.when(cs^, default^)


def _expr_cast_when() raises -> LogicalPlan:
    var xs = ExprArray()
    xs.append(_named("c_f64", Expr.cast(_col("a"), DType.float64)))
    xs.append(_named("c_i32", Expr.cast(_col("f"), DType.int32)))
    xs.append(_named("c_f16", Expr.cast(_col("i"), DType.float16)))
    xs.append(_named("c_try", Expr.try_cast(_col("s"), DType.int64)))
    xs.append(_named("c_date", Expr.cast_to_arrow(_col("s"), ArrowType.DATE32)))
    xs.append(
        _named("c_ts", Expr.cast_to_arrow(_col("a"), ArrowType.TIMESTAMP_US))
    )
    xs.append(_named("c_str", Expr.cast_to_arrow(_col("a"), ArrowType.STRING)))
    xs.append(_named("c_dec", Expr.cast_to_decimal(_col("f"), 10, 3)))
    xs.append(
        _named(
            "c_try_dec",
            Expr.cast_from_parts(
                _col("a"), DTYPE_NONE, ArrowType.DECIMAL128, 18, 0, True
            ),
        )
    )
    xs.append(
        _named(
            "c_both",
            Expr.cast_from_parts(
                _col("a"),
                DType.int64,
                ArrowType.TIMESTAMP_MS,
                0,
                0,
                False,
            ),
        )
    )

    var w_int = List[WhenCaseData]()
    w_int.append(_case(_gt("a", 0), _int(1)))
    w_int.append(_case(_bin(BIN_LT, _col("b"), _int(0)), _int(2)))
    xs.append(_named("w_int", Expr.when(w_int^, _int(-1))))

    xs.append(_named("w_promote", _when1(_gt("a", 0), _flt(1.0), _flt(2.5))))
    xs.append(
        _named(
            "w_null_float",
            _when1(
                Expr.unary(UN_IS_NULL, _col("b")),
                _lit(ScalarValue.null(DType.float64)),
                _col("f"),
            ),
        )
    )
    xs.append(
        _named(
            "w_null_int",
            _when1(
                Expr.unary(UN_IS_NULL, _col("b")),
                _lit(ScalarValue.null(DType.int64)),
                _col("a"),
            ),
        )
    )
    xs.append(
        _named(
            "w_str",
            _when1(
                Expr.string_op(STR_STARTS_WITH, _col("s"), "x"),
                _col("s"),
                _str("none"),
            ),
        )
    )
    xs.append(_named("w_dec", _when1(_gt("a", 0), _col("d"), _col("d"))))
    xs.append(
        _named(
            "w_bool_float",
            _when1(
                _gt("a", 0),
                _lit(ScalarValue.from_bool(True)),
                _flt(1.5),
            ),
        )
    )
    var inner = _when1(
        _bin(BIN_LT, _col("b"), _int(0)), _flt(1.0), _flt(2.0)
    )
    xs.append(_named("w_nested", _when1(_gt("a", 0), inner^, _flt(3.0))))
    return _project(xs^)


def test_expr_literals_bytes_are_frozen() raises:
    _assert_frozen(String("expr_literals"), _expr_literals())


def test_expr_operators_bytes_are_frozen() raises:
    _assert_frozen(String("expr_operators"), _expr_operators())


def test_expr_cast_when_bytes_are_frozen() raises:
    _assert_frozen(String("expr_cast_when"), _expr_cast_when())


def main() raises:
    var suite = TestSuite()
    suite.test[test_expr_literals_bytes_are_frozen]()
    suite.test[test_expr_operators_bytes_are_frozen]()
    suite.test[test_expr_cast_when_bytes_are_frozen]()
    suite^.run()
