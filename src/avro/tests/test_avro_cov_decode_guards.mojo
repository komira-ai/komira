# =============================================================================
# test_avro_cov_decode_guards.mojo -- the decoder's internal guards, called
# directly or through hand-built tables: the resolver never builds a table or
# accumulator that reaches them, and each exists so a wrong one raises by name
# instead of decoding garbage. Also the two predicates a union route and a
# union default are checked with, over every arm.
#
# What each case proves:
#   G1  an accumulator for an Arrow type with no column builder (LIST) is
#       refused, naming the type id.
#   G2  a dense-union accumulator takes a child offset of 2^31-1 and refuses
#       2^31; it refuses a null (a null is a row of the null branch) and a
#       plain build (a union is built from its children).
#   G3  a wire read of kind null pushes a null and consumes nothing; a wire
#       read of an unknown kind, and a skip of one, are refused by name.
#   G4  a union route whose promotion does not fit the reader column, and a
#       union default that fits no branch, are refused by name.
#   G5  `_acc_accepts`: each promotion is taken only by the arm it widens to,
#       an unknown promotion by none; with no promotion each wire kind is
#       taken only by its own arm (bytes and fixed also by a decimal arm) and
#       a nested kind by none.
#   G6  `_default_fits_tag`: each default kind fits exactly the arms it can
#       be pushed into, and an absent default fits none.
#   G7  a general union reaching `_field_type_info` is refused by name; a
#       two-branch nullable union reports the side its null is on.
#   G8  the skip walk refuses a node kind it does not know, by name.
#   G9  an empty payload is not taken for a truncated xz stream.
# =============================================================================

from std.testing import assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import SchemaBuilder, Field

from avro import (
    AvroByteReader,
    AvroDefault,
    AvroSchema,
    ResolutionTable,
    ActionTableInterpreter,
    ColumnAccVariant,
    FieldAction,
    ReadFieldData,
    SynthesizeDefaultData,
    BranchRoute,
    UnionRouteData,
    NULL_NONE,
    NULL_FIRST,
    NULL_SECOND,
    PROMOTE_NONE,
    PROMOTE_TO_LONG,
    PROMOTE_TO_FLOAT,
    PROMOTE_TO_DOUBLE,
    PROMOTE_STRING_TO_BYTES,
    PROMOTE_BYTES_TO_STRING,
    AVRO_KIND_NULL,
    AVRO_KIND_BOOLEAN,
    AVRO_KIND_INT,
    AVRO_KIND_LONG,
    AVRO_KIND_FLOAT,
    AVRO_KIND_DOUBLE,
    AVRO_KIND_BYTES,
    AVRO_KIND_STRING,
    AVRO_KIND_RECORD,
    AVRO_KIND_FIXED,
    AVRO_DEFAULT_NONE,
    AVRO_DEFAULT_NULL,
    AVRO_DEFAULT_BOOL,
    AVRO_DEFAULT_INT,
    AVRO_DEFAULT_DOUBLE,
    AVRO_DEFAULT_STRING,
    AVRO_DEFAULT_BYTES,
)
from avro.action_table import (
    ACC_I32,
    ACC_I64,
    ACC_F32,
    ACC_F64,
    ACC_BOOL,
    ACC_STRING,
    ACC_BINARY,
    ACC_DECIMAL,
    ACC_NULL,
    ACC_UNION,
    _acc_accepts,
    _default_fits_tag,
    _field_type_info,
    _skip_value,
)
from avro.avro_codec import _xz_lacks_stream_footer
from avro.avro_skip import SkipProgram
from avro.union_route import ROUTE_READ


def _rfd(kind: Int, at: ArrowType) -> ReadFieldData:
    return ReadFieldData(
        avro_kind=kind,
        arrow_type=at,
        nullability=NULL_NONE,
        fixed_size=0,
        precision=0,
        scale=0,
        logical_type=String(""),
        promote_to=PROMOTE_NONE,
    )


def _one_column(
    var action: FieldAction,
    at: ArrowType,
    var union_branches: List[List[ReadFieldData]],
) -> ResolutionTable:
    var sb = SchemaBuilder()
    sb.add_field(Field("x", at, True))
    var actions = List[FieldAction]()
    actions.append(action^)
    var specs = List[ReadFieldData]()
    specs.append(_rfd(AVRO_KIND_INT, at))
    return ResolutionTable(
        actions=actions^,
        out_schema=sb.build(),
        out_specs=specs^,
        union_branches=union_branches^,
    )


def _decode_err(var table: ResolutionTable, payload: List[UInt8]) -> String:
    try:
        var interp = ActionTableInterpreter(table^)
        interp.decode_block(Span(payload), 1)
    except e:
        return String(e)
    return String("(accepted)")


def test_accumulator_without_builder_refused() raises:
    """G1."""
    var got = String("(accepted)")
    try:
        _ = ColumnAccVariant.create(_rfd(AVRO_KIND_INT, ArrowType.LIST))
    except e:
        got = String(e)
    assert_equal(
        got,
        "AvroDecodeError.UNSUPPORTED_COLUMN_TYPE: Arrow type 20 has no column"
        " builder",
    )


def test_union_accumulator_guards() raises:
    """G2."""
    var acc = ColumnAccVariant.create(
        _rfd(AVRO_KIND_INT, ArrowType.UNION_DENSE)
    )
    assert_equal(acc.tag, ACC_UNION)
    acc.union_push(0, 2147483647)
    var got = String("(accepted)")
    try:
        acc.union_push(0, 2147483648)
    except e:
        got = String(e)
    assert_equal(
        got,
        "AvroDecodeError.UNION_TOO_LARGE: a union branch holds more than"
        " 2^31-1 values",
    )
    got = String("(accepted)")
    try:
        acc.push_null()
    except e:
        got = String(e)
    assert_equal(
        got,
        "AvroDecodeError.INTERNAL: a null in a dense-union column is a row of"
        " its null branch",
    )
    got = String("(accepted)")
    try:
        _ = acc.build()
    except e:
        got = String(e)
    assert_equal(
        got,
        "AvroDecodeError.INTERNAL: a dense-union column is built from its"
        " children (ColumnAccVariant.build_union)",
    )


def test_wire_read_and_skip_of_unknown_kind() raises:
    """G3."""
    var interp = ActionTableInterpreter(
        _one_column(
            FieldAction.read("x", _rfd(AVRO_KIND_INT, ArrowType.INT32), 0),
            ArrowType.INT32,
            List[List[ReadFieldData]](),
        )
    )
    var payload: List[UInt8] = [0x02]
    var reader = AvroByteReader(Span(payload))
    interp._read_wire(reader, 0, AVRO_KIND_NULL, False, 0)
    var got = String("(accepted)")
    try:
        interp._read_wire(reader, 0, 99, False, 0)
    except e:
        got = String(e)
    assert_equal(
        got,
        "AvroDecodeError.UNSUPPORTED_FIELD_KIND: Avro kind 99 (record / enum /"
        " array / map nested decode is not supported)",
    )
    got = String("(accepted)")
    try:
        _skip_value(reader, 99, 0)
    except e:
        got = String(e)
    assert_equal(
        got,
        "AvroDecodeError.UNSUPPORTED_FIELD_KIND: cannot skip kind 99 (a nested"
        " or union type is skipped by SkipProgram)",
    )
    # The null read consumed no byte: the int written is still next.
    assert_equal(Int(reader.read_int()), 1)
    var rb = interp.build_batch()
    assert_equal(rb.num_rows(), 1)
    assert_true(rb.column_as_primitive_int32(0).is_null(0), "null pushed")


def test_union_route_and_default_refusals() raises:
    """G4."""
    var routes = List[BranchRoute]()
    routes.append(
        BranchRoute(
            status=ROUTE_READ,
            wire_kind=AVRO_KIND_INT,
            fixed_size=0,
            promote_to=PROMOTE_TO_DOUBLE,
            target=-1,
        )
    )
    var one: List[UInt8] = [0x02]
    assert_equal(
        _decode_err(
            _one_column(
                FieldAction.route_union(
                    "x",
                    UnionRouteData(writer_is_union=False, routes=routes^),
                    0,
                ),
                ArrowType.INT32,
                List[List[ReadFieldData]](),
            ),
            one,
        ),
        "AvroResolutionError.INCOMPATIBLE_TYPE_PROMOTION: writer int value of"
        " field 'x' does not fit the reader column",
    )
    var branches = List[List[ReadFieldData]]()
    branches.append([_rfd(AVRO_KIND_INT, ArrowType.INT32)])
    var string_default = AvroDefault.none()
    string_default.kind = AVRO_DEFAULT_STRING
    string_default.str_val = String("s")
    assert_equal(
        _decode_err(
            _one_column(
                FieldAction.synth_default(
                    "x",
                    SynthesizeDefaultData(
                        default=string_default^,
                        arrow_type=ArrowType.UNION_DENSE,
                    ),
                    0,
                ),
                ArrowType.UNION_DENSE,
                branches^,
            ),
            one,
        ),
        "AvroResolutionError.INVALID_DEFAULT: the default of field 'x' fits no"
        " branch of its union",
    )


def test_acc_accepts_every_arm() raises:
    """G5."""
    # Promotions: only the widened-to arm.
    assert_true(_acc_accepts(ACC_I64, AVRO_KIND_INT, PROMOTE_TO_LONG))
    assert_true(not _acc_accepts(ACC_I32, AVRO_KIND_INT, PROMOTE_TO_LONG))
    assert_true(_acc_accepts(ACC_F32, AVRO_KIND_LONG, PROMOTE_TO_FLOAT))
    assert_true(not _acc_accepts(ACC_F64, AVRO_KIND_LONG, PROMOTE_TO_FLOAT))
    assert_true(_acc_accepts(ACC_F64, AVRO_KIND_FLOAT, PROMOTE_TO_DOUBLE))
    assert_true(not _acc_accepts(ACC_F32, AVRO_KIND_FLOAT, PROMOTE_TO_DOUBLE))
    assert_true(
        _acc_accepts(ACC_BINARY, AVRO_KIND_STRING, PROMOTE_STRING_TO_BYTES)
    )
    assert_true(
        not _acc_accepts(ACC_STRING, AVRO_KIND_STRING, PROMOTE_STRING_TO_BYTES)
    )
    assert_true(
        _acc_accepts(ACC_STRING, AVRO_KIND_BYTES, PROMOTE_BYTES_TO_STRING)
    )
    assert_true(
        not _acc_accepts(ACC_BINARY, AVRO_KIND_BYTES, PROMOTE_BYTES_TO_STRING)
    )
    assert_true(not _acc_accepts(ACC_I64, AVRO_KIND_INT, Int8(99)))
    # No promotion: the wire kind's own arm.
    var kinds: List[Int] = [
        AVRO_KIND_BOOLEAN,
        AVRO_KIND_INT,
        AVRO_KIND_LONG,
        AVRO_KIND_FLOAT,
        AVRO_KIND_DOUBLE,
        AVRO_KIND_STRING,
    ]
    var arms: List[Int8] = [ACC_BOOL, ACC_I32, ACC_I64, ACC_F32, ACC_F64, ACC_STRING]
    for k in range(len(kinds)):
        for a in range(len(arms)):
            assert_equal(
                _acc_accepts(arms[a], kinds[k], PROMOTE_NONE),
                k == a,
                String("kind ") + String(kinds[k]) + " arm " + String(arms[a]),
            )
        assert_true(not _acc_accepts(ACC_BINARY, kinds[k], PROMOTE_NONE))
    assert_true(_acc_accepts(ACC_BINARY, AVRO_KIND_BYTES, PROMOTE_NONE))
    assert_true(_acc_accepts(ACC_DECIMAL, AVRO_KIND_BYTES, PROMOTE_NONE))
    assert_true(_acc_accepts(ACC_BINARY, AVRO_KIND_FIXED, PROMOTE_NONE))
    assert_true(_acc_accepts(ACC_DECIMAL, AVRO_KIND_FIXED, PROMOTE_NONE))
    assert_true(not _acc_accepts(ACC_STRING, AVRO_KIND_FIXED, PROMOTE_NONE))
    assert_true(not _acc_accepts(ACC_NULL, AVRO_KIND_RECORD, PROMOTE_NONE))


def test_default_fits_tag_every_arm() raises:
    """G6."""
    var defaults: List[Int] = [
        AVRO_DEFAULT_NULL,
        AVRO_DEFAULT_BOOL,
        AVRO_DEFAULT_INT,
        AVRO_DEFAULT_DOUBLE,
        AVRO_DEFAULT_STRING,
        AVRO_DEFAULT_BYTES,
        AVRO_DEFAULT_NONE,
    ]
    var arms: List[Int8] = [
        ACC_NULL, ACC_BOOL, ACC_I32, ACC_I64, ACC_F32, ACC_F64, ACC_STRING,
        ACC_BINARY, ACC_DECIMAL,
    ]
    # fits[d] lists the arms default kind d fits, as indices into `arms`.
    var fits = List[List[Int]]()
    fits.append([0])
    fits.append([1])
    fits.append([2, 3, 4, 5])
    fits.append([4, 5])
    fits.append([6])
    fits.append([7])
    fits.append(List[Int]())
    for d in range(len(defaults)):
        for a in range(len(arms)):
            var want = False
            for i in range(len(fits[d])):
                if fits[d][i] == a:
                    want = True
            assert_equal(
                _default_fits_tag(defaults[d], arms[a]),
                want,
                String("default ") + String(defaults[d]) + " arm "
                + String(arms[a]),
            )


def test_field_type_info_of_unions() raises:
    """G7."""
    var general = AvroSchema.parse('["int","string","null"]')
    var got = String("(accepted)")
    try:
        _ = _field_type_info(general, general.root_idx)
    except e:
        got = String(e)
    assert_equal(
        got,
        "AvroDecodeError.INTERNAL: a general union reached _field_type_info"
        " (it is routed by FA_UNION_ROUTE)",
    )
    var null_first = AvroSchema.parse('["null","int"]')
    var nf = _field_type_info(null_first, null_first.root_idx)
    assert_equal(nf.nullability, NULL_FIRST)
    assert_equal(null_first.node(nf.inner_idx).kind, AVRO_KIND_INT)
    var null_second = AvroSchema.parse('["long","null"]')
    var ns = _field_type_info(null_second, null_second.root_idx)
    assert_equal(ns.nullability, NULL_SECOND)
    assert_equal(null_second.node(ns.inner_idx).kind, AVRO_KIND_LONG)


def test_skip_walk_refuses_unknown_kind() raises:
    """G8."""
    var schema = AvroSchema.parse('"int"')
    var prog = SkipProgram(schema)
    prog.kinds[schema.root_idx] = 99
    var payload: List[UInt8] = [0x02]
    var reader = AvroByteReader(Span(payload))
    var got = String("(accepted)")
    try:
        prog.skip(reader, schema.root_idx)
    except e:
        got = String(e)
    assert_equal(
        got, "AvroDecodeError.UNSUPPORTED_FIELD_KIND: cannot skip kind 99"
    )


def test_empty_payload_is_no_truncated_xz_stream() raises:
    """G9."""
    var empty = List[UInt8]()
    assert_true(not _xz_lacks_stream_footer(Span(empty)), "empty payload")
    var magic_only: List[UInt8] = [0xFD, 0x37, 0x7A]
    assert_true(_xz_lacks_stream_footer(Span(magic_only)), "header prefix")


def main() raises:
    test_accumulator_without_builder_refused()
    test_union_accumulator_guards()
    test_wire_read_and_skip_of_unknown_kind()
    test_union_route_and_default_refusals()
    test_acc_accepts_every_arm()
    test_default_fits_tag_every_arm()
    test_field_type_info_of_unions()
    test_skip_walk_refuses_unknown_kind()
    test_empty_payload_is_no_truncated_xz_stream()
    print("test_avro_cov_decode_guards: ALL PASS")
