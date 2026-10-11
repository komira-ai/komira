# =============================================================================
# src/komira_table_store/tests/test_table_store_codec_edges.mojo
#   The commit-chunk codec's edges: the v3 (explicit stamp_lsn) wire layout,
#   the format-version gate, and every truncation / negative-count refusal of
#   both decoders (the full decode and the keys-only OCC decode).
# =============================================================================
#
# What each test proves:
#   * v3 round trip: a chunk encoded with an explicit stamp_lsn carries the
#     "PGC3" magic, puts the stamp at offset 16 and the write count at offset 24,
#     and both decoders read the write-set from offset 32. Values with every
#     byte set (snapshot, stamp, a 300-byte row whose length has a non-zero
#     second byte) catch a dropped or mis-shifted byte.
#   * v2 stays byte-identical when no stamp is given (the default path).
#   * the version gate: "PGC1" and "PGC4" are refused as unsupported versions,
#     "PGC:" and "PGC/" as a non-digit version byte, by both decoders.
#   * truncation: a body too short for the magic, the schema slot, the v2
#     write count or the v3 stamp names the field width and offset; a declared
#     write with no op tag and a key length with a high byte set are refused.
#   * a negative write count is refused by both decoders.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_table_store.table_store_codec import (
    TS_OP_PUT,
    TS_OP_TOMBSTONE,
    TS_STAMP_LSN_UNSET,
    WriteOp,
    bytes_eq,
    decode_commit_chunk,
    decode_commit_chunk_keys,
    encode_commit_chunk,
)


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _le64(v: Int64) -> List[UInt8]:
    var out = List[UInt8]()
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))
    return out^


def _get_le64(b: List[UInt8], off: Int) -> Int64:
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(b[off + i])) << UInt64(8 * i)
    return Int64(u)


def _magic(digit: UInt8) -> List[UInt8]:
    """'P' 'G' 'C' then the version byte."""
    var out = List[UInt8]()
    out.append(UInt8(0x50))
    out.append(UInt8(0x47))
    out.append(UInt8(0x43))
    out.append(digit)
    return out^


def _extend(mut dst: List[UInt8], src: List[UInt8]):
    for i in range(len(src)):
        dst.append(src[i])


def _v2_header(n_writes: Int64) -> List[UInt8]:
    """A v2 header: magic | snapshot_lsn 5 | schema 0 | n_writes."""
    var out = _magic(UInt8(0x32))
    _extend(out, _le64(Int64(5)))
    for _ in range(4):
        out.append(UInt8(0))
    _extend(out, _le64(n_writes))
    return out^


def _full_err(body: List[UInt8]) -> String:
    """The error decode_commit_chunk raises on `body`, or "" if it decoded."""
    try:
        _ = decode_commit_chunk(body)
    except e:
        return String(e)
    return String("")


def _keys_err(body: List[UInt8]) -> String:
    """The error decode_commit_chunk_keys raises on `body`, or "" if it decoded."""
    try:
        _ = decode_commit_chunk_keys(body)
    except e:
        return String(e)
    return String("")


def _row300() -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(300):
        out.append(UInt8((i * 7 + 3) & 0xFF))
    return out^


def _write_set() -> List[WriteOp]:
    var ws = List[WriteOp]()
    ws.append(WriteOp(TS_OP_PUT, _b("key-one"), _row300()))
    ws.append(WriteOp(TS_OP_TOMBSTONE, _b("k2"), List[UInt8]()))
    return ws^


def test_v3_round_trip_layout() raises:
    print("[codec] v3: PGC3 magic, stamp at 16, count at 24, writes at 32")
    var snap = Int64(0x0102030405060708)
    var stamp = Int64(0x7F00_0000_0000_00FF)
    var body = encode_commit_chunk(snap, _write_set(), stamp)
    var want_magic = _magic(UInt8(0x33))
    for i in range(4):
        assert_equal(Int(body[i]), Int(want_magic[i]), "v3 magic byte " + String(i))
    assert_equal(_get_le64(body, 4), snap, "snapshot_lsn at offset 4")
    for i in range(12, 16):
        assert_equal(Int(body[i]), 0, "reserved schema_version byte " + String(i))
    assert_equal(_get_le64(body, 16), stamp, "stamp_lsn at offset 16")
    assert_equal(_get_le64(body, 24), Int64(2), "n_writes at offset 24")
    # op(1) + key len(8) + 7 + row len(8) + 300, then op(1) + 8 + 2 + 8 + 0.
    assert_equal(len(body), 32 + (1 + 8 + 7 + 8 + 300) + (1 + 8 + 2 + 8))
    assert_equal(Int(body[32]), Int(TS_OP_PUT), "first op tag at offset 32")

    var c = decode_commit_chunk(body)
    assert_equal(c.snapshot_lsn, snap, "decoded snapshot_lsn")
    assert_equal(c.stamp_lsn, stamp, "decoded stamp_lsn")
    assert_equal(Int(c.schema_version), 0, "decoded schema_version")
    assert_equal(len(c.write_set), 2, "decoded write count")
    assert_equal(Int(c.write_set[0].op), Int(TS_OP_PUT))
    assert_true(bytes_eq(c.write_set[0].key, _b("key-one")), "key 0")
    assert_true(bytes_eq(c.write_set[0].row, _row300()), "300-byte row")
    assert_equal(Int(c.write_set[1].op), Int(TS_OP_TOMBSTONE))
    assert_true(bytes_eq(c.write_set[1].key, _b("k2")), "key 1")
    assert_equal(len(c.write_set[1].row), 0, "tombstone row is empty")

    var keys = decode_commit_chunk_keys(body)
    assert_equal(len(keys), 2, "keys-only decode count")
    assert_true(bytes_eq(keys[0], _b("key-one")), "keys-only key 0")
    assert_true(bytes_eq(keys[1], _b("k2")), "keys-only key 1")


def test_v2_default_is_unstamped() raises:
    print("[codec] v2: no stamp -> PGC2, count at 16, stamp decodes as unset")
    var body = encode_commit_chunk(Int64(9), _write_set())
    assert_equal(Int(body[3]), 0x32, "v2 version byte")
    assert_equal(_get_le64(body, 16), Int64(2), "n_writes at offset 16")
    assert_equal(len(body), 24 + (1 + 8 + 7 + 8 + 300) + (1 + 8 + 2 + 8))
    var c = decode_commit_chunk(body)
    assert_equal(c.stamp_lsn, TS_STAMP_LSN_UNSET, "v2 decodes stamp -1")
    assert_equal(c.snapshot_lsn, Int64(9))
    # A stamp of 0 is explicit (v3), not the unset sentinel.
    var z = encode_commit_chunk(Int64(9), _write_set(), Int64(0))
    assert_equal(Int(z[3]), 0x33, "stamp 0 encodes v3")
    assert_equal(decode_commit_chunk(z).stamp_lsn, Int64(0), "stamp 0 decodes")


def test_version_gate() raises:
    print("[codec] unknown versions and non-digit version bytes are refused")
    var versions = List[UInt8]()
    versions.append(UInt8(0x31))
    versions.append(UInt8(0x34))
    for vi in range(len(versions)):
        var d = versions[vi]
        var body = _magic(d)
        _extend(body, _le64(Int64(0)))
        var fe = _full_err(body)
        assert_true(
            fe.find("unsupported commit-chunk format version " + String(Int(d) - 0x30)) >= 0,
            "full decode refuses version " + String(Int(d) - 0x30) + ": " + fe,
        )
        var ke = _keys_err(body)
        assert_true(
            ke.find("unsupported commit-chunk format version") >= 0
            and ke.find("in key-decode") >= 0,
            "keys decode refuses the version: " + ke,
        )
    var bad_digits = List[UInt8]()
    bad_digits.append(UInt8(0x2F))
    bad_digits.append(UInt8(0x3A))
    for bi in range(len(bad_digits)):
        var d = bad_digits[bi]
        var body = _magic(d)
        var fe = _full_err(body)
        assert_true(
            fe.find("not an ASCII digit (got " + String(Int(d)) + ")") >= 0,
            "full decode refuses version byte " + String(Int(d)) + ": " + fe,
        )
        var ke = _keys_err(body)
        assert_true(
            ke.find("not an ASCII digit") >= 0,
            "keys decode refuses version byte " + String(Int(d)) + ": " + ke,
        )


def test_truncated_fixed_fields() raises:
    print("[codec] truncated magic / schema / count / stamp name width + offset")
    var two = List[UInt8]()
    two.append(UInt8(0x50))
    two.append(UInt8(0x47))
    var e = _full_err(two)
    assert_true(e.find("truncated u32 at offset 0") >= 0, "magic: " + e)
    e = _keys_err(two)
    assert_true(e.find("truncated u32 at offset 0") >= 0, "keys magic: " + e)

    var v2 = _v2_header(Int64(0))
    var cut14 = List[UInt8]()
    for i in range(14):
        cut14.append(v2[i])
    e = _full_err(cut14)
    assert_true(e.find("truncated i32 at offset 12") >= 0, "schema slot: " + e)

    var cut20 = List[UInt8]()
    for i in range(20):
        cut20.append(v2[i])
    e = _full_err(cut20)
    assert_true(e.find("truncated i64 at offset 16") >= 0, "v2 n_writes: " + e)
    e = _keys_err(cut20)
    assert_true(e.find("truncated i64 at offset 16") >= 0, "keys v2 n_writes: " + e)

    var v3 = encode_commit_chunk(Int64(1), List[WriteOp](), Int64(4))
    var v3cut = List[UInt8]()
    for i in range(20):
        v3cut.append(v3[i])
    e = _full_err(v3cut)
    assert_true(e.find("truncated i64 at offset 16") >= 0, "v3 stamp: " + e)
    var v3cut28 = List[UInt8]()
    for i in range(28):
        v3cut28.append(v3[i])
    e = _full_err(v3cut28)
    assert_true(e.find("truncated i64 at offset 24") >= 0, "v3 n_writes: " + e)
    e = _keys_err(v3cut28)
    assert_true(e.find("truncated i64 at offset 24") >= 0, "keys v3 n_writes: " + e)


def test_negative_and_missing_writes() raises:
    print("[codec] negative n_writes, a missing op tag, a huge key length")
    var neg = _v2_header(Int64(-1))
    var e = _full_err(neg)
    assert_true(e.find("negative n_writes -1") >= 0, "full negative: " + e)
    e = _keys_err(neg)
    assert_true(e.find("negative n_writes -1") >= 0, "keys negative: " + e)

    # One write declared, none present.
    var one = _v2_header(Int64(1))
    e = _full_err(one)
    assert_true(
        e.find("truncated WriteOp op tag") >= 0 and e.find("key-decode") < 0,
        "full missing op tag: " + e,
    )
    e = _keys_err(one)
    assert_true(e.find("truncated WriteOp op tag (key-decode)") >= 0, "keys: " + e)

    # Two writes declared, one present: the second op tag is missing.
    var ws = List[WriteOp]()
    ws.append(WriteOp(TS_OP_PUT, _b("a"), _b("b")))
    var body = encode_commit_chunk(Int64(0), ws^, Int64(3))
    var two_le = _le64(Int64(2))
    for i in range(8):
        body[24 + i] = two_le[i]
    e = _full_err(body)
    assert_true(e.find("truncated WriteOp op tag") >= 0, "v3 2nd op: " + e)
    e = _keys_err(body)
    assert_true(e.find("truncated WriteOp op tag (key-decode)") >= 0, "v3 keys: " + e)

    # A key length whose high byte is set (2^56) runs past the body.
    var big = _v2_header(Int64(1))
    big.append(TS_OP_PUT)
    _extend(big, _le64(Int64(1) << Int64(56)))
    big.append(UInt8(0x41))
    e = _full_err(big)
    assert_true(
        e.find("truncated lp-bytes (len=72057594037927936, off=33") >= 0,
        "huge key length: " + e,
    )
    e = _keys_err(big)
    assert_true(e.find("truncated lp-bytes") >= 0, "keys huge key length: " + e)
    # A negative key length is refused, not read backwards.
    var negk = _v2_header(Int64(1))
    negk.append(TS_OP_PUT)
    _extend(negk, _le64(Int64(-2)))
    e = _full_err(negk)
    assert_true(e.find("truncated lp-bytes (len=-2,") >= 0, "negative key length: " + e)


def main() raises:
    test_v3_round_trip_layout()
    test_v2_default_is_unstamped()
    test_version_gate()
    test_truncated_fixed_fields()
    test_negative_and_missing_writes()
    print("ALL table store codec edge tests PASSED")
