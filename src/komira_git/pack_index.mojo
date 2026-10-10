# =============================================================================
# komira_git/pack_index.mojo -- the pack index, version 2 (gitformat-pack,
# "Version 2 pack-*.idx files support packs larger than 4 GiB").
# =============================================================================
#
# An index v2 file is, all numbers big-endian:
#
#   * the magic `\377tOc` and the version 2;
#   * a fan-out table of 256 four-byte counts: entry i is the number of
#     objects whose first id byte is <= i, so entry 255 is the count;
#   * the ids, sorted;
#   * a CRC-32 per object (of the entry's bytes in the pack, header and
#     zlib stream), in id order;
#   * a four-byte offset per object; one with the top bit set is instead an
#     index into the next table;
#   * eight-byte offsets, one per four-byte entry that pointed here, in id
#     order;
#   * the pack's checksum, then the format's hash of every byte before it.
#
# `serialize` writes what `git index-pack` writes for the same objects:
# an offset goes to the eight-byte table when it is over
# `large_offset_threshold` or does not fit 31 bits (git's
# `need_large_offset`; `git index-pack --index-version=2,<threshold>` sets
# the threshold, 0x7fffffff by default).
#
# `parse_pack_index` refuses a wrong magic or version, a length that does
# not match the counts, a fan-out table that decreases or disagrees with the
# ids, ids out of order or repeated, an offset inside the pack header, an
# eight-byte-table reference past the table, and a wrong checksum.
# =============================================================================

from .object_id import ObjectFormat, ObjectId
from .pack_format import PACK_HEADER_SIZE, _append_be32, _be32, _digest

comptime PACK_INDEX_DEFAULT_LARGE_OFFSET: Int = 0x7FFFFFFF
"""The offset above which `serialize` uses the eight-byte table by
default (git's)."""

comptime _IDX_MAGIC_0: UInt8 = 255
comptime _IDX_MAGIC_1: UInt8 = 116  # t
comptime _IDX_MAGIC_2: UInt8 = 79  # O
comptime _IDX_MAGIC_3: UInt8 = 99  # c
comptime _FANOUT_END: Int = 8 + 256 * 4


def _id_compare(a: ObjectId, b: ObjectId) -> Int:
    """-1, 0 or 1 as `a`'s raw bytes sort before, equal or after `b`'s."""
    for i in range(a.format().raw_size()):
        var x = a.byte_at(i)
        var y = b.byte_at(i)
        if x < y:
            return -1
        if x > y:
            return 1
    return 0


def _sort_by_id(ids: List[ObjectId]) -> List[Int]:
    """The positions of `ids` in ascending id order (a stable merge sort)."""
    var n = len(ids)
    var order = List[Int](capacity=n)
    for i in range(n):
        order.append(i)
    var tmp = List[Int](length=n, fill=0)
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var i = lo
            var j = mid
            var k = lo
            while i < mid and j < hi:
                if _id_compare(ids[order[j]], ids[order[i]]) < 0:
                    tmp[k] = order[j]
                    j += 1
                else:
                    tmp[k] = order[i]
                    i += 1
                k += 1
            while i < mid:
                tmp[k] = order[i]
                i += 1
                k += 1
            while j < hi:
                tmp[k] = order[j]
                j += 1
                k += 1
            lo += 2 * width
        for x in range(n):
            order[x] = tmp[x]
        width *= 2
    return order^


struct PackIndex(Copyable, Movable):
    """The objects of one pack, in id order: each id with its entry's offset
    and CRC-32, and the pack's checksum."""

    var _format: ObjectFormat
    var _ids: List[ObjectId]
    var _offsets: List[Int]
    var _crcs: List[UInt32]
    var _pack_checksum: List[UInt8]

    def __init__(
        out self,
        format: ObjectFormat,
        var ids: List[ObjectId],
        var offsets: List[Int],
        var crcs: List[UInt32],
        var pack_checksum: List[UInt8],
    ):
        """An index of `ids`, which the caller has sorted ascending with no
        repeats, `offsets[i]` and `crcs[i]` belonging to `ids[i]`."""
        self._format = format
        self._ids = ids^
        self._offsets = offsets^
        self._crcs = crcs^
        self._pack_checksum = pack_checksum^

    def format(self) -> ObjectFormat:
        return self._format

    def count(self) -> Int:
        """The number of objects."""
        return len(self._ids)

    def id_at(self, i: Int) -> ObjectId:
        """The `i`-th id in ascending order."""
        return self._ids[i]

    def offset_at(self, i: Int) -> Int:
        """The pack offset of the `i`-th object's entry."""
        return self._offsets[i]

    def crc32_at(self, i: Int) -> UInt32:
        """The CRC-32 of the `i`-th object's entry bytes."""
        return self._crcs[i]

    def pack_checksum(self) -> List[UInt8]:
        """The checksum (trailer) of the pack this index describes."""
        return self._pack_checksum.copy()

    def find(self, id: ObjectId) -> Int:
        """The position of `id`, or -1 when the pack does not hold it."""
        if id.format() != self._format:
            return -1
        var lo = 0
        var hi = len(self._ids)
        while lo < hi:
            var mid = (lo + hi) // 2
            var c = _id_compare(self._ids[mid], id)
            if c == 0:
                return mid
            if c < 0:
                lo = mid + 1
            else:
                hi = mid
        return -1

    def serialize(
        self, large_offset_threshold: Int = PACK_INDEX_DEFAULT_LARGE_OFFSET
    ) raises -> List[UInt8]:
        """The index v2 file `git index-pack` writes for this index, with
        offsets over `large_offset_threshold` (at most 0x7fffffff) in the
        eight-byte table."""
        if large_offset_threshold < 0 or large_offset_threshold > PACK_INDEX_DEFAULT_LARGE_OFFSET:
            raise Error(
                "komira_git: pack index: large offset threshold "
                + String(large_offset_threshold) + " is not in [0, 0x7fffffff]"
            )
        var n = len(self._ids)
        var hs = self._format.raw_size()
        var out = List[UInt8](capacity=_FANOUT_END + n * (hs + 8) + 2 * hs)
        out.append(_IDX_MAGIC_0)
        out.append(_IDX_MAGIC_1)
        out.append(_IDX_MAGIC_2)
        out.append(_IDX_MAGIC_3)
        _append_be32(out, 2)
        var counts = List[Int](length=256, fill=0)
        for i in range(n):
            counts[Int(self._ids[i].byte_at(0))] += 1
        var acc = 0
        for b in range(256):
            acc += counts[b]
            _append_be32(out, acc)
        for i in range(n):
            self._ids[i].append_raw_to(out)
        for i in range(n):
            _append_be32(out, Int(self._crcs[i]))
        var large = List[Int]()
        for i in range(n):
            var off = self._offsets[i]
            if off > large_offset_threshold or (off >> 31) != 0:
                _append_be32(out, 0x80000000 | len(large))
                large.append(off)
            else:
                _append_be32(out, off)
        for i in range(len(large)):
            _append_be32(out, large[i] >> 32)
            _append_be32(out, large[i] & 0xFFFFFFFF)
        out.extend(Span(self._pack_checksum))
        var sum = _digest(self._format, Span(out))
        out.extend(Span(sum))
        return out^


def parse_pack_index(format: ObjectFormat, data: Span[UInt8, _]) raises -> PackIndex:
    """Read an index v2 file of `format`, refusing every malformation the
    header of this file lists."""
    var hs = format.raw_size()
    var p = "komira_git: pack index: "
    if len(data) < _FANOUT_END + 2 * hs:
        raise Error(p + String(len(data)) + " bytes is shorter than an empty index")
    if (
        data[0] != _IDX_MAGIC_0
        or data[1] != _IDX_MAGIC_1
        or data[2] != _IDX_MAGIC_2
        or data[3] != _IDX_MAGIC_3
    ):
        raise Error(p + "no version 2 magic (a version 1 index is not supported)")
    var version = _be32(data, 4)
    if version != 2:
        raise Error(p + "version " + String(version) + " is not 2")
    var end = len(data) - hs
    var sum = _digest(format, data[0:end])
    for i in range(hs):
        if sum[i] != data[end + i]:
            raise Error(p + "the checksum does not match")
    var prev = 0
    for b in range(256):
        var c = _be32(data, 8 + 4 * b)
        if c < prev:
            raise Error(p + "fan-out entry " + String(b) + " decreases")
        prev = c
    var n = prev
    var fixed = _FANOUT_END + n * (hs + 8) + 2 * hs
    if len(data) < fixed or (len(data) - fixed) % 8 != 0:
        raise Error(
            p + String(len(data)) + " bytes does not fit " + String(n) + " objects"
        )
    var n_large = (len(data) - fixed) // 8
    var ids_at = _FANOUT_END
    var crcs_at = ids_at + n * hs
    var offs_at = crcs_at + n * 4
    var large_at = offs_at + n * 4
    var ids = List[ObjectId](capacity=n)
    var offsets = List[Int](capacity=n)
    var crcs = List[UInt32](capacity=n)
    for i in range(n):
        var id = ObjectId.from_raw(format, data[ids_at + i * hs : ids_at + (i + 1) * hs])
        if i > 0 and _id_compare(ids[i - 1], id) >= 0:
            raise Error(p + "object " + String(i) + " is not after the one before it")
        var first = Int(id.byte_at(0))
        var below = 0 if first == 0 else _be32(data, 8 + 4 * (first - 1))
        if i < below or i >= _be32(data, 8 + 4 * first):
            raise Error(p + "the fan-out table disagrees with object " + String(i))
        ids.append(id)
        crcs.append(UInt32(_be32(data, crcs_at + 4 * i)))
        var off = _be32(data, offs_at + 4 * i)
        if off & 0x80000000:
            var k = off & 0x7FFFFFFF
            if k >= n_large:
                raise Error(
                    p + "object " + String(i) + " names eight-byte offset "
                    + String(k) + " of " + String(n_large)
                )
            var hi = _be32(data, large_at + 8 * k)
            if hi & 0x80000000:
                raise Error(p + "object " + String(i) + " has an offset over 2^63")
            off = (hi << 32) | _be32(data, large_at + 8 * k + 4)
        if off < PACK_HEADER_SIZE:
            raise Error(
                p + "object " + String(i) + " is at offset " + String(off)
                + ", inside the pack header"
            )
        offsets.append(off)
    var checksum = List[UInt8](capacity=hs)
    checksum.extend(data[end - hs : end])
    return PackIndex(format, ids^, offsets^, crcs^, checksum^)
