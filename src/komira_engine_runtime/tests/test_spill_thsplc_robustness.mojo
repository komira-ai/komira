# =============================================================================
# test_spill_thsplc_robustness.mojo — THSPLC column codec REJECTS bad chunks.
# =============================================================================
#
# SPILL-FU-DECODE-ROBUSTNESS / Task #10. The happy-path round-trip lives in
# test_thsplc_roundtrip.mojo; THIS suite proves the decoder REJECTS truncated /
# corrupt chunks with a typed `raise` (NOT a debug_assert that elides in
# release, NOT a silent out-of-bounds read) on BOTH decode_copy AND
# decode_zerocopy.
#
# Bug-fix protocol: every case here would have mis-decoded / OOB'd / passed
# WITHOUT the release-build guards added to thsplc.mojo
# (_parse_header n_cols/total-length sanity, _validate_descriptor per-column
# bounds, _check_fingerprint). Each case asserts the SPECIFIC typed error.
#
# Corruption matrix (each proven-rejected on both decode paths):
#   * truncation: mid-header, mid-descriptor-table, mid-body, off-by-one short
#   * corrupt magic / wrong version
#   * header declares wrong total length (too big)
#   * schema col-count mismatch
#   * schema fingerprint mismatch (same col-count, different field type)
#   * descriptor region_offset out of bounds (the zerocopy UAF case)
#   * descriptor sub-region (values_len) overruns the chunk
#   * descriptor absurd (near-2^64) length
#   * dict-in-zerocopy raises; encode-dict raises
#   * ENCODE side: a `validity_len` / `offsets_len` that does not fit its
#     UInt32 wire field is REFUSED in pass 1, before the chunk is allocated
#     (VARHEAP-OFFSET-CEILING's spill-format sibling, 2026-09-23)
#
# The descriptor-OOB cases are the load-bearing UAF-prevention proof: the
# decoder MUST raise BEFORE from_borrowed_view builds a view aliasing past the
# chunk end.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion

from komira_engine_runtime.spill.thsplc import (
    THSPLC_WIRE_U32_MAX,
    THSPLCDecoder,
    THSPLCEncoder,
    _thsplc_wire_u32,
)


# =============================================================================
# THSPLC on-wire offsets (mirror thsplc_header.mojo + _ColumnDescriptor).
# =============================================================================

comptime HDR_VERSION_OFF: Int = 8  # UInt32
comptime HDR_NCOLS_OFF: Int = 12  # UInt32
comptime HDR_BODYLEN_OFF: Int = 16  # UInt64
comptime HDR_FINGERPRINT_OFF: Int = 32  # UInt64
comptime HEADER_SIZE: Int = 96
comptime DESCRIPTOR_SIZE: Int = 48

# _ColumnDescriptor sub-offsets (relative to descriptor start).
comptime DESC_REGION_OFFSET_OFF: Int = 24  # UInt64
comptime DESC_VALUES_LEN_OFF: Int = 40  # UInt64


# =============================================================================
# Helpers — build a valid chunk, then make truncated / mutable copies.
# =============================================================================


def _int64_schema(name0: String, name1: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(name0, ArrowType.INT64, False))
    sb.add_field(Field(name1, ArrowType.INT64, False))
    return sb.build()


def _i64_list(*vals: Int) -> List[Scalar[DType.int64]]:
    var out = List[Scalar[DType.int64]]()
    for v in vals:
        out.append(Int64(v))
    return out^


def _build_valid_chunk() raises -> SharedAlignedBuffer[HeapRegion]:
    """A valid 2-column INT64 THSPLC chunk."""
    var c0 = _i64_list(1, 2, 3, 4, 5, 6, 7, 8)
    var c1 = _i64_list(-100, 0, 100, 200, 300, 400, 500, 600)
    var cols = Slab[Column[HeapRegion]].create(2)
    cols.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(c0)
        )
    )
    cols.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(c1)
        )
    )
    var batch = RecordBatch.from_typed_columns_slab(_int64_schema("a", "b"), cols^)
    return THSPLCEncoder.encode(batch^)


def _copy_prefix(
    src: SharedAlignedBuffer[HeapRegion], n: Int
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Copy the first `n` bytes of `src` into a fresh owning SAB. Used to
    build truncated chunks (n < src.len())."""
    var oab = OwnedAlignedBuffer(capacity=max(n, 1))
    oab.set_length(Int64(n))
    if n > 0:
        oab.copy_from_view(src.view_range_ro(0, n))
    return SharedAlignedBuffer[HeapRegion].from_owned(oab^)


def _mutable_full_copy(
    src: SharedAlignedBuffer[HeapRegion],
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Full-length owning copy of `src` (so the caller can corrupt fields
    via write_*_le_at without touching the original)."""
    return _copy_prefix(src, src.len())


# =============================================================================
# Truncation cases — both decode paths must raise (not OOB).
# =============================================================================


def _assert_both_paths_raise(
    chunk: SharedAlignedBuffer[HeapRegion],
    contains: String,
    case_name: String,
) raises:
    """Run decode_copy + decode_zerocopy on `chunk` (each gets its own
    full-length copy) and assert BOTH raise an error containing `contains`."""
    with assert_raises(contains=contains):
        _ = THSPLCDecoder.decode_copy(
            _mutable_full_copy(chunk), _int64_schema("a", "b")
        )
    with assert_raises(contains=contains):
        _ = THSPLCDecoder.decode_zerocopy(
            _mutable_full_copy(chunk), _int64_schema("a", "b")
        )


def test_truncated_mid_header() raises:
    # 50 bytes < 96-byte header → parse_thsplc_header raises "shorter than".
    var trunc = _copy_prefix(_build_valid_chunk(), 50)
    _assert_both_paths_raise(trunc, "shorter than header", "mid-header")


def test_truncated_off_by_one_header() raises:
    # 95 bytes = header minus one byte.
    var trunc = _copy_prefix(_build_valid_chunk(), 95)
    _assert_both_paths_raise(trunc, "shorter than header", "off-by-one-header")


def test_truncated_mid_descriptor_table() raises:
    # Header (96) + part of the first descriptor (96+20). The full-length
    # cross-check in _parse_header sees chunk_len < declared_total and the
    # n_cols/descriptor-section sanity sees the descriptor section overrun.
    var trunc = _copy_prefix(_build_valid_chunk(), HEADER_SIZE + 20)
    _assert_both_paths_raise(trunc, "THSPLCDecoder", "mid-descriptor")


def test_truncated_mid_body() raises:
    # Cut the chunk somewhere inside the per-column buffer region (after the
    # descriptor table). The declared total exceeds the actual length.
    var valid = _build_valid_chunk()
    var cut = HEADER_SIZE + 2 * DESCRIPTOR_SIZE + 16
    var trunc = _copy_prefix(valid, cut)
    _assert_both_paths_raise(trunc, "THSPLCDecoder", "mid-body")


def test_truncated_off_by_one_short() raises:
    # Drop exactly the last byte (the trailing magic region) — declared_total
    # is one byte more than the chunk.
    var valid = _build_valid_chunk()
    var trunc = _copy_prefix(valid, valid.len() - 1)
    _assert_both_paths_raise(trunc, "THSPLCDecoder", "off-by-one-short")


# =============================================================================
# Corrupt magic / version.
# =============================================================================


def test_corrupt_magic() raises:
    var chunk = _mutable_full_copy(_build_valid_chunk())
    chunk.write_u8_at(0, UInt8(0xFF))  # clobber 'T'
    _assert_both_paths_raise(chunk, "bad magic", "corrupt-magic")


def test_wrong_version() raises:
    var chunk = _mutable_full_copy(_build_valid_chunk())
    chunk.write_u32_le_at(HDR_VERSION_OFF, UInt32(99))
    _assert_both_paths_raise(chunk, "unknown version", "wrong-version")


# =============================================================================
# Header declares wrong total length.
# =============================================================================


def test_header_body_length_too_big() raises:
    # Inflate body_length so declared_total > actual chunk length.
    var chunk = _mutable_full_copy(_build_valid_chunk())
    chunk.write_u64_le_at(HDR_BODYLEN_OFF, UInt64(1 << 20))
    _assert_both_paths_raise(chunk, "header declares", "bodylen-too-big")


# =============================================================================
# Schema col-count mismatch.
# =============================================================================


def test_col_count_mismatch() raises:
    var chunk = _build_valid_chunk()  # 2 cols
    # Restore with a 1-column schema.
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    with assert_raises(contains="fields but chunk has"):
        _ = THSPLCDecoder.decode_copy(_mutable_full_copy(chunk), sb.build())
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("a", ArrowType.INT64, False))
    with assert_raises(contains="fields but chunk has"):
        _ = THSPLCDecoder.decode_zerocopy(_mutable_full_copy(chunk), sb2.build())


# =============================================================================
# Schema fingerprint mismatch (same col-count, different types).
# =============================================================================


def _int64_float64_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.FLOAT64, False))
    return sb.build()


def test_fingerprint_mismatch() raises:
    # Chunk was encoded with [INT64, INT64]; restore with [INT64, FLOAT64].
    # Same col-count (so col-count check passes) but the fingerprint differs.
    var chunk = _build_valid_chunk()
    with assert_raises(contains="fingerprint mismatch"):
        _ = THSPLCDecoder.decode_copy(
            _mutable_full_copy(chunk), _int64_float64_schema()
        )
    with assert_raises(contains="fingerprint mismatch"):
        _ = THSPLCDecoder.decode_zerocopy(
            _mutable_full_copy(chunk), _int64_float64_schema()
        )


# =============================================================================
# Descriptor out-of-bounds — the zerocopy UAF-prevention proof.
# =============================================================================


def _descriptor_field_offset(col_idx: Int, field_off: Int) -> Int:
    """Absolute byte offset of a descriptor field within the chunk."""
    return HEADER_SIZE + col_idx * DESCRIPTOR_SIZE + field_off


def test_descriptor_region_offset_out_of_bounds() raises:
    # Point column 0's region_offset PAST the chunk end. WITHOUT
    # _validate_descriptor, decode_zerocopy would call from_borrowed_view at a
    # bogus offset (debug_assert-only) and alias past the chunk — a UAF in
    # release. The guard must raise FIRST.
    var chunk = _mutable_full_copy(_build_valid_chunk())
    var chunk_len = chunk.len()
    chunk.write_u64_le_at(
        _descriptor_field_offset(0, DESC_REGION_OFFSET_OFF),
        UInt64(chunk_len + 4096),
    )
    _assert_both_paths_raise(chunk, "past the chunk end", "region-offset-oob")


def test_descriptor_values_len_overruns() raises:
    # Keep region_offset valid but inflate values_len so the region END
    # overruns the chunk. The sub-region bounds check must catch it before
    # the values view/borrow is built.
    var chunk = _mutable_full_copy(_build_valid_chunk())
    var chunk_len = chunk.len()
    chunk.write_u64_le_at(
        _descriptor_field_offset(0, DESC_VALUES_LEN_OFF),
        UInt64(chunk_len * 2),
    )
    _assert_both_paths_raise(chunk, "out of bounds", "values-len-overrun")


def test_descriptor_absurd_length() raises:
    # values_len near 2^64 → Int64 reinterpretation is negative → caught by
    # the negative-length guard in _validate_descriptor.
    var chunk = _mutable_full_copy(_build_valid_chunk())
    chunk.write_u64_le_at(
        _descriptor_field_offset(0, DESC_VALUES_LEN_OFF),
        UInt64(0xFFFFFFFFFFFFFFFF),
    )
    _assert_both_paths_raise(chunk, "negative", "absurd-length")


# =============================================================================
# Header n_cols absurd → descriptor section overruns the chunk.
# =============================================================================


def test_ncols_absurd() raises:
    # Inflate n_cols so the descriptor section alone overruns the chunk.
    # _parse_header's descriptor-section sanity must reject it before the
    # per-column walk. (Restore with a matching-count schema is impossible to
    # build cheaply, so we just assert the header-level guard fires.)
    var chunk = _mutable_full_copy(_build_valid_chunk())
    chunk.write_u32_le_at(HDR_NCOLS_OFF, UInt32(1 << 20))
    with assert_raises(contains="descriptor section"):
        _ = THSPLCDecoder.decode_copy(
            _mutable_full_copy(chunk), _int64_schema("a", "b")
        )
    with assert_raises(contains="descriptor section"):
        _ = THSPLCDecoder.decode_zerocopy(
            _mutable_full_copy(chunk), _int64_schema("a", "b")
        )


# =============================================================================
# Dictionary cases — encode-dict raises; the zerocopy dict raise is reached
# only with a valid dict body, which encode refuses to produce, so we assert
# the encode-side rejection (the v0.4 contract).
# =============================================================================


def test_encode_dictionary_raises() raises:
    # The encoder reads each COLUMN's arrow_type. Force a column to report
    # DICTIONARY and assert encode raises (v0.4: planner dictionary-decodes
    # upstream of spill; DICTIONARY on the wire is deferred).
    var forced = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(_i64_list(1, 2, 3))
    )
    forced.arrow_type = ArrowType.DICTIONARY
    var dcols = Slab[Column[HeapRegion]].create(1)
    dcols.append(forced^)
    var sb = SchemaBuilder()
    sb.add_field(Field("d", ArrowType.DICTIONARY, False))
    var batch = RecordBatch.from_typed_columns_slab(sb.build(), dcols^)
    with assert_raises(contains="DICTIONARY"):
        _ = THSPLCEncoder.encode(batch^)


# =============================================================================
# ENCODE-side: the two UInt32 descriptor fields (2026-09-23)
# =============================================================================
#
# `validity_len` and `offsets_len` are the only 32-bit lengths in a descriptor
# whose other lengths and offsets are all 64-bit. The encoder narrowed them
# with a bare `UInt32(...)`, and pass 2 then copied `Int(d.offsets_len)` -- the
# NARROWED value -- so a wrap wrote the offsets region SHORT and the decoder,
# reading the same narrowed field, rebuilt the column from the wrong bytes.
# None of the DECODE-side guards above can see that: every region still lies
# inside the chunk.


def test_wire_u32_admits_the_ceiling_and_refuses_past_it() raises:
    """The field's width, both edges: 2**32-1 round-trips, 2**32 is refused,
    a negative length is refused (an upstream arithmetic bug, not a size)."""
    assert_equal(THSPLC_WIRE_U32_MAX, (1 << 32) - 1)
    assert_equal(
        Int(_thsplc_wire_u32(THSPLC_WIRE_U32_MAX, "offsets_len", 0)),
        THSPLC_WIRE_U32_MAX,
    )
    with assert_raises(contains="offsets_len"):
        _ = _thsplc_wire_u32(1 << 32, "offsets_len", 0)
    with assert_raises(contains="validity_len"):
        _ = _thsplc_wire_u32(-1, "validity_len", 0)


def test_encode_refuses_an_offsets_region_past_the_u32_field() raises:
    """THROUGH `encode`: a STRING column of 2**30 - 1 rows has an offsets
    region of exactly 2**32 bytes, one past the field.

    The column's `_length` is forged (the way `test_encode_dictionary_raises`
    forges `arrow_type`): pass 1 sizes the region from `_length` alone, so the
    refusal it must make is reached without materialising 4 GiB of offsets. ⚠
    That is also why the refusal has to be in PASS 1 -- before the guard, this
    call went on to allocate and zero the full 4 GiB chunk, then wrote an
    offsets region of `UInt32(2**32) == 0` bytes."""
    var vals = List[String]()
    vals.append("a")
    vals.append("bb")
    vals.append("ccc")
    var forced = Column.from_string(StringArray.from_strings(vals))
    forced._length = (1 << 30) - 1
    var cols = Slab[Column[HeapRegion]].create(1)
    cols.append(forced^)
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    var batch = RecordBatch.from_typed_columns_slab(sb.build(), cols^)
    with assert_raises(contains="offsets_len"):
        _ = THSPLCEncoder.encode(batch^)


def main() raises:
    test_truncated_mid_header()
    print("test_truncated_mid_header PASSED")
    test_truncated_off_by_one_header()
    print("test_truncated_off_by_one_header PASSED")
    test_truncated_mid_descriptor_table()
    print("test_truncated_mid_descriptor_table PASSED")
    test_truncated_mid_body()
    print("test_truncated_mid_body PASSED")
    test_truncated_off_by_one_short()
    print("test_truncated_off_by_one_short PASSED")
    test_corrupt_magic()
    print("test_corrupt_magic PASSED")
    test_wrong_version()
    print("test_wrong_version PASSED")
    test_header_body_length_too_big()
    print("test_header_body_length_too_big PASSED")
    test_col_count_mismatch()
    print("test_col_count_mismatch PASSED")
    test_fingerprint_mismatch()
    print("test_fingerprint_mismatch PASSED")
    test_descriptor_region_offset_out_of_bounds()
    print("test_descriptor_region_offset_out_of_bounds PASSED")
    test_descriptor_values_len_overruns()
    print("test_descriptor_values_len_overruns PASSED")
    test_descriptor_absurd_length()
    print("test_descriptor_absurd_length PASSED")
    test_ncols_absurd()
    print("test_ncols_absurd PASSED")
    test_encode_dictionary_raises()
    print("test_encode_dictionary_raises PASSED")
    test_wire_u32_admits_the_ceiling_and_refuses_past_it()
    print("test_wire_u32_admits_the_ceiling_and_refuses_past_it PASSED")
    test_encode_refuses_an_offsets_region_past_the_u32_field()
    print("test_encode_refuses_an_offsets_region_past_the_u32_field PASSED")
    print("ALL THSPLC ROBUSTNESS TESTS PASSED")
