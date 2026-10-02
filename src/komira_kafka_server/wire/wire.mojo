# =============================================================================
# src/komira_kafka_server/wire/wire.mojo — Kafka wire-protocol primitive codec
# =============================================================================
#
# The Kafka binary protocol primitive types (encode/decode only; the TCP
# server is not part of this subpackage). Source of truth:
# the Apache Kafka protocol spec (https://kafka.apache.org/protocol.html) —
# a fixed external spec; no product judgment.
#
# Kafka is BIG-ENDIAN on the wire (network byte order). The x86-64 and aarch64
# hosts are little-endian; every multi-byte primitive here is hand-staged BE
# so the host endianness is irrelevant.
#
# Scope (NON-flexible base forms + the KIP-482 flexible/compact forms):
#   * fixed-width:   INT8 / INT16 / INT32 / INT64 (signed, two's-complement BE)
#   * BOOLEAN:       one byte (0 = false, non-zero = true)
#   * STRING:        INT16 length (>= 0) + UTF-8 bytes
#   * NULLABLE_STRING: INT16 length (-1 == null) + UTF-8 bytes
#   * BYTES:         INT32 length (-1 == null) + bytes
#   * ARRAY:         INT32 length (-1 == null) + N elements (length is a header;
#                    the elements are written by the caller)
#   * UNSIGNED_VARINT: KIP-482 7-bit-group continuation-bit varint
#   * COMPACT_STRING:  UNSIGNED_VARINT(len+1) + bytes (0 == null)
#   * COMPACT_ARRAY:   UNSIGNED_VARINT(count+1) (0 == null) (header only)
#   * TAG_BUFFER:      UNSIGNED_VARINT(tagged-field-count); 0 == empty
#
# Encapsulation: ZERO UnsafePointer in any public signature. The
# encoder owns a `List[UInt8]`; the decoder borrows a `Span[UInt8, origin]`
# via a typed cursor. No raw pointer arithmetic, no wildcard origins, no
# `unsafe_from_address`. All byte access is index-checked through the cursor.
# =============================================================================


# =============================================================================
# §0 — TaggedField — one entry in a KIP-482 TAG_BUFFER.
# =============================================================================


struct TaggedField(Copyable, Movable, Deinitable):
    """One tagged field: an unsigned-varint `tag` + its opaque `data` bytes
    (themselves length-prefixed by an unsigned-varint on the wire).

    Copyable so tagged fields can live in a `List[TaggedField]` (Mojo 1.0.0b1
    List requires Copyable). A transient codec DTO — never a byte-slab element,
    so it holds no pointer that could go stale across destroy and recreate."""

    var tag: UInt32
    var data: List[UInt8]

    def __init__(out self, tag: UInt32, var data: List[UInt8]):
        self.tag = tag
        self.data = data^

    def copy(self) -> Self:
        return Self(self.tag, self.data.copy())


# =============================================================================
# §1 — KafkaEncoder — append-only big-endian byte writer.
# =============================================================================


struct KafkaEncoder(Movable, Deinitable):
    """An append-only Kafka-wire byte writer. Owns a `List[UInt8]`.

    All multi-byte writes are big-endian (Kafka network byte order). The
    writer never exposes a raw pointer — callers append typed primitives and
    finally `take_bytes()` to move the owned buffer out.

    Movable, NOT Copyable — owns the accumulator buffer.
    """

    var _buf: List[UInt8]

    def __init__(out self):
        self._buf = List[UInt8]()

    @staticmethod
    def new() -> KafkaEncoder:
        return KafkaEncoder()

    @always_inline
    def len(imm self) -> Int:
        """Number of bytes written so far."""
        return len(self._buf)

    # -- fixed-width integers (signed, big-endian, two's-complement) ----------

    @always_inline
    def put_int8(mut self, v: Int8):
        self._buf.append(UInt8(v.cast[DType.uint8]()))

    @always_inline
    def put_int16(mut self, v: Int16):
        var u = v.cast[DType.uint16]()
        self._buf.append(UInt8((u >> 8) & 0xFF))
        self._buf.append(UInt8(u & 0xFF))

    @always_inline
    def put_int32(mut self, v: Int32):
        var u = v.cast[DType.uint32]()
        self._buf.append(UInt8((u >> 24) & 0xFF))
        self._buf.append(UInt8((u >> 16) & 0xFF))
        self._buf.append(UInt8((u >> 8) & 0xFF))
        self._buf.append(UInt8(u & 0xFF))

    @always_inline
    def put_int64(mut self, v: Int64):
        var u = v.cast[DType.uint64]()
        for shift in range(7, -1, -1):
            self._buf.append(UInt8((u >> UInt64(shift * 8)) & 0xFF))

    @always_inline
    def put_bool(mut self, v: Bool):
        self._buf.append(UInt8(1) if v else UInt8(0))

    # -- variable-length (KIP-482) --------------------------------------------

    def put_unsigned_varint(mut self, value: UInt32):
        """KIP-482 unsigned varint: 7-bit little-endian groups, MSB is the
        continuation bit (1 == more bytes follow)."""
        var v = value
        while True:
            var low = UInt8(v & 0x7F)
            v = v >> 7
            if v != 0:
                self._buf.append(low | UInt8(0x80))
            else:
                self._buf.append(low)
                break

    # -- length-prefixed strings / bytes --------------------------------------

    def put_string(mut self, s: String):
        """STRING: INT16 length (>= 0) + UTF-8 bytes. The empty string is a
        valid (length-0) STRING — distinct from NULLABLE_STRING null."""
        var b = s.as_bytes()
        var n = len(b)
        self.put_int16(Int16(n))
        for i in range(n):
            self._buf.append(b[i])

    def put_nullable_string(mut self, s: Optional[String]):
        """NULLABLE_STRING: INT16 length (-1 == null) + UTF-8 bytes."""
        if not s:
            self.put_int16(Int16(-1))
            return
        var sv = s.value()
        var b = sv.as_bytes()
        var n = len(b)
        self.put_int16(Int16(n))
        for i in range(n):
            self._buf.append(b[i])

    def put_compact_string(mut self, s: String):
        """COMPACT_STRING (KIP-482): UNSIGNED_VARINT(len+1) + UTF-8 bytes.
        The empty string encodes as varint(1)."""
        var b = s.as_bytes()
        var n = len(b)
        self.put_unsigned_varint(UInt32(n + 1))
        for i in range(n):
            self._buf.append(b[i])

    def put_compact_nullable_string(mut self, s: Optional[String]):
        """COMPACT_NULLABLE_STRING: UNSIGNED_VARINT(0) for null, else
        UNSIGNED_VARINT(len+1) + bytes."""
        if not s:
            self.put_unsigned_varint(UInt32(0))
            return
        self.put_compact_string(s.value())

    def put_bytes(mut self, data: Span[UInt8, _]):
        """BYTES: INT32 length + bytes (non-null form)."""
        var n = len(data)
        self.put_int32(Int32(n))
        for i in range(n):
            self._buf.append(data[i])

    def put_compact_bytes(mut self, data: Span[UInt8, _]):
        """COMPACT_BYTES (KIP-482): UNSIGNED_VARINT(len+1) + bytes (non-null
        form). The empty byte string encodes as varint(1)."""
        var n = len(data)
        self.put_unsigned_varint(UInt32(n + 1))
        for i in range(n):
            self._buf.append(data[i])

    def put_compact_nullable_bytes(mut self, data: Optional[List[UInt8]]):
        """COMPACT_NULLABLE_BYTES: UNSIGNED_VARINT(0) for null, else
        UNSIGNED_VARINT(len+1) + bytes."""
        if not data:
            self.put_unsigned_varint(UInt32(0))
            return
        ref d = data.value()
        self.put_unsigned_varint(UInt32(len(d) + 1))
        for i in range(len(d)):
            self._buf.append(d[i])

    @always_inline
    def put_compact_array_len(mut self, count: Int):
        """COMPACT_ARRAY header: UNSIGNED_VARINT(count+1). The N elements are
        written by the caller after this header. (count == -1 / null is
        encoded as varint(0) — use put_unsigned_varint(0) directly.)"""
        self.put_unsigned_varint(UInt32(count + 1))

    @always_inline
    def put_array_len(mut self, count: Int):
        """ARRAY header (non-compact): INT32 length. -1 == null array. The N
        elements are written by the caller after this header."""
        self.put_int32(Int32(count))

    @always_inline
    def put_empty_tag_buffer(mut self):
        """TAG_BUFFER with zero tagged fields: UNSIGNED_VARINT(0)."""
        self.put_unsigned_varint(UInt32(0))

    def put_tagged_fields(mut self, fields: List[TaggedField]):
        """TAG_BUFFER (KIP-482) with N tagged fields: UNSIGNED_VARINT(count)
        then, for each field in ASCENDING tag order, UNSIGNED_VARINT(tag) +
        UNSIGNED_VARINT(data_len) + data bytes.

        (The Kafka spec requires tagged fields be serialized in ascending tag
        order; the caller is responsible for supplying them sorted. An empty
        list is identical to `put_empty_tag_buffer`.)"""
        self.put_unsigned_varint(UInt32(len(fields)))
        for i in range(len(fields)):
            ref f = fields[i]
            self.put_unsigned_varint(f.tag)
            self.put_unsigned_varint(UInt32(len(f.data)))
            for j in range(len(f.data)):
                self._buf.append(f.data[j])

    # -- finalize -------------------------------------------------------------

    def take_bytes(mut self) -> List[UInt8]:
        """Move the owned buffer out, leaving the encoder empty."""
        var out = self._buf^
        self._buf = List[UInt8]()
        return out^

    def snapshot(imm self) -> List[UInt8]:
        """Copy the buffer so far (the encoder stays usable). Cold path —
        used by tests / size-prefix framing that needs the length first."""
        return self._buf.copy()


# =============================================================================
# §2 — KafkaDecoder — borrowing big-endian byte reader (typed cursor).
# =============================================================================


struct KafkaDecoder[origin: Origin[mut=False]](
    Movable, Deinitable
):
    """A borrowing Kafka-wire reader over a `Span[UInt8, origin]`. Every read
    goes through `_require`, which raises rather than reading out of bounds.

    The decoder holds a Span (no ownership, no pointer) parametric on the
    caller's origin — no wildcards. The borrowed bytes outlive the decoder by
    construction (the origin is threaded through the type).

    The bounds guarantee is enforced at the ROOT, in `_require` — the single
    gate every accessor calls — not only at the leaves. The eight
    length-taking accessors (`get_string` / `get_nullable_string` /
    `get_compact_string` / `get_compact_nullable_string` / `get_bytes` /
    `get_nullable_bytes` / `get_compact_bytes` / `get_compact_nullable_bytes`)
    also check the sign themselves, but a guarantee stated at the root and
    enforced only at the leaves means the next accessor added inherits
    nothing. See `_require`.
    """

    var _data: Span[UInt8, Self.origin]
    var _pos: Int

    def __init__(out self, data: Span[UInt8, Self.origin]):
        self._data = data
        self._pos = 0

    @always_inline
    def pos(imm self) -> Int:
        """Current read offset."""
        return self._pos

    @always_inline
    def remaining(imm self) -> Int:
        return len(self._data) - self._pos

    @always_inline
    def _require(imm self, n: Int) raises:
        """The ONE bounds gate for the whole decoder. Called once per read,
        never per byte.

        Two things this gate must do:

        1. REJECT A NEGATIVE `n`. `self._pos + n > len(self._data)` is FALSE
           for every negative `n`, so the gate passed it. `_read_raw` /
           `_read_utf8` then run `for i in range(n)` (empty, so no read) and
           `self._pos += n` — which moves the cursor BACKWARD. A decode loop
           over a caller-supplied count whose element read rewinds the cursor
           does not terminate. `List.reserve(n)` on the same negative value is
           an unchecked allocation request.
        2. NOT OVERFLOW ITS OWN ADDITION. `self._pos + n` is written as
           `n > len - pos` so a huge `n` cannot wrap the comparison into
           passing.

        REACHABILITY: neither case is reachable through this module's public
        API, because all eight length-taking accessors re-check the sign
        themselves and no accessor can produce an `n` above 2^32-1. The gate
        enforces it anyway, so the next accessor inherits the guarantee
        instead of having to remember it.
        """
        if n < 0:
            raise Error(
                "komira_kafka_server.wire: negative read length "
                + String(n)
                + " at offset "
                + String(self._pos)
                + " (corrupt length prefix)"
            )
        if n > len(self._data) - self._pos:
            raise Error(
                "komira_kafka_server.wire: short read — need "
                + String(n)
                + " bytes at offset "
                + String(self._pos)
                + " but only "
                + String(self.remaining())
                + " remain"
            )

    # -- fixed-width integers -------------------------------------------------

    def get_int8(mut self) raises -> Int8:
        self._require(1)
        var b = self._data[self._pos]
        self._pos += 1
        return Int8(b.cast[DType.int8]())

    def get_int16(mut self) raises -> Int16:
        self._require(2)
        var hi = UInt16(self._data[self._pos])
        var lo = UInt16(self._data[self._pos + 1])
        self._pos += 2
        return ((hi << 8) | lo).cast[DType.int16]()

    def get_int32(mut self) raises -> Int32:
        self._require(4)
        var u = UInt32(0)
        for i in range(4):
            u = (u << 8) | UInt32(self._data[self._pos + i])
        self._pos += 4
        return u.cast[DType.int32]()

    def get_int64(mut self) raises -> Int64:
        self._require(8)
        var u = UInt64(0)
        for i in range(8):
            u = (u << 8) | UInt64(self._data[self._pos + i])
        self._pos += 8
        return u.cast[DType.int64]()

    def get_bool(mut self) raises -> Bool:
        self._require(1)
        var b = self._data[self._pos]
        self._pos += 1
        return b != UInt8(0)

    # -- variable-length (KIP-482) --------------------------------------------

    def get_unsigned_varint(mut self) raises -> UInt32:
        """KIP-482 unsigned varint. Bounded at 5 bytes (UInt32 range)."""
        var result = UInt32(0)
        var shift = UInt32(0)
        var count = 0
        while True:
            self._require(1)
            var b = self._data[self._pos]
            self._pos += 1
            count += 1
            result = result | (UInt32(b & 0x7F) << shift)
            if (b & 0x80) == 0:
                break
            shift += 7
            if count >= 5:
                raise Error(
                    "komira_kafka_server.wire: unsigned varint exceeds 5 bytes"
                    " (corrupt stream)"
                )
        return result

    # -- length-prefixed strings ----------------------------------------------

    def get_string(mut self) raises -> String:
        """STRING: INT16 length (>= 0) + UTF-8 bytes. A -1 length is a
        protocol error for a non-nullable STRING."""
        var n = Int(self.get_int16())
        if n < 0:
            raise Error(
                "komira_kafka_server.wire: negative length for non-nullable STRING"
            )
        return self._read_utf8(n)

    def get_nullable_string(mut self) raises -> Optional[String]:
        """NULLABLE_STRING: INT16 length (-1 == null) + UTF-8 bytes."""
        var n = Int(self.get_int16())
        if n < 0:
            return Optional[String]()
        return Optional(self._read_utf8(n))

    def get_compact_string(mut self) raises -> String:
        """COMPACT_STRING: UNSIGNED_VARINT(len+1) + bytes."""
        var raw = Int(self.get_unsigned_varint())
        if raw == 0:
            raise Error(
                "komira_kafka_server.wire: null length for non-nullable"
                " COMPACT_STRING"
            )
        return self._read_utf8(raw - 1)

    def get_compact_nullable_string(mut self) raises -> Optional[String]:
        """COMPACT_NULLABLE_STRING: varint(0) == null, else varint(len+1)."""
        var raw = Int(self.get_unsigned_varint())
        if raw == 0:
            return Optional[String]()
        return Optional(self._read_utf8(raw - 1))

    def get_array_len(mut self) raises -> Int:
        """ARRAY header (non-compact): INT32 length. Returns -1 for a null
        array; the caller reads that many elements."""
        return Int(self.get_int32())

    def get_compact_array_len(mut self) raises -> Int:
        """COMPACT_ARRAY header: UNSIGNED_VARINT(count+1). Returns -1 for a
        null array (varint 0), else the element count."""
        var raw = Int(self.get_unsigned_varint())
        return raw - 1

    def get_compact_bytes(mut self) raises -> List[UInt8]:
        """COMPACT_BYTES: UNSIGNED_VARINT(len+1) + bytes. A varint 0 (null) is
        a protocol error for non-nullable COMPACT_BYTES."""
        var raw = Int(self.get_unsigned_varint())
        if raw == 0:
            raise Error(
                "komira_kafka_server.wire: null length for non-nullable COMPACT_BYTES"
            )
        return self._read_raw(raw - 1)

    def get_compact_nullable_bytes(mut self) raises -> Optional[List[UInt8]]:
        """COMPACT_NULLABLE_BYTES: varint(0) == null, else varint(len+1)."""
        var raw = Int(self.get_unsigned_varint())
        if raw == 0:
            return Optional[List[UInt8]]()
        return Optional(self._read_raw(raw - 1))

    def get_bytes(mut self) raises -> List[UInt8]:
        """BYTES (non-compact): INT32 length + bytes. A negative length (null)
        is a protocol error for non-nullable BYTES — use get_nullable_bytes
        for the nullable form."""
        var n = Int(self.get_int32())
        if n < 0:
            raise Error(
                "komira_kafka_server.wire: negative length for non-nullable BYTES"
            )
        return self._read_raw(n)

    def get_nullable_bytes(mut self) raises -> Optional[List[UInt8]]:
        """NULLABLE_BYTES (non-compact): INT32 length (-1 == null) + bytes."""
        var n = Int(self.get_int32())
        if n < 0:
            return Optional[List[UInt8]]()
        return Optional(self._read_raw(n))

    def skip_tag_buffer(mut self) raises:
        """TAG_BUFFER: read the tagged-field count; for each, read its
        tag + size and skip `size` bytes. Use this when the tagged fields are
        not needed (the common case — we encode empty + skip on read)."""
        var count = Int(self.get_unsigned_varint())
        for _ in range(count):
            _ = self.get_unsigned_varint()  # tag
            var size = Int(self.get_unsigned_varint())
            self._require(size)
            self._pos += size

    def get_tagged_fields(mut self) raises -> List[TaggedField]:
        """TAG_BUFFER: read the tagged-field count then each {tag, data} entry,
        returning them. Use this when a caller wants to inspect the tagged
        fields rather than discard them (the general form of skip_tag_buffer).
        An empty buffer (count 0) returns an empty list."""
        var count = Int(self.get_unsigned_varint())
        var out = List[TaggedField]()
        for _ in range(count):
            var tag = self.get_unsigned_varint()
            var size = Int(self.get_unsigned_varint())
            var data = self._read_raw(size)
            out.append(TaggedField(tag, data^))
        return out^

    def _read_raw(mut self, n: Int) raises -> List[UInt8]:
        """Read `n` raw bytes into an owned List (no UTF-8 interpretation)."""
        self._require(n)
        var bytes = List[UInt8]()
        bytes.reserve(n)
        for i in range(n):
            bytes.append(self._data[self._pos + i])
        self._pos += n
        return bytes^

    def _read_utf8(mut self, n: Int) raises -> String:
        self._require(n)
        var bytes = List[UInt8]()
        for i in range(n):
            bytes.append(self._data[self._pos + i])
        self._pos += n
        # The bytes->String idiom:
        # build a StringSlice over the owned bytes, then materialize a String.
        return String(StringSlice(unsafe_from_utf8=Span(bytes)))
