# =============================================================================
# test_thspill2_zerocopy.mojo — THSPILL2 row codec copy + 0-copy restore.
# =============================================================================
#
# Exercises `THSpill2Encoder.encode` and `THSpill2Decoder.decode_copy` /
# `.decode_zerocopy` for:
#   (a) fixed-width rows (32-byte stride flat block)
#   (b) var-width rows (fixed prefix + trailing offsets/var-data region)
#   (c) empty body (0 rows)
#   (d) lifetime: a zero-copy restore stays valid after the read handle is
#       gone, after the storage releases the chunk and after the storage is
#       destroyed
#
# Both restore paths must reproduce byte equality. The zero-copy body must
# alias the source chunk (its address falls inside the chunk's byte range, no
# payload allocation); the copy body must fall outside it.
#
# This is the row-grain mirror of test_thsplc_roundtrip.mojo (column codec).
# =============================================================================

from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_buffer.byte_view import ByteView
from komira_buffer.heap_region import HeapRegion

from komira_engine_runtime.spill.local_disk import LocalDiskSpillStorage
from komira_engine_runtime.spill.spill_storage import ChunkId, SpillStorage
from komira_libc.posix import _read_env
from komira_engine_runtime.spill.thspill2 import (
    Spillable,
    THSpill2Encoder,
    THSpill2Decoder,
)


def _scratch_dir() raises -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    return d


# =============================================================================
# In-memory SpillStorage. read_chunk returns a NON-OWNING borrowed SAB
# aliasing the stored bytes (no memcpy on the storage side). The stored Slab
# keeps the bytes alive for the whole test; the decoder copies (copy path) or
# borrows (0-copy path) the body from it.
# =============================================================================


struct _MemSpillStorage(SpillStorage):
    var _chunks: Slab[SharedAlignedBuffer[HeapRegion]]
    var _live: Int64

    def __init__(out self):
        self._chunks = Slab[SharedAlignedBuffer[HeapRegion]].create(8)
        self._live = 0

    def write_chunk(
        mut self, var bytes: SharedAlignedBuffer[HeapRegion]
    ) raises -> ChunkId:
        var idx = len(self._chunks)
        self._live += bytes.length()
        self._chunks.append(bytes^)
        return ChunkId(UInt64(idx))

    def read_chunk(
        self, chunk_id: ChunkId
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        var idx = Int(chunk_id._unsafe_value())
        if idx < 0 or idx >= len(self._chunks):
            raise Error("_MemSpillStorage.read_chunk: bad chunk id")
        # Borrowed SAB aliasing the stored chunk's bytes (Arc-clone, no
        # memcpy). The stored Slab outlives every read.
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

    def chunk_base_addr(self, chunk_id: ChunkId) -> Int:
        """Integer address of the FIRST byte of the stored chunk — the
        source byte range against which 0-copy aliasing is asserted."""
        var idx = Int(chunk_id._unsafe_value())
        ref stored = self._chunks[idx]
        return Int(stored.view_range_ro(0, stored.len())._unsafe_ptr())

    def chunk_len(self, chunk_id: ChunkId) -> Int:
        var idx = Int(chunk_id._unsafe_value())
        ref stored = self._chunks[idx]
        return stored.len()


# =============================================================================
# Bench-local Spillable RowBlock conformer (mirror of the microbench's
# _RowBlock). Body = an opaque flat byte block = the in-memory row image.
# =============================================================================


struct _RowBlock(Spillable):
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
        return Self(bytes^, row_count, schema_fingerprint)

    def body_base_addr(self) -> Int:
        """Integer address of the FIRST byte of this block's body — used to
        prove 0-copy aliasing (body falls inside the source chunk's range)."""
        return Int(self._bytes.view_range_ro(0, self._bytes.len())._unsafe_ptr())


# =============================================================================
# Fixture builders.
# =============================================================================

comptime ROW_FIXED_STRIDE: Int = 32


def _build_row_fixed(row_count: Int) raises -> _RowBlock:
    """row-fixed: N * 32-byte fixed rows (flat block; the 0-copy best case)."""
    var total = row_count * ROW_FIXED_STRIDE
    var oab = OwnedAlignedBuffer(capacity=max(total, 1))
    oab.set_length(Int64(total))
    oab.zero()
    for i in range(row_count):
        var base = i * ROW_FIXED_STRIDE
        oab.write_i64_le_at(base + 0, Int64(i))  # join_key
        oab.write_i64_le_at(base + 8, Int64(i * 7 + 3))  # payload0
        oab.write_i64_le_at(base + 16, Int64(i * 13 - 5))  # payload1
        oab.write_i32_le_at(base + 24, Int32(i % 1000))  # payload2
    return _RowBlock(
        SharedAlignedBuffer[HeapRegion].from_owned(oab^),
        Int64(row_count),
        UInt64(0xF1),
    )


comptime ROW_VAR_FIXED_STRIDE: Int = 16


def _build_row_var(row_count: Int) raises -> _RowBlock:
    """row-var: fixed prefix [join_key i64][payload_i i64] + trailing
    [N+1 i64 offsets][var bytes]. Exercises the var-width body shape."""
    # First pass: materialize the per-row var payloads + total var bytes.
    var payloads = List[String](capacity=row_count)
    var var_total = 0
    for i in range(row_count):
        var slen = 16 + (i % 16)  # 16..31 bytes
        var s = String("")
        for j in range(slen):
            s += chr(Int(UInt8(97 + ((i + j) % 26))))
        var_total += s.byte_length()
        payloads.append(s^)

    var fixed_bytes = row_count * ROW_VAR_FIXED_STRIDE
    var offsets_bytes = (row_count + 1) * 8
    var total = fixed_bytes + offsets_bytes + var_total
    var oab = OwnedAlignedBuffer(capacity=max(total, 1))
    oab.set_length(Int64(total))
    oab.zero()

    for i in range(row_count):
        var base = i * ROW_VAR_FIXED_STRIDE
        oab.write_i64_le_at(base + 0, Int64(i))  # join_key
        oab.write_i64_le_at(base + 8, Int64(i * 11 + 1))  # payload_i

    var off_region = fixed_bytes
    var data_region = fixed_bytes + offsets_bytes
    var cursor = 0
    oab.write_i64_le_at(off_region, Int64(0))
    for i in range(row_count):
        var s = payloads[i]
        var slen = s.byte_length()
        if slen > 0:
            var src = ByteView(s.unsafe_ptr().bitcast[UInt8](), slen)
            oab.copy_from_view_at(data_region + cursor, src)
        cursor += slen
        oab.write_i64_le_at(off_region + (i + 1) * 8, Int64(cursor))

    return _RowBlock(
        SharedAlignedBuffer[HeapRegion].from_owned(oab^),
        Int64(row_count),
        UInt64(0xF2),
    )


def _row_bytes_equal(a: _RowBlock, b: _RowBlock) -> Bool:
    if a.row_count() != b.row_count():
        return False
    if a.nbytes() != b.nbytes():
        return False
    var n = Int(a.nbytes())
    var va = a._bytes.as_view()
    var vb = b._bytes.as_view()
    for k in range(n):
        if va.into_span()[k] != vb.into_span()[k]:
            return False
    return True


# =============================================================================
# (a) fixed-width rows — copy + 0-copy.
# =============================================================================


def test_row_fixed_copy_and_zerocopy() raises:
    comptime N = 64
    var src_ref = _build_row_fixed(N)  # independent reference image

    # --- copy path ---
    var storage_c = _MemSpillStorage()
    var cid_c = THSpill2Encoder[_RowBlock].encode(storage_c, _build_row_fixed(N))
    var restored_copy = THSpill2Decoder[_RowBlock].decode_copy(storage_c, cid_c)
    assert_equal(Int(restored_copy.row_count()), N)
    assert_true(
        _row_bytes_equal(src_ref, restored_copy),
        "row-fixed copy: restored bytes must equal source image",
    )
    var copy_base = restored_copy.body_base_addr()
    var c_chunk_base = storage_c.chunk_base_addr(cid_c)
    var c_chunk_end = c_chunk_base + storage_c.chunk_len(cid_c)
    assert_true(
        copy_base < c_chunk_base or copy_base >= c_chunk_end,
        "copy-path body must NOT alias source chunk bytes",
    )

    # --- 0-copy path ---
    var storage_z = _MemSpillStorage()
    var cid_z = THSpill2Encoder[_RowBlock].encode(storage_z, _build_row_fixed(N))
    var z_chunk_base = storage_z.chunk_base_addr(cid_z)
    var z_chunk_end = z_chunk_base + storage_z.chunk_len(cid_z)
    var restored_zc = THSpill2Decoder[_RowBlock].decode_zerocopy(
        storage_z, cid_z
    )
    assert_equal(Int(restored_zc.row_count()), N)
    assert_true(
        _row_bytes_equal(src_ref, restored_zc),
        "row-fixed 0-copy: restored bytes must equal source image",
    )
    var zc_base = restored_zc.body_base_addr()
    assert_true(
        zc_base >= z_chunk_base and zc_base < z_chunk_end,
        "0-copy body MUST alias source chunk bytes",
    )
    # The 0-copy body begins exactly at the chunk's 96-byte header offset.
    assert_equal(zc_base - z_chunk_base, 96)
    _ = storage_z^


# =============================================================================
# (b) var-width rows — copy + 0-copy.
# =============================================================================


def test_row_var_copy_and_zerocopy() raises:
    comptime N = 48
    var src_ref = _build_row_var(N)

    # --- copy path ---
    var storage_c = _MemSpillStorage()
    var cid_c = THSpill2Encoder[_RowBlock].encode(storage_c, _build_row_var(N))
    var restored_copy = THSpill2Decoder[_RowBlock].decode_copy(storage_c, cid_c)
    assert_equal(Int(restored_copy.row_count()), N)
    assert_true(
        _row_bytes_equal(src_ref, restored_copy),
        "row-var copy: restored bytes must equal source image",
    )

    # --- 0-copy path ---
    var storage_z = _MemSpillStorage()
    var cid_z = THSpill2Encoder[_RowBlock].encode(storage_z, _build_row_var(N))
    var z_chunk_base = storage_z.chunk_base_addr(cid_z)
    var z_chunk_end = z_chunk_base + storage_z.chunk_len(cid_z)
    var restored_zc = THSpill2Decoder[_RowBlock].decode_zerocopy(
        storage_z, cid_z
    )
    assert_equal(Int(restored_zc.row_count()), N)
    assert_true(
        _row_bytes_equal(src_ref, restored_zc),
        "row-var 0-copy: restored bytes must equal source image",
    )
    var zc_base = restored_zc.body_base_addr()
    assert_true(
        zc_base >= z_chunk_base and zc_base < z_chunk_end,
        "0-copy var-width body MUST alias source chunk bytes",
    )
    _ = storage_z^


# =============================================================================
# (c) empty body (0 rows) — both paths must round-trip without aliasing UB.
# =============================================================================


def test_row_empty_copy_and_zerocopy() raises:
    var storage = _MemSpillStorage()
    var cid = THSpill2Encoder[_RowBlock].encode(storage, _build_row_fixed(0))

    var restored_copy = THSpill2Decoder[_RowBlock].decode_copy(storage, cid)
    assert_equal(Int(restored_copy.row_count()), 0)
    assert_equal(Int(restored_copy.nbytes()), 0)

    var restored_zc = THSpill2Decoder[_RowBlock].decode_zerocopy(storage, cid)
    assert_equal(Int(restored_zc.row_count()), 0)
    assert_equal(Int(restored_zc.nbytes()), 0)
    _ = storage^


# =============================================================================
# (d) The 0-copy restore keeps the source storage pinned: the restored block
# is read AFTER the local read-chunk handle drops (Arc keepalive contract).
# =============================================================================


def test_row_zerocopy_keepalive() raises:
    comptime N = 32
    var src_ref = _build_row_fixed(N)
    var storage = _MemSpillStorage()
    var cid = THSpill2Encoder[_RowBlock].encode(storage, _build_row_fixed(N))

    # decode_zerocopy's internal `raw` read-chunk handle drops at the end of
    # the call; the restored block's body Arc-clone keeps the bytes alive.
    var restored = THSpill2Decoder[_RowBlock].decode_zerocopy(storage, cid)
    # Read every byte AFTER that handle is gone.
    assert_true(
        _row_bytes_equal(src_ref, restored),
        "0-copy body must remain valid after the read-chunk handle drops",
    )
    _ = storage^


def test_row_zerocopy_outlives_storage() raises:
    # Destroy the storage (which owns the chunk) BEFORE reading the restored
    # block. The body must hold its own reference to the chunk's buffer.
    comptime N = 32
    var src_ref = _build_row_fixed(N)
    var storage = _MemSpillStorage()
    var cid = THSpill2Encoder[_RowBlock].encode(storage, _build_row_fixed(N))
    var restored = THSpill2Decoder[_RowBlock].decode_zerocopy(storage, cid)
    _ = storage^
    assert_true(
        _row_bytes_equal(src_ref, restored),
        "0-copy body must stay valid after its storage is destroyed",
    )


def test_row_zerocopy_survives_disk_release() raises:
    # On the local-disk storage the chunk is read into a heap buffer; releasing
    # the chunk (unlinking its file) and cleaning up the root must not
    # invalidate a zero-copy restore.
    comptime N = 32
    var src_ref = _build_row_fixed(N)
    var storage = LocalDiskSpillStorage.with_unlimited(
        _scratch_dir()
        + String("/komira_spill_test_zc_")
        + String(Int(perf_counter_ns()))
    )
    var cid = THSpill2Encoder[_RowBlock].encode(storage, _build_row_fixed(N))
    var restored = THSpill2Decoder[_RowBlock].decode_zerocopy(storage, cid)
    storage.release_chunk(cid)
    storage.cleanup()
    _ = storage^
    assert_true(
        _row_bytes_equal(src_ref, restored),
        "0-copy body must stay valid after the chunk file is released",
    )


def main() raises:
    test_row_fixed_copy_and_zerocopy()
    print("test_row_fixed_copy_and_zerocopy PASSED")
    test_row_var_copy_and_zerocopy()
    print("test_row_var_copy_and_zerocopy PASSED")
    test_row_empty_copy_and_zerocopy()
    print("test_row_empty_copy_and_zerocopy PASSED")
    test_row_zerocopy_keepalive()
    print("test_row_zerocopy_keepalive PASSED")
    test_row_zerocopy_outlives_storage()
    print("test_row_zerocopy_outlives_storage PASSED")
    test_row_zerocopy_survives_disk_release()
    print("test_row_zerocopy_survives_disk_release PASSED")
    print("ALL THSPILL2 ZEROCOPY TESTS PASSED")
