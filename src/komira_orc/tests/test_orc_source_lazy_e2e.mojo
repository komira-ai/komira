"""ORC source-variant substrate test (LIGHT).

Pins the contract that `OrcSource` + `SourceVariant` ORC arm + the
`LogicalPlan.scan_from_source(SourceVariant(OrcSource(...)))` dispatch all
wire correctly, mirroring the CsvSource e2e test (the LIGHT variant — does
NOT pull in an engine context / materialize, to keep the test binary small
and fast to compile).

The full engine read -> materialize integration is the engine's to test;
this substrate test verifies the arm:

  lazy ORC read -> OrcSource -> SourceVariant(SOURCE_VARIANT_ORC) ->
  scan_from_source -> LogicalPlan(PLAN_SCAN, source_type=SOURCE_ORC)

The lazy / streaming / projection scan body itself is the
read_orc_bytes_projected path; this test exercises the SourceVariant
dispatch surface, the arm every ORC scan enters the engine through.

Coverage:
  T1: OrcSource ctor + schema + fingerprint stability across copy().
  T2: OrcSource projection fingerprint disambiguation (same path,
      different projection -> different fingerprint).
  T3: SourceVariant ORC arm tag + per-arm accessor round-trip.
  T4: SourceVariant.copy() preserves identity byte-for-byte.
  T5: read_orc_bytes_projected end-to-end on a hand-emitted ORC file
      (verifies the projection plumbing OrcSource carries actually fires
      against the chassis — 2-of-3 cols selected, RecordBatch shape +
      values match).
  T6: read_orc_bytes_projected = read_orc_bytes for the empty / full
      projection case (oracle equality).
"""

from std.testing import assert_equal, assert_true
from std.os import remove
from std.io import FileHandle

from komira_arrow.schema import Schema
from komira_scan_source.orc_source import OrcSource
from komira_scan_source.source_variant import (
    SourceVariant,
    SOURCE_VARIANT_ORC,
)
from komira_plan_ir.logical_plan import LogicalPlan, SOURCE_ORC

from komira_orc import (
    ORC_COMPRESSION_NONE,
    ORC_KIND_STRUCT,
    ORC_KIND_LONG,
    ORC_KIND_STRING,
    ORC_STREAM_DATA,
    ORC_STREAM_LENGTH,
    ORC_ENCODING_DIRECT_V2,
    PB_WIRE_VARINT,
    PB_WIRE_LEN,
    read_orc_bytes,
    read_orc_bytes_projected,
)
from komira_runtime_paths import test_tmpdir


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH. Two runs of the same test may
# execute at once on one machine, and a fixed `/tmp` path is shared by every
# one of them. The test runner makes `TEST_TMPDIR` private to each run;
# `komira_runtime_paths.test_tmpdir` is the one helper that reads it (and
# raises when it is unset rather than falling back to a shared directory).
# ---------------------------------------------------------------------------
def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into."""
    return test_tmpdir()


# =============================================================================
# Hand-emitted ORC file helper.
# =============================================================================


def _pb_varint(n: UInt64, mut out: List[UInt8]):
    var v = n
    while True:
        var b = UInt8(v & 0x7F)
        v >>= 7
        if v != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _pb_varint_field(field_number: Int, value: UInt64, mut out: List[UInt8]):
    _pb_varint(UInt64((field_number << 3) | PB_WIRE_VARINT), out)
    _pb_varint(value, out)


def _pb_string_field(field_number: Int, s: String, mut out: List[UInt8]):
    _pb_varint(UInt64((field_number << 3) | PB_WIRE_LEN), out)
    var b = s.as_bytes()
    _pb_varint(UInt64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _pb_message_field(field_number: Int, body: List[UInt8], mut out: List[UInt8]):
    _pb_varint(UInt64((field_number << 3) | PB_WIRE_LEN), out)
    _pb_varint(UInt64(len(body)), out)
    for i in range(len(body)):
        out.append(body[i])


def _i64s(*vals: Int) -> List[Int64]:
    var out = List[Int64]()
    for i in range(len(vals)):
        out.append(Int64(vals[i]))
    return out^


def _zigzag_encode(v: Int64) -> UInt64:
    return UInt64((v << 1) ^ (v >> 63))


def _pack_bits_be(values: List[Int64], bits: Int, mut out: List[UInt8]):
    var cur: UInt64 = 0
    var filled: Int = 0
    for vi in range(len(values)):
        var v = UInt64(values[vi]) & ((UInt64(1) << UInt64(bits)) - 1)
        var need = bits
        while need > 0:
            var space = 8 - filled
            var take = need if need < space else space
            var shift = need - take
            var chunk = (v >> UInt64(shift)) & ((UInt64(1) << UInt64(take)) - 1)
            cur = (cur << UInt64(take)) | chunk
            filled += take
            need -= take
            if filled == 8:
                out.append(UInt8(cur & 0xFF))
                cur = 0
                filled = 0
    if filled > 0:
        cur = cur << UInt64(8 - filled)
        out.append(UInt8(cur & 0xFF))


def _rlev2_direct(values: List[Int64], bits: Int, signed: Bool) -> List[UInt8]:
    var packed = List[Int64]()
    for i in range(len(values)):
        if signed:
            packed.append(Int64(_zigzag_encode(values[i])))
        else:
            packed.append(values[i])
    var out = List[UInt8]()
    var L = len(values) - 1
    var b0 = (1 << 6) | ((bits - 1) << 1) | ((L >> 8) & 1)
    out.append(UInt8(b0))
    out.append(UInt8(L & 0xFF))
    _pack_bits_be(packed, bits, out)
    return out^


def _enc_stream(kind: Int, column: Int, length: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _pb_varint_field(1, UInt64(kind), b)
    _pb_varint_field(2, UInt64(column), b)
    _pb_varint_field(3, UInt64(length), b)
    return b^


def _enc_encoding(kind: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _pb_varint_field(1, UInt64(kind), b)
    return b^


def _enc_leaf(kind: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _pb_varint_field(1, UInt64(kind), b)
    return b^


def _build_3col_orc_file() -> List[UInt8]:
    """Build a struct<a:bigint, b:bigint, c:string> ORC file, 3 rows:
        a = 10, 20, 30
        b = 100, 200, 300
        c = "alpha","beta","delta"
    """
    var a_data = _rlev2_direct(_i64s(10, 20, 30), 8, True)
    var b_data = _rlev2_direct(_i64s(100, 200, 300), 9, True)
    # c (string) DIRECT_V2 encoding: a single concatenated DATA stream +
    # a LENGTH stream giving per-row byte length.
    var c_data = List[UInt8]()
    var concat = String("alphabetadelta")
    var cb = concat.as_bytes()
    for i in range(len(cb)):
        c_data.append(cb[i])
    var c_len = _rlev2_direct(_i64s(5, 4, 5), 4, False)

    var data_region = List[UInt8]()
    for i in range(len(a_data)):
        data_region.append(a_data[i])
    for i in range(len(b_data)):
        data_region.append(b_data[i])
    for i in range(len(c_data)):
        data_region.append(c_data[i])
    for i in range(len(c_len)):
        data_region.append(c_len[i])

    var sf = List[UInt8]()
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 1, len(a_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 2, len(b_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 3, len(c_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_LENGTH, 3, len(c_len)), sf)
    # 4 encodings: column 0 = root struct, 1 = a, 2 = b, 3 = c. The leaf
    # types are LONG / LONG / STRING (root struct has no leaf type).
    _pb_message_field(2, _enc_encoding(ORC_ENCODING_DIRECT_V2), sf)
    _pb_message_field(2, _enc_encoding(ORC_ENCODING_DIRECT_V2), sf)
    _pb_message_field(2, _enc_encoding(ORC_ENCODING_DIRECT_V2), sf)
    _pb_message_field(2, _enc_encoding(ORC_ENCODING_DIRECT_V2), sf)

    # Root struct type entry: STRUCT with subtypes [1, 2, 3].
    var root = List[UInt8]()
    _pb_varint_field(1, UInt64(ORC_KIND_STRUCT), root)
    _pb_varint_field(2, 1, root)
    _pb_varint_field(2, 2, root)
    _pb_varint_field(2, 3, root)
    _pb_string_field(3, String("a"), root)
    _pb_string_field(3, String("b"), root)
    _pb_string_field(3, String("c"), root)

    var footer = List[UInt8]()
    _pb_varint_field(1, 3, footer)
    _pb_varint_field(2, UInt64(len(data_region) + len(sf)), footer)
    var stripe_entry = List[UInt8]()
    _pb_varint_field(1, 3, stripe_entry)  # offset
    _pb_varint_field(2, 0, stripe_entry)  # indexLength
    _pb_varint_field(3, UInt64(len(data_region)), stripe_entry)  # dataLength
    _pb_varint_field(4, UInt64(len(sf)), stripe_entry)  # footerLength
    _pb_varint_field(5, 3, stripe_entry)  # numberOfRows
    _pb_message_field(3, stripe_entry, footer)
    _pb_message_field(4, root, footer)
    _pb_message_field(4, _enc_leaf(ORC_KIND_LONG), footer)
    _pb_message_field(4, _enc_leaf(ORC_KIND_LONG), footer)
    _pb_message_field(4, _enc_leaf(ORC_KIND_STRING), footer)
    _pb_varint_field(6, 3, footer)

    var ps = List[UInt8]()
    _pb_varint_field(1, UInt64(len(footer)), ps)
    _pb_varint_field(2, UInt64(ORC_COMPRESSION_NONE), ps)
    _pb_varint_field(3, 262144, ps)
    _pb_varint_field(5, 0, ps)
    _pb_string_field(8000, String("ORC"), ps)

    var f = List[UInt8]()
    f.append(UInt8(ord("O")))
    f.append(UInt8(ord("R")))
    f.append(UInt8(ord("C")))
    for i in range(len(data_region)):
        f.append(data_region[i])
    for i in range(len(sf)):
        f.append(sf[i])
    for i in range(len(footer)):
        f.append(footer[i])
    for i in range(len(ps)):
        f.append(ps[i])
    f.append(UInt8(len(ps)))
    return f^


def _best_unlink(path: String):
    try:
        remove(path)
    except:
        pass


# =============================================================================
# Tests
# =============================================================================


def test_orc_source_ctor_and_schema() raises:
    print("T1: OrcSource ctor + schema + fingerprint stability across copy()")
    var sch = Schema()
    var proj = List[Int]()
    var src = OrcSource((_scratch_dir() + String("/foo.orc")), sch^, proj^)
    var fp1 = src.fingerprint()

    # Clone preserves identity (cache-discrimination contract).
    var c = src.copy()
    var fp2 = c.fingerprint()
    assert_equal(fp1, fp2)

    # Two different paths -> different fingerprints.
    var sch2 = Schema()
    var proj2 = List[Int]()
    var src2 = OrcSource((_scratch_dir() + String("/bar.orc")), sch2^, proj2^)
    var fp3 = src2.fingerprint()
    assert_true(fp1 != fp3)

    # estimate_rows() == -1 (unknown without footer read).
    assert_equal(src.estimate_rows(), -1)
    print("  PASS")


def test_orc_source_projection_disambiguation() raises:
    print("T2: OrcSource projection fingerprint disambiguation")
    var sch = Schema()
    var proj_empty = List[Int]()
    var src_all = OrcSource((_scratch_dir() + String("/x.orc")), sch^, proj_empty^)
    var fp_all = src_all.fingerprint()

    # Different projection -> different fingerprint (same path).
    var sch2 = Schema()
    var proj_02 = List[Int]()
    proj_02.append(0)
    proj_02.append(2)
    var src_02 = OrcSource((_scratch_dir() + String("/x.orc")), sch2^, proj_02^)
    var fp_02 = src_02.fingerprint()
    assert_true(fp_all != fp_02, "empty != [0,2] projection")

    # Order-sensitive: [0,2] != [2,0].
    var sch3 = Schema()
    var proj_20 = List[Int]()
    proj_20.append(2)
    proj_20.append(0)
    var src_20 = OrcSource((_scratch_dir() + String("/x.orc")), sch3^, proj_20^)
    var fp_20 = src_20.fingerprint()
    assert_true(fp_02 != fp_20, "[0,2] != [2,0] (order-sensitive)")
    print("  PASS")


def test_source_variant_orc_arm() raises:
    print("T3: SourceVariant ORC arm tag + accessor round-trip")
    var sch = Schema()
    var proj = List[Int]()
    var src = OrcSource((_scratch_dir() + String("/foo.orc")), sch^, proj^)
    var fp_src = src.fingerprint()
    var sv = SourceVariant(src^)

    assert_equal(Int(sv.tag), Int(SOURCE_VARIANT_ORC), "tag is SOURCE_VARIANT_ORC")
    # The variant dispatches fingerprint() into the inner OrcSource.
    assert_equal(sv.fingerprint(), fp_src, "variant fp == inner src fp")
    # estimate_rows passes through.
    assert_equal(sv.estimate_rows(), -1, "estimate_rows is -1")
    # kind_name -> "orc"
    assert_equal(sv.kind_name(), String("orc"), "kind_name is 'orc'")
    print("  PASS")


def test_source_variant_orc_copy_identity() raises:
    print("T4: SourceVariant.copy() preserves identity byte-for-byte")
    var sch = Schema()
    var proj = List[Int]()
    proj.append(1)
    proj.append(3)
    var src = OrcSource((_scratch_dir() + String("/foo.orc")), sch^, proj^)
    var sv = SourceVariant(src^)
    var fp_sv = sv.fingerprint()

    var sv_clone = sv.copy()
    assert_equal(sv_clone.fingerprint(), fp_sv, "copy preserves fingerprint")
    assert_equal(Int(sv_clone.tag), Int(SOURCE_VARIANT_ORC), "copy preserves tag")
    print("  PASS")


def test_orc_projected_e2e_two_of_three() raises:
    print("T5: read_orc_bytes_projected on a 3-col file, project [0, 2]")
    var bytes = _build_3col_orc_file()

    # First sanity: full read returns 3 cols.
    var rb_full = read_orc_bytes(Span(bytes))
    assert_equal(rb_full.num_columns(), 3, "full read sees 3 cols")
    assert_equal(rb_full.num_rows(), 3, "full read sees 3 rows")

    # Project [a, c] = [0, 2].
    var proj = List[Int]()
    proj.append(0)
    proj.append(2)
    var rb_proj = read_orc_bytes_projected(Span(bytes), proj)
    assert_equal(rb_proj.num_columns(), 2, "projected has 2 cols")
    assert_equal(rb_proj.num_rows(), 3, "projected has 3 rows")

    # Column 0 of projection is the original 'a' (bigint).
    ref a = rb_proj.column_at(0)
    var aa = a.as_primitive[DType.int64]()
    assert_equal(Int(aa.get(0)), 10, "a[0]")
    assert_equal(Int(aa.get(1)), 20, "a[1]")
    assert_equal(Int(aa.get(2)), 30, "a[2]")

    # Column 1 of projection is the original 'c' (string).
    ref c = rb_proj.column_at(1)
    var cc = c.as_string()
    assert_equal(cc.get(0), String("alpha"), "c[0]")
    assert_equal(cc.get(1), String("beta"), "c[1]")
    assert_equal(cc.get(2), String("delta"), "c[2]")
    print("  PASS")


def test_orc_projected_empty_equals_full() raises:
    print("T6: read_orc_bytes_projected with empty projection == read_orc_bytes")
    var bytes = _build_3col_orc_file()
    var rb_full = read_orc_bytes(Span(bytes))
    var proj = List[Int]()
    var rb_empty_proj = read_orc_bytes_projected(Span(bytes), proj)

    assert_equal(rb_full.num_rows(), rb_empty_proj.num_rows(), "rows match")
    assert_equal(rb_full.num_columns(), rb_empty_proj.num_columns(), "cols match")

    # Spot-check value parity in column 1 ('b' = bigint, 100/200/300).
    ref b_full = rb_full.column_at(1)
    var bf = b_full.as_primitive[DType.int64]()
    ref b_proj = rb_empty_proj.column_at(1)
    var bp = b_proj.as_primitive[DType.int64]()
    assert_equal(Int(bf.get(0)), Int(bp.get(0)), "b[0] matches")
    assert_equal(Int(bf.get(2)), Int(bp.get(2)), "b[2] matches")
    print("  PASS")


def test_logical_plan_scan_from_source_orc() raises:
    print("T7: LogicalPlan.scan_from_source(OrcSource) sets SOURCE_ORC type")
    var sch = Schema()
    var proj = List[Int]()
    var src = OrcSource((_scratch_dir() + String("/foo.orc")), sch^, proj^)
    var sv = SourceVariant(src^)
    var plan = LogicalPlan.scan_from_source(sv^, Schema())
    ref scan = plan._scan.value()[]
    assert_equal(Int(scan.source_type), Int(SOURCE_ORC), "source_type is SOURCE_ORC")
    assert_equal(scan.source_path, (_scratch_dir() + String("/foo.orc")), "source_path derived")
    print("  PASS")


def main() raises:
    test_orc_source_ctor_and_schema()
    test_orc_source_projection_disambiguation()
    test_source_variant_orc_arm()
    test_source_variant_orc_copy_identity()
    test_orc_projected_e2e_two_of_three()
    test_orc_projected_empty_equals_full()
    test_logical_plan_scan_from_source_orc()
    print("test_orc_source_lazy_e2e: ALL PASS")
