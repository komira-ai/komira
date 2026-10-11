# =============================================================================
# test_pplan_wire_golden_bytes.mojo: the physical-plan wire bytes, frozen.
# =============================================================================
#
# THE PROPERTY THIS FILE HOLDS: a change to `pplan_wire_codec.mojo` that alters
# the bytes it writes is a DELIBERATE act that updates a checked-in fixture.
#
# The round-trip test (`test_pplan_wire_roundtrip.mojo`) decodes what the
# encoder just wrote, in one process. A SYMMETRIC change (a wire code
# renumbered in the table both directions read, two fields swapped in both
# `_put_*` and `_get_*`) round-trips perfectly and keeps it green, while every
# plan already written to disk or sent over a socket now decodes differently.
# Only bytes that live outside the process can see that, and these do.
#
# The format is NOT protobuf: it is a positional, little-endian,
# length-prefixed layout with no field tags (see the header of
# `pplan_wire_codec.mojo`). There is therefore no `.proto` for a foreign
# decoder to read; these fixtures are the format's only external statement.
#
# ============================ WHAT IS ASSERTED ===============================
#
#   LEG A  FREEZE.   `pplan_to_bytes(corpus[i])` equals `<name>.hex` byte for
#                    byte, with the first differing offset named on failure.
#   LEG B  MEANING.  `pplan_from_bytes(<name>.hex)` (the bytes ON DISK, not
#                    the bytes just encoded) equals the corpus plan, field for
#                    field (`pplan_fields_equal`).
#   LEG C  NON-TRIVIAL. Each encoding is longer than 16 bytes, the
#                    magic + version + op-count floor.
#   LAYOUT The source block is a byte-identical PREFIX of every plan over the
#          same source, followed by the 8-byte op count: the ops are appended,
#          not interleaved, which is what the format's layout says.
#   DISTINCT The fixtures are pairwise different bytes.
#
# ============================ THE CORPUS =====================================
#
# One member per shape the codec encodes, every carried field at a value that
# is NOT its default (a field written as zero is indistinguishable from a field
# not written at all):
#
#   scan_bare            a source with EVERY optional ABSENT (projection,
#                        pushed_filter, row_window: the 0x00 presence bytes),
#                        the local fs descriptor (node_id -1), no ops.
#   scan_full            a source with every encoded field set: projection,
#                        a nested pushed_filter, an S3 descriptor, both
#                        preserve flags, explicit_paths, a row window. No ops.
#   filter               two FILTER ops: BINARY(AND) over BINARY(EQ) of a
#                        LEFT- and a RIGHT-side COL_REF, and UNARY(IS_NOT_NULL);
#                        then UNARY(NOT) over a NONE-side COL_REF.
#   project              PROJECT with a COL_REF and an ALIAS over
#                        BINARY(ADD, COL_REF, LITERAL); reorders_only = True.
#   limit                LIMIT 1000.
#   literal_every_field  a LITERAL whose 20 ScalarValue fields are ALL set,
#                        including a NaN with a payload, negative integers and
#                        a multi-byte UTF-8 string.
#   collect_chain        the whole shape over scan_full:
#                        FILTER, FILTER, PROJECT, LIMIT.
#
# ============================= HOW TO REGOLD =================================
#
# Every case prints a `GOLDEN-BEGIN`/`GOLDEN-END` block UNCONDITIONALLY. Run
# this test, copy the block into `tests/fixtures/golden/<name>.hex` and declare
# it in BUCK. The block is printed on PASS as well as FAIL, so a NEW member can
# be bootstrapped from one run.
#
# REGOLDING IS NOT A FIX. If a `.hex` moved and you did not intend to change
# the format, the diff is the bug report. Bump `PPLAN_WIRE_FORMAT_VERSION`
# when the change is deliberate: bytes already written must be REFUSED, not
# re-read with a new meaning.
# =============================================================================

from std.memory import bitcast
from std.testing import assert_equal, assert_true

from komira_arrow.schema import Field
from komira_collections.slab import Slab
from komira_plan_expr.expr import (
    Expr,
    BIN_ADD,
    BIN_AND,
    BIN_EQ,
    BIN_GT,
    BIN_NE,
    UN_IS_NOT_NULL,
    UN_NOT,
)
from komira_plan_expr.fs_descriptor_pod import FsDescriptorPod, FS_SCHEME_S3
from komira_plan_ir.logical_plan import ExprArray
from komira_physical_plan.physical_plan import (
    MorselOp,
    ParquetRowWindow,
    ParquetSourceData,
)
from komira_plan_expr.scalar_value import (
    ScalarValue,
    SCALAR_KIND_TIMESTAMP,
    SCALAR_TIME_UNIT_NANO,
)

from komira_pplan_wire import pplan_fields_equal, pplan_from_bytes, pplan_to_bytes


# =============================================================================
# THE FIXTURE FILES
# =============================================================================

comptime _FIXTURE_DIR: String = "src/komira_pplan_wire/tests/fixtures/golden/"

# 32 bytes (64 hex digits) per line: a one-byte change is ONE changed line.
comptime _HEX_BYTES_PER_LINE: Int = 32


def _hex_nibble(v: UInt8) -> String:
    comptime DIGITS = String("0123456789abcdef")
    return String(DIGITS[byte=Int(v)])


def _to_hex_lines(bytes: List[UInt8]) -> String:
    """Lowercase, 32 bytes per line, `\\n` terminated, no offsets (an offset
    column would make a one-byte insertion reflow the whole file)."""
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
    raise Error(
        "pplan_wire golden: a `.hex` fixture holds a character that is not a"
        + " lowercase hex digit (byte "
        + String(Int(c))
        + "). Fixtures are copied from the GOLDEN block this test prints."
    )


def _from_hex(text: String) raises -> List[UInt8]:
    """Parse a `.hex` fixture; newlines are skipped, so line width is a review
    convention and not part of what the file means."""
    var nibbles = List[UInt8]()
    var b = text.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord("\n")) or c == UInt8(ord(" ")):
            continue
        nibbles.append(_hex_value(c))
    if len(nibbles) % 2 != 0:
        raise Error(
            "pplan_wire golden: a `.hex` fixture has an odd number of hex"
            + " digits ("
            + String(len(nibbles))
            + ")."
        )
    var out = List[UInt8]()
    for i in range(0, len(nibbles), 2):
        out.append((nibbles[i] << 4) | nibbles[i + 1])
    return out^


def _read_fixture(name: String) raises -> List[UInt8]:
    """`tests/fixtures/golden/<name>.hex`, staged at its repository path under
    the test's working directory."""
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
            "pplan_wire golden: fixture `"
            + path
            + "` is MISSING. If this is a NEW corpus member, the GOLDEN block"
            + " this test just printed is its content: write it to that path"
            + " and declare it as test data in BUCK."
        )
    return _from_hex(text)


# =============================================================================
# THE CORPUS
# =============================================================================
#
# Every value below is a published constant once its `.hex` is checked in:
# changing `"lake"` to `"l"` is a fixture change, and the diff says so.


struct _Plan(Movable):
    var pq: ParquetSourceData
    var ops: Slab[MorselOp]

    def __init__(out self, var pq: ParquetSourceData, var ops: Slab[MorselOp]):
        self.pq = pq^
        self.ops = ops^


def _source_bare() -> ParquetSourceData:
    return ParquetSourceData(
        String("bare.parquet"),
        None,  # projection: absent
        None,  # pushed_filter: absent
        List[Field](),
        None,
        FsDescriptorPod.local(),  # scheme FILE, bucket "", node_id -1
        False,  # preserve_numeric_dict
        List[String](),
        None,  # row_window: absent
        False,  # preserve_string_dict
    )


def _source_full() -> ParquetSourceData:
    var proj = List[String]()
    proj.append(String("id"))
    proj.append(String("amount"))
    var paths = List[String]()
    paths.append(String("part-0.parquet"))
    paths.append(String("part-1.parquet"))
    var pushed = Expr.binary(
        BIN_GT,
        Expr.col_ref(String("amount")),
        Expr.literal(ScalarValue.from_int(100)),
    )
    return ParquetSourceData(
        String("s3://lake/events/"),
        Optional[List[String]](proj^),
        Optional[Expr](pushed^),
        List[Field](),
        None,
        FsDescriptorPod.cloud(FS_SCHEME_S3, String("lake"), 7),
        True,  # preserve_numeric_dict
        paths^,
        Optional[ParquetRowWindow](ParquetRowWindow(11, 22)),
        True,  # preserve_string_dict
    )


def _filter_ops(mut ops: Slab[MorselOp]):
    var join_eq = Expr.binary(
        BIN_EQ, Expr.left(String("k")), Expr.right(String("k"))
    )
    var not_null = Expr.unary(UN_IS_NOT_NULL, Expr.col_ref(String("v")))
    ops.append(MorselOp.filter(Expr.binary(BIN_AND, join_eq^, not_null^)))
    ops.append(MorselOp.filter(Expr.unary(UN_NOT, Expr.col_ref(String("flag")))))


def _project_op() -> MorselOp:
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("a")))
    exprs.append(
        Expr.alias(
            Expr.binary(
                BIN_ADD,
                Expr.col_ref(String("b")),
                Expr.literal(ScalarValue.from_int(1)),
            ),
            String("b_plus_1"),
        )
    )
    var names = List[String]()
    names.append(String("a"))
    names.append(String("b_plus_1"))
    return MorselOp.project(exprs^, names^, reorders_only=True)


def _scalar_every_field() -> ScalarValue:
    """All 19 fields away from their defaults. Not a coherent value of any one
    kind: the codec carries every field unconditionally, so the fixture pins
    every field's offset and width."""
    var s = ScalarValue()
    s.dtype = DType.int64
    s.int_val = Int64(-2)
    # A quiet NaN with a payload: a decimal render could not carry it.
    s.float_val = bitcast[DType.float64](UInt64(0x7FF8000000000ABC))
    s.string_val = String("naïve")  # 6 bytes, one 2-byte code point
    s.bool_val = True
    s._kind = SCALAR_KIND_TIMESTAMP
    s.dec128_high = Int64(-3)
    s.dec128_low = Int64(0x0102030405060708)
    s.dec128_precision = 38
    s.dec128_scale = 9
    s.date32_val = Int32(-719162)
    s.ts_micros = Int64(1700000000000000)
    s.null_dtype = DType.float32
    s.iv_months = Int32(-14)
    s.iv_days = Int32(45)
    s.iv_nanos = Int64(-5)
    s.time_unit = SCALAR_TIME_UNIT_NANO
    s.dec256_high_lo = Int64(-6)
    s.dec256_high_hi = Int64(7)
    return s^


def _corpus(name: String) raises -> _Plan:
    var ops = Slab[MorselOp]()
    if name == "scan_bare":
        return _Plan(_source_bare(), ops^)
    if name == "scan_full":
        return _Plan(_source_full(), ops^)
    if name == "filter":
        _filter_ops(ops)
        return _Plan(_source_bare(), ops^)
    if name == "project":
        ops.append(_project_op())
        return _Plan(_source_bare(), ops^)
    if name == "limit":
        ops.append(MorselOp.limit(1000))
        return _Plan(_source_bare(), ops^)
    if name == "literal_every_field":
        ops.append(
            MorselOp.filter(
                Expr.binary(
                    BIN_NE,
                    Expr.col_ref(String("x")),
                    Expr.literal(_scalar_every_field()),
                )
            )
        )
        return _Plan(_source_bare(), ops^)
    if name == "collect_chain":
        _filter_ops(ops)
        ops.append(_project_op())
        ops.append(MorselOp.limit(1000))
        return _Plan(_source_full(), ops^)
    raise Error("pplan_wire golden: no corpus member named `" + name + "`")


def _names() -> List[String]:
    var n = List[String]()
    n.append(String("scan_bare"))
    n.append(String("scan_full"))
    n.append(String("filter"))
    n.append(String("project"))
    n.append(String("limit"))
    n.append(String("literal_every_field"))
    n.append(String("collect_chain"))
    return n^


# =============================================================================
# LEGS A, B, C
# =============================================================================


def _assert_frozen(name: String) raises:
    var plan = _corpus(name)
    var bytes = pplan_to_bytes(plan.pq, plan.ops)

    # Printed UNCONDITIONALLY, pass or fail: this is the regold / bootstrap.
    print("GOLDEN-BEGIN " + name)
    print(_to_hex_lines(bytes), end="")
    print("GOLDEN-END " + name)

    # --- LEG C --------------------------------------------------------------
    assert_true(
        len(bytes) > 16,
        name
        + ": LEG C: the encoder wrote only "
        + String(len(bytes))
        + " bytes, at most magic + version + op count. A fixture frozen at"
        + " that size freezes an encoder that writes nothing.",
    )

    # --- LEG A --------------------------------------------------------------
    var want = _read_fixture(name)
    var first_diff = -1
    var n = min(len(bytes), len(want))
    for i in range(n):
        if bytes[i] != want[i]:
            first_diff = i
            break
    if first_diff < 0 and len(bytes) != len(want):
        first_diff = n
    if first_diff >= 0:
        var got_b = String("end of input")
        if first_diff < len(bytes):
            got_b = String(Int(bytes[first_diff]))
        var want_b = String("end of input")
        if first_diff < len(want):
            want_b = String(Int(want[first_diff]))
        raise Error(
            name
            + ": LEG A: the encoder's bytes DIVERGE from the frozen fixture at"
            + " offset "
            + String(first_diff)
            + " (encoder wrote "
            + got_b
            + ", fixture holds "
            + want_b
            + "; lengths "
            + String(len(bytes))
            + " vs "
            + String(len(want))
            + "). This is a WIRE FORMAT change. If it was deliberate, bump"
            + " PPLAN_WIRE_FORMAT_VERSION and regold from the GOLDEN block"
            + " above; if it was not, the diff is the bug report."
        )

    # --- LEG B --------------------------------------------------------------
    # Decoded from the FIXTURE, not from `bytes`: decoding what was just
    # encoded is the round-trip test's job, and it is blind to a symmetric
    # change. This leg asks whether the bytes on disk still MEAN this plan.
    var back = pplan_from_bytes(want^)
    assert_true(
        pplan_fields_equal(plan.pq, plan.ops, back.pq_data, back.ops),
        name
        + ": LEG B: the CHECKED-IN bytes decode to a plan that differs from"
        + " the corpus plan, field for field. The decoder now reads frozen"
        + " bytes with a different meaning.",
    )


# =============================================================================
# LAYOUT and DISTINCT
# =============================================================================


def _assert_source_prefix(source: String, plan: String, n_ops: Int) raises:
    """`plan`'s bytes are `source`'s bytes up to the op count, then the op
    count `n_ops` as a little-endian Int64, then the ops."""
    var src = _read_fixture(source)
    var full = _read_fixture(plan)
    var head = len(src) - 8  # every byte before the op count
    assert_true(
        len(full) > len(src),
        plan + ": LAYOUT: not longer than its source `" + source + "`",
    )
    for i in range(head):
        assert_equal(
            full[i],
            src[i],
            plan
            + ": LAYOUT: byte "
            + String(i)
            + " of the source block differs from `"
            + source
            + "`; the ops are not appended after an unchanged source.",
        )
    for i in range(8):
        var want = UInt8((n_ops >> (8 * i)) & 0xFF)
        assert_equal(
            full[head + i],
            want,
            plan + ": LAYOUT: the op count is not " + String(n_ops),
        )


def test_ops_are_appended_after_the_source_block() raises:
    _assert_source_prefix(String("scan_bare"), String("filter"), 2)
    _assert_source_prefix(String("scan_bare"), String("project"), 1)
    _assert_source_prefix(String("scan_bare"), String("limit"), 1)
    _assert_source_prefix(String("scan_bare"), String("literal_every_field"), 1)
    _assert_source_prefix(String("scan_full"), String("collect_chain"), 4)


def test_the_fixtures_are_pairwise_distinct() raises:
    var names = _names()
    var all = List[List[UInt8]]()
    for i in range(len(names)):
        all.append(_read_fixture(names[i]))
    for i in range(len(all)):
        for j in range(i + 1, len(all)):
            var same = len(all[i]) == len(all[j])
            if same:
                for k in range(len(all[i])):
                    if all[i][k] != all[j][k]:
                        same = False
                        break
            assert_true(
                not same,
                "the frozen fixtures `"
                + names[i]
                + "` and `"
                + names[j]
                + "` are the SAME bytes; an encoder that collapsed both plans"
                + " would pass both.",
            )


def _run(name: String, mut failed: List[String]):
    """Run one frozen-bytes case, recording a failure instead of stopping, so
    ONE run prints every GOLDEN block (a missing fixture must not hide the
    blocks after it)."""
    try:
        _assert_frozen(name)
    except e:
        print("FAIL " + name + ": " + String(e))
        failed.append(name)


def main() raises:
    var failed = List[String]()
    var names = _names()
    for i in range(len(names)):
        _run(names[i], failed)
    if len(failed) != 0:
        var msg = String("pplan_wire golden: ") + String(len(failed)) + " case(s) failed:"
        for i in range(len(failed)):
            msg += " " + failed[i]
        raise Error(msg)
    test_ops_are_appended_after_the_source_block()
    test_the_fixtures_are_pairwise_distinct()
    print("ok")
