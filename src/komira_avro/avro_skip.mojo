# =============================================================================
# avro_skip.mojo — skip one value of any Avro type without materializing it.
# =============================================================================
#
# Schema resolution drops a writer field the reader does not have, whatever its
# type (the spec's "the writer's value for that field is ignored"). A scalar is
# skipped by its width; a record, enum, array, map or union is skipped by
# walking its schema. `SkipProgram` is that walk, compiled once from the writer
# schema: one entry per schema node, at the node's own arena index, so a named
# type referenced from many places is compiled once and the program is never
# larger than the schema.
#
# UNTRUSTED INPUT. Array and map block counts come off the wire. A block of
# items that occupy no bytes (an array of `null`, a map is never zero-width
# because each entry has a key) would otherwise let a 2^62 count spin the
# loop; such a block is skipped without iterating (`zero_width`). Every other
# item consumes at least one byte, so the payload length bounds the iterations.
# A negative count carries the block's byte size, which is skipped directly.
# The walk recurses only along schema edges, and the schema parser refuses a
# recursive schema, so recursion depth is bounded by the schema's nesting.
# =============================================================================

from .avro_schema import (
    AvroSchema,
    AVRO_KIND_NULL,
    AVRO_KIND_BOOLEAN,
    AVRO_KIND_INT,
    AVRO_KIND_LONG,
    AVRO_KIND_FLOAT,
    AVRO_KIND_DOUBLE,
    AVRO_KIND_BYTES,
    AVRO_KIND_STRING,
    AVRO_KIND_RECORD,
    AVRO_KIND_ENUM,
    AVRO_KIND_ARRAY,
    AVRO_KIND_MAP,
    AVRO_KIND_UNION,
    AVRO_KIND_FIXED,
)
from .varint_decode_scalar import AvroByteReader


struct SkipProgram(Copyable, Movable):
    """Per-node skip descriptors for one schema, indexed like `schema.nodes`."""

    var kinds: List[Int]
    var sizes: List[Int]  # fixed size (AVRO_KIND_FIXED only)
    # Record fields, the array item, the map value, or the union branches.
    var children: List[List[Int]]
    # True iff a value of the node occupies no bytes on the wire: null, a
    # fixed of size 0, or a record whose fields are all zero-width.
    var zero_width: List[Bool]

    def __init__(out self, schema: AvroSchema) raises:
        var n = len(schema.nodes)
        self.kinds = List[Int](capacity=n)
        self.sizes = List[Int](capacity=n)
        self.children = List[List[Int]](capacity=n)
        self.zero_width = List[Bool](capacity=n)
        for i in range(n):
            ref node = schema.nodes[i]
            self.kinds.append(node.kind)
            self.sizes.append(node.size)
            self.children.append(node.children.copy())
            self.zero_width.append(False)
        # A record is zero-width when all its fields are. Children of a record
        # may sit at any arena index, so iterate to a fixed point (at most one
        # pass per nesting level; the schema has no cycles).
        var changed = True
        while changed:
            changed = False
            for i in range(n):
                if self.zero_width[i]:
                    continue
                var k = self.kinds[i]
                var zw = False
                if k == AVRO_KIND_NULL:
                    zw = True
                elif k == AVRO_KIND_FIXED:
                    zw = self.sizes[i] == 0
                elif k == AVRO_KIND_RECORD:
                    zw = True
                    for c in range(len(self.children[i])):
                        if not self.zero_width[self.children[i][c]]:
                            zw = False
                            break
                if zw:
                    self.zero_width[i] = True
                    changed = True

    def skip(self, mut reader: AvroByteReader[_], idx: Int) raises:
        """Advance `reader` past one value of the schema node `idx`."""
        if self.zero_width[idx]:
            return
        var k = self.kinds[idx]
        if k == AVRO_KIND_BOOLEAN:
            reader.skip_n(1)
        elif k == AVRO_KIND_INT or k == AVRO_KIND_LONG or k == AVRO_KIND_ENUM:
            reader.skip_long()
        elif k == AVRO_KIND_FLOAT:
            reader.skip_n(4)
        elif k == AVRO_KIND_DOUBLE:
            reader.skip_n(8)
        elif k == AVRO_KIND_STRING or k == AVRO_KIND_BYTES:
            reader.skip_n(Int(reader.read_long()))
        elif k == AVRO_KIND_FIXED:
            reader.skip_n(self.sizes[idx])
        elif k == AVRO_KIND_RECORD:
            for c in range(len(self.children[idx])):
                self.skip(reader, self.children[idx][c])
        elif k == AVRO_KIND_UNION:
            var tag = reader.read_long()
            var nb = len(self.children[idx])
            if tag < 0 or tag >= Int64(nb):
                raise Error(
                    "AvroDecodeError.MALFORMED: union branch "
                    + String(tag)
                    + " out of range for a "
                    + String(nb)
                    + "-branch union"
                )
            self.skip(reader, self.children[idx][Int(tag)])
        elif k == AVRO_KIND_ARRAY or k == AVRO_KIND_MAP:
            self._skip_blocks(reader, idx, k == AVRO_KIND_MAP)
        else:
            raise Error(
                "AvroDecodeError.UNSUPPORTED_FIELD_KIND: cannot skip kind "
                + String(k)
            )

    def _skip_blocks(
        self, mut reader: AvroByteReader[_], idx: Int, is_map: Bool
    ) raises:
        """Skip the blocks of an array or map: a count, then that many items
        (a map item is a string key and a value), until a zero count. A
        negative count is followed by the block's size in bytes."""
        var item = self.children[idx][0]
        var item_zero_width = self.zero_width[item] and not is_map
        while True:
            var count = reader.read_long()
            if count == 0:
                return
            if count < 0:
                var size = reader.read_long()
                if size < 0:
                    raise Error(
                        "AvroDecodeError.MALFORMED: negative block size "
                        + String(size)
                    )
                reader.skip_n(Int(size))
                continue
            if item_zero_width:
                continue
            for _i in range(Int(count)):
                if is_map:
                    reader.skip_n(Int(reader.read_long()))
                self.skip(reader, item)
