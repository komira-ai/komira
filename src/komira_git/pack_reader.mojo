# =============================================================================
# komira_git/pack_reader.mojo -- reading a packfile: indexing a whole pack
# (what `git index-pack` does) and reading one object out of an indexed pack.
# =============================================================================
#
# `index_pack(format, pack, limits)`:
#   1. checks the header and the trailer (pack_format.mojo);
#   2. walks the entries in order, reading each header and inflating each
#      zlib stream to find where the next entry starts; a non-delta is
#      hashed to its id at once, a delta's instructions are kept;
#   3. resolves the deltas from their bases outward, git's order: a resolved
#      object's OFS_DELTA children (by its offset) and REF_DELTA children (by
#      its id) are rebuilt from it, then theirs, with an explicit stack, so a
#      long chain costs no recursion, and a payload is dropped once its
#      children are rebuilt. A REF_DELTA may name a base anywhere in the pack,
#      before or after it; one whose base never resolves (it is not in the
#      pack, or the deltas form a cycle) is refused;
#   4. refuses an object that appears twice, and returns an `IndexedPack`:
#      the `PackIndex` and, per entry in pack order, a `PackEntryInfo`.
#
# `index_thin_pack` is the same with an `ExternalBases`: a REF_DELTA whose
# base is not in the pack may name one of them (a thin pack, as a fetch or
# push with `--thin` sends). The index lists the pack's own objects only.
#
# `read_pack_object(pack, index, id, limits)` reads one object: it follows
# the delta chain from the object's entry to a non-delta (OFS_DELTA by
# offset, REF_DELTA through the index), applies the deltas back up, and
# refuses a result that does not hash to `id`, so an index that does not
# describe the pack cannot hand back a wrong object.
#
# Limits (`PackLimits`): the object count, each declared or rebuilt size,
# the chain depth, and the bytes produced against the pack's budget are all
# checked before the work they bound is done. Every inflation counts against
# the budget, so `index_thin_pack` counts a non-delta with delta children
# twice (walked, then inflated again to resolve them), and every delta
# result counts once; `read_thin_pack_object` keeps a budget of its own per
# call, counting each entry of the chain and each delta result. An
# `ExternalBases` object is not counted: the reader did not produce it.
# =============================================================================

from std.builtin.swap import swap
from std.collections import Dict

from komira_zlib import zlib_crc32

from .delta import apply_delta, read_delta_header
from .object_id import ObjectFormat, ObjectId, ObjectKind, hash_object
from .pack_format import (
    PACK_HEADER_SIZE,
    PACK_OBJ_OFS_DELTA,
    PACK_OBJ_REF_DELTA,
    PackLimits,
    PackObject,
    _check_pack_header,
    _inflate_entry,
    _parse_entry_head,
)
from .pack_index import PackIndex, _id_compare, _sort_by_id


struct PackEntryInfo(Copyable, Movable):
    """One entry of an indexed pack, as `git verify-pack -v` describes it:
    the object's id and kind, the entry's pack type number (1-4, or 6 / 7
    for a delta), its offset and size in the pack, its CRC-32, and for a
    delta its chain depth and its base's id (`depth` 0 and the null id
    otherwise)."""

    var id: ObjectId
    var kind: ObjectKind
    var type_code: Int
    var offset: Int
    var packed_size: Int
    var crc32: UInt32
    var depth: Int
    var base_id: ObjectId

    def __init__(out self, format: ObjectFormat):
        self.id = ObjectId(format)
        self.kind = ObjectKind.blob()
        self.type_code = 0
        self.offset = 0
        self.packed_size = 0
        self.crc32 = 0
        self.depth = 0
        self.base_id = ObjectId(format)

    def is_delta(self) -> Bool:
        return self.type_code == PACK_OBJ_OFS_DELTA or self.type_code == PACK_OBJ_REF_DELTA


struct IndexedPack(Copyable, Movable):
    """What `index_pack` returns: the index, and every entry in pack order."""

    var index: PackIndex
    var entries: List[PackEntryInfo]

    def __init__(out self, var index: PackIndex, var entries: List[PackEntryInfo]):
        self.index = index^
        self.entries = entries^


struct ExternalBases(Copyable, Movable):
    """Objects outside a pack that its REF_DELTAs may name as bases (a thin
    pack's). Each is stored under the id it hashes to."""

    var _format: ObjectFormat
    var _by_id: Dict[String, Int]
    var _kinds: List[ObjectKind]
    var _payloads: List[List[UInt8]]

    def __init__(out self, format: ObjectFormat):
        self._format = format
        self._by_id = Dict[String, Int]()
        self._kinds = List[ObjectKind]()
        self._payloads = List[List[UInt8]]()

    def add(mut self, kind: ObjectKind, payload: Span[UInt8, _]) raises -> ObjectId:
        """Add an object; returns its id. Raises what `hash_object` raises."""
        var id = hash_object(self._format, kind, payload)
        var key = id.to_hex()
        if key not in self._by_id:
            self._by_id[key] = len(self._kinds)
            self._kinds.append(kind)
            var copy = List[UInt8](capacity=len(payload))
            copy.extend(payload)
            self._payloads.append(copy^)
        return id

    def count(self) -> Int:
        return len(self._kinds)

    def _find(self, id: ObjectId) -> Int:
        if id.format() != self._format:
            return -1
        try:
            return self._by_id[id.to_hex()]
        except:
            return -1


def _offset_lookup(offsets: List[Int], want: Int) -> Int:
    """The position of `want` in the ascending `offsets`, or -1."""
    var lo = 0
    var hi = len(offsets)
    while lo < hi:
        var mid = (lo + hi) // 2
        if offsets[mid] == want:
            return mid
        if offsets[mid] < want:
            lo = mid + 1
        else:
            hi = mid
    return -1


def _charge(produced: Int, budget: Int, n: Int, offset: Int) raises -> Int:
    """`produced + n`, or a refusal naming the entry at `offset` when that
    passes `budget`."""
    if n > budget - produced:
        raise Error(
            "komira_git: pack: entry at offset " + String(offset)
            + ": the pack inflates past its budget of " + String(budget)
            + " bytes"
        )
    return produced + n


struct _Resolver:
    """The state of one `index_thin_pack` call."""

    var format: ObjectFormat
    var limits: PackLimits
    var budget: Int
    var produced: Int
    var base_pos: List[Int]
    var deltas: List[List[UInt8]]
    var payloads: List[List[UInt8]]
    var resolved: List[Bool]
    var ofs_child: List[Int]
    var ref_child: Dict[String, Int]
    var next_sibling: List[Int]
    var info: List[PackEntryInfo]

    def __init__(out self, format: ObjectFormat, limits: PackLimits, budget: Int):
        self.format = format
        self.limits = limits
        self.budget = budget
        self.produced = 0
        self.base_pos = List[Int]()
        self.deltas = List[List[UInt8]]()
        self.payloads = List[List[UInt8]]()
        self.resolved = List[Bool]()
        self.ofs_child = List[Int]()
        self.ref_child = Dict[String, Int]()
        self.next_sibling = List[Int]()
        self.info = List[PackEntryInfo]()

    def charge(mut self, n: Int, offset: Int) raises:
        """Count `n` more bytes produced against the budget."""
        self.produced = _charge(self.produced, self.budget, n, offset)

    def rebuild(mut self, c: Int, base: Span[UInt8, _], kind: ObjectKind, depth: Int) raises:
        """Rebuild delta entry `c` from `base` (of `kind`, at `depth - 1`)."""
        var off = self.info[c].offset
        if depth > self.limits.max_delta_depth:
            raise Error(
                "komira_git: pack: entry at offset " + String(off)
                + ": delta chain of depth " + String(depth) + " is over the limit "
                + String(self.limits.max_delta_depth)
            )
        var delta = List[UInt8]()
        swap(delta, self.deltas[c])
        var head = read_delta_header(Span(delta))
        if head.result_size <= self.limits.max_object_size:
            self.charge(head.result_size, off)
        var out = apply_delta(base, Span(delta), self.limits.max_object_size)
        self.info[c].id = hash_object(self.format, kind, Span(out))
        self.info[c].kind = kind
        self.info[c].depth = depth
        self.payloads[c] = out^
        self.resolved[c] = True

    def children_of(self, i: Int) -> List[Int]:
        """Entry `i`'s unresolved delta children: by offset, then by id."""
        var out = List[Int]()
        var c = self.ofs_child[i]
        while c >= 0:
            out.append(c)
            c = self.next_sibling[c]
        try:
            c = self.ref_child[self.info[i].id.to_hex()]
        except:
            c = -1
        while c >= 0:
            if not self.resolved[c]:
                out.append(c)
            c = self.next_sibling[c]
        return out^

    def ref_children(self, id: ObjectId) -> List[Int]:
        var out = List[Int]()
        var c: Int
        try:
            c = self.ref_child[id.to_hex()]
        except:
            c = -1
        while c >= 0:
            if not self.resolved[c]:
                out.append(c)
            c = self.next_sibling[c]
        return out^

    def descend(mut self, root: Int) raises:
        """Rebuild every delta below resolved entry `root` (whose payload is
        held), dropping each payload once its children are rebuilt."""
        var stack = List[Int]()
        stack.append(root)
        while len(stack) > 0:
            var j = stack.pop()
            var kids = self.children_of(j)
            var base = List[UInt8]()
            swap(base, self.payloads[j])
            var kind = self.info[j].kind
            var depth = self.info[j].depth + 1
            for k in range(len(kids)):
                var c = kids[k]
                self.rebuild(c, Span(base), kind, depth)
                stack.append(c)


def index_pack(
    format: ObjectFormat, pack: Span[UInt8, _], limits: PackLimits
) raises -> IndexedPack:
    """Index a self-contained pack: every delta's base must be in it."""
    return index_thin_pack(format, pack, limits, ExternalBases(format))


def index_thin_pack(
    format: ObjectFormat,
    pack: Span[UInt8, _],
    limits: PackLimits,
    bases: ExternalBases,
) raises -> IndexedPack:
    """Index a pack whose REF_DELTAs may also name objects of `bases`."""
    var count = _check_pack_header(format, pack, limits)
    var hs = format.raw_size()
    var end = len(pack) - hs
    var r = _Resolver(format, limits, limits.budget(len(pack)))
    var offsets = List[Int](capacity=count)
    var base_offsets = List[Int](capacity=count)
    var base_ids = List[ObjectId](capacity=count)
    var types = List[Int](capacity=count)
    var offset = PACK_HEADER_SIZE
    # Phase 1: walk the entries.
    for i in range(count):
        if offset >= end:
            raise Error(
                "komira_git: pack: ends after " + String(i) + " of "
                + String(count) + " objects"
            )
        var head = _parse_entry_head(format, pack, offset, end, limits)
        r.charge(head.size, offset)
        var data = List[UInt8]()
        var stop = _inflate_entry(pack, offset, head, end, data)
        var e = PackEntryInfo(format)
        e.type_code = head.type_code
        e.offset = offset
        e.packed_size = stop - offset
        e.crc32 = zlib_crc32(pack[offset:stop])
        offsets.append(offset)
        base_offsets.append(head.base_offset)
        base_ids.append(head.base_id)
        types.append(head.type_code)
        r.base_pos.append(-1)
        if head.is_delta():
            r.deltas.append(data^)
            r.resolved.append(False)
        else:
            var kind = ObjectKind.from_code(head.type_code)
            e.kind = kind
            e.id = hash_object(format, kind, Span(data))
            r.deltas.append(List[UInt8]())
            r.resolved.append(True)
        r.info.append(e^)
        r.payloads.append(List[UInt8]())
        r.ofs_child.append(-1)
        r.next_sibling.append(-1)
        offset = stop
    if offset != end:
        raise Error(
            "komira_git: pack: " + String(end - offset)
            + " bytes after the last object"
        )
    # Link every delta to its base: OFS_DELTA by position, REF_DELTA by id.
    # Lists are built back to front so each one is in pack order.
    var i = count - 1
    while i >= 0:
        if types[i] == PACK_OBJ_OFS_DELTA:
            var b = _offset_lookup(offsets, base_offsets[i])
            if b < 0:
                raise Error(
                    "komira_git: pack: entry at offset " + String(offsets[i])
                    + ": delta base offset " + String(base_offsets[i])
                    + " starts no entry"
                )
            r.base_pos[i] = b
            r.next_sibling[i] = r.ofs_child[b]
            r.ofs_child[b] = i
        elif types[i] == PACK_OBJ_REF_DELTA:
            var key = base_ids[i].to_hex()
            var first = -1
            if key in r.ref_child:
                first = r.ref_child[key]
            r.next_sibling[i] = first
            r.ref_child[key] = i
        i -= 1
    # Phase 2: resolve from every non-delta that has children.
    for j in range(count):
        if r.info[j].is_delta():
            continue
        if r.ofs_child[j] < 0 and r.info[j].id.to_hex() not in r.ref_child:
            continue
        var head = _parse_entry_head(format, pack, offsets[j], end, limits)
        r.charge(head.size, offsets[j])
        var root = List[UInt8]()
        _ = _inflate_entry(pack, offsets[j], head, end, root)
        r.payloads[j] = root^
        r.descend(j)
    # Thin bases: REF_DELTAs still waiting on an object outside the pack.
    for j in range(count):
        if r.resolved[j] or types[j] != PACK_OBJ_REF_DELTA:
            continue
        var x = bases._find(base_ids[j])
        if x < 0:
            continue
        var kids = r.ref_children(base_ids[j])
        for k in range(len(kids)):
            var c = kids[k]
            r.rebuild(c, Span(bases._payloads[x]), bases._kinds[x], 1)
            r.descend(c)
    var unresolved = 0
    for j in range(count):
        if not r.resolved[j]:
            unresolved += 1
    if unresolved > 0:
        raise Error(
            "komira_git: pack: " + String(unresolved)
            + " deltas have no base in the pack"
        )
    for j in range(count):
        if types[j] == PACK_OBJ_OFS_DELTA:
            r.info[j].base_id = r.info[r.base_pos[j]].id
        elif types[j] == PACK_OBJ_REF_DELTA:
            r.info[j].base_id = base_ids[j]
    # The index, in id order.
    var ids = List[ObjectId](capacity=count)
    for j in range(count):
        ids.append(r.info[j].id)
    var order = _sort_by_id(ids)
    var sorted_ids = List[ObjectId](capacity=count)
    var sorted_offsets = List[Int](capacity=count)
    var crcs = List[UInt32](capacity=count)
    for k in range(count):
        var j = order[k]
        if k > 0 and _id_compare(ids[order[k - 1]], ids[j]) == 0:
            raise Error(
                "komira_git: pack: object " + ids[j].to_hex() + " appears twice"
            )
        sorted_ids.append(ids[j])
        sorted_offsets.append(offsets[j])
        crcs.append(r.info[j].crc32)
    var checksum = List[UInt8](capacity=hs)
    checksum.extend(pack[end : len(pack)])
    var index = PackIndex(format, sorted_ids^, sorted_offsets^, crcs^, checksum^)
    var infos = List[PackEntryInfo]()
    swap(infos, r.info)
    return IndexedPack(index^, infos^)


def read_pack_object(
    pack: Span[UInt8, _], index: PackIndex, id: ObjectId, limits: PackLimits
) raises -> PackObject:
    """Read object `id` out of `pack`, which `index` describes."""
    return read_thin_pack_object(pack, index, id, limits, ExternalBases(index.format()))


def read_thin_pack_object(
    pack: Span[UInt8, _],
    index: PackIndex,
    id: ObjectId,
    limits: PackLimits,
    bases: ExternalBases,
) raises -> PackObject:
    """`read_pack_object` where a REF_DELTA may also name an object of
    `bases`."""
    var format = index.format()
    var hs = format.raw_size()
    if len(pack) < PACK_HEADER_SIZE + hs:
        raise Error(
            "komira_git: pack: " + String(len(pack))
            + " bytes is shorter than a header and a trailer"
        )
    var end = len(pack) - hs
    var checksum = index.pack_checksum()
    for i in range(hs):
        if checksum[i] != pack[end + i]:
            raise Error("komira_git: pack: the index describes another pack")
    var pos = index.find(id)
    if pos < 0:
        raise Error("komira_git: pack: object " + id.to_hex() + " is not in the pack")
    var offset = index.offset_at(pos)
    var budget = limits.budget(len(pack))
    var produced = 0
    var chain = List[List[UInt8]]()
    var chain_at = List[Int]()
    var base = List[UInt8]()
    var kind = ObjectKind.blob()
    while True:
        var head = _parse_entry_head(format, pack, offset, end, limits)
        if not head.is_delta():
            produced = _charge(produced, budget, head.size, offset)
            _ = _inflate_entry(pack, offset, head, end, base)
            kind = ObjectKind.from_code(head.type_code)
            break
        if len(chain) >= limits.max_delta_depth:
            raise Error(
                "komira_git: pack: object " + id.to_hex()
                + ": delta chain is longer than the limit "
                + String(limits.max_delta_depth)
            )
        produced = _charge(produced, budget, head.size, offset)
        var delta = List[UInt8]()
        _ = _inflate_entry(pack, offset, head, end, delta)
        chain.append(delta^)
        chain_at.append(offset)
        if head.type_code == PACK_OBJ_OFS_DELTA:
            offset = head.base_offset
            continue
        var b = index.find(head.base_id)
        if b >= 0:
            offset = index.offset_at(b)
            continue
        var x = bases._find(head.base_id)
        if x < 0:
            raise Error(
                "komira_git: pack: object " + id.to_hex() + ": delta base "
                + head.base_id.to_hex() + " is not in the pack"
            )
        base = bases._payloads[x].copy()
        kind = bases._kinds[x]
        break
    var k = len(chain) - 1
    while k >= 0:
        var result_size = read_delta_header(Span(chain[k])).result_size
        if result_size <= limits.max_object_size:
            produced = _charge(produced, budget, result_size, chain_at[k])
        var out = apply_delta(Span(base), Span(chain[k]), limits.max_object_size)
        base = out^
        k -= 1
    var got = hash_object(format, kind, Span(base))
    if got != id:
        raise Error(
            "komira_git: pack: the entry at offset " + String(index.offset_at(pos))
            + " is object " + got.to_hex() + ", the index says " + id.to_hex()
        )
    return PackObject(kind, base^)
