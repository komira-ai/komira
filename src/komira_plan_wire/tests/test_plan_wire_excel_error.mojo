# =============================================================================
# test_plan_wire_excel_error.mojo: the ExcelErrorCode wire space, frozen.
# =============================================================================
#
# A `SCALAR_KIND_ERROR` literal carries an Excel error code
# (`WireScalar.error_code`, the `ExcelErrorCode` enum). The code space is
# written down in THREE places:
#
#   komira_plan_expr/excel_error_code.mojo   the engine's `XL_ERR_*` constants
#   plan_wire_vocabulary.mojo                engine code <-> wire number, and
#                                            the wire NAME of each number
#   komira_plan_proto/plan_vocabulary.proto  `enum ExcelErrorCode`, which every
#                                            other language reads
#
# WHAT THIS FILE HOLDS:
#
#   test_the_three_copies_agree
#       Every engine constant, by name, maps to wire code + 1, and that wire
#       number has the same name in the Mojo vocabulary and in the generated
#       proto enum. A renumbered or renamed member in any one copy is red.
#
#   test_excel_error_literal_bytes_are_frozen
#       A plan whose expressions carry all ten error codes as literals,
#       frozen as `tests/fixtures/golden/excel_error_literal.hex`, with the
#       legs of `test_plan_wire_golden_bytes.mojo`: the encoder's bytes equal
#       the fixture (A), the fixture decodes to this plan (B), it is not an
#       empty envelope (C), and the Mojo decoder reads protoc's own encoding
#       of it, `.canonical.hex` (D). `plan_wire_golden_fixtures` in BUCK has
#       protoc decode the `.hex` to the `.txtpb`, which prints each code by
#       its proto NAME, so the `.txtpb` is the proto copy's half of the
#       agreement as read by an implementation that never saw this package.
#
# The two codes OUTSIDE the space (wire 0 and wire 12 inside a literal) are
# hostile fixtures, refused by name in `test_plan_wire_hostile_values.mojo`.
#
# HOW TO REGOLD: as in `test_plan_wire_golden_bytes.mojo`. The test prints a
# `GOLDEN-BEGIN`/`GOLDEN-END` block on every run; copy it to the `.hex`, write
# protoc's decode as the `.txtpb`, and build
# `//src/komira_plan_wire:golden_excel_error_literal_canonical` with `--out` to
# the `.canonical.hex`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.excel_error_code import (
    XL_ERR_NONE,
    XL_ERR_DIV0,
    XL_ERR_NA,
    XL_ERR_VALUE,
    XL_ERR_REF,
    XL_ERR_NAME,
    XL_ERR_NUM,
    XL_ERR_NULL,
    XL_ERR_SPILL,
    XL_ERR_CALC,
    XL_ERR_CIRCULAR,
)
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import LogicalPlan, ExprArray
from komira_plan_proto.plan_vocabulary import ExcelErrorCode
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SNAPSHOT_PINNED,
)
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.source_variant import SourceVariant, SOURCE_VARIANT_ORC

from komira_plan_wire import plan_to_bytes, plan_from_bytes
from komira_plan_wire.plan_wire_vocabulary import (
    EXCEL_ERROR_CODE_WIRE_MEMBERS,
    EXCEL_ERROR_CODE_WIRE_MAX,
    excel_error_code_is_declared,
    excel_error_code_to_wire,
    excel_error_code_from_wire,
    excel_error_code_wire_name,
)


# =============================================================================
# THE THREE COPIES
# =============================================================================


@fieldwise_init
struct _Member(Copyable, Movable, ImplicitlyCopyable):
    var code: UInt8
    var name: String


def _members() -> List[_Member]:
    """The engine's constants, each beside the NAME the wire gives it. The
    names are literals here, so the pairing is this file's claim and each copy
    is held to it independently."""
    var m = List[_Member]()
    m.append(_Member(XL_ERR_NONE, String("XL_ERR_NONE")))
    m.append(_Member(XL_ERR_DIV0, String("XL_ERR_DIV0")))
    m.append(_Member(XL_ERR_NA, String("XL_ERR_NA")))
    m.append(_Member(XL_ERR_VALUE, String("XL_ERR_VALUE")))
    m.append(_Member(XL_ERR_REF, String("XL_ERR_REF")))
    m.append(_Member(XL_ERR_NAME, String("XL_ERR_NAME")))
    m.append(_Member(XL_ERR_NUM, String("XL_ERR_NUM")))
    m.append(_Member(XL_ERR_NULL, String("XL_ERR_NULL")))
    m.append(_Member(XL_ERR_SPILL, String("XL_ERR_SPILL")))
    m.append(_Member(XL_ERR_CALC, String("XL_ERR_CALC")))
    m.append(_Member(XL_ERR_CIRCULAR, String("XL_ERR_CIRCULAR")))
    return m^


def test_the_three_copies_agree() raises:
    """Engine constant -> wire number -> name, in the Mojo vocabulary and in
    the generated proto enum, for all eleven members; and back."""
    var m = _members()
    assert_equal(
        len(m), EXCEL_ERROR_CODE_WIRE_MEMBERS,
        "the wire vocabulary publishes a different number of ExcelErrorCode"
        " members than the engine declares",
    )
    for i in range(len(m)):
        var what = m[i].name + " (engine " + String(Int(m[i].code)) + ")"
        # Dense from 0, so the table above is the whole engine space.
        assert_equal(Int(m[i].code), i, what + ": not engine code " + String(i))
        var wire = excel_error_code_to_wire(m[i].code)
        assert_equal(Int(wire), i + 1, what + ": wire is not engine + 1")
        assert_equal(
            excel_error_code_wire_name(wire), m[i].name,
            what + ": plan_wire_vocabulary names wire " + String(Int(wire))
            + " differently",
        )
        assert_equal(
            ExcelErrorCode(Int(wire)).json_name(), m[i].name,
            what + ": plan_vocabulary.proto names wire " + String(Int(wire))
            + " differently",
        )
        assert_equal(
            Int(ExcelErrorCode.from_json_name(m[i].name).value), Int(wire),
            what + ": plan_vocabulary.proto gives this name another number",
        )
        assert_equal(
            Int(excel_error_code_from_wire(wire)), Int(m[i].code),
            what + ": the wire number does not decode back to the engine code",
        )
    # The edges: wire 0 is the proto3 zero and names no code; one past the
    # last code is not declared by either side.
    assert_equal(ExcelErrorCode(0).json_name(), "XL_ERR_WIRE_UNSPECIFIED")
    assert_equal(Int(EXCEL_ERROR_CODE_WIRE_MAX), Int(XL_ERR_CIRCULAR) + 1)
    assert_false(excel_error_code_is_declared(XL_ERR_CIRCULAR + 1))


# =============================================================================
# THE GOLDEN
# =============================================================================

comptime _FIXTURE_DIR: String = "src/komira_plan_wire/tests/fixtures/golden/"
comptime _GOLDEN: String = "excel_error_literal"
comptime _HEX_BYTES_PER_LINE: Int = 32


def _hex_nibble(v: UInt8) -> String:
    comptime DIGITS = String("0123456789abcdef")
    return String(DIGITS[byte=Int(v)])


def _to_hex_lines(bytes: List[UInt8]) -> String:
    """The golden `.hex` rendering: lowercase, 32 bytes per line."""
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
    raise Error("excel_error golden: non-hex byte " + String(Int(c)))


def _from_hex(text: String) raises -> List[UInt8]:
    var nibbles = List[UInt8]()
    var b = text.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if (
            c == UInt8(ord(" ")) or c == UInt8(ord("\n"))
            or c == UInt8(ord("\r")) or c == UInt8(ord("\t"))
        ):
            continue
        nibbles.append(_hex_value(c))
    if len(nibbles) % 2 != 0:
        raise Error("excel_error golden: odd number of hex digits")
    var out = List[UInt8]()
    for i in range(0, len(nibbles), 2):
        out.append((nibbles[i] << 4) | nibbles[i + 1])
    return out^


def _read_fixture(name: String) raises -> List[UInt8]:
    var path = _FIXTURE_DIR + name + ".hex"
    var text = String("")
    var found = False
    try:
        with open(path, "r") as f:
            text = f.read()
        found = True
    except:
        pass
    if not found:
        raise Error(
            "excel_error golden: `" + path + "` is MISSING. The GOLDEN block"
            " this test printed is its content."
        )
    return _from_hex(text)


def _schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.STRING, True))
    return sb.build()


def _scan() raises -> LogicalPlan:
    var p = ScanParams()
    p.put_str(String("path"), String("/data/sheet.orc"))
    var b = ScanBinding(
        kind_id=scan_kind_id(String("komira.orc")),
        kind_name=String("komira.orc"),
        name=String("sheet"),
        params=p^,
        schema=_schema(),
        fingerprint=UInt64(0xDEADBEEF),
        structural_id=UInt64(0xFEEDFACE),
        gate=PushdownGate.conjunctive_comparison(),
        snapshot_policy=SNAPSHOT_PINNED,
        snapshot_token=UInt64(1234567890),
    )
    return LogicalPlan.scan_from_source(
        SourceVariant(tag=SOURCE_VARIANT_ORC, binding=b^), _schema()
    )


def _corpus_excel_error_literal() raises -> LogicalPlan:
    """A project of ten comparisons `s > <error literal>`, one per error code
    in code order and each named for its code, so the `.txtpb` lists every
    `ExcelErrorCode` from XL_ERR_DIV0 (wire 2) to XL_ERR_CIRCULAR (wire 11)
    beside a column name saying which it should be. A codec that wrote one
    code for all of them, or shifted them by one, is a diff in that list.
    XL_ERR_NONE (wire 1) is on every non-error literal in the other goldens.

    A comparison, not one IN list: the value gate refuses an IN list of error
    values against a string column (`PLAN_WIRE_INCOMPARABLE_LITERAL`), while a
    comparison with an error literal is admitted (an error has no column
    domain to disagree with)."""
    var names: List[String] = [
        String("div0"), String("na"), String("value"), String("ref"),
        String("name"), String("num"), String("null"), String("spill"),
        String("calc"), String("circular"),
    ]
    var m = _members()
    var xs = ExprArray()
    for i in range(1, len(m)):
        xs.append(
            Expr.alias(
                Expr.binary(
                    BIN_GT,
                    Expr.col_ref("s"),
                    Expr.literal(ScalarValue.from_error(m[i].code)),
                ),
                names[i - 1],
            )
        )
    return LogicalPlan.project(xs^, _scan())


def test_excel_error_literal_bytes_are_frozen() raises:
    var plan = _corpus_excel_error_literal()
    var text = String(plan)
    var bytes = plan_to_bytes(plan)
    print("GOLDEN-BEGIN " + _GOLDEN)
    print(_to_hex_lines(bytes), end="")
    print("GOLDEN-END " + _GOLDEN)

    # LEG C: more than an envelope.
    assert_true(len(bytes) > 16, "LEG C: the encoder wrote an empty plan")

    # LEG A: the encoder's bytes are the frozen bytes.
    var want = _read_fixture(_GOLDEN)
    assert_equal(
        _to_hex_lines(bytes), _to_hex_lines(want),
        "LEG A: the encoding of the error-literal plan moved. If deliberate,"
        " regold from the GOLDEN block above; if not, the diff is the bug.",
    )

    # LEG B: the frozen bytes still mean this plan, every code included (the
    # render prints each literal's code).
    var back = plan_from_bytes(want^)
    assert_equal(String(back), text, "LEG B: the fixture decodes to another plan")
    assert_equal(
        String(back.structural_hash()), String(plan.structural_hash()),
        "LEG B: same render, different structural_hash",
    )

    # LEG D: the Mojo decoder reads protoc's own encoding of the fixture.
    var canonical = _read_fixture(_GOLDEN + ".canonical")
    assert_true(len(canonical) > 16, "LEG D: the canonical fixture is a stub")
    var foreign = plan_from_bytes(canonical^)
    assert_equal(
        String(foreign), text,
        "LEG D: the Mojo decoder cannot rebuild this plan from protoc's bytes",
    )
    _ = plan^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
