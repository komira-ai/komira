# =============================================================================
# komira_git/pack_format.mojo -- the pieces of a packfile (gitformat-pack)
# shared by the pack reader and the index: the limits a reader enforces, the
# pack header, one entry's header, one entry's zlib stream, and the format's
# digest.
# =============================================================================
#
# A pack is `PACK`, a 4-byte big-endian version (2 or 3), a 4-byte
# big-endian object count, the entries, and the format's hash of every byte
# before it (the trailer). An entry is:
#
#   * a header: the first byte holds a continuation bit (0x80), the type
#     number in bits 4-6 and the low four bits of the inflated size; each
#     further byte adds seven bits of size, low group first;
#   * for an OFS_DELTA (type 6), the distance back to the base entry's
#     offset, in the "offset encoding" of gitformat-pack: big-endian groups
#     of seven bits where every continuation adds one before shifting, so
#     that each length has its own range (two bytes start at 128, not 0);
#   * for a REF_DELTA (type 7), the base's raw object id;
#   * one zlib stream inflating to exactly the declared size (the object's
#     payload, or for a delta the delta instructions).
#
# Every read is bounds-checked against the end of the entries (the start of
# the trailer); a malformed entry raises an error naming its offset and what
# is wrong, never reads past the input.
# =============================================================================

from komira_crypto import Sha1, Sha256
from komira_zlib import ZLIB_WINDOW_BITS_ZLIB, zlib_inflate_once

from .object_id import ObjectFormat, ObjectId, ObjectKind

comptime PACK_OBJ_COMMIT: Int = 1
"""Pack type number of a commit entry."""
comptime PACK_OBJ_TREE: Int = 2
"""Pack type number of a tree entry."""
comptime PACK_OBJ_BLOB: Int = 3
"""Pack type number of a blob entry."""
comptime PACK_OBJ_TAG: Int = 4
"""Pack type number of a tag entry."""
comptime PACK_OBJ_OFS_DELTA: Int = 6
"""Pack type number of a delta whose base is named by its offset."""
comptime PACK_OBJ_REF_DELTA: Int = 7
"""Pack type number of a delta whose base is named by its object id."""

comptime PACK_HEADER_SIZE: Int = 12
"""`PACK`, the version and the object count."""

comptime _Z_OK: Int = 0
comptime _Z_STREAM_END: Int = 1
comptime _Z_BUF_ERROR: Int = -5
comptime _ZLIB_MAX_SRC: Int = 4294967295


struct PackLimits(ImplicitlyCopyable, Movable):
    """What a pack reader refuses before it allocates or works past it.

    * `max_objects`: the object count a pack header may declare.
    * `max_object_size`: the inflated size of one entry, and the size of
      one object a delta rebuilds; checked against the declared size before
      anything is inflated or applied.
    * `max_delta_depth`: the length of a delta chain (a delta of a
      non-delta has depth 1). The default is 4095, the deepest chain
      `git pack-objects` writes.
    * `max_inflate_ratio`: every byte one `index_pack` or
      `read_pack_object` call produces (each entry inflation, each delta
      result) counts against that call's budget of
      `max_inflate_ratio * len(pack) + max_object_size`, checked before the
      bytes are produced. It bounds the work a small pack can cause (a zlib
      or delta bomb); the default allows the ratios real histories reach,
      where a 100-byte delta rebuilding a megabyte is common.
    """

    var max_objects: Int
    var max_object_size: Int
    var max_delta_depth: Int
    var max_inflate_ratio: Int

    def __init__(
        out self,
        *,
        max_objects: Int = 1 << 25,
        max_object_size: Int = 1 << 30,
        max_delta_depth: Int = 4095,
        max_inflate_ratio: Int = 1 << 16,
    ):
        self.max_objects = max_objects
        self.max_object_size = max_object_size
        self.max_delta_depth = max_delta_depth
        self.max_inflate_ratio = max_inflate_ratio

    def budget(self, pack_size: Int) -> Int:
        """The bytes a reader may produce from a pack of `pack_size` bytes:
        `max_inflate_ratio * pack_size + max_object_size`, saturating."""
        comptime cap = Int.MAX
        if self.max_inflate_ratio > 0 and pack_size > (cap - self.max_object_size) // self.max_inflate_ratio:
            return cap
        return self.max_inflate_ratio * pack_size + self.max_object_size


struct PackObject(Copyable, Movable):
    """One object read out of a pack: its kind and its payload."""

    var kind: ObjectKind
    var payload: List[UInt8]

    def __init__(out self, kind: ObjectKind, var payload: List[UInt8]):
        self.kind = kind
        self.payload = payload^


struct _EntryHead(ImplicitlyCopyable, Movable):
    """One entry's header as read: its type number, declared inflated size,
    where its zlib stream starts, and its base (an absolute offset for an
    OFS_DELTA, an id for a REF_DELTA)."""

    var type_code: Int
    var size: Int
    var data_start: Int
    var base_offset: Int
    var base_id: ObjectId

    def __init__(out self, format: ObjectFormat):
        self.type_code = 0
        self.size = 0
        self.data_start = 0
        self.base_offset = -1
        self.base_id = ObjectId(format)

    def is_delta(self) -> Bool:
        return self.type_code == PACK_OBJ_OFS_DELTA or self.type_code == PACK_OBJ_REF_DELTA


def _be32(data: Span[UInt8, _], at: Int) -> Int:
    """The big-endian 32-bit number at `data[at:at + 4]` (the caller checked
    the bounds)."""
    return (
        (Int(data[at]) << 24)
        | (Int(data[at + 1]) << 16)
        | (Int(data[at + 2]) << 8)
        | Int(data[at + 3])
    )


def _append_be32(mut out: List[UInt8], v: Int):
    out.append(UInt8((v >> 24) & 255))
    out.append(UInt8((v >> 16) & 255))
    out.append(UInt8((v >> 8) & 255))
    out.append(UInt8(v & 255))


def _digest(format: ObjectFormat, data: Span[UInt8, _]) -> List[UInt8]:
    """The format's hash of `data` (a pack's or an index's checksum)."""
    var out = List[UInt8](length=format.raw_size(), fill=UInt8(0))
    if format == ObjectFormat.sha1():
        var h = Sha1()
        h.update(data)
        h.finalize_into(Span(out))
    else:
        var h = Sha256()
        h.update(data)
        h.finalize_into(Span(out))
    return out^


def _check_pack_header(
    format: ObjectFormat, pack: Span[UInt8, _], limits: PackLimits
) raises -> Int:
    """Check the header and the trailer of `pack`; return the object count."""
    var hs = format.raw_size()
    if len(pack) < PACK_HEADER_SIZE + hs:
        raise Error(
            "komira_git: pack: " + String(len(pack))
            + " bytes is shorter than a header and a trailer"
        )
    if pack[0] != 80 or pack[1] != 65 or pack[2] != 67 or pack[3] != 75:
        raise Error("komira_git: pack: does not start with PACK")
    var version = _be32(pack, 4)
    if version != 2 and version != 3:
        raise Error("komira_git: pack: version " + String(version) + " is not 2 or 3")
    var count = _be32(pack, 8)
    if count > limits.max_objects:
        raise Error(
            "komira_git: pack: " + String(count) + " objects, over the limit "
            + String(limits.max_objects)
        )
    var end = len(pack) - hs
    var sum = _digest(format, pack[0:end])
    for i in range(hs):
        if sum[i] != pack[end + i]:
            raise Error("komira_git: pack: the trailer is not the checksum of the pack")
    return count


def _parse_entry_head(
    format: ObjectFormat,
    pack: Span[UInt8, _],
    offset: Int,
    end: Int,
    limits: PackLimits,
) raises -> _EntryHead:
    """Read the header of the entry at `offset`; `end` is the start of the
    trailer. Refuses an invalid type, a size over `limits.max_object_size`,
    a header or base that runs past `end`, and an OFS_DELTA base outside
    `[PACK_HEADER_SIZE, offset)`."""
    var at = "komira_git: pack: entry at offset " + String(offset) + ": "
    if offset < PACK_HEADER_SIZE or offset >= end:
        raise Error(at + "outside the entries")
    var head = _EntryHead(format)
    var p = offset
    var c = Int(pack[p])
    p += 1
    head.type_code = (c >> 4) & 7
    var size = c & 15
    var shift = 4
    while c & 128:
        if p >= end:
            raise Error(at + "truncated header")
        if shift > 56:
            raise Error(at + "size does not fit 64 bits")
        c = Int(pack[p])
        p += 1
        size += (c & 127) << shift
        shift += 7
    var t = head.type_code
    if t == 0 or t == 5:
        raise Error(at + "invalid type " + String(t))
    if size < 0 or size > limits.max_object_size:
        raise Error(
            at + "declares " + String(size) + " bytes, over the limit "
            + String(limits.max_object_size)
        )
    head.size = size
    if t == PACK_OBJ_OFS_DELTA:
        if p >= end:
            raise Error(at + "truncated delta base offset")
        c = Int(pack[p])
        p += 1
        var dist = c & 127
        while c & 128:
            if p >= end:
                raise Error(at + "truncated delta base offset")
            if dist > (Int.MAX >> 8):
                raise Error(at + "delta base offset does not fit 64 bits")
            c = Int(pack[p])
            p += 1
            dist = ((dist + 1) << 7) | (c & 127)
        var base = offset - dist
        if dist == 0 or base < PACK_HEADER_SIZE:
            raise Error(
                at + "delta base offset " + String(dist)
                + " points outside the entries before it"
            )
        head.base_offset = base
    elif t == PACK_OBJ_REF_DELTA:
        var hs = format.raw_size()
        if p + hs > end:
            raise Error(at + "truncated delta base id")
        head.base_id = ObjectId.from_raw(format, pack[p : p + hs])
        p += hs
    head.data_start = p
    return head


def _inflate_entry(
    pack: Span[UInt8, _],
    offset: Int,
    head: _EntryHead,
    end: Int,
    mut data: List[UInt8],
) raises -> Int:
    """Inflate the zlib stream of the entry at `offset` (header `head`),
    which must end before `end` and inflate to exactly `head.size` bytes,
    into `data`; return the offset where the stream ends."""
    var at = "komira_git: pack: entry at offset " + String(offset) + ": "
    var start = head.data_start
    if start >= end:
        raise Error(at + "no data before the trailer")
    var stop = min(end, start + _ZLIB_MAX_SRC)
    var buf = List[UInt8](length=head.size + 1, fill=UInt8(0))
    var out = zlib_inflate_once(Span(buf), pack[start:stop], ZLIB_WINDOW_BITS_ZLIB)
    var rc = Int(out.rc)
    if rc == _Z_STREAM_END:
        if out.written != head.size:
            raise Error(
                at + "inflates to " + String(out.written)
                + " bytes, the header says " + String(head.size)
            )
        buf.resize(head.size, UInt8(0))
        data = buf^
        return stop - out.unread
    if rc == _Z_OK or rc == _Z_BUF_ERROR:
        if out.unwritten == 0:
            raise Error(
                at + "inflates past its declared " + String(head.size) + " bytes"
            )
        raise Error(at + "zlib stream runs into the trailer")
    raise Error(at + "corrupt zlib stream (rc=" + String(rc) + ")")
