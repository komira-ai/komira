# =============================================================================
# komira_git/tests/test_object_ids.mojo -- object formats, kinds, ids and
# `hash_object`.
# =============================================================================
#
# WHERE THE EXPECTED IDS COME FROM (git v2.47.0's own test suite):
#   * t/oid-info/hash-info: `empty_blob`, `empty_tree`, `zero`, `rawsz`,
#     `hexsz` for sha1 and sha256.
#   * t/t1007-hash-object.sh: `hello` ("Hello World", no newline) and
#     `example` ("This is an example", no newline), sha1 and sha256.
#   * t/t0000-basic.sh: the eight blobs of the "various types of objects"
#     tree: `echo "hello $p" >$p` (content with a newline) and the symlink
#     `${p}sym` whose target is "hello $p" (no newline), for $p in path0,
#     path2/file2, path3/file3, path3/subp3/file3 (`path0f`, `path0s`, ...).
#
# WHAT EACH TEST CATCHES:
#   * test_hash_vectors_*: a wrong header (`<kind> <size>\0`), a wrong size
#     spelling, a wrong hash per format.
#   * test_parse_hex_*: length and digit checks, case folding on output.
#   * test_ids_of_two_formats_differ: an id comparing equal across formats.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_git import ObjectFormat, ObjectId, ObjectKind, hash_object, object_header


def _b(s: String) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def _blob_hex(format: ObjectFormat, content: String) raises -> String:
    var data = _b(content)
    return hash_object(format, ObjectKind.blob(), Span(data)).to_hex()


def _parse_err(format: ObjectFormat, text: String) -> String:
    try:
        _ = ObjectId.parse_hex(format, text)
    except e:
        return String(e)
    return String("OK")


def test_formats() raises:
    var s1 = ObjectFormat.sha1()
    var s2 = ObjectFormat.sha256()
    assert_equal(s1.raw_size(), 20)
    assert_equal(s1.hex_size(), 40)
    assert_equal(s2.raw_size(), 32)
    assert_equal(s2.hex_size(), 64)
    assert_equal(s1.name(), "sha1")
    assert_equal(s2.name(), "sha256")
    assert_true(ObjectFormat.from_name("sha256") == s2)
    assert_true(s1 != s2)
    try:
        _ = ObjectFormat.from_name("sha512")
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: unknown object format 'sha512'")


def test_kinds() raises:
    assert_equal(ObjectKind.commit().code(), 1)
    assert_equal(ObjectKind.tree().code(), 2)
    assert_equal(ObjectKind.blob().code(), 3)
    assert_equal(ObjectKind.tag().code(), 4)
    assert_equal(ObjectKind.from_code(4).name(), "tag")
    var tr = _b("tree")
    assert_true(ObjectKind.from_name(Span(tr)) == ObjectKind.tree())
    try:
        var bb = _b("Blob")
        _ = ObjectKind.from_name(Span(bb))
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: unknown object kind")
    try:
        var bt = _b("tags")
        _ = ObjectKind.from_name(Span(bt))
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: unknown object kind 'tags'")
    try:
        _ = ObjectKind.from_code(5)
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: unknown object type number 5")


def test_object_header() raises:
    var h = object_header(ObjectKind.blob(), 11)
    var want = _b("blob 11")
    want.append(UInt8(0))
    assert_equal(len(h), len(want))
    for i in range(len(h)):
        assert_equal(h[i], want[i])


def test_hash_vectors_hash_info() raises:
    var s1 = ObjectFormat.sha1()
    var s2 = ObjectFormat.sha256()
    assert_equal(_blob_hex(s1, ""), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    assert_equal(
        _blob_hex(s2, ""),
        "473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813",
    )
    var empty = List[UInt8]()
    assert_equal(
        hash_object(s1, ObjectKind.tree(), Span(empty)).to_hex(),
        "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
    )
    assert_equal(
        hash_object(s2, ObjectKind.tree(), Span(empty)).to_hex(),
        "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321",
    )
    assert_equal(
        ObjectId.zero(s1).to_hex(), "0000000000000000000000000000000000000000"
    )
    assert_equal(ObjectId.zero(s2).to_hex().byte_length(), 64)


def test_hash_vectors_t1007() raises:
    var s1 = ObjectFormat.sha1()
    var s2 = ObjectFormat.sha256()
    assert_equal(
        _blob_hex(s1, "Hello World"), "5e1c309dae7f45e0f39b1bf3ac3cd9db12e7d689"
    )
    assert_equal(
        _blob_hex(s2, "Hello World"),
        "1e3b6c04d2eeb2b3e45c8a330445404c0b7cc7b257e2b097167d26f5230090c4",
    )
    assert_equal(
        _blob_hex(s1, "This is an example"),
        "ddd3f836d3e3fbb7ae289aa9ae83536f76956399",
    )
    assert_equal(
        _blob_hex(s2, "This is an example"),
        "b44fe1fe65589848253737db859bd490453510719d7424daab03daf0767b85ae",
    )


def test_hash_vectors_t0000() raises:
    var s1 = ObjectFormat.sha1()
    var s2 = ObjectFormat.sha256()
    # path0f / path0s
    assert_equal(_blob_hex(s1, "hello path0\n"), "f87290f8eb2cbbea7857214459a0739927eab154")
    assert_equal(
        _blob_hex(s2, "hello path0\n"),
        "638106af7c38be056f3212cbd7ac65bc1bac74f420ca5a436ff006a9d025d17d",
    )
    assert_equal(_blob_hex(s1, "hello path0"), "15a98433ae33114b085f3eb3bb03b832b3180a01")
    assert_equal(
        _blob_hex(s2, "hello path0"),
        "3a24cc53cf68edddac490bbf94a418a52932130541361f685df685e41dd6c363",
    )
    # path2f / path2s
    assert_equal(
        _blob_hex(s1, "hello path2/file2\n"), "3feff949ed00a62d9f7af97c15cd8a30595e7ac7"
    )
    assert_equal(
        _blob_hex(s2, "hello path2/file2\n"),
        "2a7f36571c6fdbaf0e3f62751a0b25a3f4c54d2d1137b3f4af9cb794bb498e5f",
    )
    assert_equal(
        _blob_hex(s1, "hello path2/file2"), "d8ce161addc5173867a3c3c730924388daedbc38"
    )
    assert_equal(
        _blob_hex(s2, "hello path2/file2"),
        "18fd611b787c2e938ddcc248fabe4d66a150f9364763e9ec133dd01d5bb7c65a",
    )
    # path3f / path3s
    assert_equal(
        _blob_hex(s1, "hello path3/file3\n"), "0aa34cae68d0878578ad119c86ca2b5ed5b28376"
    )
    assert_equal(
        _blob_hex(s2, "hello path3/file3\n"),
        "09f58616b951bd571b8cb9dc76d372fbb09ab99db2393f5ab3189d26c45099ad",
    )
    assert_equal(
        _blob_hex(s1, "hello path3/file3"), "8599103969b43aff7e430efea79ca4636466794f"
    )
    assert_equal(
        _blob_hex(s2, "hello path3/file3"),
        "fce1aed087c053306f3f74c32c1a838c662bbc4551a7ac2420f5d6eb061374d0",
    )
    # subp3f / subp3s
    assert_equal(
        _blob_hex(s1, "hello path3/subp3/file3\n"),
        "00fb5908cb97c2564a9783c0c64087333b3b464f",
    )
    assert_equal(
        _blob_hex(s2, "hello path3/subp3/file3\n"),
        "a1a9e16998c988453f18313d10375ee1d0ddefe757e710dcae0d66aa1e0c58b3",
    )
    assert_equal(
        _blob_hex(s1, "hello path3/subp3/file3"),
        "6649a1ebe9e9f1c553b66f5a6e74136a07ccc57c",
    )
    assert_equal(
        _blob_hex(s2, "hello path3/subp3/file3"),
        "81759d9f5e93c6546ecfcadb560c1ff057314b09f93fe8ec06e2d8610d34ef10",
    )


def test_parse_hex_round_trip() raises:
    var s1 = ObjectFormat.sha1()
    var id = ObjectId.parse_hex(s1, "E69DE29BB2D1D6434B8B29AE775AD8C2E48C5391")
    assert_equal(id.to_hex(), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    assert_equal(String(id), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    assert_equal(Int(id.byte_at(0)), 0xE6)
    assert_equal(Int(id.byte_at(19)), 0x91)
    var raw = id.raw_bytes()
    assert_equal(len(raw), 20)
    assert_true(ObjectId.from_raw(s1, Span(raw)) == id)
    assert_false(id.is_zero())
    assert_true(ObjectId.zero(s1).is_zero())
    var s2 = ObjectFormat.sha256()
    var long = ObjectId.parse_hex(
        s2, "473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813"
    )
    assert_equal(len(long.raw_bytes()), 32)
    assert_equal(Int(long.byte_at(31)), 0x13)
    assert_true(long.format() == s2)


def test_parse_hex_refusals() raises:
    var s1 = ObjectFormat.sha1()
    assert_equal(
        _parse_err(s1, "e69de29b"), "komira_git: a sha1 id is 40 hex digits, got 8"
    )
    assert_equal(
        _parse_err(
            ObjectFormat.sha256(), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
        ),
        "komira_git: a sha256 id is 64 hex digits, got 40",
    )
    assert_equal(
        _parse_err(s1, "e69de29bb2d1d6434b8b29ae775ad8c2e48c539g"),
        "komira_git: bad hex digit in object id at offset 39",
    )
    var short = List[UInt8](length=19, fill=UInt8(0))
    try:
        _ = ObjectId.from_raw(s1, Span(short))
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: a sha1 id is 20 bytes, got 19")


def test_ids_of_two_formats_differ() raises:
    assert_true(ObjectId.zero(ObjectFormat.sha1()) != ObjectId.zero(ObjectFormat.sha256()))


def main() raises:
    test_formats()
    test_kinds()
    test_object_header()
    test_hash_vectors_hash_info()
    test_hash_vectors_t1007()
    test_hash_vectors_t0000()
    test_parse_hex_round_trip()
    test_parse_hex_refusals()
    test_ids_of_two_formats_differ()
    print("komira_git object id tests passed")
