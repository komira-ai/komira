# =============================================================================
# test_plan_wire_expr_goldens_fns.mojo - the expression goldens, part two.
# =============================================================================
#
# Freezes the bytes of two projections over one wide scan, built with the
# engine's own expression factories:
#
#   expr_strings        every string operator, regexp operator, one-argument
#                       and many-argument string function, and substrings with
#                       a length, without one and of length zero.
#   expr_math_temporal  every math function of one and two operands, every
#                       extract unit (truncations of the date column and of the
#                       zoned timestamp column), and both fields of a struct.
#
# These goldens are what the Python plan encoder's test
# (python/tests/test_plan_expr_goldens.py) compares its bytes to: the same
# expressions, in the same order and under the same aliases, encoded from
# Python, must equal `<stem>.canonical.hex`. The Python lists are the source of
# truth for what each plan holds. The sibling file
# test_plan_wire_expr_goldens.mojo holds the literal, operator and cast
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
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.expr import (
    Expr,
    EXTRACT_DAY,
    EXTRACT_DAYOFWEEK,
    EXTRACT_DAYOFYEAR,
    EXTRACT_HOUR,
    EXTRACT_ISODOW,
    EXTRACT_ISOYEAR,
    EXTRACT_MICROSECOND,
    EXTRACT_MILLISECOND,
    EXTRACT_MINUTE,
    EXTRACT_MONTH,
    EXTRACT_QUARTER,
    EXTRACT_SECOND,
    EXTRACT_TRUNC_DAY,
    EXTRACT_TRUNC_HOUR,
    EXTRACT_TRUNC_MICROSECOND,
    EXTRACT_TRUNC_MILLISECOND,
    EXTRACT_TRUNC_MINUTE,
    EXTRACT_TRUNC_MONTH,
    EXTRACT_TRUNC_QUARTER,
    EXTRACT_TRUNC_SECOND,
    EXTRACT_TRUNC_WEEK,
    EXTRACT_TRUNC_YEAR,
    EXTRACT_WEEK,
    EXTRACT_YEAR,
    EXTRACT_YEARWEEK,
    MATH2_ATAN2,
    MATH2_POW,
    MATH_ACOS,
    MATH_ACOSH,
    MATH_ASIN,
    MATH_ASINH,
    MATH_ATAN,
    MATH_ATANH,
    MATH_CBRT,
    MATH_CEIL,
    MATH_COS,
    MATH_COSH,
    MATH_COT,
    MATH_DEGREES,
    MATH_EXP,
    MATH_FLOOR,
    MATH_GAMMA,
    MATH_LN,
    MATH_LOG10,
    MATH_LOG2,
    MATH_RADIANS,
    MATH_SIN,
    MATH_SINH,
    MATH_SQRT,
    MATH_TAN,
    MATH_TANH,
    REGEXP_COUNT,
    REGEXP_EXTRACT,
    REGEXP_EXTRACT_ALL,
    REGEXP_FULL_MATCH,
    REGEXP_INSTR,
    REGEXP_LIKE,
    REGEXP_MATCH,
    REGEXP_REPLACE,
    REGEXP_SPLIT_TO_ARRAY,
    REGEXP_SUBSTR,
    STR_CONTAINS,
    STR_ENDS_WITH,
    STR_STARTS_WITH,
    STRFN_ASCII,
    STRFN_BIN,
    STRFN_BIT_LENGTH,
    STRFN_HEX,
    STRFN_LENGTH,
    STRFN_LOWER,
    STRFN_LTRIM,
    STRFN_MD5,
    STRFN_REGEXP_ESCAPE,
    STRFN_REVERSE,
    STRFN_RTRIM,
    STRFN_SHA1,
    STRFN_SHA256,
    STRFN_STRLEN,
    STRFN_TRIM,
    STRFN_UNICODE,
    STRFN_UPPER,
    STRFN_URL_DECODE,
    STRFN_URL_ENCODE,
    STRFNN_CONCAT,
    STRFNN_CONCAT_WS,
    STRFNN_DAMERAU_LEVENSHTEIN,
    STRFNN_HAMMING,
    STRFNN_JACCARD,
    STRFNN_TRIM,
    STRFNN_LTRIM,
    STRFNN_RTRIM,
    STRFNN_JARO,
    STRFNN_JARO_WINKLER,
    STRFNN_LEVENSHTEIN,
    STRFNN_LPAD,
    STRFNN_REPEAT,
    STRFNN_REPLACE,
    STRFNN_RPAD,
    STRFNN_STRPOS,
    STRFNN_TRANSLATE,
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


# =============================================================================
# expr_strings
# =============================================================================


def _rx(
    name: String,
    op: UInt8,
    pattern: String,
    replacement: String = "",
    flags: String = "",
    group: Int = 0,
) -> Expr:
    return _named(
        "rx_" + name,
        Expr.regexp(op, _col("s"), pattern, replacement, flags, group),
    )


def _sn(name: String, op: UInt8, var args: List[Expr]) -> Expr:
    return _named("sn_" + name, Expr.string_fn_n(op, args^))


def _s_abc(op: UInt8, name: String) -> Expr:
    var args = List[Expr]()
    args.append(_col("s"))
    args.append(_str("abc"))
    return _sn(name, op, args^)


def _expr_strings() raises -> LogicalPlan:
    var xs = ExprArray()
    xs.append(
        _named("so_contains", Expr.string_op(STR_CONTAINS, _col("s"), "ab"))
    )
    xs.append(
        _named(
            "so_starts_with", Expr.string_op(STR_STARTS_WITH, _col("s"), "ab")
        )
    )
    xs.append(
        _named("so_ends_with", Expr.string_op(STR_ENDS_WITH, _col("s"), "ab"))
    )

    xs.append(_rx("like", REGEXP_LIKE, "^a.*"))
    xs.append(_rx("match", REGEXP_MATCH, "(a)(b)", flags="i"))
    xs.append(
        _rx("replace", REGEXP_REPLACE, "a+", replacement="X", flags="g")
    )
    xs.append(_rx("extract", REGEXP_EXTRACT, "(a)(b)", group=1))
    xs.append(_rx("split_to_array", REGEXP_SPLIT_TO_ARRAY, ","))
    xs.append(_rx("extract_all", REGEXP_EXTRACT_ALL, "(a)(b)", group=2))
    xs.append(_rx("count", REGEXP_COUNT, "a"))
    xs.append(_rx("instr", REGEXP_INSTR, "b"))
    xs.append(_rx("substr", REGEXP_SUBSTR, "a(b)", group=1))
    xs.append(_rx("full_match", REGEXP_FULL_MATCH, "a.*b", flags="i"))

    var fn_names: List[String] = [
        "ascii", "bin", "bit_length", "hex", "length", "lower", "ltrim",
        "md5", "regexp_escape", "reverse", "rtrim", "sha1", "sha256",
        "strlen", "trim", "unicode", "upper", "url_decode", "url_encode",
    ]
    var fn_ops: List[UInt8] = [
        STRFN_ASCII, STRFN_BIN, STRFN_BIT_LENGTH, STRFN_HEX, STRFN_LENGTH,
        STRFN_LOWER, STRFN_LTRIM, STRFN_MD5, STRFN_REGEXP_ESCAPE,
        STRFN_REVERSE, STRFN_RTRIM, STRFN_SHA1, STRFN_SHA256, STRFN_STRLEN,
        STRFN_TRIM, STRFN_UNICODE, STRFN_UPPER, STRFN_URL_DECODE,
        STRFN_URL_ENCODE,
    ]
    for k in range(len(fn_names)):
        xs.append(
            _named("sf_" + fn_names[k], Expr.string_fn(fn_ops[k], _col("s")))
        )

    var concat = List[Expr]()
    concat.append(_col("s"))
    concat.append(_str("-"))
    concat.append(_col("s"))
    xs.append(_sn("concat", STRFNN_CONCAT, concat^))

    var concat_ws = List[Expr]()
    concat_ws.append(_str(","))
    concat_ws.append(_col("s"))
    concat_ws.append(_col("s"))
    xs.append(_sn("concat_ws", STRFNN_CONCAT_WS, concat_ws^))

    xs.append(_s_abc(STRFNN_DAMERAU_LEVENSHTEIN, "damerau_levenshtein"))
    xs.append(_s_abc(STRFNN_HAMMING, "hamming"))
    xs.append(_s_abc(STRFNN_JACCARD, "jaccard"))
    xs.append(_s_abc(STRFNN_JARO, "jaro"))
    xs.append(_s_abc(STRFNN_JARO_WINKLER, "jaro_winkler"))
    xs.append(_s_abc(STRFNN_LEVENSHTEIN, "levenshtein"))

    var lpad = List[Expr]()
    lpad.append(_col("s"))
    lpad.append(_int(5))
    lpad.append(_str("*"))
    xs.append(_sn("lpad", STRFNN_LPAD, lpad^))
    xs.append(_s_abc(STRFNN_LTRIM, "ltrim"))

    var repeat = List[Expr]()
    repeat.append(_col("s"))
    repeat.append(_int(3))
    xs.append(_sn("repeat", STRFNN_REPEAT, repeat^))

    var replace = List[Expr]()
    replace.append(_col("s"))
    replace.append(_str("a"))
    replace.append(_str("b"))
    xs.append(_sn("replace", STRFNN_REPLACE, replace^))

    var rpad = List[Expr]()
    rpad.append(_col("s"))
    rpad.append(_int(5))
    rpad.append(_str("*"))
    xs.append(_sn("rpad", STRFNN_RPAD, rpad^))
    xs.append(_s_abc(STRFNN_RTRIM, "rtrim"))

    var strpos = List[Expr]()
    strpos.append(_col("s"))
    strpos.append(_str("a"))
    xs.append(_sn("strpos", STRFNN_STRPOS, strpos^))

    var translate = List[Expr]()
    translate.append(_col("s"))
    translate.append(_str("ab"))
    translate.append(_str("xy"))
    xs.append(_sn("translate", STRFNN_TRANSLATE, translate^))
    xs.append(_s_abc(STRFNN_TRIM, "trim"))

    xs.append(_named("sub_len", Expr.substring(_col("s"), 2, 4)))
    xs.append(_named("sub_open", Expr.substring(_col("s"), -3)))
    xs.append(_named("sub_zero", Expr.substring(_col("s"), 1, 0)))
    return _project(xs^)


# =============================================================================
# expr_math_temporal
# =============================================================================


def _expr_math_temporal() raises -> LogicalPlan:
    var xs = ExprArray()
    var m_names: List[String] = [
        "acos", "acosh", "asin", "asinh", "atan", "atanh", "cbrt", "ceil",
        "cos", "cosh", "cot", "degrees", "exp", "floor", "gamma", "ln",
        "log10", "log2", "radians", "sin", "sinh", "sqrt", "tan", "tanh",
    ]
    var m_ops: List[UInt8] = [
        MATH_ACOS, MATH_ACOSH, MATH_ASIN, MATH_ASINH, MATH_ATAN, MATH_ATANH,
        MATH_CBRT, MATH_CEIL, MATH_COS, MATH_COSH, MATH_COT, MATH_DEGREES,
        MATH_EXP, MATH_FLOOR, MATH_GAMMA, MATH_LN, MATH_LOG10, MATH_LOG2,
        MATH_RADIANS, MATH_SIN, MATH_SINH, MATH_SQRT, MATH_TAN, MATH_TANH,
    ]
    for k in range(len(m_names)):
        xs.append(
            _named("m_" + m_names[k], Expr.math_fn(m_ops[k], _col("f")))
        )
    xs.append(
        _named("m2_atan2", Expr.math_fn2(MATH2_ATAN2, _col("f"), _col("a")))
    )
    xs.append(
        _named("m2_pow", Expr.math_fn2(MATH2_POW, _col("a"), _int(2)))
    )

    var e_names: List[String] = [
        "day", "dayofweek", "dayofyear", "hour", "isodow", "isoyear",
        "microsecond", "millisecond", "minute", "month", "quarter", "second",
        "trunc_day", "trunc_hour", "trunc_microsecond", "trunc_millisecond",
        "trunc_minute", "trunc_month", "trunc_quarter", "trunc_second",
        "trunc_week", "trunc_year", "week", "year", "yearweek",
    ]
    var e_ops: List[UInt8] = [
        EXTRACT_DAY, EXTRACT_DAYOFWEEK, EXTRACT_DAYOFYEAR, EXTRACT_HOUR,
        EXTRACT_ISODOW, EXTRACT_ISOYEAR, EXTRACT_MICROSECOND,
        EXTRACT_MILLISECOND, EXTRACT_MINUTE, EXTRACT_MONTH, EXTRACT_QUARTER,
        EXTRACT_SECOND, EXTRACT_TRUNC_DAY, EXTRACT_TRUNC_HOUR,
        EXTRACT_TRUNC_MICROSECOND, EXTRACT_TRUNC_MILLISECOND,
        EXTRACT_TRUNC_MINUTE, EXTRACT_TRUNC_MONTH, EXTRACT_TRUNC_QUARTER,
        EXTRACT_TRUNC_SECOND, EXTRACT_TRUNC_WEEK, EXTRACT_TRUNC_YEAR,
        EXTRACT_WEEK, EXTRACT_YEAR, EXTRACT_YEARWEEK,
    ]
    for k in range(len(e_names)):
        var n = e_names[k]
        var on_date = (
            n == "trunc_year"
            or n == "trunc_quarter"
            or n == "trunc_month"
            or n == "trunc_week"
            or n == "trunc_day"
        )
        var child = _col("dt") if on_date else _col("ts")
        xs.append(_named("ex_" + n, Expr.extract(e_ops[k], child^)))

    xs.append(_named("st_k", Expr.struct_field(_col("st"), "k")))
    xs.append(_named("st_v", Expr.struct_field(_col("st"), "v")))
    return _project(xs^)


def test_expr_strings_bytes_are_frozen() raises:
    _assert_frozen(String("expr_strings"), _expr_strings())


def test_expr_math_temporal_bytes_are_frozen() raises:
    _assert_frozen(String("expr_math_temporal"), _expr_math_temporal())


def main() raises:
    var suite = TestSuite()
    suite.test[test_expr_strings_bytes_are_frozen]()
    suite.test[test_expr_math_temporal_bytes_are_frozen]()
    suite^.run()
