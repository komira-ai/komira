from std.testing import assert_equal, assert_true
from buildtools.bytes import normpath, sort_strings, split_words
from buildtools.doc_links import slug
from buildtools.json import canonical_document, flatten_document
from buildtools.sha256 import sha256_hex
from buildtools.tar import read_tar


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _put(mut blk: List[UInt8], off: Int, s: String):
    var b = s.as_bytes()
    for i in range(len(b)):
        blk[off + i] = b[i]


def _header(name: String, typeflag: String, size: Int, mode: String) -> List[UInt8]:
    """A ustar header with a correct checksum."""
    var blk = List[UInt8]()
    for _ in range(512):
        blk.append(UInt8(0))
    _put(blk, 0, name)
    _put(blk, 100, mode)
    _put(blk, 108, "0000000")
    _put(blk, 116, "0000000")
    var sz = String()
    var x = size
    for _ in range(11):
        sz = String(x % 8) + sz
        x //= 8
    _put(blk, 124, sz)
    _put(blk, 136, "00000000000")
    _put(blk, 156, typeflag)
    _put(blk, 257, "ustar")
    _put(blk, 263, "00")
    _put(blk, 148, "        ")
    var sum = 0
    for i in range(512):
        sum += Int(blk[i])
    var cs = String()
    for _ in range(6):
        cs = String(sum % 8) + cs
        sum //= 8
    _put(blk, 148, cs)
    return blk^


def _add(mut t: List[UInt8], b: List[UInt8]):
    for i in range(len(b)):
        t.append(b[i])


def _pad(mut b: List[UInt8]):
    while len(b) % 512 != 0:
        b.append(UInt8(0))


def test_sha256() raises:
    var empty = List[UInt8]()
    assert_equal(sha256_hex(empty, 0, 0), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    var abc = _bytes("abc")
    assert_equal(sha256_hex(abc, 0, 3), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    # Two blocks: 56 bytes of message force the length into a second block.
    var two = _bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
    assert_equal(sha256_hex(two, 0, len(two)), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")


def test_json() raises:
    var out = String()
    flatten_document(_bytes('{"a": [1, "x\\ty"], "b": {}, "c": {"d": null}}'), String(""), out)
    assert_equal(out, "a\t0\t1\na\t1\tx\\ty\nb\t{}\nc\td\tnull\n")
    assert_equal(
        canonical_document(_bytes('{"b": 1, "a": ["\\u00e9", true], "A": "q\\""}')),
        '{"A":"q\\"","a":["\\u00e9",true],"b":1}',
    )
    var refused = False
    try:
        _ = canonical_document(_bytes('{"a": 1} x'))
    except:
        refused = True
    assert_true(refused, "trailing data must be refused")


def test_tar() raises:
    var t = List[UInt8]()
    _add(t, _header("top/", "5", 0, "0000755"))
    # A PAX path longer than the 100-byte name field.
    var long_name = String("top/")
    for _ in range(120):
        long_name += "d"
    long_name += "/f.txt"
    var rec = " path=" + long_name + "\n"
    var n = rec.byte_length() + 3
    rec = String(n) + rec
    _add(t, _header("PaxHeader", "x", rec.byte_length(), "0000644"))
    _add(t, _bytes(rec))
    _pad(t)
    _add(t, _header("short", "0", 3, "0000644"))
    _add(t, _bytes("abc"))
    _pad(t)
    for _ in range(1024):
        t.append(UInt8(0))
    var m = read_tar(t)
    assert_equal(len(m), 2)
    assert_equal(m[0].name, "top")
    assert_true(m[0].is_dir())
    assert_equal(m[1].name, long_name)
    assert_true(m[1].pax_path)
    assert_equal(m[1].mode, 420)
    assert_equal(sha256_hex(t, m[1].offset, m[1].offset + m[1].size), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")


def test_paths_and_words() raises:
    assert_equal(normpath("a/./b/../c"), "a/c")
    assert_equal(normpath("./x"), "x")
    assert_equal(normpath("../x"), "../x")
    assert_equal(normpath("/a/../../b"), "/b")
    assert_equal(normpath(""), ".")
    var w = split_words("  a\tb \n c  ")
    assert_equal(len(w), 3)
    assert_equal(w[2], "c")
    var s: List[String] = ["b", "B", "a", "ab"]
    sort_strings(s)
    assert_equal(s[0], "B")
    assert_equal(s[3], "b")


def test_slug() raises:
    assert_equal(slug("8. Host floor and runtime libraries"), "8-host-floor-and-runtime-libraries")
    assert_equal(slug("Protobuf: `mojo_proto_library`"), "protobuf-mojo_proto_library")
    assert_equal(slug("C and C++"), "c-and-c")
    assert_equal(slug("See [x](y.md) — z"), "see-x--z")


def main() raises:
    test_sha256()
    test_json()
    test_tar()
    test_paths_and_words()
    test_slug()
    print("test_buildtools: PASS")
