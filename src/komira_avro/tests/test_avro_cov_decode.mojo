# =============================================================================
# test_avro_cov_decode.mojo -- the decode interpreter's fixed and decimal
# arms on a plain read, and its defensive arms on hand-built action tables
# (the resolver never builds those tables; the arms exist so a table that is
# wrong raises instead of decoding garbage).
# =============================================================================
#
# What each case proves, and the mutant planted in the product code to see
# it fail (each alone, then restored; the red message is quoted):
#   D1  a plain read of fixed(3), decimal over fixed(4), a nullable decimal
#       over bytes (with a null) and a decimal over bytes holding an empty
#       value (0, as the Python implementations read it) returns the bytes
#       and the two's-complement values written. Mutants: the fixed arm reads
#       `fsz - 1` bytes: red, 2 vs 3; read_fixed no longer advances: red,
#       "TRUNCATED: bytes payload overrun".
#   D2  hand-built tables: an action of an unknown kind, a plan of an unknown
#       kind, a promotion of an unknown tag, a synthesized default with no
#       value, a union branch of a nested kind, are each refused by name; a
#       read action of wire kind null pushes a null. Mutants: the null arm
#       of `_decode_read_plan` disabled: red, "UNSUPPORTED_FIELD_KIND: Avro
#       kind 0"; the unknown-plan-kind raise -> `pass`: red, "(accepted)".
#   D3  accumulators: a capacity above the ceiling is refused (and the
#       ceiling check refuses a negative target); an accumulator whose tag is
#       unknown refuses to build; the null-flag packer returns no bitmap when
#       no row is null; the default-kind diagnostic names an unknown kind.
#       Mutant: `target < 0` dropped from the ceiling check: red,
#       "(accepted)".
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import SchemaBuilder, Field

from komira_avro import (
    read_avro_bytes,
    AvroDefault,
    ResolutionTable,
    ActionTableInterpreter,
    ColumnAccVariant,
    FieldAction,
    ReadFieldData,
    SynthesizeDefaultData,
    SelectBranchData,
    NULL_NONE,
    PROMOTE_NONE,
    AVRO_KIND_NULL,
    AVRO_KIND_INT,
    AVRO_KIND_RECORD,
    OCF_SYNC_LEN,
)
from komira_avro.action_table import (
    _check_acc_capacity,
    _bitmap_from_nulls,
    _default_kind_name,
)


def _enc_long(n: Int64, mut out: List[UInt8]):
    var zz = UInt64((n << 1) ^ (n >> 63))
    while True:
        var b = UInt8(zz & 0x7F)
        zz >>= 7
        if zz != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _enc_str(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _file(schema: String, count: Int, payload: List[UInt8]) -> List[UInt8]:
    var out: List[UInt8] = [0x4F, 0x62, 0x6A, 0x01]
    _enc_long(2, out)
    _enc_str("avro.schema", out)
    _enc_str(schema, out)
    _enc_str("avro.codec", out)
    _enc_str("null", out)
    _enc_long(0, out)
    for i in range(OCF_SYNC_LEN):
        out.append(UInt8(0x70 + i))
    _enc_long(Int64(count), out)
    _enc_long(Int64(len(payload)), out)
    out.extend(Span(payload))
    for i in range(OCF_SYNC_LEN):
        out.append(UInt8(0x70 + i))
    return out^


def test_fixed_and_decimal_plain_read() raises:
    """D1."""
    var schema = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"f","type":{"type":"fixed","name":"F3","size":3}},'
        '{"name":"d","type":{"type":"fixed","name":"D4","size":4,'
        '"logicalType":"decimal","precision":9,"scale":2}},'
        '{"name":"nd","type":["null",{"type":"bytes","logicalType":"decimal",'
        '"precision":9,"scale":2}]},'
        '{"name":"e","type":{"type":"bytes","logicalType":"decimal",'
        '"precision":9,"scale":2}}]}'
    )
    var p: List[UInt8] = [
        # row 0
        0x61, 0x62, 0x63,  # f
        0x00, 0x00, 0x01, 0x00,  # d = 256
        0x00,  # nd: null branch
        0x00,  # e: empty bytes
        # row 1
        0x78, 0x79, 0x7A,  # f
        0xFF, 0xFF, 0xFF, 0xFE,  # d = -2
        0x02, 0x02, 0x80,  # nd: value branch, 1 byte, -128
        0x02, 0x01,  # e: 1 byte, 1
    ]
    var rb = read_avro_bytes(Span(_file(schema, 2, p)))
    assert_equal(rb.num_rows(), 2)
    ref fcol = rb.column_at(0)
    assert_true(fcol.arrow_type == ArrowType.BINARY, "fixed -> BINARY")
    var f = fcol.as_binary()
    assert_equal(len(f.get(0)), 3)
    assert_equal(Int(f.get(0)[2]), 0x63)
    assert_equal(Int(f.get(1)[0]), 0x78)
    var d = rb.column_at(1).as_decimal128()
    assert_equal(Int(d.get_low(0)), 256)
    assert_equal(Int(d.get_high(0)), 0)
    assert_equal(Int(d.get_low(1)), -2)
    assert_equal(Int(d.get_high(1)), -1)
    var nd = rb.column_at(2).as_decimal128()
    assert_true(nd.is_null(0), "nd[0] null")
    assert_true(not nd.is_null(1), "nd[1] valid")
    assert_equal(Int(nd.get_low(1)), -128)
    assert_equal(Int(nd.get_high(1)), -1)
    var e = rb.column_at(3).as_decimal128()
    assert_equal(Int(e.get_low(0)), 0)
    assert_equal(Int(e.get_high(0)), 0)
    assert_equal(Int(e.get_low(1)), 1)


def _rfd(kind: Int, at: ArrowType, promote: Int8) -> ReadFieldData:
    return ReadFieldData(
        avro_kind=kind,
        arrow_type=at,
        nullability=NULL_NONE,
        fixed_size=0,
        precision=0,
        scale=0,
        logical_type=String(""),
        promote_to=promote,
    )


def _table(var action: FieldAction, at: ArrowType) -> ResolutionTable:
    var sb = SchemaBuilder()
    sb.add_field(Field("x", at, True))
    var actions = List[FieldAction]()
    actions.append(action^)
    var specs = List[ReadFieldData]()
    specs.append(_rfd(AVRO_KIND_INT, at, PROMOTE_NONE))
    return ResolutionTable(actions=actions^, out_schema=sb.build(), out_specs=specs^)


def _decode_err(var table: ResolutionTable, payload: List[UInt8]) -> String:
    try:
        var interp = ActionTableInterpreter(table^)
        interp.decode_block(Span(payload), 1)
    except e:
        return String(e)
    return String("(accepted)")


def test_hand_built_tables() raises:
    """D2."""
    var one: List[UInt8] = [0x02]
    var bad_kind = FieldAction.read(
        "x", _rfd(AVRO_KIND_INT, ArrowType.INT32, PROMOTE_NONE), 0
    )
    bad_kind.kind = 99
    assert_equal(
        _decode_err(_table(bad_kind^, ArrowType.INT32), one),
        "AvroDecodeError.INTERNAL: unknown FieldAction kind 99",
    )
    var interp = ActionTableInterpreter(
        _table(
            FieldAction.read(
                "x", _rfd(AVRO_KIND_INT, ArrowType.INT32, PROMOTE_NONE), 0
            ),
            ArrowType.INT32,
        )
    )
    interp._plan[0].plan_kind = 9
    var got = String("(accepted)")
    try:
        interp.decode_block(Span(one), 1)
    except e:
        got = String(e)
    assert_equal(got, "AvroDecodeError.INTERNAL: unknown plan kind 9")
    assert_equal(
        _decode_err(
            _table(
                FieldAction.promote(
                    "x", _rfd(AVRO_KIND_INT, ArrowType.INT64, Int8(99)), 0
                ),
                ArrowType.INT64,
            ),
            one,
        ),
        "AvroResolutionError.INCOMPATIBLE_TYPE_PROMOTION: unknown promotion"
        " tag 99",
    )
    assert_equal(
        _decode_err(
            _table(
                FieldAction.synth_default(
                    "x",
                    SynthesizeDefaultData(
                        default=AvroDefault.none(), arrow_type=ArrowType.INT64
                    ),
                    0,
                ),
                ArrowType.INT64,
            ),
            one,
        ),
        "AvroResolutionError.NO_DEFAULT_FOR_MISSING_FIELD: field 'x' has no"
        " synthesizable default",
    )
    assert_equal(
        _decode_err(
            _table(
                FieldAction.select_branch_action(
                    "x",
                    SelectBranchData(
                        writer_is_union=False,
                        reader_is_union=True,
                        branch_kind=AVRO_KIND_RECORD,
                        nullability=NULL_NONE,
                        fixed_size=0,
                    ),
                    0,
                ),
                ArrowType.INT32,
            ),
            one,
        ),
        "AvroResolutionError.UNION_NO_MATCHING_BRANCH: branch kind 8 not"
        " decodable",
    )
    # A read of wire kind null consumes no byte and pushes a null.
    var nt = ActionTableInterpreter(
        _table(
            FieldAction.read(
                "x", _rfd(AVRO_KIND_NULL, ArrowType.INT32, PROMOTE_NONE), 0
            ),
            ArrowType.INT32,
        )
    )
    var empty = List[UInt8]()
    nt.decode_block(Span(empty), 2)
    var rb = nt.build_batch()
    assert_equal(rb.num_rows(), 2)
    var col = rb.column_as_primitive_int32(0)
    assert_true(col.is_null(0), "null 0")
    assert_true(col.is_null(1), "null 1")


def test_accumulator_guards() raises:
    """D3."""
    var acc = ColumnAccVariant.create(
        _rfd(AVRO_KIND_INT, ArrowType.INT64, PROMOTE_NONE)
    )
    var got = String("(accepted)")
    try:
        acc.reserve((1 << 34) + 1)
    except e:
        got = String(e)
    assert_equal(
        got,
        "AvroDecodeError.ROW_COUNT_OUT_OF_RANGE: a block asked for"
        " 17179869185 accumulator elements; the ceiling is 17179869184 (the"
        " file's declared record count is not credible)",
    )
    got = String("(accepted)")
    try:
        _check_acc_capacity(-1)
    except e:
        got = String(e)
    assert_true(got.find("asked for -1 accumulator elements") > 0, got)
    got = String("(accepted)")
    try:
        _check_acc_capacity(1 << 34)
    except e:
        got = String(e)
    assert_equal(got, "(accepted)")
    var odd = ColumnAccVariant.create(
        _rfd(AVRO_KIND_INT, ArrowType.INT32, PROMOTE_NONE)
    )
    odd.tag = 42
    got = String("(accepted)")
    try:
        _ = odd.build()
    except e:
        got = String(e)
    assert_equal(got, "AvroDecodeError.INTERNAL: unknown accumulator tag")
    var flags: List[Bool] = [False, False, False]
    assert_true(not _bitmap_from_nulls(flags), "no null -> no bitmap")
    flags[1] = True
    var bm = _bitmap_from_nulls(flags)
    assert_true(Bool(bm), "a null -> a bitmap")
    assert_true(bm.value().test(0), "row 0 valid")
    assert_true(not bm.value().test(1), "row 1 null")
    assert_equal(_default_kind_name(99), "a kind#99")


def main() raises:
    test_fixed_and_decimal_plain_read()
    test_hand_built_tables()
    test_accumulator_guards()
    print("test_avro_cov_decode: ALL PASS")
