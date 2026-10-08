# =============================================================================
# komira_git/tests/test_pack_reader.mojo -- indexing a pack and reading
# objects out of it, on packs built here entry by entry.
# =============================================================================
#
# The packs are assembled by `_pack_of` in the layout of gitformat-pack
# (header, entries, SHA-1 trailer); entry headers, OFS_DELTA distances and
# REF_DELTA ids are encoded as git's pack-objects encodes them
# (`_entry_header`, `_ofs` follow write_no_reuse_object). Packs git itself
# writes are read by src/tests/conformance/komira_git_conformance.
#
# WHAT EACH TEST CATCHES:
#   * test_index_and_read: one pack holding a 300-byte and a 5000-byte blob
#     (two- and three-byte entry headers), an OFS_DELTA 300+ bytes after its
#     base (a two-byte distance), an OFS_DELTA of that delta (depth 2), a
#     REF_DELTA whose base comes after it in the pack, a tree, and a
#     REF_DELTA of the tree. Catches a size varint read without its
#     continuation or with the wrong shift, an OFS distance decoded without
#     gitformat-pack's "+1 per continuation" (the base lands on no entry), a
#     REF base looked up only among earlier entries, a delta that does not
#     inherit its base's kind, a wrong depth, base id, offset, packed size or
#     CRC-32 (each checked per entry), and an index that does not find each
#     object at its offset.
#   * test_thin_pack: a REF_DELTA on an object outside the pack is refused
#     by `index_pack` and resolved by `index_thin_pack` from
#     `ExternalBases` (depth 1, base id the outside object's), and read back
#     with `read_thin_pack_object`.
#   * test_reader_refusals: `read_pack_object` refuses an id not in the
#     index, an index of another pack, an index entry whose offset holds a
#     different object, a chain over the depth limit, and a REF base that is
#     neither in the pack nor given.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto import Sha1
from komira_zlib import ZLIB_WINDOW_BITS_ZLIB, zlib_compress_bound, zlib_crc32, zlib_deflate_into

from komira_git import (
    MODE_BLOB,
    PACK_OBJ_BLOB,
    PACK_OBJ_OFS_DELTA,
    PACK_OBJ_REF_DELTA,
    PACK_OBJ_TREE,
    ExternalBases,
    ObjectFormat,
    ObjectId,
    ObjectKind,
    PackIndex,
    PackLimits,
    Tree,
    hash_object,
    index_pack,
    index_thin_pack,
    parse_pack_index,
    read_pack_object,
    read_thin_pack_object,
)


# ---- pack building ------------------------------------------------------------


def _bytes(s: String) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def _noise(n: Int, seed: Int) -> List[UInt8]:
    """`n` bytes zlib cannot shrink (a linear congruential sequence)."""
    var out = List[UInt8](capacity=n)
    var x = seed
    for _ in range(n):
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        out.append(UInt8((x >> 16) & 255))
    return out^


def _z(payload: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8](length=zlib_compress_bound(len(payload), ZLIB_WINDOW_BITS_ZLIB), fill=UInt8(0))
    var n = zlib_deflate_into(Span(out), Span(payload), 6, ZLIB_WINDOW_BITS_ZLIB)
    out.resize(n, UInt8(0))
    return out^


def _entry_header(t: Int, size: Int) -> List[UInt8]:
    var out = List[UInt8]()
    var c = (t << 4) | (size & 15)
    var rest = size >> 4
    while rest > 0:
        out.append(UInt8(c | 128))
        c = rest & 127
        rest >>= 7
    out.append(UInt8(c))
    return out^


def _ofs(dist: Int) -> List[UInt8]:
    var rev = List[UInt8]()
    var d = dist
    rev.append(UInt8(d & 127))
    d >>= 7
    while d > 0:
        d -= 1
        rev.append(UInt8(128 | (d & 127)))
        d >>= 7
    var out = List[UInt8]()
    var i = len(rev) - 1
    while i >= 0:
        out.append(rev[i])
        i -= 1
    return out^


def _obj(t: Int, payload: List[UInt8]) raises -> List[UInt8]:
    var out = _entry_header(t, len(payload))
    out.extend(Span(_z(payload)))
    return out^


def _ofs_delta(dist: Int, delta: List[UInt8]) raises -> List[UInt8]:
    var out = _entry_header(PACK_OBJ_OFS_DELTA, len(delta))
    out.extend(Span(_ofs(dist)))
    out.extend(Span(_z(delta)))
    return out^


def _ref_delta(base: ObjectId, delta: List[UInt8]) raises -> List[UInt8]:
    var out = _entry_header(PACK_OBJ_REF_DELTA, len(delta))
    base.append_raw_to(out)
    out.extend(Span(_z(delta)))
    return out^


def _varint(mut out: List[UInt8], v: Int):
    var x = v
    while x >= 128:
        out.append(UInt8((x & 127) | 128))
        x >>= 7
    out.append(UInt8(x))


def _delta(base: List[UInt8], keep: Int, tail: String) -> List[UInt8]:
    """A delta rebuilding `base[0:keep] + tail`; returns the delta."""
    var t = _bytes(tail)
    var out = List[UInt8]()
    _varint(out, len(base))
    _varint(out, keep + len(t))
    if keep > 0:
        out.append(0x80 | 0x10 | 0x20)  # copy: offset 0, two size bytes
        out.append(UInt8(keep & 255))
        out.append(UInt8(keep >> 8))
    if len(t) > 0:
        out.append(UInt8(len(t)))
        out.extend(Span(t))
    return out^


def _rebuilt(base: List[UInt8], keep: Int, tail: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(base)[0:keep])
    out.extend(Span(_bytes(tail)))
    return out^


def _pack_of(entries: List[List[UInt8]]) -> List[UInt8]:
    var out = _bytes("PACK")
    for b in [0, 0, 0, 2]:
        out.append(UInt8(b))
    var n = len(entries)
    out.append(UInt8((n >> 24) & 255))
    out.append(UInt8((n >> 16) & 255))
    out.append(UInt8((n >> 8) & 255))
    out.append(UInt8(n & 255))
    for i in range(len(entries)):
        out.extend(Span(entries[i]))
    var h = Sha1()
    h.update(Span(out))
    var sum = List[UInt8](length=20, fill=UInt8(0))
    h.finalize_into(Span(sum))
    out.extend(Span(sum))
    return out^


def _offsets(entries: List[List[UInt8]]) -> List[Int]:
    var out = List[Int]()
    var at = 12
    for i in range(len(entries)):
        out.append(at)
        at += len(entries[i])
    return out^


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


# ---- tests ----------------------------------------------------------------------


def test_index_and_read() raises:
    var f = ObjectFormat.sha1()
    var a = _noise(300, 1)
    var c = List[UInt8]()
    for i in range(500):
        c.extend(Span(_bytes("line " + String(1000 + i) + "\n")))
    assert_true(len(c) > 2048)
    var b = _bytes("the base of a REF_DELTA, placed after it in the pack\n")
    var tree = Tree(f)
    tree.add(MODE_BLOB, "a.bin", hash_object(f, ObjectKind.blob(), Span(a)))
    var t = tree.serialize()
    var a1 = _rebuilt(a, 100, "tail-1")
    var a2 = _rebuilt(a1, 50, "tail-2")
    var b1 = _rebuilt(b, 10, "ref")
    var t1 = _rebuilt(t, len(t), "")
    var id_a = hash_object(f, ObjectKind.blob(), Span(a))
    var id_b = hash_object(f, ObjectKind.blob(), Span(b))
    var id_t = hash_object(f, ObjectKind.tree(), Span(t))

    var entries = List[List[UInt8]]()
    entries.append(_obj(PACK_OBJ_BLOB, a))  # 0
    entries.append(_obj(PACK_OBJ_BLOB, c))  # 1
    var offs = _offsets(entries)
    var at2 = offs[1] + len(entries[1])
    entries.append(_ofs_delta(at2 - offs[0], _delta(a, 100, "tail-1")))  # 2
    var at3 = at2 + len(entries[2])
    entries.append(_ofs_delta(at3 - at2, _delta(a1, 50, "tail-2")))  # 3
    entries.append(_ref_delta(id_b, _delta(b, 10, "ref")))  # 4
    entries.append(_obj(PACK_OBJ_BLOB, b))  # 5
    entries.append(_obj(PACK_OBJ_TREE, t))  # 6
    entries.append(_ref_delta(id_t, _delta(t, len(t), "")))  # 7
    offs = _offsets(entries)
    assert_true(offs[2] - offs[0] > 300)
    assert_equal(len(_entry_header(PACK_OBJ_BLOB, len(a))), 2)
    assert_equal(len(_entry_header(PACK_OBJ_BLOB, len(c))), 3)
    var pack = _pack_of(entries)

    var payloads = List[List[UInt8]]()
    payloads.append(a.copy())
    payloads.append(c.copy())
    payloads.append(a1.copy())
    payloads.append(a2.copy())
    payloads.append(b1.copy())
    payloads.append(b.copy())
    payloads.append(t.copy())
    payloads.append(t1.copy())
    var kinds = List[ObjectKind]()
    for k in [3, 3, 3, 3, 3, 3, 2, 2]:
        kinds.append(ObjectKind.from_code(k))
    var types = [3, 3, 6, 6, 7, 3, 2, 7]
    var depths = [0, 0, 1, 2, 1, 0, 0, 1]
    var bases = List[ObjectId]()
    var zero = ObjectId.zero(f)
    bases.append(zero)
    bases.append(zero)
    bases.append(id_a)
    bases.append(hash_object(f, ObjectKind.blob(), Span(a1)))
    bases.append(id_b)
    bases.append(zero)
    bases.append(zero)
    bases.append(id_t)

    var limits = PackLimits()
    var got = index_pack(f, Span(pack), limits)
    assert_equal(len(got.entries), 8)
    assert_equal(got.index.count(), 8)
    for i in range(8):
        var e = got.entries[i].copy()
        var want_id = hash_object(f, kinds[i], Span(payloads[i]))
        assert_equal(e.id, want_id)
        assert_true(e.kind == kinds[i])
        assert_equal(e.type_code, types[i])
        assert_equal(e.depth, depths[i])
        assert_equal(e.base_id, bases[i])
        assert_equal(e.offset, offs[i])
        assert_equal(e.packed_size, len(entries[i]))
        assert_equal(e.crc32, zlib_crc32(Span(entries[i])))
        assert_equal(e.is_delta(), types[i] >= 6)
        var pos = got.index.find(want_id)
        assert_true(pos >= 0)
        assert_equal(got.index.offset_at(pos), offs[i])
        assert_equal(got.index.crc32_at(pos), e.crc32)
        var obj = read_pack_object(Span(pack), got.index, want_id, limits)
        assert_true(obj.kind == kinds[i])
        assert_true(_same(obj.payload, payloads[i]))
    for i in range(1, 8):
        assert_true(got.index.id_at(i - 1).to_hex() < got.index.id_at(i).to_hex())
    var trailer = got.index.pack_checksum()
    assert_equal(len(trailer), 20)
    assert_equal(Int(trailer[19]), Int(pack[len(pack) - 1]))
    # The index written and read back is the same index.
    var again = parse_pack_index(f, Span(got.index.serialize()))
    assert_equal(again.count(), 8)
    for i in range(8):
        assert_equal(again.id_at(i), got.index.id_at(i))
        assert_equal(again.offset_at(i), got.index.offset_at(i))
        assert_equal(again.crc32_at(i), got.index.crc32_at(i))
    # Version 3 packs are read as version 2 ones.
    var v3 = pack.copy()
    v3[7] = 3
    var h = Sha1()
    h.update(Span(v3)[0 : len(v3) - 20])
    var sum = List[UInt8](length=20, fill=UInt8(0))
    h.finalize_into(Span(sum))
    for i in range(20):
        v3[len(v3) - 20 + i] = sum[i]
    assert_equal(index_pack(f, Span(v3), limits).index.count(), 8)


def test_thin_pack() raises:
    var f = ObjectFormat.sha1()
    var outside = _bytes("an object the receiver already has, not sent in the pack\n")
    var id_out = hash_object(f, ObjectKind.blob(), Span(outside))
    var r1 = _rebuilt(outside, 20, "-thin")
    var entries = List[List[UInt8]]()
    entries.append(_ref_delta(id_out, _delta(outside, 20, "-thin")))
    var offs0 = _offsets(entries)
    var at1 = offs0[0] + len(entries[0])
    var r2 = _rebuilt(r1, 5, "+2")
    entries.append(_ofs_delta(at1 - offs0[0], _delta(r1, 5, "+2")))
    var pack = _pack_of(entries)
    var limits = PackLimits()
    try:
        _ = index_pack(f, Span(pack), limits)
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: pack: 2 deltas have no base in the pack")
    var bases = ExternalBases(f)
    assert_equal(bases.add(ObjectKind.blob(), Span(outside)), id_out)
    _ = bases.add(ObjectKind.blob(), Span(outside))
    assert_equal(bases.count(), 1)
    var got = index_thin_pack(f, Span(pack), limits, bases)
    assert_equal(got.index.count(), 2)
    assert_equal(got.index.find(id_out), -1)
    var id1 = hash_object(f, ObjectKind.blob(), Span(r1))
    var id2 = hash_object(f, ObjectKind.blob(), Span(r2))
    assert_equal(got.entries[0].id, id1)
    assert_equal(got.entries[0].depth, 1)
    assert_equal(got.entries[0].base_id, id_out)
    assert_equal(got.entries[1].id, id2)
    assert_equal(got.entries[1].depth, 2)
    assert_equal(got.entries[1].base_id, id1)
    var obj = read_thin_pack_object(Span(pack), got.index, id2, limits, bases)
    assert_true(_same(obj.payload, r2))
    try:
        _ = read_pack_object(Span(pack), got.index, id2, limits)
        assert_true(False)
    except e:
        assert_equal(
            String(e),
            "komira_git: pack: object " + id2.to_hex() + ": delta base "
            + id_out.to_hex() + " is not in the pack",
        )


def _read_err(pack: List[UInt8], index: PackIndex, id: ObjectId, limits: PackLimits) -> String:
    try:
        _ = read_pack_object(Span(pack), index, id, limits)
        return "OK"
    except e:
        return String(e)


def test_reader_refusals() raises:
    var f = ObjectFormat.sha1()
    var a = _bytes("first object of the reader refusal pack\n")
    var b = _bytes("second object of the reader refusal pack\n")
    var a1 = _rebuilt(a, 10, "+1")
    var a2 = _rebuilt(a1, 5, "+2")
    var entries = List[List[UInt8]]()
    entries.append(_obj(PACK_OBJ_BLOB, a))
    entries.append(_obj(PACK_OBJ_BLOB, b))
    var offs = _offsets(entries)
    var at2 = offs[1] + len(entries[1])
    entries.append(_ofs_delta(at2 - offs[0], _delta(a, 10, "+1")))
    var at3 = at2 + len(entries[2])
    entries.append(_ofs_delta(at3 - at2, _delta(a1, 5, "+2")))
    var pack = _pack_of(entries)
    var limits = PackLimits()
    var got = index_pack(f, Span(pack), limits)
    var p = "komira_git: pack: "
    var id_a = hash_object(f, ObjectKind.blob(), Span(a))
    var id_b = hash_object(f, ObjectKind.blob(), Span(b))
    var id_a2 = hash_object(f, ObjectKind.blob(), Span(a2))
    var missing = hash_object(f, ObjectKind.blob(), Span(_bytes("absent")))
    assert_equal(_read_err(pack, got.index, missing, limits), p + "object " + missing.to_hex() + " is not in the pack")
    assert_equal(_read_err(pack, got.index, id_a2, limits), "OK")
    assert_equal(
        _read_err(pack, got.index, id_a2, PackLimits(max_delta_depth=1)),
        p + "object " + id_a2.to_hex() + ": delta chain is longer than the limit 1",
    )
    var other = pack.copy()
    other[len(other) - 1] ^= 1
    assert_equal(_read_err(other, got.index, id_a, limits), p + "the index describes another pack")
    assert_equal(_read_err(List[UInt8](length=20, fill=UInt8(0)), got.index, id_a, limits), p + "20 bytes is shorter than a header and a trailer")
    # An index that puts object a at b's entry.
    var ids = List[ObjectId]()
    var offsets = List[Int]()
    var crcs = List[UInt32]()
    ids.append(id_a)
    offsets.append(offs[1])
    crcs.append(0)
    var wrong = PackIndex(f, ids^, offsets^, crcs^, got.index.pack_checksum())
    assert_equal(
        _read_err(pack, wrong, id_a, limits),
        p + "the entry at offset " + String(offs[1]) + " is object " + id_b.to_hex()
        + ", the index says " + id_a.to_hex(),
    )


def main() raises:
    test_index_and_read()
    test_thin_pack()
    test_reader_refusals()
    print("komira_git pack reader tests passed")
