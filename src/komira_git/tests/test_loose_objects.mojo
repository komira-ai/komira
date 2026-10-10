# =============================================================================
# komira_git/tests/test_loose_objects.mojo -- loose object encode, decode,
# read.
# =============================================================================
#
# WHERE THE FIXTURES COME FROM: two loose-object files written by git 2.51.0
# (`git hash-object -w`), copied byte for byte as hex below:
#   * `_GIT_BLOB`: the blob "hello path0\n" (t/t0000-basic.sh's `path0f`).
#     A sha1 and a sha256 repository write the same bytes for it (the
#     compressed content does not depend on the format), so the one file is
#     read under both ids, f87290f8... and 638106af....
#   * `_GIT_COMMIT`: the commit `c_root` of test_commits_tags.mojo,
#     bb0e40b5....
# Both start 0x78 0x01: a zlib stream at level 1, git's loose default.
#
# WHAT EACH TEST CATCHES:
#   * test_read_git_files: a wrong header parse, a payload off by a byte, a
#     hash over the wrong bytes.
#   * test_encode_matches_git: a level or framing other than git's (the
#     bytes would differ from git's file).
#   * test_refusals: each refusal by its exact message, including a size
#     limit checked before the payload is inflated (`max_size`), trailing
#     bytes after the stream, and a declared size that disagrees with the
#     inflated payload in either direction.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_zlib import ZLIB_WINDOW_BITS_ZLIB, zlib_compress_bound, zlib_deflate_into

from komira_git import (
    ObjectFormat,
    ObjectId,
    ObjectKind,
    decode_loose,
    encode_loose,
    loose_path,
    read_loose,
)

comptime _GIT_BLOB = "78014bcac94f52303462c848cdc9c95728482cc930e002004335063e"
comptime _GIT_COMMIT = (
    "780185cd410a42211485e1c6aee26ea0f09a3daff088a2518368520b50bbf18467"
    "8618b4fc0ca169b39f0f0e27e494620534b4a88519241923b5b38377770cea8681"
    "06ebc84bd29a90513520bff1c2bdea940bece10a976f8c1d76fc76e939f32ae4b4"
    "05445416d1da352ca59152346d77950b1ce00ca79ee34fffacc5f1116b7433f481"
    "f800f2e838f0"
)


def _unhex(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i + 1 < len(b):
        var hi = Int(b[i])
        var lo = Int(b[i + 1])
        hi = hi - 48 if hi <= 57 else hi - 87
        lo = lo - 48 if lo <= 57 else lo - 87
        out.append(UInt8(hi * 16 + lo))
        i += 2
    return out^


def _b(s: String) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def _text(b: List[UInt8]) -> String:
    var s = String()
    for i in range(len(b)):
        s += chr(Int(b[i]))
    return s^


def _zlib(plain: List[UInt8]) raises -> List[UInt8]:
    """Deflate `plain` as one zlib stream (for hand-made loose files)."""
    var out = List[UInt8](
        length=zlib_compress_bound(len(plain), ZLIB_WINDOW_BITS_ZLIB), fill=UInt8(0)
    )
    var n = zlib_deflate_into(Span(out), Span(plain), Int32(6), ZLIB_WINDOW_BITS_ZLIB)
    out.resize(n, UInt8(0))
    return out^


def _with_nul(head: String, body: String) -> List[UInt8]:
    var out = _b(head)
    out.append(UInt8(0))
    var rest = _b(body)
    for i in range(len(rest)):
        out.append(rest[i])
    return out^


def _decode_err(data: List[UInt8], max_size: Int = 1 << 20) -> String:
    try:
        _ = decode_loose(Span(data), max_size)
    except e:
        return String(e)
    return String("OK")


def test_read_git_files() raises:
    var blob = _unhex(_GIT_BLOB)
    var s1 = ObjectId.parse_hex(
        ObjectFormat.sha1(), "f87290f8eb2cbbea7857214459a0739927eab154"
    )
    var obj = read_loose(s1, Span(blob), 1024)
    assert_true(obj.kind == ObjectKind.blob())
    assert_equal(_text(obj.payload), "hello path0\n")
    var s2 = ObjectId.parse_hex(
        ObjectFormat.sha256(),
        "638106af7c38be056f3212cbd7ac65bc1bac74f420ca5a436ff006a9d025d17d",
    )
    assert_equal(_text(read_loose(s2, Span(blob), 1024).payload), "hello path0\n")
    var commit = _unhex(_GIT_COMMIT)
    var cid = ObjectId.parse_hex(
        ObjectFormat.sha1(), "bb0e40b5d718273d8cd5d4806d4913aa21783ef4"
    )
    var c = read_loose(cid, Span(commit), 1024)
    assert_true(c.kind == ObjectKind.commit())
    assert_equal(
        _text(c.payload),
        "tree 087704a96baf1c2d1c869a8b084481e121c88b5b\nauthor A U Thor"
        " <author@example.com> 1112911993 -0700\ncommitter C O Mitter"
        " <committer@example.com> 1112911993 -0700\n\nInitial commit\n",
    )
    assert_equal(loose_path(s1), "f8/7290f8eb2cbbea7857214459a0739927eab154")
    # The wrong id is refused after hashing.
    var wrong = ObjectId.parse_hex(
        ObjectFormat.sha1(), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
    )
    try:
        _ = read_loose(wrong, Span(blob), 1024)
        assert_true(False)
    except e:
        assert_equal(
            String(e),
            "komira_git: loose object: hashes to"
            " f87290f8eb2cbbea7857214459a0739927eab154, expected"
            " e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
        )


def test_encode_matches_git() raises:
    var payload = _b("hello path0\n")
    var enc = encode_loose(ObjectKind.blob(), Span(payload))
    var git = _unhex(_GIT_BLOB)
    assert_equal(len(enc), len(git))
    for i in range(len(git)):
        assert_equal(enc[i], git[i])


def test_round_trip_large() raises:
    var payload = List[UInt8](capacity=100003)
    for i in range(100003):
        payload.append(UInt8((i * 7 + i // 251) & 255))
    var enc = encode_loose(ObjectKind.blob(), Span(payload))
    var dec = decode_loose(Span(enc), 100003)
    assert_equal(len(dec.payload), 100003)
    for i in range(100003):
        assert_equal(dec.payload[i], payload[i])


def test_refusals() raises:
    var p = "komira_git: loose object: "
    var blob = _unhex(_GIT_BLOB)
    assert_equal(_decode_err(blob, 12), "OK")
    assert_equal(_decode_err(blob, 11), p + "size 12 exceeds the limit 11")
    var trailing = blob.copy()
    trailing.append(UInt8(0x78))
    assert_equal(_decode_err(trailing), p + "1 bytes after the zlib stream")
    var truncated = blob.copy()
    for _ in range(4):
        _ = truncated.pop()
    assert_equal(_decode_err(truncated), p + "truncated zlib stream")
    assert_equal(_decode_err(_b("not a zlib stream")), p + "corrupt zlib stream (rc=-3)")
    assert_equal(_decode_err(List[UInt8]()), p + "empty file")
    # Declared size disagrees with the payload ("hello path0\n" is 12 bytes).
    assert_equal(
        _decode_err(_zlib(_with_nul("blob 5", "hello path0\n"))),
        p + "inflates past its declared size 5",
    )
    assert_equal(
        _decode_err(_zlib(_with_nul("blob 20", "hello path0\n"))),
        p + "inflates to 12 payload bytes, header says 20",
    )
    assert_equal(_decode_err(_zlib(_with_nul("blob 12", "hello path0\n"))), "OK")
    assert_equal(
        _decode_err(_zlib(_with_nul("blob 012", "hello path0\n"))),
        p + "size: number has a leading zero",
    )
    assert_equal(
        _decode_err(_zlib(_with_nul("blub 12", "hello path0\n"))),
        p + "unknown kind",
    )
    assert_equal(
        _decode_err(_zlib(_with_nul("blob", "hello path0\n"))),
        p + "header has no space",
    )
    var long_head = String()
    for _ in range(70):
        long_head += "a"
    assert_equal(
        _decode_err(_zlib(_with_nul(long_head, "x"))),
        p + "no NUL in the first 64 bytes",
    )


def main() raises:
    test_read_git_files()
    test_encode_matches_git()
    test_round_trip_large()
    test_refusals()
    print("komira_git loose object tests passed")
