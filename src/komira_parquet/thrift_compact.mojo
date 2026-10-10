# =============================================================================
# Thrift Compact Protocol reader for Parquet metadata
# =============================================================================
#
# Parquet encodes its footer (FileMetaData), its page headers, its page index
# and its bloom filter headers with the Thrift Compact Protocol. This module
# holds the reader every one of those parsers shares, and a summary parse of
# the footer's top-level fields.
#
# Every read is bounds-checked against the view the reader was built over, so
# a malformed or hostile footer raises an error; it never reads outside the
# view, recurses without bound or loops on a count the bytes cannot hold.
# =============================================================================

from std.memory import unsafe_memcpy

from komira_buffer.byte_view import ByteView


# =============================================================================
# Thrift metadata minimal parser
# =============================================================================
# Parquet uses Compact Protocol Thrift for its metadata.
#
# Compact Protocol wire types:
#   0 = stop (end of struct)
#   1 = bool true
#   2 = bool false
#   3 = i8
#   4 = i16 (zigzag varint)
#   5 = i32 (zigzag varint)
#   6 = i64 (zigzag varint)
#   7 = double (8 bytes LE)
#   8 = binary (varint length + bytes)
#   9 = list (elem_type_and_size + elements)
#   10 = set (elem_type_and_size + elements)
#   11 = map (size + key_type_and_val_type + entries)
#   12 = struct (nested struct)
# =============================================================================

# The maximum struct/list/map nesting the Thrift skip path will recurse
# through. Parquet's own metadata schema nests a handful of levels
# (FileMetaData > RowGroup > ColumnChunk > ColumnMetaData > Statistics); 64
# is far above anything a real writer emits and far below the stack depth a
# footer of nested headers (one or two bytes per level) would otherwise reach.
comptime _THRIFT_MAX_SKIP_DEPTH: Int = 64


struct ThriftCompactReader[mut: Bool, //, origin: Origin[mut=mut]](Movable):
    """Minimal Thrift Compact Protocol reader for Parquet metadata.

    Parameterized on `origin` so the reader's backing byte range is
    lifetime-tied to the owner of the buffer (e.g. a `ParquetFileReader`'s
    metadata buffer).

    Parameters:
        mut: Whether the source view's origin permits mutation (inferred;
             ThriftCompactReader only reads from the view).
        origin: The origin the input view is tied to.

    Public fields:
        data_len: Length of the backing byte range (in bytes).
        pos: Current read position (0-based offset from the view start).
        prev_field_id: Previous field ID, for Thrift delta-field encoding.

    Private fields:
        _view: Origin-tied `ByteView` over the Thrift-encoded bytes.
    """

    # SAFETY: `_view` carries an origin tied to the caller's buffer. All
    # byte access goes through the view's typed `read_*_at` methods, which
    # are bounds-checked. The reader never escapes the origin beyond its
    # own lifetime.
    var _view: ByteView[Self.origin]
    var data_len: Int
    var pos: Int
    var prev_field_id: Int

    @always_inline
    def __init__(out self, view: ByteView[Self.origin]):
        """Construct a reader over `view`, starting at offset 0.

        Args:
            view: Origin-tied byte view over the Thrift-encoded bytes.
                The view (and therefore this reader) must not outlive the
                buffer it borrows from.
        """
        self._view = view
        self.data_len = view.len()
        self.pos = 0
        self.prev_field_id = 0

    @always_inline
    def byte_at(self, offset: Int) raises -> UInt8:
        """Read a single byte at absolute `offset`. Raises on OOB."""
        if offset < 0 or offset >= self.data_len:
            raise Error("thrift: byte_at past end of data")
        return self._view.read_u8_at(offset)

    @always_inline
    def load_i64_le_at(self, offset: Int) raises -> Int64:
        """Load an unaligned 8-byte little-endian Int64 at absolute `offset`.

        PERF-CRITICAL: a statistics reader calls this on every row group's
        min/max field; the inline load is what keeps that read far cheaper
        than a full `parse_full_metadata()`.

        Raises:
            Error if the 8 bytes at `offset` are not all inside the view.
        """
        if offset < 0 or offset > self.data_len - 8:
            raise Error("thrift: load_i64_le_at past end of data")
        return self._view.read_i64_le_at(offset)

    @always_inline
    def _read_byte(mut self) raises -> Int:
        """Read a single byte and advance position."""
        # `_skip_field` and the metadata/page-index parsers advance `pos` by
        # lengths read from the input, and a negative one would move it below
        # zero, so both bounds are checked here.
        if self.pos < 0 or self.pos >= self.data_len:
            raise Error("thrift: unexpected end of data")
        var b = Int(self._view.read_u8_at(self.pos))
        self.pos += 1
        return b

    @always_inline
    def _read_varint(mut self) raises -> Int:
        """Read an unsigned varint (ULEB128).

        Raises:
            Error if the encoding overruns 64 bits or decodes to a value
            that does not fit a non-negative Int.
        """
        var result = 0
        var shift = 0
        while True:
            var b = self._read_byte()
            result = result | ((b & 0x7F) << shift)
            if b & 0x80 == 0:
                break
            shift += 7
            if shift >= 64:
                # Returning the accumulated value here would hand a negative
                # Int (the ten-byte all-continuation form sets the sign bit)
                # to callers that advance `pos` by it, walking backward and
                # re-parsing the same bytes forever.
                raise Error(
                    "thrift: malformed varint — continuation bits extend"
                    " past 64 bits"
                )
        if result < 0:
            raise Error(
                "thrift: malformed varint — decoded value "
                + String(result)
                + " does not fit a non-negative Int"
            )
        return result

    @always_inline
    def _read_zigzag(mut self) raises -> Int:
        """Read a zigzag-encoded signed integer."""
        var n = self._read_varint()
        return (n >> 1) ^ (-(n & 1))

    def _read_field_header(mut self) raises -> Tuple[Int, Int]:
        """Read a field header. Returns (field_id, wire_type).

        In Compact Protocol, field headers use delta encoding:
        - If high nibble != 0: delta = high nibble, type = low nibble
        - If high nibble == 0: type = low nibble, field_id follows as i16 zigzag
        - type == 0 means STOP (end of struct)
        """
        var byte = self._read_byte()
        var wire_type = byte & 0x0F
        if wire_type == 0:
            return (0, 0)  # STOP

        var delta = (byte >> 4) & 0x0F
        if delta != 0:
            self.prev_field_id += delta
        else:
            self.prev_field_id = self._read_zigzag()

        return (self.prev_field_id, wire_type)

    @always_inline
    def _read_binary_to_list(mut self, length: Int) raises -> List[UInt8]:
        """Read `length` raw bytes at the current position into a new
        `List[UInt8]`, advancing `pos` by `length`.

        # PERF-CRITICAL: hot path for ColumnChunk Statistics fields
        # (min_value / max_value). One bulk copy from the view replaces a
        # per-byte append loop, which dominated the footer parse on large
        # binary fields.

        Args:
            length: Number of bytes to read.

        Returns:
            A `List[UInt8]` of exactly `length` initialized bytes.

        Raises:
            Error if `pos + length` exceeds the view length.
        """
        if length < 0 or length > self.data_len - self.pos:
            raise Error("thrift: binary read past end of data")
        # SAFETY: List[UInt8] holds POD bytes so `unsafe_uninit_length`
        # is sound; we memcpy-initialize EVERY slot before returning.
        # UnsafePointer + memcpy is confined to this private helper
        # (no UnsafePointer crosses the public boundary).
        var out = List[UInt8](unsafe_uninit_length=length)
        if length > 0:
            var dst = out.unsafe_ptr()
            # Bulk copy from the origin-tied view into the freshly-allocated
            # List buffer. Source and dest do NOT alias (List was just
            # allocated via `unsafe_uninit_length`).
            #
            # `_view._unsafe_ptr()` exposes the view's raw pointer; the
            # bounds check above keeps `[pos, pos + length)` inside it.
            var src_byte = self._view._unsafe_ptr() + self.pos
            unsafe_memcpy(dest=dst, src=src_byte, count=length)
        self.pos += length
        return out^

    @always_inline
    def _checked_list_size(self, size: Int) raises -> Int:
        """Return `size`, refusing a list/set element count the buffer cannot
        possibly contain.

        A Thrift compact list header carries its element count in a nibble,
        or — when the nibble is 15 — in a following ULEB128. Callers then
        append one parsed element per count. Once `pos >= data_len` each
        inner parse returns a default-constructed element immediately, so
        without this check a few header bytes could request an unbounded
        number of appends and grow the heap until the allocator aborts.

        Every element type Parquet uses in these lists (SchemaElement,
        RowGroup, Encoding varint, path string) consumes AT LEAST one
        byte, so a count larger than the bytes remaining is unsatisfiable
        by construction — rejecting it up front costs one compare per
        LIST and cannot reject anything a real file contains.
        """
        if size < 0 or size > self.data_len - self.pos:
            raise Error(
                "thrift: list declares "
                + String(size)
                + " elements but only "
                + String(self.data_len - self.pos)
                + " bytes remain — refusing to allocate for a count the"
                " buffer cannot contain"
            )
        return size

    @always_inline
    def _advance(mut self, n: Int) raises:
        """Advance `pos` by `n`, refusing to leave the buffer.

        Every `self.pos += <length from the input>` in the skip path routes
        through here, so a negative or oversized length raises instead of
        placing `pos` outside [0, data_len].
        """
        if n < 0 or n > self.data_len - self.pos:
            raise Error(
                "thrift: field length "
                + String(n)
                + " runs past the end of the buffer (pos="
                + String(self.pos)
                + ", len="
                + String(self.data_len)
                + ")"
            )
        self.pos += n

    def _skip_field(mut self, wire_type: Int, depth: Int = 0) raises:
        """Skip a field value of the given wire type.

        Args:
            wire_type: Thrift Compact wire type of the field to skip.
            depth: Current nesting depth, capped at `_THRIFT_MAX_SKIP_DEPTH`
                (a list of lists or a map of maps nests without passing
                through `_skip_struct`, so the cap is checked here too).
        """
        if depth > _THRIFT_MAX_SKIP_DEPTH:
            raise Error(
                "thrift: nesting depth exceeds "
                + String(_THRIFT_MAX_SKIP_DEPTH)
                + " — refusing to recurse further on a malformed field"
            )
        if wire_type == 1 or wire_type == 2:
            pass  # bool true/false - no additional bytes
        elif wire_type == 3:
            self._advance(1)  # i8
        elif wire_type == 4 or wire_type == 5 or wire_type == 6:
            _ = self._read_varint()  # i16/i32/i64 zigzag varint
        elif wire_type == 7:
            self._advance(8)  # double
        elif wire_type == 8:
            var len = self._read_varint()  # binary
            self._advance(len)
        elif wire_type == 9 or wire_type == 10:
            # list or set
            var header = self._read_byte()
            var size = (header >> 4) & 0x0F
            if size == 15:
                size = self._read_varint()
            var elem_type = header & 0x0F
            # A bool element (wire type 1/2) carries its value in the type
            # nibble and consumes ZERO bytes, so the loop below would never
            # advance `pos` — a 5-byte varint could request 2^40 no-op
            # iterations. Skipping them is a no-op by construction, so
            # short-circuit rather than spin.
            if elem_type != 1 and elem_type != 2:
                # Every other element type consumes at least one byte, so
                # a declared count larger than the remaining buffer is
                # unsatisfiable by definition — reject it up front instead
                # of discovering it `size` iterations later.
                if size < 0 or size > self.data_len - self.pos:
                    raise Error(
                        "thrift: list/set declares "
                        + String(size)
                        + " elements but only "
                        + String(self.data_len - self.pos)
                        + " bytes remain"
                    )
                for _ in range(size):
                    self._skip_field(elem_type, depth + 1)
        elif wire_type == 11:
            # map
            var size = self._read_varint()
            if size > 0:
                var types = self._read_byte()
                var key_type = (types >> 4) & 0x0F
                var val_type = types & 0x0F
                # Every map's entry count is bounded by the bytes that remain,
                # with no exception for maps whose key and value are both
                # bools: `_skip_field` on wire type 1/2 consumes no byte, so
                # such a map would advance `pos` by zero per entry while the
                # loop below still ran `size` times. Parquet metadata has no
                # maps of bools, so this rejects nothing a conforming writer
                # emits, and costs one compare per MAP.
                if size > self.data_len - self.pos:
                    raise Error(
                        "thrift: map declares "
                        + String(size)
                        + " entries but only "
                        + String(self.data_len - self.pos)
                        + " bytes remain"
                    )
                for _ in range(size):
                    self._skip_field(key_type, depth + 1)
                    self._skip_field(val_type, depth + 1)
        elif wire_type == 12:
            # nested struct
            self._skip_struct(depth + 1)
        else:
            raise Error("thrift: unknown wire type " + String(wire_type))

    def _skip_struct(mut self, depth: Int = 0) raises:
        """Skip an entire struct (read until STOP).

        Args:
            depth: Current nesting depth, capped at `_THRIFT_MAX_SKIP_DEPTH`.

        `_skip_field(12)` calls `_skip_struct`, which calls `_skip_field` for
        every field it sees, which recurses again on any wire-type-12 field —
        so a footer of repeated `0x0C` bytes would nest one stack frame per
        ~2 input bytes and overflow the stack. The cap is far above any real
        schema (Parquet nests struct/list/map a handful of levels) and is
        checked once per level, not per field.
        """
        if depth > _THRIFT_MAX_SKIP_DEPTH:
            raise Error(
                "thrift: nesting depth exceeds "
                + String(_THRIFT_MAX_SKIP_DEPTH)
                + " — refusing to recurse further on a malformed struct"
            )
        var saved = self.prev_field_id
        self.prev_field_id = 0
        # Use bounded for loop to avoid potential Mojo parser issues.
        for _ in range(10000):
            var fld = self._read_field_header()
            if fld[1] == 0:
                break
            self._skip_field(fld[1], depth)
        self.prev_field_id = saved


struct ParquetMetadataSummary(Movable, Copyable):
    """Summary of key Parquet file metadata fields.

    Extracted from the Thrift-encoded FileMetaData without parsing
    the full schema or row group details.

    Fields:
        version: Parquet format version (1 or 2).
        num_rows: Total number of rows across all row groups.
        num_schema_elements: Number of elements in the flattened schema.
        num_row_groups: Number of row groups in the file.
        created_by: Library that created the file (empty if not present).
    """

    var version: Int
    var num_rows: Int
    var num_schema_elements: Int
    var num_row_groups: Int
    var created_by: String

    def __init__(
        out self,
        version: Int = 0,
        num_rows: Int = 0,
        num_schema_elements: Int = 0,
        num_row_groups: Int = 0,
        var created_by: String = "",
    ):
        self.version = version
        self.num_rows = num_rows
        self.num_schema_elements = num_schema_elements
        self.num_row_groups = num_row_groups
        self.created_by = created_by^


def parse_metadata_summary[
    mut: Bool, //, origin: Origin[mut=mut]
](view: ByteView[origin]) raises -> ParquetMetadataSummary:
    """Parse key fields from Thrift-encoded FileMetaData.

    Extracts version, schema element count, row group count, num_rows,
    and created_by string from the Parquet file footer.

    FileMetaData Thrift structure (field IDs):
      1: version (i32)
      2: schema (list<SchemaElement>)
      3: num_rows (i64)
      4: row_groups (list<RowGroup>)
      5: key_value_metadata (list<KeyValue>)
      6: created_by (string)
      7: column_orders (list<ColumnOrder>)

    Parameters:
        mut: Whether the source view's origin permits mutation (inferred).
        origin: Origin the view is tied to.

    Args:
        view: Origin-tied view over the Thrift-encoded metadata bytes.

    Returns:
        A ParquetMetadataSummary with the extracted fields.
    """
    var reader = ThriftCompactReader[origin](view)
    var summary = ParquetMetadataSummary()

    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var field_id = field[0]
        var wire_type = field[1]

        if wire_type == 0:
            break  # STOP

        if field_id == 1 and wire_type == 5:
            # version: i32 (zigzag)
            summary.version = reader._read_zigzag()
        elif field_id == 2 and (wire_type == 9 or wire_type == 12):
            # schema: list<SchemaElement>
            if wire_type == 9:
                var header = reader._read_byte()
                var size = (header >> 4) & 0x0F
                if size == 15:
                    size = reader._read_varint()
                size = reader._checked_list_size(size)
                summary.num_schema_elements = size
                var elem_type = header & 0x0F
                for _ in range(size):
                    reader._skip_field(elem_type)
            else:
                reader._skip_field(wire_type)
        elif field_id == 3 and wire_type == 6:
            # num_rows: i64 (zigzag)
            summary.num_rows = reader._read_zigzag()
        elif field_id == 4 and wire_type == 9:
            # row_groups: list<RowGroup>
            var header = reader._read_byte()
            var size = (header >> 4) & 0x0F
            if size == 15:
                size = reader._read_varint()
            size = reader._checked_list_size(size)
            summary.num_row_groups = size
            var elem_type = header & 0x0F
            for _ in range(size):
                reader._skip_field(elem_type)
        elif field_id == 6 and wire_type == 8:
            # created_by: string (binary)
            var str_len = reader._read_varint()
            if str_len > 0 and str_len <= reader.data_len - reader.pos:
                # Safe scalar byte-append — no wildcard-origin cast, no
                # memcpy pointer laundering. The per-byte access goes
                # through the origin-tied view. The footer's `created_by`
                # string is typically ~20 bytes; perf is not sensitive here.
                var bytes = List[UInt8](capacity=str_len + 1)
                for i in range(str_len):
                    bytes.append(reader.byte_at(reader.pos + i))
                bytes.append(0)  # null terminator for String
                reader.pos += str_len
                summary.created_by = String(unsafe_from_utf8_ptr=bytes.unsafe_ptr())
            else:
                # An empty string, or a length past the end: the walk stops at
                # the end of the bytes, and `pos` is never moved past it.
                reader.pos += min(str_len, reader.data_len - reader.pos)
        else:
            reader._skip_field(wire_type)

    return summary^
