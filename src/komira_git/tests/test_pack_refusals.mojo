# =============================================================================
# komira_git/tests/test_pack_refusals.mojo -- what `index_pack` refuses, and
# the limits it enforces, each by its exact message.
# =============================================================================
#
# Every pack here carries a correct SHA-1 trailer (`_pack_with` computes it),
# so each refusal is reached by the malformation under test and not by the
# trailer check, which has a test of its own.
#
# WHAT EACH TEST CATCHES:
#   * test_header_refusals: a short pack, a wrong magic, an unknown version,
#     a count over `max_objects`, a wrong trailer, a count larger than the
#     entries (a reader that stops early and reports success), bytes after
#     the last entry.
#   * test_entry_refusals: types 0 and 5, a header cut by the trailer, a
#     size varint past 64 bits, a size over `max_object_size` (checked
#     before inflating), a stream inflating past or short of its size, a
#     corrupt stream, a stream cut by the trailer, an entry with no data;
#     OFS_DELTA distances of 0, past the pack start, and into the middle of
#     an entry; a truncated distance or REF id; a REF base not in the pack;
#     an object stored twice.
#   * test_limits: a chain one deeper than `max_delta_depth`; a bomb: blobs
#     of zeros, each a few hundred bytes in the pack and 100000 inflated,
#     refused once their sum passes the budget (`max_inflate_ratio *
#     len(pack) + max_object_size`), naming the entry that crossed it; a
#     delta whose result passes the budget, refused before it is applied;
#     and a delta result over `max_object_size`, which `index_pack` and
#     `read_pack_object` both leave to `apply_delta`'s own refusal (a read
#     path that charges it first refuses by the budget message instead).
#   * test_budget_exact: the budget is charged exactly: `index_pack` at the
#     count of bytes it produces passes and one byte under is refused,
#     including the second inflation of a root that has deltas;
#     `read_pack_object` the same with its own count. Catches any one
#     charge dropped or counted twice.
#   * test_budget_exact_chain: `read_pack_object` on a chain of depth two
#     charges every delta entry it walks and every result it applies,
#     the intermediate one included: a reader that charges only the first
#     entry, or only the final result, reads past the exact count.
#   * test_budget_result_at_limit: `read_pack_object` charges a delta result
#     of exactly `max_object_size` bytes; a reader that skips the result
#     charge at that size reads the object past its budget.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto import Sha1
from komira_zlib import ZLIB_WINDOW_BITS_ZLIB, zlib_compress_bound, zlib_deflate_into

from komira_git import (
    PACK_OBJ_BLOB,
    PACK_OBJ_OFS_DELTA,
    PACK_OBJ_REF_DELTA,
    ObjectFormat,
    ObjectId,
    ObjectKind,
    PackIndex,
    PackLimits,
    hash_object,
    index_pack,
    read_pack_object,
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


def _pack_with(
    count: Int, body: List[UInt8], version: Int = 2, magic: String = "PACK"
) -> List[UInt8]:
    """A pack whose header says `count` objects, whose entries are `body`,
    with a correct trailer."""
    var out = _bytes(magic)
    for b in [0, 0, 0]:
        out.append(UInt8(b))
    out.append(UInt8(version))
    out.append(UInt8((count >> 24) & 255))
    out.append(UInt8((count >> 16) & 255))
    out.append(UInt8((count >> 8) & 255))
    out.append(UInt8(count & 255))
    out.extend(Span(body))
    var h = Sha1()
    h.update(Span(out))
    var sum = List[UInt8](length=20, fill=UInt8(0))
    h.finalize_into(Span(sum))
    out.extend(Span(sum))
    return out^


def _err(pack: List[UInt8], limits: PackLimits = PackLimits()) -> String:
    try:
        _ = index_pack(ObjectFormat.sha1(), Span(pack), limits)
        return "OK"
    except e:
        return String(e)


comptime _P = "komira_git: pack: "
comptime _E12 = "komira_git: pack: entry at offset 12: "


def test_header_refusals() raises:
    var blob = _obj(PACK_OBJ_BLOB, _bytes("x\n"))
    assert_equal(_err(_pack_with(1, blob)), "OK")
    assert_equal(_err(List[UInt8](length=31, fill=UInt8(0))), _P + "31 bytes is shorter than a header and a trailer")
    assert_equal(_err(_pack_with(1, blob, magic="PACX")), _P + "does not start with PACK")
    assert_equal(_err(_pack_with(1, blob, version=4)), _P + "version 4 is not 2 or 3")
    assert_equal(_err(_pack_with(1, blob, version=1)), _P + "version 1 is not 2 or 3")
    var two = blob.copy()
    two.extend(Span(_obj(PACK_OBJ_BLOB, _bytes("y\n"))))
    assert_equal(_err(_pack_with(2, two), PackLimits(max_objects=1)), _P + "2 objects, over the limit 1")
    var bad = _pack_with(1, blob)
    bad[len(bad) - 1] ^= 0x40
    assert_equal(_err(bad), _P + "the trailer is not the checksum of the pack")
    assert_equal(_err(_pack_with(2, blob)), _P + "ends after 1 of 2 objects")
    var extra = blob.copy()
    for _ in range(3):
        extra.append(0)
    assert_equal(_err(_pack_with(1, extra)), _P + "3 bytes after the last object")
    assert_equal(_err(_pack_with(0, List[UInt8]())), "OK")


def test_entry_refusals() raises:
    var f = ObjectFormat.sha1()
    var z = _z(_bytes("hello"))
    var t5 = List[UInt8]()
    t5.append(0x55)
    t5.extend(Span(z))
    assert_equal(_err(_pack_with(1, t5)), _E12 + "invalid type 5")
    var t0 = List[UInt8]()
    t0.append(0x05)
    t0.extend(Span(z))
    assert_equal(_err(_pack_with(1, t0)), _E12 + "invalid type 0")
    var cut = List[UInt8]()
    cut.append(0xB5)
    assert_equal(_err(_pack_with(1, cut)), _E12 + "truncated header")
    var wide = List[UInt8]()
    wide.append(0xB0)
    for _ in range(9):
        wide.append(0xFF)
    wide.append(0x01)
    assert_equal(_err(_pack_with(1, wide)), _E12 + "size does not fit 64 bits")
    var eleven = _obj(PACK_OBJ_BLOB, _bytes("eleven byte"))
    assert_equal(_err(_pack_with(1, eleven), PackLimits(max_object_size=10)), _E12 + "declares 11 bytes, over the limit 10")
    assert_equal(_err(_pack_with(1, eleven), PackLimits(max_object_size=11)), "OK")
    var past = _entry_header(PACK_OBJ_BLOB, 3)
    past.extend(Span(z))
    assert_equal(_err(_pack_with(1, past)), _E12 + "inflates past its declared 3 bytes")
    var short = _entry_header(PACK_OBJ_BLOB, 7)
    short.extend(Span(z))
    assert_equal(_err(_pack_with(1, short)), _E12 + "inflates to 5 bytes, the header says 7")
    var corrupt = _entry_header(PACK_OBJ_BLOB, 5)
    corrupt.append(0x78)
    corrupt.append(0x9C)
    for _ in range(8):
        corrupt.append(0xFF)
    assert_equal(_err(_pack_with(1, corrupt)), _E12 + "corrupt zlib stream (rc=-3)")
    var trunc = _entry_header(PACK_OBJ_BLOB, 5)
    trunc.extend(Span(z)[0 : len(z) - 6])
    assert_equal(_err(_pack_with(1, trunc)), _E12 + "zlib stream runs into the trailer")
    assert_equal(_err(_pack_with(1, _entry_header(PACK_OBJ_BLOB, 1))), _E12 + "no data before the trailer")

    # OFS_DELTA bases.
    var base = _obj(PACK_OBJ_BLOB, _bytes("base\n"))
    var delta = _delta(_bytes("base\n"), 4, "!")
    var zero = base.copy()
    zero.extend(Span(_entry_header(PACK_OBJ_OFS_DELTA, len(delta))))
    zero.append(0)
    zero.extend(Span(_z(delta)))
    var at = 12 + len(base)
    var e_at = _P + "entry at offset " + String(at) + ": "
    assert_equal(_err(_pack_with(2, zero)), e_at + "delta base offset 0 points outside the entries before it")
    var before = base.copy()
    before.extend(Span(_ofs_delta(at - 11, delta)))
    assert_equal(
        _err(_pack_with(2, before)),
        e_at + "delta base offset " + String(at - 11) + " points outside the entries before it",
    )
    var inside = base.copy()
    inside.extend(Span(_ofs_delta(len(base) - 1, delta)))
    assert_equal(_err(_pack_with(2, inside)), e_at + "delta base offset 13 starts no entry")
    var good = base.copy()
    good.extend(Span(_ofs_delta(len(base), delta)))
    assert_equal(_err(_pack_with(2, good)), "OK")
    var ofs_cut = base.copy()
    ofs_cut.extend(Span(_entry_header(PACK_OBJ_OFS_DELTA, len(delta))))
    assert_equal(_err(_pack_with(2, ofs_cut)), e_at + "truncated delta base offset")
    ofs_cut.append(0x81)
    assert_equal(_err(_pack_with(2, ofs_cut)), e_at + "truncated delta base offset")
    var ofs_wide = base.copy()
    ofs_wide.extend(Span(_entry_header(PACK_OBJ_OFS_DELTA, len(delta))))
    for _ in range(10):
        ofs_wide.append(0xFF)
    ofs_wide.append(0x01)
    assert_equal(_err(_pack_with(2, ofs_wide)), e_at + "delta base offset does not fit 64 bits")

    # REF_DELTA bases.
    var id_base = hash_object(f, ObjectKind.blob(), Span(_bytes("base\n")))
    var ref_cut = base.copy()
    ref_cut.extend(Span(_entry_header(PACK_OBJ_REF_DELTA, len(delta))))
    for i in range(19):
        ref_cut.append(id_base.byte_at(i))
    assert_equal(_err(_pack_with(2, ref_cut)), e_at + "truncated delta base id")
    var other = hash_object(f, ObjectKind.blob(), Span(_bytes("not in the pack\n")))
    var no_base = base.copy()
    no_base.extend(Span(_ref_delta(other, delta)))
    assert_equal(_err(_pack_with(2, no_base)), _P + "1 deltas have no base in the pack")
    var ref_ok = base.copy()
    ref_ok.extend(Span(_ref_delta(id_base, delta)))
    assert_equal(_err(_pack_with(2, ref_ok)), "OK")
    # A delta of the wrong base size fails as the delta says.
    var wrong = base.copy()
    wrong.extend(Span(_ofs_delta(len(base), _delta(_bytes("base\n!!"), 4, "!"))))
    assert_equal(_err(_pack_with(2, wrong)), "komira_git: delta: expects a base of 7 bytes, the base is 5")

    var dup = base.copy()
    dup.extend(Span(base))
    assert_equal(_err(_pack_with(2, dup)), _P + "object " + id_base.to_hex() + " appears twice")


def test_limits() raises:
    # A chain of depth 3.
    var a = _bytes("depth zero object, a blob\n")
    var a1 = _rebuilt(a, 10, "+1")
    var a2 = _rebuilt(a1, 10, "+2")
    var body = _obj(PACK_OBJ_BLOB, a)
    var at1 = 12 + len(body)
    body.extend(Span(_ofs_delta(at1 - 12, _delta(a, 10, "+1"))))
    var at2 = 12 + len(body)
    body.extend(Span(_ofs_delta(at2 - at1, _delta(a1, 10, "+2"))))
    var at3 = 12 + len(body)
    body.extend(Span(_ofs_delta(at3 - at2, _delta(a2, 10, "+3"))))
    var chain = _pack_with(4, body)
    assert_equal(_err(chain, PackLimits(max_delta_depth=3)), "OK")
    assert_equal(
        _err(chain, PackLimits(max_delta_depth=2)),
        _P + "entry at offset " + String(at3) + ": delta chain of depth 3 is over the limit 2",
    )

    # A bomb: eleven blobs of 100000 equal bytes.
    var bomb = List[UInt8]()
    var starts = List[Int]()
    for i in range(11):
        starts.append(12 + len(bomb))
        bomb.extend(Span(_obj(PACK_OBJ_BLOB, List[UInt8](length=100000, fill=UInt8(i)))))
    var pack = _pack_with(11, bomb)
    assert_true(len(pack) < 4000)
    var limits = PackLimits(max_object_size=1 << 20, max_inflate_ratio=1)
    var budget = len(pack) + (1 << 20)
    assert_equal(limits.budget(len(pack)), budget)
    assert_equal(
        _err(pack, limits),
        _P + "entry at offset " + String(starts[10])
        + ": the pack inflates past its budget of " + String(budget) + " bytes",
    )
    assert_equal(_err(pack, PackLimits(max_object_size=1 << 20, max_inflate_ratio=100)), "OK")
    assert_equal(PackLimits(max_inflate_ratio=1 << 40).budget(1 << 40), Int.MAX)

    # A delta whose result alone passes the budget.
    var small = _bytes("s")
    var big_delta = List[UInt8]()
    _varint(big_delta, 1)
    _varint(big_delta, 200000)
    for _ in range(4):
        big_delta.append(0x80 | 0x10 | 0x20 | 0x40)  # copy 0x10000 ... from offset 0
        big_delta.append(0)
        big_delta.append(0)
        big_delta.append(1)
    var d_body = _obj(PACK_OBJ_BLOB, small)
    var d_at = 12 + len(d_body)
    d_body.extend(Span(_ofs_delta(d_at - 12, big_delta)))
    var d_pack = _pack_with(2, d_body)
    var d_limits = PackLimits(max_object_size=150000, max_inflate_ratio=1)
    assert_equal(
        _err(d_pack, d_limits),
        "komira_git: delta: result of 200000 bytes is over the limit 150000",
    )
    var d_limits2 = PackLimits(max_object_size=200000, max_inflate_ratio=0)
    assert_equal(
        _err(d_pack, d_limits2),
        _P + "entry at offset " + String(d_at) + ": the pack inflates past its budget of "
        + String(200000) + " bytes",
    )

    # The same refusal on the read path: a 50000-byte root of zeros and a
    # delta copying it four times. `read_pack_object` leaves the
    # 200000-byte result uncharged (it is over `max_object_size`) so that
    # `apply_delta` refuses it by its own message.
    var zeros = List[UInt8](length=50000, fill=UInt8(0))
    var four = List[UInt8]()
    _varint(four, 50000)
    _varint(four, 200000)
    for _ in range(4):
        four.append(0x80 | 0x10 | 0x20)  # copy: offset 0, two size bytes
        four.append(UInt8(50000 & 255))
        four.append(UInt8(50000 >> 8))
    var r_body = _obj(PACK_OBJ_BLOB, zeros)
    var r_at = 12 + len(r_body)
    r_body.extend(Span(_ofs_delta(r_at - 12, four)))
    var r_pack = _pack_with(2, r_body)
    var r_got = index_pack(ObjectFormat.sha1(), Span(r_pack), PackLimits())
    var r_id = hash_object(
        ObjectFormat.sha1(), ObjectKind.blob(), Span(List[UInt8](length=200000, fill=UInt8(0)))
    )
    assert_equal(
        _read_err(r_pack, r_got.index, r_id, PackLimits(max_object_size=150000, max_inflate_ratio=1)),
        "komira_git: delta: result of 200000 bytes is over the limit 150000",
    )
    assert_equal(
        _read_err(r_pack, r_got.index, r_id, PackLimits(max_object_size=200000, max_inflate_ratio=1000)),
        "OK",
    )


def _read_err(pack: List[UInt8], index: PackIndex, id: ObjectId, limits: PackLimits) -> String:
    try:
        _ = read_pack_object(Span(pack), index, id, limits)
        return "OK"
    except e:
        return String(e)


def test_budget_exact() raises:
    # A 1000-byte blob and an OFS_DELTA rebuilding 12 bytes of it. Under
    # `max_inflate_ratio=0` the budget is `max_object_size`, so each limit
    # below is the exact count of bytes produced, or one byte short of it.
    var f = ObjectFormat.sha1()
    var root = _noise(1000, 7)
    var delta = _delta(root, 10, "+r")
    var s = len(root)
    var d = len(delta)
    var t = 12
    var body = _obj(PACK_OBJ_BLOB, root)
    var d_at = 12 + len(body)
    body.extend(Span(_ofs_delta(d_at - 12, delta)))
    var pack = _pack_with(2, body)
    # index_pack inflates the root twice (walked, then again to resolve its
    # delta), the delta once, and produces the delta's result.
    assert_equal(_err(pack, PackLimits(max_object_size=2 * s + d + t, max_inflate_ratio=0)), "OK")
    assert_equal(
        _err(pack, PackLimits(max_object_size=2 * s + d + t - 1, max_inflate_ratio=0)),
        _P + "entry at offset " + String(d_at) + ": the pack inflates past its budget of "
        + String(2 * s + d + t - 1) + " bytes",
    )
    # A budget that fits the walk and the result but not the root's second
    # inflation is refused at the root.
    assert_equal(
        _err(pack, PackLimits(max_object_size=s + d + t, max_inflate_ratio=0)),
        _E12 + "the pack inflates past its budget of " + String(s + d + t) + " bytes",
    )
    # read_pack_object inflates the delta and the root once each and
    # produces the result, against a budget of its own.
    var got = index_pack(f, Span(pack), PackLimits())
    var id_r = hash_object(f, ObjectKind.blob(), Span(_rebuilt(root, 10, "+r")))
    assert_equal(_read_err(pack, got.index, id_r, PackLimits(max_object_size=s + d + t, max_inflate_ratio=0)), "OK")
    assert_equal(
        _read_err(pack, got.index, id_r, PackLimits(max_object_size=s + d + t - 1, max_inflate_ratio=0)),
        _P + "entry at offset " + String(d_at) + ": the pack inflates past its budget of "
        + String(s + d + t - 1) + " bytes",
    )
    assert_equal(
        _read_err(pack, got.index, id_r, PackLimits(max_object_size=s + d - 1, max_inflate_ratio=0)),
        _E12 + "the pack inflates past its budget of " + String(s + d - 1) + " bytes",
    )


def test_budget_exact_chain() raises:
    # A chain of depth two: root, d1 (a delta of root) and d2 (a delta of
    # d1's result r1). Reading d2 charges d2, d1 and the root as it walks,
    # then r1 and r2 as it applies; under `max_inflate_ratio=0` each limit
    # is that exact count, or short of it by one byte.
    var f = ObjectFormat.sha1()
    var root = _noise(1000, 13)
    var d1 = _delta(root, 900, "+a")
    var r1 = _rebuilt(root, 900, "+a")
    var d2 = _delta(r1, 800, "+b")
    var r2 = _rebuilt(r1, 800, "+b")
    var s = len(root)
    var n = len(d1) + len(d2)
    var body = _obj(PACK_OBJ_BLOB, root)
    var d1_at = 12 + len(body)
    body.extend(Span(_ofs_delta(d1_at - 12, d1)))
    var d2_at = 12 + len(body)
    body.extend(Span(_ofs_delta(d2_at - d1_at, d2)))
    var pack = _pack_with(3, body)
    var got = index_pack(f, Span(pack), PackLimits())
    var id2 = hash_object(f, ObjectKind.blob(), Span(r2))
    var total = s + n + len(r1) + len(r2)
    assert_equal(_read_err(pack, got.index, id2, PackLimits(max_object_size=total, max_inflate_ratio=0)), "OK")
    # One byte short: the last charge, r2, crosses and names d2.
    assert_equal(
        _read_err(pack, got.index, id2, PackLimits(max_object_size=total - 1, max_inflate_ratio=0)),
        _P + "entry at offset " + String(d2_at) + ": the pack inflates past its budget of "
        + String(total - 1) + " bytes",
    )
    # Room for the walk but not for r1: the intermediate result crosses and
    # names d1.
    var walk_r1 = s + n + len(r1)
    assert_equal(
        _read_err(pack, got.index, id2, PackLimits(max_object_size=walk_r1 - 1, max_inflate_ratio=0)),
        _P + "entry at offset " + String(d1_at) + ": the pack inflates past its budget of "
        + String(walk_r1 - 1) + " bytes",
    )


def test_budget_result_at_limit() raises:
    # A delta whose result is exactly `max_object_size` bytes: the 1000-byte
    # root copied four times. Under `max_inflate_ratio=0` the budget is
    # `max_object_size` = 4000; the walk (delta, root) fits under it and only
    # the result's charge crosses it, so the refusal names the delta.
    var f = ObjectFormat.sha1()
    var root = _noise(1000, 11)
    var delta = List[UInt8]()
    _varint(delta, 1000)
    _varint(delta, 4000)
    for _ in range(4):
        delta.append(0x80 | 0x10 | 0x20)  # copy: offset 0, two size bytes
        delta.append(UInt8(1000 & 255))
        delta.append(UInt8(1000 >> 8))
    var result = List[UInt8]()
    for _ in range(4):
        result.extend(Span(root))
    var s = len(root)
    var d = len(delta)
    var body = _obj(PACK_OBJ_BLOB, root)
    var d_at = 12 + len(body)
    body.extend(Span(_ofs_delta(d_at - 12, delta)))
    var pack = _pack_with(2, body)
    var got = index_pack(f, Span(pack), PackLimits())
    var id_r = hash_object(f, ObjectKind.blob(), Span(result))
    assert_true(s + d <= 4000)
    assert_equal(
        _read_err(pack, got.index, id_r, PackLimits(max_object_size=4000, max_inflate_ratio=0)),
        _P + "entry at offset " + String(d_at) + ": the pack inflates past its budget of 4000 bytes",
    )
    # One ratio step up the budget is `len(pack) + 4000`, which covers the
    # walk, so the same result at the same object limit is read.
    assert_true(s + d <= len(pack))
    assert_equal(
        _read_err(pack, got.index, id_r, PackLimits(max_object_size=4000, max_inflate_ratio=1)), "OK"
    )
    var obj = read_pack_object(Span(pack), got.index, id_r, PackLimits(max_object_size=4000, max_inflate_ratio=1))
    assert_true(_same(obj.payload, result))


def main() raises:
    test_header_refusals()
    test_entry_refusals()
    test_limits()
    test_budget_exact()
    test_budget_exact_chain()
    test_budget_result_at_limit()
    print("komira_git pack refusal tests passed")
