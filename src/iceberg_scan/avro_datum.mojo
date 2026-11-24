# =============================================================================
# iceberg_scan/avro_datum.mojo -- writer-schema Avro decoding of any OCF file
# =============================================================================
#
# WHAT THIS IS. A reader of the Avro object container files an Iceberg table
# keeps (the manifest list and every manifest) that decodes each record by the
# schema the file's own header carries, into a flat arena of `AvroDatum` nodes.
# No reader schema is assumed: a manifest written by Java, Spark, pyiceberg or
# this repository's writer has its own field order and its own optional
# fields, and a caller finds a field by NAME (`field`, `get_long`, ...).
#
# THE ARENA. `AvroDatums.nodes` holds every value of the file. A record's node
# lists its fields' node indices in `children` (writer order) and their names
# in `names`; an array node lists its items; a map node lists its values and
# keeps the keys in `names`. A union is resolved to the value of its branch,
# so a nullable field is its value or a NULL node. A top-level record of the
# file is listed in `records`, in file order.
#
# THE CODEC. Every block is decompressed by the codec the header names
# (`avro.decompress_block`: null, deflate, snappy, bzip2, xz, zstandard).
#
# THE HEADER MAP. The OCF header's key-value map (`schema`, `partition-spec`,
# `format-version`, ...) is read by a decoder of its own here, because avro's
# `OcfHeader` keeps only the schema and the codec.
#
# ERRORS. Every refusal is `ICEBERG_MANIFEST_INVALID: <what>`.
# =============================================================================

from std.memory import bitcast

from avro.avro_codec import decompress_block
from avro.avro_schema import (
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
from avro.ocf_block_scan import scan_ocf_blocks_after_header
from avro.ocf_header import decode_ocf_header, OcfHeader, OCF_MAGIC_LEN


comptime ICEBERG_MANIFEST_INVALID: String = "ICEBERG_MANIFEST_INVALID"

comptime AVRO_DATUM_NULL: Int = 0
comptime AVRO_DATUM_BOOL: Int = 1
comptime AVRO_DATUM_INT: Int = 2
comptime AVRO_DATUM_LONG: Int = 3
comptime AVRO_DATUM_FLOAT: Int = 4
comptime AVRO_DATUM_DOUBLE: Int = 5
comptime AVRO_DATUM_BYTES: Int = 6
comptime AVRO_DATUM_STRING: Int = 7
comptime AVRO_DATUM_RECORD: Int = 8
comptime AVRO_DATUM_ENUM: Int = 9
comptime AVRO_DATUM_ARRAY: Int = 10
comptime AVRO_DATUM_MAP: Int = 11
comptime AVRO_DATUM_FIXED: Int = 12


def _invalid(what: String) -> Error:
    return Error(ICEBERG_MANIFEST_INVALID + String(": ") + what)


struct AvroDatum(Copyable, Movable):
    """One node of the arena: a value and, for a container, its children."""

    var kind: Int
    """`AVRO_DATUM_*`."""
    var i: Int64
    """BOOL (0 or 1), INT, LONG, and the symbol index of an ENUM."""
    var f: Float64
    """FLOAT and DOUBLE."""
    var bytes: List[UInt8]
    """BYTES, STRING (UTF-8) and FIXED."""
    var children: List[Int]
    """RECORD: the field nodes in writer order. ARRAY: the items. MAP: the
    values."""
    var names: List[String]
    """RECORD: the field names. MAP: the keys."""

    def __init__(out self, kind: Int):
        self.kind = kind
        self.i = 0
        self.f = 0.0
        self.bytes = List[UInt8]()
        self.children = List[Int]()
        self.names = List[String]()


struct AvroDatums(Movable):
    """The arena and the records of one OCF file."""

    var nodes: List[AvroDatum]
    var records: List[Int]
    """Node indices of the file's top-level records, in file order."""
    var metadata_keys: List[String]
    """The OCF header map's keys, in file order."""
    var metadata_values: List[String]
    """The OCF header map's values (UTF-8 text), parallel to the keys."""

    def __init__(out self):
        self.nodes = List[AvroDatum]()
        self.records = List[Int]()
        self.metadata_keys = List[String]()
        self.metadata_values = List[String]()

    def field(self, record: Int, name: String) -> Int:
        """The node of the field `name` of the record node `record`, or -1
        when the node is no record, has no such field, or the value is NULL."""
        if record < 0 or record >= len(self.nodes):
            return -1
        ref r = self.nodes[record]
        if r.kind != AVRO_DATUM_RECORD:
            return -1
        for k in range(len(r.names)):
            if r.names[k] == name:
                var child = r.children[k]
                if self.nodes[child].kind == AVRO_DATUM_NULL:
                    return -1
                return child
        return -1

    def get_long(self, record: Int, name: String) -> Optional[Int64]:
        """The INT or LONG field `name`, or None when absent, NULL or of
        another kind."""
        var n = self.field(record, name)
        if n < 0:
            return None
        ref d = self.nodes[n]
        if d.kind == AVRO_DATUM_INT or d.kind == AVRO_DATUM_LONG:
            return Optional[Int64](d.i)
        return None

    def get_string(self, record: Int, name: String) -> Optional[String]:
        """The STRING field `name`, or None when absent, NULL or of another
        kind."""
        var n = self.field(record, name)
        if n < 0:
            return None
        ref d = self.nodes[n]
        if d.kind == AVRO_DATUM_STRING:
            return Optional[String](String(unsafe_from_utf8=Span(d.bytes)))
        return None

    def get_bytes(self, record: Int, name: String) -> Optional[List[UInt8]]:
        """The BYTES or FIXED field `name`, or None when absent, NULL or of
        another kind."""
        var n = self.field(record, name)
        if n < 0:
            return None
        ref d = self.nodes[n]
        if d.kind == AVRO_DATUM_BYTES or d.kind == AVRO_DATUM_FIXED:
            return Optional[List[UInt8]](d.bytes.copy())
        return None

    def get_bool(self, record: Int, name: String) -> Optional[Bool]:
        """The BOOL field `name`, or None when absent, NULL or of another
        kind."""
        var n = self.field(record, name)
        if n < 0:
            return None
        ref d = self.nodes[n]
        if d.kind == AVRO_DATUM_BOOL:
            return Optional[Bool](d.i != 0)
        return None

    def metadata(self, key: String) -> Optional[String]:
        """The OCF header map's value of `key`, or None."""
        for k in range(len(self.metadata_keys)):
            if self.metadata_keys[k] == key:
                return Optional[String](String(self.metadata_values[k]))
        return None


# =============================================================================
# The cursor over one block's bytes.
# =============================================================================


struct _Cursor(Movable):
    var data: List[UInt8]
    var pos: Int

    def __init__(out self, var data: List[UInt8], pos: Int = 0):
        self.data = data^
        self.pos = pos

    def read_long(mut self) raises -> Int64:
        var shift: UInt64 = 0
        var acc: UInt64 = 0
        while True:
            if self.pos >= len(self.data):
                raise _invalid(String("a value runs past the end of its block"))
            var b = self.data[self.pos]
            self.pos += 1
            acc |= UInt64(b & 0x7F) << shift
            if (b & 0x80) == 0:
                break
            shift += 7
            if shift >= 64:
                raise _invalid(String("an integer is longer than 10 bytes"))
        return Int64((acc >> 1) ^ (~(acc & 1) + 1))

    def read_count(mut self) raises -> Int:
        """A length or an item count that must not be negative."""
        var n = self.read_long()
        if n < 0:
            raise _invalid(String("a negative length"))
        return Int(n)

    def read_raw(mut self, n: Int) raises -> List[UInt8]:
        if n > len(self.data) - self.pos:
            raise _invalid(String("a value runs past the end of its block"))
        var out = List[UInt8](capacity=n)
        for k in range(n):
            out.append(self.data[self.pos + k])
        self.pos += n
        return out^

    def read_blob(mut self) raises -> List[UInt8]:
        """A length-prefixed run of bytes (an Avro bytes or string)."""
        var n = self.read_count()
        return self.read_raw(n)

    def read_float(mut self) raises -> Float64:
        var raw = self.read_raw(4)
        var bits: UInt32 = 0
        for k in range(4):
            bits |= UInt32(raw[k]) << UInt32(8 * k)
        return Float64(bitcast[DType.float32, 1](bits))

    def read_double(mut self) raises -> Float64:
        var raw = self.read_raw(8)
        var bits: UInt64 = 0
        for k in range(8):
            bits |= UInt64(raw[k]) << UInt64(8 * k)
        return bitcast[DType.float64, 1](bits)


# =============================================================================
# The decoder.
# =============================================================================


def _add(mut nodes: List[AvroDatum], var d: AvroDatum) -> Int:
    nodes.append(d^)
    return len(nodes) - 1


def _decode_value(
    schema: AvroSchema,
    idx: Int,
    mut cur: _Cursor,
    mut nodes: List[AvroDatum],
) raises -> Int:
    """Decode one value of the schema node `idx` and return its arena node."""
    ref sn = schema.nodes[idx]
    var kind = sn.kind
    if kind == AVRO_KIND_NULL:
        return _add(nodes, AvroDatum(AVRO_DATUM_NULL))
    elif kind == AVRO_KIND_BOOLEAN:
        var d = AvroDatum(AVRO_DATUM_BOOL)
        var raw = cur.read_raw(1)
        d.i = Int64(1) if raw[0] != 0 else Int64(0)
        return _add(nodes, d^)
    elif kind == AVRO_KIND_INT:
        var d = AvroDatum(AVRO_DATUM_INT)
        d.i = cur.read_long()
        return _add(nodes, d^)
    elif kind == AVRO_KIND_LONG:
        var d = AvroDatum(AVRO_DATUM_LONG)
        d.i = cur.read_long()
        return _add(nodes, d^)
    elif kind == AVRO_KIND_FLOAT:
        var d = AvroDatum(AVRO_DATUM_FLOAT)
        d.f = cur.read_float()
        return _add(nodes, d^)
    elif kind == AVRO_KIND_DOUBLE:
        var d = AvroDatum(AVRO_DATUM_DOUBLE)
        d.f = cur.read_double()
        return _add(nodes, d^)
    elif kind == AVRO_KIND_BYTES or kind == AVRO_KIND_STRING:
        var d = AvroDatum(
            AVRO_DATUM_BYTES if kind == AVRO_KIND_BYTES else AVRO_DATUM_STRING
        )
        d.bytes = cur.read_blob()
        return _add(nodes, d^)
    elif kind == AVRO_KIND_FIXED:
        var d = AvroDatum(AVRO_DATUM_FIXED)
        d.bytes = cur.read_raw(sn.size)
        return _add(nodes, d^)
    elif kind == AVRO_KIND_ENUM:
        var d = AvroDatum(AVRO_DATUM_ENUM)
        d.i = cur.read_long()
        if d.i < 0 or Int(d.i) >= len(sn.symbols):
            raise _invalid(String("an enum symbol index is out of range"))
        return _add(nodes, d^)
    elif kind == AVRO_KIND_UNION:
        var branch = cur.read_long()
        if branch < 0 or Int(branch) >= len(sn.children):
            raise _invalid(String("a union branch index is out of range"))
        return _decode_value(schema, sn.children[Int(branch)], cur, nodes)
    elif kind == AVRO_KIND_RECORD:
        var d = AvroDatum(AVRO_DATUM_RECORD)
        for k in range(len(sn.children)):
            d.names.append(sn.field_names[k])
            d.children.append(_decode_value(schema, sn.children[k], cur, nodes))
        return _add(nodes, d^)
    else:
        # ARRAY or MAP: the schema parser yields no other kind.
        var is_map = kind == AVRO_KIND_MAP
        var d = AvroDatum(AVRO_DATUM_MAP if is_map else AVRO_DATUM_ARRAY)
        while True:
            var count = cur.read_long()
            if count == 0:
                break
            if count < 0:
                # A negative count is followed by the block's byte size.
                count = -count
                if count < 0:
                    raise _invalid(String("an item count is out of range"))
                _ = cur.read_long()
            if Int(count) > len(cur.data) - cur.pos:
                # Every item of an Iceberg file takes at least one byte, so a
                # count beyond the bytes left is a damaged block.
                raise _invalid(
                    String("an item count runs past the end of its block")
                )
            for _k in range(Int(count)):
                if is_map:
                    var key = cur.read_blob()
                    d.names.append(String(unsafe_from_utf8=Span(key)))
                var item = _decode_value(schema, sn.children[0], cur, nodes)
                d.children.append(item)
        return _add(nodes, d^)


def _read_header_map(
    bytes: Span[UInt8, _], header_len: Int, mut out: AvroDatums
) raises:
    """The header's key-value map: the bytes after the magic. `avro`'s own
    decoder has read the same bytes, so the counts are sound; a read past the
    header still raises."""
    var raw = List[UInt8](capacity=header_len)
    for k in range(header_len):
        raw.append(bytes[k])
    var cur = _Cursor(raw^, OCF_MAGIC_LEN)
    while True:
        var count = cur.read_long()
        if count == 0:
            break
        if count < 0:
            # The writer's block form: a byte size follows the negated count.
            count = -count
            _ = cur.read_long()
        for _k in range(Int(count)):
            var key = cur.read_blob()
            var value = cur.read_blob()
            out.metadata_keys.append(String(unsafe_from_utf8=Span(key)))
            out.metadata_values.append(String(unsafe_from_utf8=Span(value)))


def _read_file(bytes: Span[UInt8, _]) raises -> AvroDatums:
    var out = AvroDatums()
    var header = decode_ocf_header(bytes)
    _read_header_map(bytes, header.header_len, out)
    var schema = header.parse_schema()
    var blocks = scan_ocf_blocks_after_header(bytes, header)
    for b in range(len(blocks)):
        ref blk = blocks[b]
        var start = blk.payload_offset
        var payload = decompress_block(
            header.codec_tag, bytes[start : start + blk.payload_len]
        )
        var cur = _Cursor(payload^)
        for _r in range(Int(blk.object_count)):
            var rec = _decode_value(schema, schema.root_idx, cur, out.nodes)
            out.records.append(rec)
        if cur.pos != len(cur.data):
            raise _invalid(String("a block holds bytes after its last record"))
    return out^


def read_avro_datums(bytes: Span[UInt8, _]) raises -> AvroDatums:
    """Decode every record of an Avro OCF file by the file's own schema.

    Raises:
        `ICEBERG_MANIFEST_INVALID: ...` for bytes that are not an OCF file, a
        schema or block that does not decode, or a value that runs past its
        block. A refusal of the avro package is carried in the message."""
    try:
        return _read_file(bytes)
    except e:
        var msg = String(e)
        if msg.startswith(ICEBERG_MANIFEST_INVALID):
            raise Error(msg)
        raise _invalid(msg)
