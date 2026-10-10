# =============================================================================
# test_pplan_wire_hostile_bytes.mojo: bytes this codec did not write.
# =============================================================================
#
# THE PROPERTY THIS FILE HOLDS: `pplan_from_bytes` REFUSES every malformed
# input with its exact, named error, and never builds a plan out of it. Every
# other test in this package hands the decoder bytes the encoder wrote; these
# fixtures are what a truncated file, a newer writer or a hostile peer sends.
#
# Each fixture is `tests/fixtures/hostile/<name>.hex`, in the golden fixtures'
# rendering, and each is the golden layout with ONE thing wrong. The FULL error
# message is asserted, not a token search: the position and value in the
# message are what prove WHICH read refused.
#
# The format is positional and fixed-width (see `pplan_wire_codec.mojo`):
# there are no varints and no field tags, so "mid-varint" is "mid fixed-width
# integer" and an "unknown field" is either an unknown TAG BYTE (op, expr) or
# an unknown CODE (dtype, side, operator, scheme, scalar kind) or trailing
# bytes. All of those are below.
#
# ============================ WHAT IS ASSERTED ===============================
#
#   TRUNCATION   empty input; inside the magic, the version, a string length,
#                a string payload, a scalar's float, the op count; before an
#                op; inside a nested expression.
#   LYING LENGTHS a negative string/op/project count, an INT64_MAX string
#                length or op count over a short buffer, and a PROJECT whose
#                name count differs from its expression count.
#   UNKNOWN      op tags, expr tags, dtype codes, column sides, binary/unary
#                operator codes, fs schemes, scalar kind / time unit, a bool
#                byte that is neither 0 nor 1, a negative LIMIT or
#                row window, a non-UTF-8 identifier, an Int32 scalar field
#                (date32, interval months/days) outside Int32.
#   VERSION GATE versions 0, 1 and 3 refused; and refused BEFORE the body is
#                read (`version_1` is `scan_full` in the version-1 layout and
#                `version_3_truncated_body` is truncated: each names the
#                version, not the misparse or truncation behind it).
#   ENCODER      the encoder refuses a non-UTF-8 path or column name and a
#                PROJECT count mismatch with the decoder's own message, so no
#                plan encodes to bytes the decoder refuses.
#   CONTROLS     the version-3 fixture with its version byte set back to 2 is
#                byte-identical to the `scan_full` golden and decodes; a
#                64-deep expression decodes and a 65-deep one is refused; a
#                BINARY literal's non-UTF-8 bytes are carried, not refused.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.schema import Field
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr
from komira_plan_expr.fs_descriptor_pod import FsDescriptorPod
from komira_plan_ir.logical_plan import ExprArray
from komira_physical_plan.physical_plan import MorselOp, ParquetSourceData
from komira_pplan_wire import pplan_from_bytes, pplan_to_bytes


comptime _HOSTILE_DIR: String = "src/komira_pplan_wire/tests/fixtures/hostile/"
comptime _GOLDEN_DIR: String = "src/komira_pplan_wire/tests/fixtures/golden/"


def _hex_value(c: UInt8) raises -> UInt8:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return c - UInt8(ord("a")) + UInt8(10)
    raise Error(
        "pplan_wire hostile: a `.hex` fixture holds a non-hex character (byte "
        + String(Int(c))
        + ")."
    )


def _read_hex(path: String) raises -> List[UInt8]:
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
            "pplan_wire hostile: fixture `" + path + "` is MISSING (declare it"
            + " as test data in BUCK)."
        )
    var nibbles = List[UInt8]()
    var b = text.as_bytes()
    for i in range(len(b)):
        if b[i] == UInt8(ord("\n")):
            continue
        nibbles.append(_hex_value(b[i]))
    if len(nibbles) % 2 != 0:
        raise Error("pplan_wire hostile: `" + path + "` has an odd digit count")
    var out = List[UInt8]()
    for i in range(0, len(nibbles), 2):
        out.append((nibbles[i] << 4) | nibbles[i + 1])
    return out^


def _hostile(name: String) raises -> List[UInt8]:
    return _read_hex(_HOSTILE_DIR + name + ".hex")


def _refusal(var data: List[UInt8]) -> String:
    """The decoder's error text, or "" when it ACCEPTED the bytes."""
    try:
        _ = pplan_from_bytes(data^)
    except e:
        return String(e)
    return String("")


def _check(name: String, want: String, mut failed: List[String]):
    """One fixture, one exact message. Records a mismatch and keeps going, so
    a run reports EVERY divergence rather than the first."""
    var got: String
    try:
        got = _refusal(_hostile(name))
    except e:
        got = String("<fixture unreadable: ") + String(e) + ">"
    if got == want:
        return
    var shown = got
    if got == "":
        shown = String("<ACCEPTED: decoded into a plan instead of refusing>")
    print("FAIL " + name + "\n  want: " + want + "\n  got:  " + shown)
    failed.append(name)


def test_hostile_fixtures_are_refused_by_exact_message() raises:
    var f = List[String]()
    # ---- truncation: every fixed-width read checks its bound ---------------
    _check("truncated_empty", "PPLAN_WIRE_TRUNCATED: need 4 at 0", f)
    _check("truncated_mid_magic", "PPLAN_WIRE_TRUNCATED: need 4 at 0", f)
    _check("truncated_mid_version", "PPLAN_WIRE_TRUNCATED: need 4 at 4", f)
    _check("truncated_mid_string_length", "PPLAN_WIRE_TRUNCATED: need 8 at 8", f)
    _check("truncated_mid_string_bytes", "PPLAN_WIRE_TRUNCATED: need 12 at 16", f)
    _check("truncated_mid_float", "PPLAN_WIRE_TRUNCATED: need 8 at 93", f)
    _check("truncated_mid_op_count", "PPLAN_WIRE_TRUNCATED: need 8 at 58", f)
    _check("truncated_before_op", "PPLAN_WIRE_TRUNCATED: need 1 at 66", f)
    _check("truncated_mid_nested_expr", "PPLAN_WIRE_TRUNCATED: need 8 at 96", f)
    # ---- lengths that lie --------------------------------------------------
    _check(
        "string_length_negative",
        "PPLAN_WIRE_NEGATIVE_COUNT: string length -1",
        f,
    )
    _check("op_count_negative", "PPLAN_WIRE_NEGATIVE_COUNT: op count -1", f)
    _check(
        "project_count_negative",
        "PPLAN_WIRE_NEGATIVE_COUNT: project expr count -1",
        f,
    )
    _check(
        "project_names_fewer_than_exprs",
        "PPLAN_WIRE_PROJECT_MISMATCH: 2 exprs, 1 names",
        f,
    )
    _check("op_count_int64_max", "PPLAN_WIRE_TRUNCATED: need 1 at 75", f)
    # ---- unknown tags and codes --------------------------------------------
    _check("op_tag_join_probe", "PPLAN_WIRE_UNSUPPORTED_OP_TAG: tag 3", f)
    _check("op_tag_255", "PPLAN_WIRE_UNSUPPORTED_OP_TAG: tag 255", f)
    _check("expr_tag_col_idx", "PPLAN_WIRE_UNSUPPORTED_EXPR_TAG: tag 1", f)
    _check("expr_tag_cast", "PPLAN_WIRE_UNSUPPORTED_EXPR_TAG: tag 5", f)
    _check("expr_tag_255", "PPLAN_WIRE_UNSUPPORTED_EXPR_TAG: tag 255", f)
    _check(
        "dtype_code_unknown",
        "PPLAN_WIRE_UNSUPPORTED_DTYPE: unknown wire code 13",
        f,
    )
    _check(
        "null_dtype_code_unknown",
        "PPLAN_WIRE_UNSUPPORTED_DTYPE: unknown wire code 4294967295",
        f,
    )
    _check("col_side_unknown", "PPLAN_WIRE_UNSUPPORTED_COL_SIDE: 3", f)
    _check("bool_byte_two", "PPLAN_WIRE_BAD_ENUM: bool byte 2 at 47", f)
    _check("binary_op_unknown", "PPLAN_WIRE_BAD_ENUM: binary op 99", f)
    _check("binary_op_gap", "PPLAN_WIRE_BAD_ENUM: binary op 5", f)
    _check("unary_op_unknown", "PPLAN_WIRE_BAD_ENUM: unary op 9", f)
    _check("fs_scheme_unknown", "PPLAN_WIRE_BAD_ENUM: fs scheme 4", f)
    _check("scalar_kind_unknown", "PPLAN_WIRE_BAD_ENUM: scalar kind 10", f)
    _check(
        "scalar_time_unit_unknown", "PPLAN_WIRE_BAD_ENUM: scalar time unit 4", f
    )
    # Int32 fields travel as Int64: a value outside Int32 would narrow to the
    # same plan as 2^32 other spellings, and would not re-encode to itself.
    _check(
        "scalar_date32_out_of_range",
        "PPLAN_WIRE_OUT_OF_RANGE: scalar date32 2147483648",
        f,
    )
    _check(
        "scalar_interval_months_out_of_range",
        "PPLAN_WIRE_OUT_OF_RANGE: scalar interval months -2147483649",
        f,
    )
    _check(
        "scalar_interval_days_out_of_range",
        "PPLAN_WIRE_OUT_OF_RANGE: scalar interval days 4294967296",
        f,
    )
    _check("limit_negative", "PPLAN_WIRE_NEGATIVE_COUNT: limit -1", f)
    _check(
        "row_window_offset_negative",
        "PPLAN_WIRE_NEGATIVE_COUNT: row window offset -1",
        f,
    )
    _check(
        "row_window_length_negative",
        "PPLAN_WIRE_NEGATIVE_COUNT: row window length -1",
        f,
    )
    _check("string_invalid_utf8", "PPLAN_WIRE_BAD_UTF8: string at 16", f)
    _check("column_name_invalid_utf8", "PPLAN_WIRE_BAD_UTF8: string at 76", f)
    _check("expr_depth_65", "PPLAN_WIRE_EXPR_TOO_DEEP: depth 65", f)
    # ---- framing and the version gate --------------------------------------
    _check("bad_magic", "PPLAN_WIRE_BAD_MAGIC", f)
    _check("trailing_byte", "PPLAN_WIRE_TRAILING_BYTES: 1 unread", f)
    _check("version_0", "PPLAN_WIRE_BAD_VERSION: 0", f)
    # `scan_full` as version 1 encoded it, whose scalar layout carried one
    # more byte. Read under the current layout it would misparse; the version
    # gate refuses it first.
    _check("version_1", "PPLAN_WIRE_BAD_VERSION: 1", f)
    _check("version_3", "PPLAN_WIRE_BAD_VERSION: 3", f)
    # The body after this version is TRUNCATED. A gate that ran after (or
    # instead of) the parse would name the truncation; the version must win.
    _check("version_3_truncated_body", "PPLAN_WIRE_BAD_VERSION: 3", f)
    # ---- memory safety: LAST, because before the bound was overflow-safe this
    # fixture read past the buffer, and a crash here must not hide the
    # verdicts above.
    _check(
        "string_length_int64_max",
        "PPLAN_WIRE_TRUNCATED: need 9223372036854775807 at 16",
        f,
    )
    if len(f) != 0:
        var msg = String("pplan_wire hostile: ") + String(len(f)) + " fixture(s):"
        for i in range(len(f)):
            msg += " " + f[i]
        raise Error(msg)


def test_version_3_is_scan_full_with_one_byte_changed() raises:
    """The version-gate control. Setting the version byte of `version_3` back
    to 2 yields the `scan_full` golden EXACTLY, and that decodes: so the
    version, and nothing else, is what `version_3` is refused for."""
    var hostile = _hostile(String("version_3"))
    var golden = _read_hex(_GOLDEN_DIR + "scan_full.hex")
    assert_equal(hostile[4], UInt8(3))
    hostile[4] = UInt8(2)
    assert_equal(len(hostile), len(golden))
    for i in range(len(golden)):
        assert_equal(hostile[i], golden[i], "byte " + String(i))
    var back = pplan_from_bytes(hostile^)
    assert_equal(back.pq_data.file_path, String("s3://lake/events/"))


def test_bool_byte_two_is_scan_bare_with_one_byte_changed() raises:
    """Control for `bool_byte_two`: with the byte at 47 set back to 0 it is the
    `scan_bare` golden, so the 2 is the only thing refused."""
    var hostile = _hostile(String("bool_byte_two"))
    var golden = _read_hex(_GOLDEN_DIR + "scan_bare.hex")
    assert_equal(hostile[47], UInt8(2))
    hostile[47] = UInt8(0)
    assert_equal(len(hostile), len(golden))
    for i in range(len(golden)):
        assert_equal(hostile[i], golden[i], "byte " + String(i))


def test_expression_depth_bound_is_exact() raises:
    """64 nested operators decode; the 65th level is the refusal above. A bound
    that is off by one in either direction fails one of the two."""
    var back = pplan_from_bytes(_hostile(String("expr_depth_64_accepted")))
    assert_equal(len(back.ops), 1)


def test_binary_literal_bytes_are_carried_not_refused() raises:
    """`string_val` of a BINARY scalar holds opaque bytes, so the UTF-8 check
    on identifiers must NOT apply to it: these bytes are not UTF-8 and decode."""
    var back = pplan_from_bytes(_hostile(String("literal_binary_bytes_accepted")))
    assert_equal(len(back.ops), 1)
    var lit = back.ops[0].filter_predicate.value().binary_right_ref().literal_value()
    var b = lit.string_val.as_bytes()
    assert_equal(len(b), 3)
    assert_equal(b[0], UInt8(0xFF))
    assert_equal(b[1], UInt8(0x00))
    assert_equal(b[2], UInt8(0xFE))


# =============================================================================
# THE ENCODER REFUSES what the decoder would refuse: bytes it writes must
# decode. Each case below names the same error, at the same offset, that the
# decoder gives for the matching hostile fixture.
# =============================================================================


def _source(path: String) -> ParquetSourceData:
    return ParquetSourceData(
        path, None, None, List[Field](), None, FsDescriptorPod.local(), False,
        List[String](), None, False,
    )


def _not_utf8(prefix: UInt8, rest: String) -> String:
    """A String whose bytes are NOT UTF-8, built the one way komira code can
    build one: `unsafe_from_utf8` over bytes nobody validated."""
    var b = List[UInt8]()
    b.append(prefix)
    var r = rest.as_bytes()
    for i in range(len(r)):
        b.append(r[i])
    return String(unsafe_from_utf8=Span(b))


def _encode_error(pq: ParquetSourceData, ops: Slab[MorselOp]) -> String:
    try:
        _ = pplan_to_bytes(pq, ops)
    except e:
        return String(e)
    return String("<ACCEPTED: encoded>")


def test_encoder_refuses_a_non_utf8_path() raises:
    # The fixture `string_invalid_utf8` is what this plan would encode to.
    assert_equal(
        _encode_error(_source(_not_utf8(0xFF, "bare.parquet")), Slab[MorselOp]()),
        "PPLAN_WIRE_BAD_UTF8: string at 16",
    )


def test_encoder_refuses_a_non_utf8_column_name() raises:
    var ops = Slab[MorselOp]()
    ops.append(MorselOp.filter(Expr.col_ref(_not_utf8(0xC3, "("))))
    assert_equal(
        _encode_error(_source(String("bare.parquet")), ops),
        "PPLAN_WIRE_BAD_UTF8: string at 76",
    )


def test_encoder_refuses_a_project_name_count_mismatch() raises:
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("a")))
    exprs.append(Expr.col_ref(String("b")))
    var names = List[String]()
    names.append(String("a"))
    var ops = Slab[MorselOp]()
    ops.append(MorselOp.project(exprs^, names^))
    assert_equal(
        _encode_error(_source(String("bare.parquet")), ops),
        "PPLAN_WIRE_PROJECT_MISMATCH: 2 exprs, 1 names",
    )


def main() raises:
    test_version_3_is_scan_full_with_one_byte_changed()
    test_bool_byte_two_is_scan_bare_with_one_byte_changed()
    test_expression_depth_bound_is_exact()
    test_binary_literal_bytes_are_carried_not_refused()
    # Encoder cases each report, then the run fails once, so one run shows
    # every divergence.
    var failed = List[String]()
    try:
        test_encoder_refuses_a_non_utf8_path()
    except e:
        print("FAIL encode non-UTF-8 path: " + String(e))
        failed.append(String("encode_path"))
    try:
        test_encoder_refuses_a_non_utf8_column_name()
    except e:
        print("FAIL encode non-UTF-8 column name: " + String(e))
        failed.append(String("encode_column_name"))
    try:
        test_encoder_refuses_a_project_name_count_mismatch()
    except e:
        print("FAIL encode project mismatch: " + String(e))
        failed.append(String("encode_project_mismatch"))
    test_hostile_fixtures_are_refused_by_exact_message()
    if len(failed) != 0:
        raise Error(String("pplan_wire hostile: ") + String(len(failed)) + " encoder case(s) failed")
    print("ok")
