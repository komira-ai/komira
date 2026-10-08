# =============================================================================
# komira_git/tests/test_pack_index.mojo -- pack index v2: write, read, refuse.
# =============================================================================
#
# The byte layout is gitformat-pack's "Version 2 pack-*.idx files". That
# `serialize` writes what `git index-pack` writes, byte for byte, is checked
# against git itself in src/tests/conformance/komira_git_conformance; here
# the layout is checked field by field on an index built by hand.
#
# WHAT EACH TEST CATCHES:
#   * test_layout: a fan-out table that counts `<` instead of `<=` (entry i
#     is the count of first bytes up to and including i), CRCs or offsets in
#     the wrong order or endianness, a missing pack checksum, and an index
#     checksum over the wrong bytes.
#   * test_large_offsets: offsets over the threshold (and any over 31 bits)
#     moved to the eight-byte table in id order, the four-byte entry holding
#     0x80000000 | its position; read back to the same offsets.
#   * test_find: lookup by binary search, an absent id, an id of the other
#     format.
#   * test_parse_refusals: each refusal by its exact message.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto import Sha1

from komira_git import ObjectFormat, ObjectId, PackIndex, parse_pack_index


def _id(first: Int, last: Int) raises -> ObjectId:
    var raw = List[UInt8](length=20, fill=UInt8(0x11))
    raw[0] = UInt8(first)
    raw[19] = UInt8(last)
    return ObjectId.from_raw(ObjectFormat.sha1(), Span(raw))


def _list(a: Int, b: Int, c: Int, d: Int) -> List[Int]:
    var out = List[Int]()
    out.append(a)
    out.append(b)
    out.append(c)
    out.append(d)
    return out^


def _checksum() -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(20):
        out.append(UInt8(0xA0 + i))
    return out^


def _sample(offsets: List[Int]) raises -> PackIndex:
    """Four objects with first bytes 0x00, 0x05, 0x05, 0xFF."""
    var ids = List[ObjectId]()
    ids.append(_id(0x00, 1))
    ids.append(_id(0x05, 1))
    ids.append(_id(0x05, 2))
    ids.append(_id(0xFF, 1))
    var crcs = List[UInt32]()
    for i in range(4):
        crcs.append(UInt32(0x01020304 * (i + 1)))
    return PackIndex(ObjectFormat.sha1(), ids^, offsets.copy(), crcs^, _checksum())


def _be32(b: List[UInt8], at: Int) -> Int:
    return (Int(b[at]) << 24) | (Int(b[at + 1]) << 16) | (Int(b[at + 2]) << 8) | Int(b[at + 3])


def _sha1(b: Span[UInt8, _]) -> List[UInt8]:
    var h = Sha1()
    h.update(b)
    var out = List[UInt8](length=20, fill=UInt8(0))
    h.finalize_into(Span(out))
    return out^


def _reseal(mut b: List[UInt8]):
    """Recompute the index checksum after an edit."""
    var sum = _sha1(Span(b)[0 : len(b) - 20])
    for i in range(20):
        b[len(b) - 20 + i] = sum[i]


def test_layout() raises:
    var offsets = _list(12, 40, 300, 77)
    var idx = _sample(offsets)
    var b = idx.serialize()
    assert_equal(len(b), 8 + 1024 + 4 * (20 + 8) + 40)
    assert_equal(Int(b[0]), 0xFF)
    assert_equal(Int(b[1]), 0x74)
    assert_equal(Int(b[2]), 0x4F)
    assert_equal(Int(b[3]), 0x63)
    assert_equal(_be32(b, 4), 2)
    assert_equal(_be32(b, 8 + 4 * 0), 1)
    assert_equal(_be32(b, 8 + 4 * 4), 1)
    assert_equal(_be32(b, 8 + 4 * 5), 3)
    assert_equal(_be32(b, 8 + 4 * 254), 3)
    assert_equal(_be32(b, 8 + 4 * 255), 4)
    var ids_at = 8 + 1024
    assert_equal(Int(b[ids_at + 20]), 0x05)
    assert_equal(Int(b[ids_at + 20 + 19]), 1)
    var crcs_at = ids_at + 80
    assert_equal(_be32(b, crcs_at), 0x01020304)
    assert_equal(_be32(b, crcs_at + 12), 0x01020304 * 4)
    var offs_at = crcs_at + 16
    for i in range(4):
        assert_equal(_be32(b, offs_at + 4 * i), offsets[i])
    var pack_sum_at = offs_at + 16
    assert_equal(Int(b[pack_sum_at]), 0xA0)
    var sum = _sha1(Span(b)[0 : len(b) - 20])
    for i in range(20):
        assert_equal(Int(b[len(b) - 20 + i]), Int(sum[i]))
    var back = parse_pack_index(ObjectFormat.sha1(), Span(b))
    assert_equal(back.count(), 4)
    for i in range(4):
        assert_equal(back.id_at(i), idx.id_at(i))
        assert_equal(back.offset_at(i), offsets[i])
        assert_equal(back.crc32_at(i), idx.crc32_at(i))
    assert_equal(len(back.pack_checksum()), 20)
    assert_equal(Int(back.pack_checksum()[19]), 0xA0 + 19)
    var empty = PackIndex(ObjectFormat.sha1(), List[ObjectId](), List[Int](), List[UInt32](), _checksum())
    assert_equal(parse_pack_index(ObjectFormat.sha1(), Span(empty.serialize())).count(), 0)


def test_large_offsets() raises:
    var offsets = _list(12, 0x41, 1 << 33, 0x40)
    var idx = _sample(offsets)
    var b = idx.serialize(0x40)
    assert_equal(len(b), 8 + 1024 + 4 * 28 + 2 * 8 + 40)
    var offs_at = 8 + 1024 + 80 + 16
    assert_equal(_be32(b, offs_at), 12)
    assert_equal(_be32(b, offs_at + 4), 0x80000000)
    assert_equal(_be32(b, offs_at + 8), 0x80000001)
    assert_equal(_be32(b, offs_at + 12), 0x40)
    var large_at = offs_at + 16
    assert_equal(_be32(b, large_at), 0)
    assert_equal(_be32(b, large_at + 4), 0x41)
    assert_equal(_be32(b, large_at + 8), 2)
    assert_equal(_be32(b, large_at + 12), 0)
    var back = parse_pack_index(ObjectFormat.sha1(), Span(b))
    for i in range(4):
        assert_equal(back.offset_at(i), offsets[i])
    # Over 31 bits goes to the table whatever the threshold.
    var d = idx.serialize()
    assert_equal(len(d), 8 + 1024 + 4 * 28 + 8 + 40)
    assert_equal(_be32(d, offs_at + 8), 0x80000000)
    try:
        _ = idx.serialize(0x80000000)
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: pack index: large offset threshold 2147483648 is not in [0, 0x7fffffff]")


def test_find() raises:
    var idx = _sample(_list(12, 13, 14, 15))
    assert_equal(idx.find(_id(0x00, 1)), 0)
    assert_equal(idx.find(_id(0x05, 2)), 2)
    assert_equal(idx.find(_id(0xFF, 1)), 3)
    assert_equal(idx.find(_id(0x05, 3)), -1)
    assert_equal(idx.find(_id(0x06, 1)), -1)
    var raw = List[UInt8](length=32, fill=UInt8(0x11))
    raw[0] = 0
    raw[31] = 1
    assert_equal(idx.find(ObjectId.from_raw(ObjectFormat.sha256(), Span(raw))), -1)
    assert_true(idx.format() == ObjectFormat.sha1())


def _err(b: List[UInt8]) -> String:
    try:
        _ = parse_pack_index(ObjectFormat.sha1(), Span(b))
        return "OK"
    except e:
        return String(e)


def test_parse_refusals() raises:
    var p = "komira_git: pack index: "
    var good = _sample(_list(12, 40, 300, 77)).serialize()
    assert_equal(_err(good), "OK")
    assert_equal(_err(List[UInt8](length=1071, fill=UInt8(0))), p + "1071 bytes is shorter than an empty index")
    var b = good.copy()
    b[1] = 0x75
    _reseal(b)
    assert_equal(_err(b), p + "no version 2 magic (a version 1 index is not supported)")
    b = good.copy()
    b[7] = 3
    _reseal(b)
    assert_equal(_err(b), p + "version 3 is not 2")
    b = good.copy()
    b[len(b) - 1] ^= 1
    assert_equal(_err(b), p + "the checksum does not match")
    b = good.copy()
    b[8 + 4 * 3 + 3] = 2  # fan-out[3] = 2 > fan-out[4] = 1
    _reseal(b)
    assert_equal(_err(b), p + "fan-out entry 4 decreases")
    b = good.copy()
    b[8 + 4 * 255 + 3] = 5  # claims five objects
    _reseal(b)
    assert_equal(_err(b), p + "1184 bytes does not fit 5 objects")
    b = good.copy()
    b.insert(len(b) - 40, 0)
    _reseal(b)
    assert_equal(_err(b), p + "1185 bytes does not fit 4 objects")
    # Objects 1 and 2 swapped: out of order.
    b = good.copy()
    var ids_at = 8 + 1024
    b[ids_at + 20 + 19] = 2
    b[ids_at + 40 + 19] = 1
    _reseal(b)
    assert_equal(_err(b), p + "object 2 is not after the one before it")
    b = good.copy()
    b[ids_at + 40 + 19] = 1  # a repeat of object 1
    _reseal(b)
    assert_equal(_err(b), p + "object 2 is not after the one before it")
    # Fan-out says object 1 starts with 0x04 or lower.
    b = good.copy()
    b[8 + 4 * 4 + 3] = 2
    _reseal(b)
    assert_equal(_err(b), p + "the fan-out table disagrees with object 1")
    # Fan-out entry 5 alone says only two objects start with 0x05 or lower,
    # so object 2 (first byte 0x05) is past its group's end. Entries 6 and
    # up stay 3, so the table is monotone and only entry 5 under-counts.
    b = good.copy()
    b[8 + 4 * 5 + 3] = 2
    _reseal(b)
    assert_equal(_err(b), p + "the fan-out table disagrees with object 2")
    # Fan-out entry 0 says no object starts with 0x00, so object 0 (first
    # byte 0x00) is past its group's end. Entries 1 to 4 stay 1, so the
    # table is monotone; this is the only case that checks object 0.
    b = good.copy()
    b[8 + 3] = 0
    _reseal(b)
    assert_equal(_err(b), p + "the fan-out table disagrees with object 0")
    # Object 3 now starts with 0x06 (still after 0x05), but fan-out entry 6
    # counts only three objects, so the last object is past its group's
    # end. With first byte 0xFF its upper bound is the count and can never
    # be exceeded; this case checks the last object's upper bound.
    b = good.copy()
    b[ids_at + 60] = 6
    _reseal(b)
    assert_equal(_err(b), p + "the fan-out table disagrees with object 3")
    var offs_at = ids_at + 80 + 16
    b = good.copy()
    b[offs_at + 3] = 11
    _reseal(b)
    assert_equal(_err(b), p + "object 0 is at offset 11, inside the pack header")
    b = good.copy()
    b[offs_at + 4] = 0x80
    b[offs_at + 7] = 0
    _reseal(b)
    assert_equal(_err(b), p + "object 1 names eight-byte offset 0 of 0")
    var big = _sample(_list(12, 1 << 33, 14, 15)).serialize()
    assert_equal(_err(big), "OK")
    b = big.copy()
    b[offs_at + 16] = 0x80  # the eight-byte offset's top bit
    _reseal(b)
    assert_equal(_err(b), p + "object 1 has an offset over 2^63")


def main() raises:
    test_layout()
    test_large_offsets()
    test_find()
    test_parse_refusals()
    print("komira_git pack index tests passed")
