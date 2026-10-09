# =============================================================================
# komira_git_conformance/check.mojo -- one pack git wrote, read by komira_git
# and checked against git's index, git's verify-pack listing and git's
# cat-file dump.
# =============================================================================

from std.collections import Dict

from komira_git import (
    PACK_OBJ_OFS_DELTA,
    PACK_OBJ_REF_DELTA,
    IndexedPack,
    ObjectFormat,
    PackIndex,
    PackLimits,
    index_pack,
    parse_pack_index,
    read_pack_object,
)

from .fixtures import GitObjects, VerifyLine, parse_verify, read_fixture


struct PackStats(ImplicitlyCopyable, Movable):
    """What a checked pack held: its entries, OFS_DELTA and REF_DELTA entries,
    and its deepest delta chain."""

    var entries: Int
    var ofs_deltas: Int
    var ref_deltas: Int
    var max_depth: Int

    def __init__(out self):
        self.entries = 0
        self.ofs_deltas = 0
        self.ref_deltas = 0
        self.max_depth = 0


def require_same_bytes(what: String, got: List[UInt8], want: List[UInt8]) raises:
    """Raise naming the first differing offset unless `got == want`."""
    var n = min(len(got), len(want))
    for i in range(n):
        if got[i] != want[i]:
            raise Error(
                what + ": byte " + String(i) + " is " + String(Int(got[i]))
                + ", git's is " + String(Int(want[i]))
            )
    if len(got) != len(want):
        raise Error(what + ": " + String(len(got)) + " bytes, git's has " + String(len(want)))


def require_same_index(what: String, got: PackIndex, want: PackIndex) raises:
    if got.count() != want.count():
        raise Error(what + ": " + String(got.count()) + " objects, git's has " + String(want.count()))
    for i in range(got.count()):
        if got.id_at(i) != want.id_at(i):
            raise Error(what + ": object " + String(i) + " is " + got.id_at(i).to_hex() + ", git's " + want.id_at(i).to_hex())
        if got.offset_at(i) != want.offset_at(i):
            raise Error(what + ": offset of " + got.id_at(i).to_hex() + " differs")
        if got.crc32_at(i) != want.crc32_at(i):
            raise Error(what + ": CRC-32 of " + got.id_at(i).to_hex() + " differs")


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def check_git_pack(format: ObjectFormat, name: String, objects: GitObjects) raises -> PackStats:
    """Read `<name>.pack`, `<name>.idx` and `<name>.verify` and check them
    with `check_pack_against_git`."""
    return check_pack_against_git(
        format,
        name,
        read_fixture(name + ".pack"),
        read_fixture(name + ".idx"),
        parse_verify(Span(read_fixture(name + ".verify"))),
        objects,
    )


def check_pack_against_git(
    format: ObjectFormat,
    name: String,
    pack: List[UInt8],
    git_idx: List[UInt8],
    lines: List[VerifyLine],
    objects: GitObjects,
) raises -> PackStats:
    """Read `pack` and require: our index byte-equal to `git_idx` (and git's
    index, parsed, equal to ours); per entry the offset, size in the pack,
    kind, depth and base of verify-pack's `lines`; every object of the
    repository in the pack once, with cat-file's kind and payload. Returns
    what the pack held."""
    var limits = PackLimits()
    var got = index_pack(format, Span(pack), limits)
    require_same_bytes(name + ".idx", got.index.serialize(), git_idx)
    require_same_index(name + ".idx parsed", got.index, parse_pack_index(format, Span(git_idx)))

    if len(lines) != len(got.entries):
        raise Error(name + ": verify-pack lists " + String(len(lines)) + " entries, we read " + String(len(got.entries)))
    var by_id = Dict[String, Int]()
    for i in range(len(lines)):
        by_id[lines[i].id] = i
    if objects.count() != len(got.entries):
        raise Error(name + ": " + String(len(got.entries)) + " entries, the repository has " + String(objects.count()) + " objects")
    var stats = PackStats()
    stats.entries = len(got.entries)
    for i in range(len(got.entries)):
        var e = got.entries[i].copy()
        var hex = e.id.to_hex()
        if hex not in by_id:
            raise Error(name + ": " + hex + " is not in verify-pack's listing")
        var v = lines[by_id[hex]].copy()
        var at = name + ": " + hex + ": "
        if v.offset != e.offset:
            raise Error(at + "offset " + String(e.offset) + ", git's " + String(v.offset))
        if v.packed_size != e.packed_size:
            raise Error(at + "size in pack " + String(e.packed_size) + ", git's " + String(v.packed_size))
        if v.kind != e.kind.name():
            raise Error(at + "kind " + e.kind.name() + ", git's " + v.kind)
        if v.depth != e.depth:
            raise Error(at + "depth " + String(e.depth) + ", git's " + String(v.depth))
        var base = e.base_id.to_hex() if e.is_delta() else String("-")
        if v.base != base:
            raise Error(at + "base " + base + ", git's " + v.base)
        if e.type_code == PACK_OBJ_OFS_DELTA:
            stats.ofs_deltas += 1
        elif e.type_code == PACK_OBJ_REF_DELTA:
            stats.ref_deltas += 1
        stats.max_depth = max(stats.max_depth, e.depth)
        var k = objects.find(e.id)
        if k < 0:
            raise Error(at + "not an object of the repository")
        var obj = read_pack_object(Span(pack), got.index, e.id, limits)
        if obj.kind != objects.kinds[k]:
            raise Error(at + "read as " + obj.kind.name() + ", cat-file says " + objects.kinds[k].name())
        if not _same(obj.payload, objects.payloads[k]):
            raise Error(at + "payload differs from cat-file's (" + String(len(obj.payload)) + " bytes, git's " + String(len(objects.payloads[k])) + ")")
    return stats
