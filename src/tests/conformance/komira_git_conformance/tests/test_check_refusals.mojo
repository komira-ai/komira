# =============================================================================
# komira_git_conformance/tests/test_check_refusals.mojo -- the oracle can
# fail: each check of check.mojo and each parse refusal of fixtures.mojo,
# shown raising its own message on input that breaks exactly that check.
# =============================================================================
#
# test_git_packs and test_git_thin_sha256 pass only if every check of
# `check_pack` holds; that proves something only if each check can fail.
# Here the `nodelta` pack's own fixtures pass `check_pack` unchanged, and
# then one thing at a time is changed and the exact message is required:
#   * git's index with one byte flipped: require_same_bytes;
#   * a verify-pack listing with one line fewer, one id replaced, and one
#     line's offset, size in the pack, kind, depth or base changed;
#   * a cat-file dump with one object fewer, one id replaced, one kind
#     changed, one payload byte flipped and one payload a byte longer.
# A check deleted, or comparing the wrong field, lets its case through (or
# raises another case's message) and fails here. require_same_bytes and
# require_same_index are also driven directly (each length order; for
# require_same_bytes a difference at the first and at the last byte, for
# require_same_index an id, offset and CRC-32 difference at the first and at
# the last entry), and every refusal of parse_batch, parse_verify and
# parse_ids gets input of the wrong shape, with too few and too many fields.
# =============================================================================

from std.testing import assert_equal

from komira_git import ObjectFormat, ObjectId, PackIndex

from komira_git_conformance import (
    GitObjects,
    VerifyLine,
    check_pack,
    parse_batch,
    parse_ids,
    parse_verify,
    read_fixture,
    require_same_bytes,
    require_same_index,
)


comptime _NAME = "nodelta"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    return out^


def _check(
    pack: List[UInt8], idx: List[UInt8], lines: List[VerifyLine], objects: GitObjects
) -> String:
    try:
        var stats = check_pack(ObjectFormat.sha1(), _NAME, pack, idx, lines, objects)
        return "OK " + String(stats.entries)
    except e:
        return String(e)


def _batch(
    o: GitObjects,
    drop: Int = -1,
    zero_id_at: Int = -1,
    kind_at: Int = -1,
    flip_at: Int = -1,
    grow_at: Int = -1,
) raises -> GitObjects:
    """`o` written back as `git cat-file --batch` prints it and parsed again,
    with object `drop` left out, object `zero_id_at` given the null id,
    object `kind_at` another kind, object `flip_at`'s first payload byte
    flipped and object `grow_at`'s payload one byte longer."""
    var out = List[UInt8]()
    for i in range(o.count()):
        if i == drop:
            continue
        var hex = ObjectId.zero(o.format).to_hex() if i == zero_id_at else o.ids[i].to_hex()
        var kind = o.kinds[i].name()
        if i == kind_at:
            kind = "tree" if kind == "blob" else "blob"
        var payload = o.payloads[i].copy()
        if i == flip_at:
            payload[0] = payload[0] ^ 1
        if i == grow_at:
            payload.append(10)
        out.extend(_bytes(hex + " " + kind + " " + String(len(payload)) + "\n"))
        out.extend(Span(payload))
        out.append(10)
    return parse_batch(o.format, Span(out))


def _first_nonempty(o: GitObjects) -> Int:
    for i in range(o.count()):
        if len(o.payloads[i]) > 0:
            return i
    return -1


def test_check_pack_each_check_fails() raises:
    var f = ObjectFormat.sha1()
    var pack = read_fixture(_NAME + ".pack")
    var idx = read_fixture(_NAME + ".idx")
    var lines = parse_verify(Span(read_fixture(_NAME + ".verify")))
    var objects = parse_batch(f, Span(read_fixture("objects.batch")))
    var n = len(lines)

    # Unchanged, the fixtures pass: every case below changes one thing.
    assert_equal(_check(pack, idx, lines, objects), "OK " + String(n))

    # git's index, one fan-out byte flipped.
    var bad_idx = idx.copy()
    bad_idx[8] = bad_idx[8] ^ 1
    assert_equal(
        _check(pack, bad_idx, lines, objects),
        _NAME + ".idx: byte 8 is " + String(Int(idx[8])) + ", git's is "
        + String(Int(bad_idx[8])),
    )

    # The listing, one line fewer.
    var fewer = lines.copy()
    _ = fewer.pop()
    assert_equal(
        _check(pack, idx, fewer, objects),
        _NAME + ": verify-pack lists " + String(n - 1) + " entries, we read " + String(n),
    )

    # The listing: the last line changed, field by field. The entries are
    # checked in pack order, so the last line's entry is reached only after
    # every other entry passed.
    var j = n - 1
    var hex = lines[j].id
    var at = _NAME + ": " + hex + ": "

    var other_id = lines.copy()
    other_id[j].id = ObjectId.zero(f).to_hex()
    assert_equal(
        _check(pack, idx, other_id, objects),
        _NAME + ": " + hex + " is not in verify-pack's listing",
    )

    var offset = lines.copy()
    offset[j].offset += 1
    assert_equal(
        _check(pack, idx, offset, objects),
        at + "offset " + String(lines[j].offset) + ", git's " + String(lines[j].offset + 1),
    )

    var size = lines.copy()
    size[j].packed_size += 1
    assert_equal(
        _check(pack, idx, size, objects),
        at + "size in pack " + String(lines[j].packed_size) + ", git's "
        + String(lines[j].packed_size + 1),
    )

    var kind = lines.copy()
    kind[j].kind = "tree" if lines[j].kind == "blob" else "blob"
    assert_equal(
        _check(pack, idx, kind, objects),
        at + "kind " + lines[j].kind + ", git's " + kind[j].kind,
    )

    var depth = lines.copy()
    depth[j].depth += 1
    assert_equal(
        _check(pack, idx, depth, objects),
        at + "depth " + String(lines[j].depth) + ", git's " + String(lines[j].depth + 1),
    )

    var base = lines.copy()
    base[j].base = "x"
    assert_equal(
        _check(pack, idx, base, objects),
        at + "base " + lines[j].base + ", git's x",
    )

    # The cat-file dump. Unchanged after the round trip through _batch.
    assert_equal(_check(pack, idx, lines, _batch(objects)), "OK " + String(n))

    assert_equal(
        _check(pack, idx, lines, _batch(objects, drop=0)),
        _NAME + ": " + String(n) + " entries, the repository has " + String(n - 1) + " objects",
    )

    var k = objects.count() - 1
    var at_k = _NAME + ": " + objects.ids[k].to_hex() + ": "
    assert_equal(
        _check(pack, idx, lines, _batch(objects, zero_id_at=k)),
        at_k + "not an object of the repository",
    )

    var other_kind = _batch(objects, kind_at=k)
    assert_equal(
        _check(pack, idx, lines, other_kind),
        at_k + "read as " + objects.kinds[k].name() + ", cat-file says "
        + other_kind.kinds[k].name(),
    )

    var p = _first_nonempty(objects)
    var at_p = _NAME + ": " + objects.ids[p].to_hex() + ": "
    var size_p = String(len(objects.payloads[p]))
    assert_equal(
        _check(pack, idx, lines, _batch(objects, flip_at=p)),
        at_p + "payload differs from cat-file's (" + size_p + " bytes, git's " + size_p + ")",
    )
    assert_equal(
        _check(pack, idx, lines, _batch(objects, grow_at=p)),
        at_p + "payload differs from cat-file's (" + size_p + " bytes, git's "
        + String(len(objects.payloads[p]) + 1) + ")",
    )


def _bytes_err(got: List[UInt8], want: List[UInt8]) -> String:
    try:
        require_same_bytes("w", got, want)
        return "OK"
    except e:
        return String(e)


def test_require_same_bytes() raises:
    var a: List[UInt8] = [1, 2, 3]
    var b: List[UInt8] = [1, 2, 4]
    var c: List[UInt8] = [9, 2, 3]
    var short: List[UInt8] = [1, 2]
    assert_equal(_bytes_err(a, a.copy()), "OK")
    assert_equal(_bytes_err(a, b), "w: byte 2 is 3, git's is 4")
    assert_equal(_bytes_err(c, a), "w: byte 0 is 9, git's is 1")
    assert_equal(_bytes_err(short, a), "w: 2 bytes, git's has 3")
    assert_equal(_bytes_err(a, short), "w: 3 bytes, git's has 2")


def _hex_id(f: ObjectFormat, digit: String) raises -> ObjectId:
    var s = String()
    for _ in range(f.hex_size()):
        s += digit
    return ObjectId.parse_hex(f, s)


def _index(
    f: ObjectFormat, var ids: List[ObjectId], var offsets: List[Int], var crcs: List[UInt32]
) -> PackIndex:
    return PackIndex(f, ids^, offsets^, crcs^, List[UInt8](length=20, fill=UInt8(0)))


def _index_err(got: PackIndex, want: PackIndex) -> String:
    try:
        require_same_index("w", got, want)
        return "OK"
    except e:
        return String(e)


def test_require_same_index() raises:
    var f = ObjectFormat.sha1()
    var a = _hex_id(f, "a")
    var b = _hex_id(f, "b")
    var c = _hex_id(f, "c")
    var want = _index(f, [a, b], [12, 40], [7, 9])
    assert_equal(_index_err(_index(f, [a, b], [12, 40], [7, 9]), want), "OK")
    assert_equal(_index_err(_index(f, [a], [12], [7]), want), "w: 1 objects, git's has 2")
    assert_equal(
        _index_err(_index(f, [a, b, c], [12, 40, 52], [7, 9, 3]), want),
        "w: 3 objects, git's has 2",
    )
    # A difference at entry 0: the loop must start at the first entry.
    assert_equal(
        _index_err(_index(f, [c, b], [12, 40], [7, 9]), want),
        "w: object 0 is " + c.to_hex() + ", git's " + a.to_hex(),
    )
    assert_equal(
        _index_err(_index(f, [a, b], [11, 40], [7, 9]), want),
        "w: offset of " + a.to_hex() + " differs",
    )
    assert_equal(
        _index_err(_index(f, [a, b], [12, 40], [6, 9]), want),
        "w: CRC-32 of " + a.to_hex() + " differs",
    )
    # A difference at the last entry: the loop must reach it.
    assert_equal(
        _index_err(_index(f, [a, c], [12, 40], [7, 9]), want),
        "w: object 1 is " + c.to_hex() + ", git's " + b.to_hex(),
    )
    assert_equal(
        _index_err(_index(f, [a, b], [12, 41], [7, 9]), want),
        "w: offset of " + b.to_hex() + " differs",
    )
    assert_equal(
        _index_err(_index(f, [a, b], [12, 40], [7, 8]), want),
        "w: CRC-32 of " + b.to_hex() + " differs",
    )


def _batch_err(text: String) -> String:
    try:
        var o = parse_batch(ObjectFormat.sha1(), Span(_bytes(text)))
        return "OK " + String(o.count())
    except e:
        return String(e)


def _verify_err(text: String) -> String:
    try:
        return "OK " + String(len(parse_verify(Span(_bytes(text)))))
    except e:
        return String(e)


def _ids_err(text: String) -> String:
    try:
        return "OK " + String(len(parse_ids(Span(_bytes(text)))))
    except e:
        return String(e)


def test_fixture_refusals() raises:
    var hex = _hex_id(ObjectFormat.sha1(), "d").to_hex()
    assert_equal(_batch_err(hex + " blob 2\nab\n"), "OK 1")
    assert_equal(_batch_err("x blob\n"), "fixtures: batch header at 0 has 2 fields")
    assert_equal(_batch_err(hex + " blob 2 extra\nab\n"), "fixtures: batch header at 0 has 4 fields")
    # The payload runs past the end, and the byte after it is not a newline.
    assert_equal(
        _batch_err(hex + " blob 5\nab\n"),
        "fixtures: batch payload of " + hex + " is not 5 bytes and a newline",
    )
    assert_equal(
        _batch_err(hex + " blob 2\nabX"),
        "fixtures: batch payload of " + hex + " is not 2 bytes and a newline",
    )
    assert_equal(_batch_err(hex + " blob 2"), "fixtures: no newline after offset 0")

    assert_equal(_verify_err("a commit 1 2 3 0 -\n"), "OK 1")
    assert_equal(_verify_err("a b c\n"), "fixtures: verify line at 0 has 3 fields")
    assert_equal(_verify_err("a b c d e f g h\n"), "fixtures: verify line at 0 has 8 fields")

    assert_equal(_ids_err("x\ny\n"), "OK 2")
    assert_equal(_ids_err("x\ny z\n"), "fixtures: id line at 2 has 2 fields")
    assert_equal(_ids_err("x\n\n"), "fixtures: id line at 2 has 0 fields")
    assert_equal(_ids_err("x\ny"), "fixtures: no newline after offset 2")

    var o = parse_batch(ObjectFormat.sha1(), Span(_bytes(hex + " blob 2\nab\n")))
    assert_equal(o.find(_hex_id(ObjectFormat.sha1(), "d")), 0)
    assert_equal(o.find(ObjectId.zero(ObjectFormat.sha1())), -1)


def main() raises:
    test_check_pack_each_check_fails()
    test_require_same_bytes()
    test_require_same_index()
    test_fixture_refusals()
