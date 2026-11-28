# =============================================================================
# test_plan_wire_strptime_goldens.mojo - the strptime goldens.
# =============================================================================
#
# Freezes the bytes of one projection over the wide scan holding `strptime`
# and `try_strptime` of a text column and a string literal format. These are
# new StringFnN wire values (15 and 16); the goldens that existed before them
# are untouched, so a reader of the earlier bytes is unaffected.
#
# Each case checks four things:
#   LEG A  the encoder's bytes equal `<stem>.hex`, byte for byte.
#   LEG B  the bytes of `<stem>.hex` decode to the plan, its hash and its
#          output schema.
#   LEG C  the bytes are longer than an envelope alone.
#   LEG D  plan_wire decodes `<stem>.canonical.hex`, protoc's canonical
#          serialization of the plan, back to the engine-built plan.
#
# Every case prints a `GOLDEN-BEGIN`/`GOLDEN-END` block holding the bytes it
# encoded. Copy the block into `tests/fixtures/golden/<stem>.hex`, regenerate
# `<stem>.txtpb` with protoc --decode and `<stem>.canonical.hex` with the
# `golden_<stem>_canonical` target of this package.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.expr import Expr, STRFNN_STRPTIME, STRFNN_TRY_STRPTIME
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



def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _str(v: String) -> Expr:
    return Expr.literal(ScalarValue.from_string(v))


def _project(var xs: ExprArray) raises -> LogicalPlan:
    return LogicalPlan.project(xs^, _scan())


def _strptime_plan() raises -> LogicalPlan:
    var xs = ExprArray()
    var a = List[Expr]()
    a.append(_col("s"))
    a.append(_str("%m/%d/%Y"))
    xs.append(Expr.alias(Expr.string_fn_n(STRFNN_STRPTIME, a^), "parsed"))
    var b = List[Expr]()
    b.append(_col("s"))
    b.append(_str("%m/%d/%Y"))
    xs.append(Expr.alias(Expr.string_fn_n(STRFNN_TRY_STRPTIME, b^), "try_parsed"))
    return _project(xs^)


def test_strptime_bytes_are_frozen() raises:
    _assert_frozen(String("strptime_fns"), _strptime_plan())


def main() raises:
    var suite = TestSuite()
    suite.test[test_strptime_bytes_are_frozen]()
    suite^.run()
