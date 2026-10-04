# =============================================================================
# test_avro_read_mmap.mojo
#
# Validates the Avro reader's file path, which reads through
# `LocalFs.read_whole(path)` rather than `Path.read_bytes()` (own-heap copy):
#
#   (a) read_whole returns an owning, 64-realigned buffer
#   (b) Avro decode is byte-identical (row count + cell-by-cell parity)
#       via the file path vs the in-memory path.
#   (c) mmap region lifetime — decode a small file, ensure RecordBatch
#       columns are still readable after the input MmapAlignedBuffer drops
#       (proves Avro decoder materializes into owning column buffers
#       and does NOT borrow from the mmap region).
#   (d) Zero-length file edge case (mmap raises clean Error).
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true, assert_false

from komira_fs.local_fs import LocalFs
from komira_async.ops.waker_sink import NoopSink
from komira_avro import (
    decode_ocf_header,
    read_avro_bytes,
    read_avro_file,
    OCF_SYNC_LEN,
)
from komira_runtime_paths import test_tmpdir


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH.
#
# The same test can run more than once at a time on one host. A fixed `/tmp`
# path is shared by every one of those executions. `TEST_TMPDIR` is private
# to each test execution, which is what keeps them disjoint; `test_tmpdir()`
# is the one helper that reads it (and raises when it is unset).
# ---------------------------------------------------------------------------
def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into."""
    return test_tmpdir()


# =============================================================================
# Fixture helpers — minimal Avro OCF "{ a: long }" schema with N rows.
# =============================================================================

def _enc_long(n: Int64, mut out: List[UInt8]):
    """Zigzag varint encode `n` into `out` (Avro spec wire format)."""
    var zz = UInt64((n << 1) ^ (n >> 63))
    while True:
        var b = UInt8(zz & 0x7F)
        zz >>= 7
        if zz != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _str_bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _enc_bytes(b: List[UInt8], mut out: List[UInt8]):
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _enc_str(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _build_tiny_avro_ocf(n_rows: Int) -> List[UInt8]:
    """Build an in-memory Avro OCF byte stream with schema `{a: long}` and
    `n_rows` rows: a[i] = i. One block, codec=null, fixed sync marker.

    Wire layout follows
    test_avro_lineitem_decode_roundtrip._make_header / _append_block.
    """
    var out = List[UInt8]()
    # OCF magic.
    out.append(UInt8(ord("O")))
    out.append(UInt8(ord("b")))
    out.append(UInt8(ord("j")))
    out.append(0x01)

    # Metadata map: 2 entries (avro.schema, avro.codec).
    _enc_long(Int64(2), out)

    var schema = String(
        '{"type":"record","name":"r","fields":[{"name":"a","type":"long"}]}'
    )
    _enc_str(String("avro.schema"), out)
    _enc_bytes(_str_bytes(schema), out)

    _enc_str(String("avro.codec"), out)
    _enc_bytes(_str_bytes(String("null")), out)

    # End-of-map: 0-count.
    _enc_long(Int64(0), out)

    # 16-byte sync marker (deterministic; matches lineitem test pattern).
    for i in range(OCF_SYNC_LEN):
        out.append(UInt8(0xA0 + i))

    # One block: count, byte-length-prefix, payload, sync.
    var payload = List[UInt8]()
    for i in range(n_rows):
        _enc_long(Int64(i), payload)

    _enc_long(Int64(n_rows), out)
    _enc_long(Int64(len(payload)), out)
    for i in range(len(payload)):
        out.append(payload[i])
    # Block trailer sync (must match header sync).
    for i in range(OCF_SYNC_LEN):
        out.append(UInt8(0xA0 + i))

    return out^


def _write_bytes_to_tmpfile(
    path: String, bytes: List[UInt8]
) raises -> None:
    """Write `bytes` to `path` using POSIX fopen+fwrite+fclose."""
    var p = path
    var c_path = p.as_c_string_slice().unsafe_ptr()
    var mode = String("wb")
    var c_mode = mode.as_c_string_slice().unsafe_ptr()
    var fp = external_call["fopen", Int64](c_path, c_mode)
    if fp == 0:
        raise Error("_write_bytes_to_tmpfile: fopen failed for ", path)
    var n = external_call["fwrite", Int64](
        bytes.unsafe_ptr(), Int64(1), Int64(len(bytes)), fp
    )
    _ = external_call["fclose", Int32](fp)
    if Int(n) != len(bytes):
        raise Error(
            "_write_bytes_to_tmpfile: short write (", n, " < ",
            len(bytes), ") to ", path,
        )


def _make_tmp_avro_path(label: String) raises -> String:
    return (_scratch_dir() + String("/komira_test_avro_mmap_")) + label + String(".avro")


# =============================================================================
# Tests — (a) read_whole shape, (b) decode parity, (c) lifetime, (d) edge.
# =============================================================================


def test_localfs_read_whole_returns_realigned_owning_buffer() raises:
    """(a) LocalFs.read_whole returns an OWNING, 64-realigned heap buffer.

    `LocalFs.read_whole` funnels through `read_chunked(path).realign_to[64]()`.
    `read_chunked` yields a zero-copy `SAB[MmapRegion]`, but `realign_to[64]()`
    UNCONDITIONALLY memcpy's into a fresh OWNING `SAB[HeapRegion]`
    (realignment owns its memcpy'd bytes; the return type cannot preserve an
    mmap-backed region) and drops the mmap keepalive cookie. So the returned
    buffer is heap-owning: `is_owned()==True`, `is_mmap_backed()==False`.
    The load-bearing assertions — length + content fidelity through the
    realign — are retained below."""
    var bytes = _build_tiny_avro_ocf(8)
    var bytes_len = len(bytes)
    var path = _make_tmp_avro_path("readwhole_shape")
    _write_bytes_to_tmpfile(path, bytes)

    var fs = LocalFs[NoopSink].new()
    var buf = fs.read_whole(path)

    # Post-`realign_to[64]()` shape: owning HeapRegion buffer, NOT mmap-
    # backed (the memcpy severs the mmap provenance + keepalive cookie).
    assert_true(buf.is_owned(), "read_whole buf is realign-owned")
    assert_false(
        buf.is_mmap_backed(), "realigned buf is no longer mmap-backed"
    )
    assert_equal(buf.len(), bytes_len, "length matches file_size")

    # Sanity: first 4 bytes are the Avro OCF magic 'O','b','j','\x01'.
    assert_equal(Int(buf.read_u8_at(0)), 0x4F, "magic[0] = 'O'")
    assert_equal(Int(buf.read_u8_at(1)), 0x62, "magic[1] = 'b'")
    assert_equal(Int(buf.read_u8_at(2)), 0x6A, "magic[2] = 'j'")
    assert_equal(Int(buf.read_u8_at(3)), 0x01, "magic[3] = 0x01")


def test_fixture_header_decodes() raises:
    """Sanity: the hand-built fixture has a valid OCF header (passes
    decode_ocf_header). Confirms the in-memory builder produces a wire
    stream that matches the existing OCF header decoder's expectations
    — load-bearing for the mmap parity test (c) below."""
    var bytes = _build_tiny_avro_ocf(4)
    var hdr = decode_ocf_header(Span(bytes))
    assert_equal(hdr.schema_json.byte_length(), 66, "schema JSON is 66 bytes")
    assert_equal(hdr.codec_tag, 0, "codec is null (tag 0)")


def test_avro_decode_via_mmap_byte_identical_to_in_memory() raises:
    """(b) read_avro_file (mmap path) decodes the same wire stream the
    in-memory `read_avro_bytes` decodes from identical bytes — byte-
    identical row count + per-cell parity (a[i] == i)."""
    var bytes = _build_tiny_avro_ocf(64)
    var path = _make_tmp_avro_path("decode_parity")
    _write_bytes_to_tmpfile(path, bytes)

    # In-memory path — the "ground truth" (no mmap involved).
    var rb_inmem = read_avro_bytes(Span(bytes))

    # File path — `read_avro_file` through `LocalFs.read_whole`.
    var rb_mmap = read_avro_file(path)

    assert_equal(rb_inmem.num_rows(), rb_mmap.num_rows(), "row count parity")
    assert_equal(
        rb_inmem.num_columns(), rb_mmap.num_columns(), "col count parity"
    )
    assert_equal(rb_mmap.num_rows(), 64, "expect 64 rows")
    assert_equal(rb_mmap.num_columns(), 1, "expect 1 col")

    # Cell-by-cell: in-memory vs mmap parity AND a[i] == i.
    ref ai_in = rb_inmem.column_at(0)
    var a_in = ai_in.as_primitive[DType.int64]()
    ref ai_mm = rb_mmap.column_at(0)
    var a_mm = ai_mm.as_primitive[DType.int64]()
    for i in range(rb_mmap.num_rows()):
        assert_equal(Int(a_in.get(i)), Int(a_mm.get(i)),
                     "cell parity (in-mem vs mmap)")
        assert_equal(Int(a_mm.get(i)), i, "a[i] == i (mmap path)")


def test_avro_decoded_batch_outlives_mmap_handle() raises:
    """(c) The decoded RecordBatch's columns are OWNING — they do not
    alias the mmap region. After read_avro_file returns, its internal
    MmapAlignedBuffer + ArcPointer[MmapRegion] have dropped, and the kernel
    has fired munmap. If the columns aliased the unmapped pages, these
    reads would crash / return garbage."""
    var bytes = _build_tiny_avro_ocf(32)
    var path = _make_tmp_avro_path("lifetime")
    _write_bytes_to_tmpfile(path, bytes)

    # read_avro_file constructs LocalFs internally, slurps via mmap,
    # decodes, returns RecordBatch. The mmap region is dropped before
    # this fn returns (the MmapAlignedBuffer goes out of scope inside
    # read_avro_file).
    var rb = read_avro_file(path)
    assert_equal(rb.num_rows(), 32, "expect 32 rows")

    # Read every cell — if any column aliased the mmap region, the bytes
    # would now be unmapped and these reads would crash / return garbage.
    ref ai = rb.column_at(0)
    var a = ai.as_primitive[DType.int64]()
    var sum: Int64 = 0
    for i in range(rb.num_rows()):
        sum += a.get(i)
    # Expected sum of 0..31 = 31*32/2 = 496.
    assert_equal(Int(sum), 496, "sum 0..31 = 496")


def test_localfs_read_whole_zero_length_file_raises() raises:
    """(d) Zero-length file: MmapRegion.open_readonly raises a clean Error."""
    var path = _make_tmp_avro_path("zerolen")
    # Write an empty file via fopen+fclose (no bytes).
    var p = path
    var c_path = p.as_c_string_slice().unsafe_ptr()
    var mode = String("wb")
    var c_mode = mode.as_c_string_slice().unsafe_ptr()
    var fp = external_call["fopen", Int64](c_path, c_mode)
    if fp == 0:
        raise Error("setup: fopen failed for ", path)
    _ = external_call["fclose", Int32](fp)

    var fs = LocalFs[NoopSink].new()
    var raised = False
    try:
        var _buf = fs.read_whole(path)
    except _:
        raised = True
    assert_true(raised, "read_whole on zero-length file must raise")


def main() raises:
    test_fixture_header_decodes()
    test_localfs_read_whole_returns_realigned_owning_buffer()
    test_avro_decode_via_mmap_byte_identical_to_in_memory()
    test_avro_decoded_batch_outlives_mmap_handle()
    test_localfs_read_whole_zero_length_file_raises()
    print("test_avro_read_mmap: ALL PASS")
