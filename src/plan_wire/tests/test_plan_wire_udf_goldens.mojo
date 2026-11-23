# =============================================================================
# test_plan_wire_udf_goldens.mojo - the user-function goldens.
# =============================================================================
#
# Freezes the bytes of two plans that call user functions, built with the
# engine's own plan factories over a Parquet scan of int32, int64 and float64
# columns:
#
#   udf_project  a projection holding a plain column, a scalar call, the same
#                scalar function called a second time on the same column (one
#                UdfRef), a map_batches_column call and a row call whose read
#                set is two columns. The three functions use the bundle form,
#                the package form and the bundle form, and the three
#                stabilities.
#   udf_frame    a projection over a map_batches_frame node, ungrouped, with a
#                read set of two columns, over the scan.
#
# These goldens are what the Python plan encoder's test
# (python/tests/test_plan_udf_goldens.py) compares its bytes to: the same
# plans, with the same functions built as komira._ops nodes and encoded from
# Python, must equal `<stem>.canonical.hex`. The Python plans are the source of
# truth for what each golden holds.
#
# The engine reads a UdfRef's descriptor and code digest as opaque bytes, so
# both are fixed here: the digest is the bytes 0 to 31, and each descriptor is
# the komira/python PythonDescriptor v1 of its function, as hex.
#
# The hex helpers and the legs are copied from test_plan_wire_rel_goldens.mojo:
# a welded test cannot import another test file.
#
# Each case checks four things:
#   LEG A  the encoder's bytes, UdfRef list included, equal `<stem>.hex`.
#   LEG B  the bytes of `<stem>.hex` decode to the plan, its hash, its output
#          schema and the same UdfRef list.
#   LEG C  the bytes are longer than an envelope alone.
#   LEG D  plan_wire decodes `<stem>.canonical.hex`, protoc's canonical
#          serialization of the plan, back to the engine-built plan and the
#          same UdfRef list. The decode runs the decoder's UDF checks, so this
#          leg is the engine accepting the bytes the Python encoder writes.
#
# Regolding: every case prints a `GOLDEN-BEGIN`/`GOLDEN-END` block holding the
# bytes it encoded, on pass as well as on fail. Copy the block into
# `tests/fixtures/golden/<stem>.hex` and re-derive `<stem>.txtpb` and
# `<stem>.canonical.hex` with protoc (`--decode` then `--encode`).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.expr import Expr, BIN_MUL
from plan_expr.scalar_value import ScalarValue
from plan_expr.udf_data import (
    UDF_NULL_MANUAL,
    UDF_NULL_PROPAGATE,
    UDF_STABILITY_IMMUTABLE,
    UDF_STABILITY_STABLE,
    UDF_STABILITY_VOLATILE,
)
from plan_expr.udf_type import UdfType
from plan_ir.logical_plan import ExprArray, LogicalPlan
from plan_ir.udf_ref import (
    CodeDigest,
    UdfCode,
    UdfRef,
    UDF_REF_KIND_SCALAR,
    UDF_REF_KIND_MAP_BATCHES_COLUMN,
    UDF_REF_KIND_MAP_BATCHES_FRAME,
    UDF_REF_KIND_ROW,
    CODE_FORM_PACKAGE,
    CODE_FORM_BUNDLE,
)
from scan_source.parquet_source import ParquetSource
from scan_source.source_variant import SourceVariant
from plan_wire import plan_envelope_from_bytes, plan_to_bytes_with_udfs

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




def _assert_same_udfs(
    name: String, leg: String, got: List[UdfRef], want: List[UdfRef]
) raises:
    """The two lists hold as many UdfRefs as each other. Their content is held
    by the byte comparison of the envelope that follows each call."""
    assert_equal(
        len(got),
        len(want),
        name + ": " + leg + " - the UdfRef lists differ in length.",
    )


def _assert_frozen(
    name: String, var plan: LogicalPlan, udfs: List[UdfRef]
) raises:
    """LEG A (freeze), LEG B (meaning), LEG C (non-trivial), LEG D (decoding
    protoc's canonical bytes) for one plan and its UdfRef list."""
    var text = String(plan)
    var h = plan.structural_hash()
    var sch = _schema_text(plan.output_schema)

    var bytes = plan_to_bytes_with_udfs(plan, udfs)

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
    var back = plan_envelope_from_bytes(want^)
    var back_udfs = List[UdfRef]()
    for i in range(len(back.udfs)):
        back_udfs.append(back.udfs[i].copy())
    var back_plan = back.take_plan()
    assert_equal(
        String(back_plan),
        text,
        name
        + ": LEG B - the checked-in bytes decode into a plan that renders"
        + " differently from the plan of the same name.",
    )
    assert_equal(
        String(back_plan.structural_hash()),
        String(h),
        name
        + ": LEG B - the decoded plan's text matches but its structural_hash"
        + " does not.",
    )
    assert_equal(
        _schema_text(back_plan.output_schema),
        sch,
        name
        + ": LEG B - the decoded plan promises different output columns.",
    )
    _assert_same_udfs(name, "LEG B", back_udfs, udfs)
    assert_true(
        plan_to_bytes_with_udfs(plan, back_udfs) == bytes,
        name
        + ": LEG B - the decoded UdfRef list, beside the engine-built plan,"
        + " encodes to other bytes than the frozen ones.",
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
    var foreign = plan_envelope_from_bytes(canonical^)
    var foreign_udfs = List[UdfRef]()
    for i in range(len(foreign.udfs)):
        foreign_udfs.append(foreign.udfs[i].copy())
    var foreign_plan = foreign.take_plan()
    assert_equal(
        String(foreign_plan),
        text,
        name
        + ": LEG D - the decoder cannot reconstruct this plan from the bytes"
        + " the reference protobuf implementation produces for it.",
    )
    assert_equal(
        String(foreign_plan.structural_hash()),
        String(h),
        name
        + ": LEG D - the plan decoded from the reference implementation's"
        + " bytes renders identically but hashes differently.",
    )
    assert_equal(
        _schema_text(foreign_plan.output_schema),
        sch,
        name
        + ": LEG D - the plan decoded from the reference implementation's"
        + " bytes promises different output columns.",
    )
    _assert_same_udfs(name, "LEG D", foreign_udfs, udfs)
    assert_true(
        plan_to_bytes_with_udfs(plan, foreign_udfs) == bytes,
        name
        + ": LEG D - the UdfRef list decoded from the reference"
        + " implementation's bytes, beside the engine-built plan, encodes to"
        + " other bytes than the frozen ones.",
    )
    _ = plan^


# The scan: one column of each type a UDF here takes.


def _events_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT32, True))
    sb.add_field(Field("c", ArrowType.FLOAT64, True))
    return sb.build()


def _scan() raises -> LogicalPlan:
    """A scan of a Parquet file as the SQL catalog binds a registered one: no
    name, mtime 0, no projection, filter or row count."""
    var schema = _events_schema()
    return LogicalPlan.scan_from_source(
        SourceVariant(
            ParquetSource(
                String("/data/udf_events.parquet"), schema.copy(), None
            )
        ),
        schema^,
    )


# The functions. A column's UdfType is nullable and carries the name of the
# column it describes; a return type is named `out`. Each type takes the
# dictionary index type a `Field` of the same type has, as the Python encoder
# writes it.


def _leaf(name: String, t: ArrowType) -> UdfType:
    var out = UdfType(name, t, Field(name, t, True).dtype, True)
    out.dict_index_type = Field(name, t, True).dict_index_type()
    return out^


def _struct(var kids: List[UdfType]) -> UdfType:
    var out = UdfType(
        "out",
        ArrowType.STRUCT,
        Field("out", ArrowType.STRUCT, True).dtype,
        True,
        kids^,
    )
    out.dict_index_type = Field("out", ArrowType.STRUCT, True).dict_index_type()
    return out^


def _hex_bytes(text: String) raises -> List[UInt8]:
    return _from_hex(text)


def _bundle_code(
    form: UInt8, entry: String, descriptor_hex: String
) raises -> UdfCode:
    """The komira/python code of a function: the bundle form carries the one
    digest 0, 1, ... 31, and the package form none."""
    var digests = List[CodeDigest]()
    if form == CODE_FORM_BUNDLE:
        var sha = List[UInt8]()
        for i in range(32):
            sha.append(UInt8(i))
        digests.append(CodeDigest(String("bundle"), sha^))
    return UdfCode(
        String("komira/python"),
        form,
        entry,
        digests^,
        1,
        _hex_bytes(descriptor_hex),
    )


def _columns(a: String, ta: ArrowType, b: String, tb: ArrowType) -> List[UdfType]:
    var out = List[UdfType]()
    out.append(_leaf(a, ta))
    out.append(_leaf(b, tb))
    return out^


def _inc() raises -> UdfRef:
    """SCALAR int32 -> int64, bundle form, immutable, null-propagating."""
    var args = List[UdfType]()
    args.append(_leaf("b", ArrowType.INT32))
    return UdfRef(
        UDF_REF_KIND_SCALAR,
        _bundle_code(CODE_FORM_BUNDLE, "m:inc", "0a056d3a696e6310013801"),
        args^,
        Optional(_leaf("out", ArrowType.INT64)),
        UDF_STABILITY_IMMUTABLE,
        UDF_NULL_PROPAGATE,
    )


def _norm() raises -> UdfRef:
    """MAP_BATCHES_COLUMN float64 -> float64, package form, stable,
    null-propagating, Arrow batches."""
    var args = List[UdfType]()
    args.append(_leaf("c", ArrowType.FLOAT64))
    return UdfRef(
        UDF_REF_KIND_MAP_BATCHES_COLUMN,
        _bundle_code(CODE_FORM_PACKAGE, "m:norm", "0a066d3a6e6f726d10043802"),
        args^,
        Optional(_leaf("out", ArrowType.FLOAT64)),
        UDF_STABILITY_STABLE,
        UDF_NULL_PROPAGATE,
    )


def _tot() raises -> UdfRef:
    """ROW over the read set a, c -> float64, bundle form, volatile, manual
    nulls."""
    var read_set = List[String]()
    read_set.append("a")
    read_set.append("c")
    return UdfRef(
        UDF_REF_KIND_ROW,
        _bundle_code(
            CODE_FORM_BUNDLE,
            "m:tot",
            "0a056d3a746f741002321a0a0b0a016110051805200140040a0b0a016310"
            "0c180c200140043801",
        ),
        _columns("a", ArrowType.INT64, "c", ArrowType.FLOAT64),
        Optional(_leaf("out", ArrowType.FLOAT64)),
        UDF_STABILITY_VOLATILE,
        UDF_NULL_MANUAL,
        Optional(read_set^),
    )


def _frame() raises -> UdfRef:
    """MAP_BATCHES_FRAME over the read set a, c -> the columns x int64 and y
    float64, bundle form, stable, null-propagating, Arrow batches."""
    var read_set = List[String]()
    read_set.append("a")
    read_set.append("c")
    return UdfRef(
        UDF_REF_KIND_MAP_BATCHES_FRAME,
        _bundle_code(
            CODE_FORM_BUNDLE,
            "m:frame",
            "0a076d3a6672616d651008321a0a0b0a016110051805200140040a0b0a01"
            "63100c180c200140043802",
        ),
        _columns("a", ArrowType.INT64, "c", ArrowType.FLOAT64),
        Optional(
            _struct(_columns("x", ArrowType.INT64, "y", ArrowType.FLOAT64))
        ),
        UDF_STABILITY_STABLE,
        UDF_NULL_PROPAGATE,
        Optional(read_set^),
    )


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _named(name: String, var e: Expr) -> Expr:
    return Expr.alias(e^, name)


def _call(index: Int, ret: UdfType, name: String) -> Expr:
    """A call of entry `index` on the column `name`."""
    var args = List[Expr]()
    args.append(_col(name))
    return Expr.udf_apply(index, ret.copy(), args^)


# =============================================================================
# udf_project
# =============================================================================


def _udf_project_udfs() raises -> List[UdfRef]:
    var out = List[UdfRef]()
    out.append(_inc())
    out.append(_norm())
    out.append(_tot())
    return out^


def _udf_project() raises -> LogicalPlan:
    var udfs = _udf_project_udfs()
    var row_args = List[Expr]()
    row_args.append(_col("a"))
    row_args.append(_col("c"))
    var xs = ExprArray()
    xs.append(_col("a"))
    xs.append(_named("inc1", _call(0, udfs[0].return_type.value(), "b")))
    xs.append(_named("inc2", _call(0, udfs[0].return_type.value(), "b")))
    xs.append(_named("norm", _call(1, udfs[1].return_type.value(), "c")))
    xs.append(
        _named(
            "tot",
            Expr.udf_apply(2, udfs[2].return_type.value().copy(), row_args^),
        )
    )
    return LogicalPlan.project(xs^, _scan())


# =============================================================================
# udf_frame
# =============================================================================


def _udf_frame_udfs() raises -> List[UdfRef]:
    var out = List[UdfRef]()
    out.append(_frame())
    return out^


def _frame_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.INT64, True))
    sb.add_field(Field("y", ArrowType.FLOAT64, True))
    return sb.build()


def _udf_frame() raises -> LogicalPlan:
    var framed = LogicalPlan.map_batches(
        _scan(), 0, List[Expr](), _frame_schema()
    )
    var xs = ExprArray()
    xs.append(_col("x"))
    xs.append(
        _named(
            "y2",
            Expr.binary(
                BIN_MUL,
                _col("y"),
                Expr.literal(ScalarValue.from_float(2.0)),
            ),
        )
    )
    return LogicalPlan.project(xs^, framed^)


def test_udf_project_bytes_are_frozen() raises:
    _assert_frozen(String("udf_project"), _udf_project(), _udf_project_udfs())


def test_udf_frame_bytes_are_frozen() raises:
    _assert_frozen(String("udf_frame"), _udf_frame(), _udf_frame_udfs())


def main() raises:
    var suite = TestSuite()
    suite.test[test_udf_project_bytes_are_frozen]()
    suite.test[test_udf_frame_bytes_are_frozen]()
    suite^.run()
