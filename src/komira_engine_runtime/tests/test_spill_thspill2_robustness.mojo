# =============================================================================
# test_spill_thspill2_robustness.mojo — THSPILL2 row codec REJECTS bad chunks.
# =============================================================================
#
# Row-grain sibling of test_spill_thsplc_robustness.mojo. A chunk read from
# storage is untrusted: each case corrupts one header field of a valid chunk
# (or truncates it) and requires a typed error from BOTH decode_copy and
# decode_zerocopy, naming the cause, before any body allocation or slice. The
# codec also delivers the header's schema_fingerprint to the conformer's
# from_bytes, which enforces it (the codec is body-opaque).
#
# Cases:
#   * truncation: empty chunk, mid-header, off-by-one header, mid-body,
#     off-by-one short
#   * corrupt magic, wrong version
#   * body_length: past the end by one byte, far past the end, and >= 2^63
#   * row_count >= 2^63
#   * unknown flag bits, the compressed flag, an uncompressed_body_length
#     that differs from body_length
#   * fingerprint mismatch, enforced by the conformer
# =============================================================================

from std.testing import assert_equal, assert_true, assert_raises

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_buffer.byte_view import ByteView
from komira_buffer.heap_region import HeapRegion

from komira_engine_runtime.spill.spill_storage import ChunkId, SpillStorage
from komira_engine_runtime.spill.thspill2 import (
    Spillable,
    THSpill2Encoder,
    THSpill2Decoder,
)


# =============================================================================
# THSPILL2 on-wire offsets (mirror thspill2_header.mojo).
# =============================================================================

comptime HDR_VERSION_OFF: Int = 4  # UInt32
comptime HDR_BODYLEN_OFF: Int = 8  # UInt64
comptime HDR_ROWCOUNT_OFF: Int = 16  # UInt64
comptime HDR_UNCOMPRESSED_OFF: Int = 32  # UInt64
comptime HDR_FLAGS_OFF: Int = 40  # UInt32
comptime HEADER_SIZE: Int = 96

# The fingerprint the well-behaved conformer expects (and that the encoder
# writes into the header for a healthy chunk).
comptime EXPECTED_FINGERPRINT: UInt64 = 0xABCDEF


# =============================================================================
# In-memory SpillStorage that lets the test CORRUPT the stored bytes before a
# read. write_chunk copies the incoming bytes into its own owning SAB; the
# test mutates that SAB via corrupt_*; read_chunk borrows it (Arc-clone).
# =============================================================================


struct _MutableMemStorage(SpillStorage):
    var _chunks: Slab[SharedAlignedBuffer[HeapRegion]]
    var _live: Int64

    def __init__(out self):
        self._chunks = Slab[SharedAlignedBuffer[HeapRegion]].create(8)
        self._live = 0

    def write_chunk(
        mut self, var bytes: SharedAlignedBuffer[HeapRegion]
    ) raises -> ChunkId:
        # Own a private full-length copy so the test can mutate it.
        var n = bytes.len()
        var oab = OwnedAlignedBuffer(capacity=max(n, 1))
        oab.set_length(Int64(n))
        if n > 0:
            oab.copy_from_view(bytes.view_range_ro(0, n))
        var idx = len(self._chunks)
        self._live += Int64(n)
        self._chunks.append(SharedAlignedBuffer[HeapRegion].from_owned(oab^))
        _ = bytes^
        return ChunkId(UInt64(idx))

    def read_chunk(
        self, chunk_id: ChunkId
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        var idx = Int(chunk_id._unsafe_value())
        if idx < 0 or idx >= len(self._chunks):
            raise Error("_MutableMemStorage.read_chunk: bad chunk id")
        ref stored = self._chunks[idx]
        return SharedAlignedBuffer[HeapRegion].from_borrowed_view(
            stored, Int64(0), stored.length()
        )

    def release_chunk(mut self, chunk_id: ChunkId) raises:
        pass

    def nbytes_in_use(self) -> Int64:
        return self._live

    def sync(mut self) raises:
        pass

    def corrupt_u8(mut self, chunk_id: ChunkId, off: Int, val: UInt8) raises:
        var idx = Int(chunk_id._unsafe_value())
        self._chunks[idx].write_u8_at(off, val)

    def corrupt_u32(mut self, chunk_id: ChunkId, off: Int, val: UInt32) raises:
        var idx = Int(chunk_id._unsafe_value())
        self._chunks[idx].write_u32_le_at(off, val)

    def corrupt_u64(mut self, chunk_id: ChunkId, off: Int, val: UInt64) raises:
        var idx = Int(chunk_id._unsafe_value())
        self._chunks[idx].write_u64_le_at(off, val)

    def truncate(mut self, chunk_id: ChunkId, new_len: Int) raises:
        """Replace the stored chunk with a prefix of `new_len` bytes."""
        var idx = Int(chunk_id._unsafe_value())
        ref stored = self._chunks[idx]
        var oab = OwnedAlignedBuffer(capacity=max(new_len, 1))
        oab.set_length(Int64(new_len))
        if new_len > 0:
            oab.copy_from_view(stored.view_range_ro(0, new_len))
        self._chunks[idx] = SharedAlignedBuffer[HeapRegion].from_owned(oab^)

    def stored_len(self, chunk_id: ChunkId) -> Int:
        var idx = Int(chunk_id._unsafe_value())
        return self._chunks[idx].len()


# =============================================================================
# A FINGERPRINT-ENFORCING RowBlock conformer. Unlike the happy-path test stub,
# from_bytes here RAISES on a fingerprint mismatch — the documented production
# contract layer. This proves the codec delivers the header fingerprint through
# to the conformer so the conformer can reject a wrong-schema restore.
# =============================================================================


struct _StrictRowBlock(Spillable):
    var _bytes: SharedAlignedBuffer[HeapRegion]
    var _row_count: Int64
    var _fingerprint: UInt64

    def __init__(
        out self,
        var bytes: SharedAlignedBuffer[HeapRegion],
        row_count: Int64,
        fingerprint: UInt64,
    ):
        self._bytes = bytes^
        self._row_count = row_count
        self._fingerprint = fingerprint

    def row_count(self) -> Int64:
        return self._row_count

    def nbytes(self) -> Int64:
        return self._bytes.length()

    def schema_fingerprint(self) -> UInt64:
        return self._fingerprint

    def as_byte_view[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self) -> ByteView[origin]:
        var inner_view = self._bytes.as_view()
        return rebind[ByteView[origin]](inner_view)

    @staticmethod
    def from_bytes(
        var bytes: SharedAlignedBuffer[HeapRegion],
        row_count: Int64,
        schema_fingerprint: UInt64,
    ) raises -> Self:
        # PRODUCTION FINGERPRINT CONTRACT: reject a fingerprint that does not
        # match this conformer's expected schema identity.
        if schema_fingerprint != EXPECTED_FINGERPRINT:
            raise Error(
                "_StrictRowBlock.from_bytes: schema fingerprint mismatch —"
                " header declares "
                + String(schema_fingerprint)
                + " but this conformer expects "
                + String(EXPECTED_FINGERPRINT)
            )
        return Self(bytes^, row_count, schema_fingerprint)


# =============================================================================
# Fixture: a valid 32-byte-stride row block encoded into storage.
# =============================================================================

comptime ROW_STRIDE: Int = 32


def _build_block(row_count: Int) raises -> _StrictRowBlock:
    var total = row_count * ROW_STRIDE
    var oab = OwnedAlignedBuffer(capacity=max(total, 1))
    oab.set_length(Int64(total))
    oab.zero()
    for i in range(row_count):
        oab.write_i64_le_at(i * ROW_STRIDE, Int64(i))
        oab.write_i64_le_at(i * ROW_STRIDE + 8, Int64(i * 7 + 3))
    return _StrictRowBlock(
        SharedAlignedBuffer[HeapRegion].from_owned(oab^),
        Int64(row_count),
        EXPECTED_FINGERPRINT,
    )


def _encode_valid(
    mut storage: _MutableMemStorage, row_count: Int
) raises -> ChunkId:
    return THSpill2Encoder[_StrictRowBlock].encode(
        storage, _build_block(row_count)
    )


def _assert_both_paths_raise(
    mut storage: _MutableMemStorage,
    cid: ChunkId,
    contains: String,
) raises:
    with assert_raises(contains=contains):
        _ = THSpill2Decoder[_StrictRowBlock].decode_copy(storage, cid)
    with assert_raises(contains=contains):
        _ = THSpill2Decoder[_StrictRowBlock].decode_zerocopy(storage, cid)


# =============================================================================
# Sanity: the valid chunk round-trips through BOTH paths (guards don't false-
# positive on a healthy chunk).
# =============================================================================


def test_valid_chunk_roundtrips() raises:
    var storage = _MutableMemStorage()
    var cid = _encode_valid(storage, 16)
    var rc = THSpill2Decoder[_StrictRowBlock].decode_copy(storage, cid)
    assert_equal(Int(rc.row_count()), 16)
    var rz = THSpill2Decoder[_StrictRowBlock].decode_zerocopy(storage, cid)
    assert_equal(Int(rz.row_count()), 16)
    _ = storage^


# =============================================================================
# Truncation.
# =============================================================================


def test_truncated_empty_chunk() raises:
    var storage = _MutableMemStorage()
    var cid = _encode_valid(storage, 16)
    storage.truncate(cid, 0)
    _assert_both_paths_raise(storage, cid, "shorter than header")
    _ = storage^


def test_truncated_mid_header() raises:
    var storage = _MutableMemStorage()
    var cid = _encode_valid(storage, 16)
    storage.truncate(cid, 50)  # < 96-byte header
    _assert_both_paths_raise(storage, cid, "shorter than header")
    _ = storage^


def test_truncated_off_by_one_header() raises:
    var storage = _MutableMemStorage()
    var cid = _encode_valid(storage, 16)
    storage.truncate(cid, 95)
    _assert_both_paths_raise(storage, cid, "shorter than header")
    _ = storage^


def test_truncated_mid_body() raises:
    var storage = _MutableMemStorage()
    var cid = _encode_valid(storage, 16)
    # Header (96) + half the body → declared_total > stored length.
    storage.truncate(cid, HEADER_SIZE + 16 * ROW_STRIDE // 2)
    _assert_both_paths_raise(storage, cid, "header declares")
    _ = storage^


def test_truncated_off_by_one_short() raises:
    var storage = _MutableMemStorage()
    var cid = _encode_valid(storage, 16)
    storage.truncate(cid, storage.stored_len(cid) - 1)
    _assert_both_paths_raise(storage, cid, "header declares")
    _ = storage^


# =============================================================================
# Corrupt magic / version.
# =============================================================================


def test_corrupt_magic() raises:
    var storage = _MutableMemStorage()
    var cid = _encode_valid(storage, 16)
    storage.corrupt_u8(cid, 0, UInt8(0xFF))
    _assert_both_paths_raise(storage, cid, "bad magic")
    _ = storage^


def test_wrong_version() raises:
    var storage = _MutableMemStorage()
    var cid = _encode_valid(storage, 16)
    storage.corrupt_u32(cid, HDR_VERSION_OFF, UInt32(99))
    _assert_both_paths_raise(storage, cid, "unknown version")
    _ = storage^


# =============================================================================
# Header declares body_length too big / absurd.
# =============================================================================


def test_body_length_too_big() raises:
    var storage = _MutableMemStorage()
    var cid = _encode_valid(storage, 16)
    storage.corrupt_u64(cid, HDR_BODYLEN_OFF, UInt64(1 << 20))
    storage.corrupt_u64(cid, HDR_UNCOMPRESSED_OFF, UInt64(1 << 20))
    _assert_both_paths_raise(storage, cid, "header declares")
    _ = storage^


def test_body_length_absurd() raises:
    # body_length near 2^64 → Int64 reinterpretation negative → caught by the
    # absurd-body-length guard BEFORE the cross-check (which would otherwise
    # falsely pass on a negative declared_total).
    var storage = _MutableMemStorage()
    var cid = _encode_valid(storage, 16)
    storage.corrupt_u64(cid, HDR_BODYLEN_OFF, UInt64(0xFFFFFFFFFFFFFFFF))
    _assert_both_paths_raise(storage, cid, "absurd")
    _ = storage^


def test_body_length_one_past_end() raises:
    var storage = _MutableMemStorage()
    var cid = _encode_valid(storage, 16)
    var body = storage.stored_len(cid) - HEADER_SIZE
    storage.corrupt_u64(cid, HDR_BODYLEN_OFF, UInt64(body + 1))
    storage.corrupt_u64(cid, HDR_UNCOMPRESSED_OFF, UInt64(body + 1))
    _assert_both_paths_raise(storage, cid, "header declares")
    _ = storage^


def test_body_length_huge_but_positive() raises:
    # 2^62 is a valid Int64: the length check, not the sign check, refuses it,
    # and it must do so without allocating the declared size.
    var storage = _MutableMemStorage()
    var cid = _encode_valid(storage, 16)
    storage.corrupt_u64(cid, HDR_BODYLEN_OFF, UInt64(1) << 62)
    storage.corrupt_u64(cid, HDR_UNCOMPRESSED_OFF, UInt64(1) << 62)
    _assert_both_paths_raise(storage, cid, "header declares")
    _ = storage^


def test_row_count_absurd() raises:
    var storage = _MutableMemStorage()
    var cid = _encode_valid(storage, 16)
    storage.corrupt_u64(cid, HDR_ROWCOUNT_OFF, UInt64(1) << 63)
    _assert_both_paths_raise(storage, cid, "row_count")
    _ = storage^


def test_unknown_flag_bits() raises:
    var storage = _MutableMemStorage()
    var cid = _encode_valid(storage, 16)
    storage.corrupt_u32(cid, HDR_FLAGS_OFF, UInt32(0x100))
    _assert_both_paths_raise(storage, cid, "unknown bits")
    _ = storage^


def test_compressed_flag_refused() raises:
    var storage = _MutableMemStorage()
    var cid = _encode_valid(storage, 16)
    storage.corrupt_u32(cid, HDR_FLAGS_OFF, UInt32(1))
    _assert_both_paths_raise(storage, cid, "compressed")
    _ = storage^


def test_uncompressed_length_mismatch() raises:
    var storage = _MutableMemStorage()
    var cid = _encode_valid(storage, 16)
    storage.corrupt_u64(cid, HDR_UNCOMPRESSED_OFF, UInt64(7))
    _assert_both_paths_raise(storage, cid, "uncompressed_body_length")
    _ = storage^


def test_sort_key_flag_is_accepted() raises:
    # Bit 1 is a known flag: the guard on unknown bits must not refuse it.
    var storage = _MutableMemStorage()
    var cid = _encode_valid(storage, 16)
    storage.corrupt_u32(cid, HDR_FLAGS_OFF, UInt32(2))
    var r = THSpill2Decoder[_StrictRowBlock].decode_copy(storage, cid)
    assert_equal(Int(r.row_count()), 16)
    _ = storage^


# =============================================================================
# Fingerprint mismatch — enforced at the conformer layer; the codec must
# DELIVER the corrupt header fingerprint through to from_bytes unchanged.
# =============================================================================


def test_fingerprint_mismatch_enforced_by_conformer() raises:
    var storage = _MutableMemStorage()
    var cid = _encode_valid(storage, 16)
    # Clobber the header fingerprint (bytes 24..31). The codec delivers this
    # to from_bytes, which raises.
    storage.corrupt_u64(cid, 24, UInt64(0xDEADBEEF))
    _assert_both_paths_raise(storage, cid, "fingerprint mismatch")
    _ = storage^


def main() raises:
    test_truncated_empty_chunk()
    print("test_truncated_empty_chunk PASSED")
    test_body_length_one_past_end()
    print("test_body_length_one_past_end PASSED")
    test_body_length_huge_but_positive()
    print("test_body_length_huge_but_positive PASSED")
    test_row_count_absurd()
    print("test_row_count_absurd PASSED")
    test_unknown_flag_bits()
    print("test_unknown_flag_bits PASSED")
    test_compressed_flag_refused()
    print("test_compressed_flag_refused PASSED")
    test_uncompressed_length_mismatch()
    print("test_uncompressed_length_mismatch PASSED")
    test_sort_key_flag_is_accepted()
    print("test_sort_key_flag_is_accepted PASSED")
    test_valid_chunk_roundtrips()
    print("test_valid_chunk_roundtrips PASSED")
    test_truncated_mid_header()
    print("test_truncated_mid_header PASSED")
    test_truncated_off_by_one_header()
    print("test_truncated_off_by_one_header PASSED")
    test_truncated_mid_body()
    print("test_truncated_mid_body PASSED")
    test_truncated_off_by_one_short()
    print("test_truncated_off_by_one_short PASSED")
    test_corrupt_magic()
    print("test_corrupt_magic PASSED")
    test_wrong_version()
    print("test_wrong_version PASSED")
    test_body_length_too_big()
    print("test_body_length_too_big PASSED")
    test_body_length_absurd()
    print("test_body_length_absurd PASSED")
    test_fingerprint_mismatch_enforced_by_conformer()
    print("test_fingerprint_mismatch_enforced_by_conformer PASSED")
    print("ALL THSPILL2 ROBUSTNESS TESTS PASSED")
