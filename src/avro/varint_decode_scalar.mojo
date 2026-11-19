# =============================================================================
# varint_decode_scalar.mojo — Avro binary primitive decoders (scalar baseline).
# =============================================================================
#
# Avro's binary encoding is row-oriented and varint-heavy:
#   - `int` / `long`        : zigzag varint (1-5 / 1-10 bytes).
#   - `float`               : 4 raw little-endian bytes (IEEE-754 binary32).
#   - `double`              : 8 raw little-endian bytes (IEEE-754 binary64).
#   - `boolean`             : 1 byte (0x00 = false, 0x01 = true).
#   - `bytes` / `string`    : a `long` byte-length followed by N raw bytes.
#   - `null`                : 0 bytes.
#
# This module is the SCALAR decoder. Any vectorized varint path would swap in
# behind the same `AvroByteReader` cursor surface.
#
# Encapsulation: every reader operates on a borrowed `Span[UInt8, _]` view of
# a (decompressed) block payload. No UnsafePointer crosses any module
# boundary. Position threading is explicit via the `AvroByteReader` cursor
# (like the OCF header's `VarintRead`/`StringRead` named-result discipline:
# heterogeneous tuple returns are awkward in Mojo, so the cursor
# carries position internally and exposes typed `read_*` methods).
# =============================================================================

from std.memory import bitcast


# =============================================================================
# AvroByteReader — a forward cursor over a (decompressed) block payload.
# =============================================================================
#
# Holds a borrowed Span and a mutable position. Each `read_*` advances the
# cursor and returns the typed value (or raises on overrun / malformed
# varint). This is the single decode surface every action handler in
# `action_table.mojo` calls into.

struct AvroByteReader[origin: Origin[mut=False]]:
    """Forward decode cursor over an immutable byte view (a block payload).

    The view is borrowed for the reader's lifetime (origin-parametric, NOT a
    wildcard origin). Position is the only mutable state. `raises` on
    overrun / malformed varint.

    ⚠ LENGTH-GUARD FORM IS LOAD-BEARING. Every
    length-prefixed read below tests

        if n > len(self.data) - self.pos:      # correct

    and NEVER

        if self.pos + n > len(self.data):      # WRONG — overflows

    `n` is a zigzag varint taken from the block payload, i.e. from a file we
    did not write, and 10 well-formed bytes reach `Int64.MAX` (the decoder's
    `shift >= 64` cutoff permits groups at shifts 0..63). In the addition form
    `self.pos + n` WRAPS NEGATIVE and the guard passes; the reader then slices
    or copies with a length of ~2^63 and advances `self.pos` by a wrapped
    amount, corrupting every later read in the block. At ASSERT=safe the stdlib
    Span check aborts; at ASSERT=none — the configuration we ship — it is an
    out-of-bounds read that `_StringAcc.push_bytes` memcpys into the Arrow data
    buffer (a SIGSEGV).

    The subtraction form cannot overflow because `0 <= self.pos <= len(self.data)`
    is an invariant of this cursor: `__init__` takes `start` from the caller and
    every mutation of `pos` happens after a guard of this shape. It costs the
    same one arithmetic op as the addition, so this is not a hot-path tax — it
    is the same check, spelled so that it works.

    ⚠ WHAT THE RULE ABOVE DOES *NOT* COVER, stated so the next auditor does not
    have to rediscover it. `read_float` and `read_double` DO use the addition
    form (`self.pos + 4 > len`, `p + 8 > len`). That is not an oversight and not
    an exception to the rule: the rule is about a length taken FROM THE WIRE,
    and 4 / 8 are compile-time constants. With `pos <= len(self.data)` bounded
    by the cursor invariant, `pos + 8` cannot overflow, so the two forms are
    equivalent there (every write to `self.pos` in this struct keeps the
    invariant). Anything whose `n` comes off the wire must still
    use the subtraction form.

    ⚠ THE FREE FUNCTIONS AT THE BOTTOM OF THIS FILE ARE NOT COVERED BY THE
    CURSOR INVARIANT AT ALL — `decode_zigzag_long(bytes, pos)` takes `pos` from
    the caller with nothing establishing its sign. It validates `pos` itself;
    see its own docstring.
    """

    var data: Span[UInt8, Self.origin]
    var pos: Int

    def __init__(out self, data: Span[UInt8, Self.origin]):
        self.data = data
        self.pos = 0

    def __init__(
        out self, data: Span[UInt8, Self.origin], start: Int
    ) raises:
        # Establishes the `0 <= pos <= len(data)` invariant the subtraction-form
        # length guards rely on (see the struct docstring). Once per block.
        if start < 0 or start > len(data):
            raise Error(
                String("AvroDecodeError.TRUNCATED: reader start offset ")
                + String(start)
                + " is outside the "
                + String(len(data))
                + "-byte payload"
            )
        self.data = data
        self.pos = start

    @always_inline
    def at_end(self) -> Bool:
        return self.pos >= len(self.data)

    @always_inline
    def remaining(self) -> Int:
        return len(self.data) - self.pos

    # -------------------------------------------------------------------------
    # Zigzag varint long (Avro `long`). 1-10 bytes.
    # -------------------------------------------------------------------------
    @always_inline
    def read_long(mut self) raises -> Int64:
        # Fast path: the overwhelmingly common 1-byte varint (Avro `long`/union
        # tags are small-magnitude on real data — tags are 0/1, lengths < 64).
        # A single bounds check + continuation-bit test handles it with no loop
        # setup. The multi-byte tail falls through to the general decoder.
        var p = self.pos
        if p < len(self.data):
            var b0 = self.data[p]
            if (b0 & 0x80) == 0:
                self.pos = p + 1
                var acc0 = UInt64(b0)
                return Int64((acc0 >> 1) ^ (~(acc0 & 1) + 1))
        var shift: UInt64 = 0
        var acc: UInt64 = 0
        while True:
            if self.pos >= len(self.data):
                raise Error("AvroDecodeError.TRUNCATED: long varint overrun")
            var b = self.data[self.pos]
            self.pos += 1
            acc |= (UInt64(b & 0x7F) << shift)
            if (b & 0x80) == 0:
                break
            shift += 7
            if shift >= 64:
                raise Error("AvroDecodeError.MALFORMED_VARINT: long > 10 bytes")
        # Zigzag decode: (n >>> 1) ^ -(n & 1).
        return Int64((acc >> 1) ^ (~(acc & 1) + 1))

    # -------------------------------------------------------------------------
    # Zigzag varint int (Avro `int`). 1-5 bytes. Decoded into Int64 then the
    # caller narrows; the wire encoding is identical to `long` modulo width.
    # -------------------------------------------------------------------------
    @always_inline
    def read_int(mut self) raises -> Int32:
        var v = self.read_long()
        return Int32(v)

    # -------------------------------------------------------------------------
    # boolean — exactly 1 byte (0x00 / 0x01).
    # -------------------------------------------------------------------------
    def read_boolean(mut self) raises -> Bool:
        if self.pos >= len(self.data):
            raise Error("AvroDecodeError.TRUNCATED: boolean overrun")
        var b = self.data[self.pos]
        self.pos += 1
        return b != 0

    # -------------------------------------------------------------------------
    # float — 4 raw little-endian bytes (IEEE-754 binary32).
    # -------------------------------------------------------------------------
    def read_float(mut self) raises -> Float32:
        if self.pos + 4 > len(self.data):
            raise Error("AvroDecodeError.TRUNCATED: float overrun")
        var bits: UInt32 = 0
        for i in range(4):
            bits |= UInt32(self.data[self.pos + i]) << UInt32(8 * i)
        self.pos += 4
        return bitcast[DType.float32, 1](bits)

    # -------------------------------------------------------------------------
    # double — 8 raw little-endian bytes (IEEE-754 binary64).
    # -------------------------------------------------------------------------
    @always_inline
    def read_double(mut self) raises -> Float64:
        var p = self.pos
        if p + 8 > len(self.data):
            raise Error("AvroDecodeError.TRUNCATED: double overrun")
        # Single 8-byte load from the (little-endian) payload — the wire format
        # is IEEE-754 LE, identical to the host, so this is a direct reinterpret
        # with no per-byte shift/OR loop.
        # SAFETY: bounds-checked above (p + 8 <= len). The Span's ptr is valid
        # for [p, p+8). bitcast stays inside this module (no pointer escapes).
        var bits = (
            self.data.unsafe_ptr() + p
        ).bitcast[UInt64]()[]
        self.pos = p + 8
        return bitcast[DType.float64, 1](bits)

    # -------------------------------------------------------------------------
    # bytes / string — a `long` byte-length followed by N raw bytes.
    # Returns an owned List[UInt8] copy (the safe cross-module shape).
    # -------------------------------------------------------------------------
    def read_bytes(mut self) raises -> List[UInt8]:
        var n = Int(self.read_long())
        if n < 0:
            raise Error("AvroDecodeError.MALFORMED: negative bytes length")
        if n > len(self.data) - self.pos:
            raise Error("AvroDecodeError.TRUNCATED: bytes payload overrun")
        var out = List[UInt8]()
        for i in range(n):
            out.append(self.data[self.pos + i])
        self.pos += n
        return out^

    def read_string(mut self) raises -> String:
        var n = Int(self.read_long())
        if n < 0:
            raise Error("AvroDecodeError.MALFORMED: negative string length")
        if n > len(self.data) - self.pos:
            raise Error("AvroDecodeError.TRUNCATED: string payload overrun")
        # Bulk-construct the String from the byte slice via a single
        # NUL-terminated scratch copy instead of `s += chr()` per byte (which is
        # O(len^2): repeated realloc + 1 String alloc per byte). Same idiom as
        # StringArray.get.
        if n == 0:
            return String("")
        var scratch = List[UInt8](capacity=n + 1)
        for i in range(n):
            scratch.append(self.data[self.pos + i])
        scratch.append(UInt8(0))
        # SAFETY: scratch is alive through the ctor call; null-terminated UTF-8.
        var out = String(unsafe_from_utf8_ptr=scratch.unsafe_ptr())
        self.pos += n
        return out^

    # -------------------------------------------------------------------------
    # read_string_span — return a borrowed view of the next string's raw bytes
    # WITHOUT materializing a String. The caller (the columnar StringAcc) copies
    # the slice directly into its Arrow data buffer (one memcpy), avoiding both
    # the per-byte concat AND the intermediate List[String] / String-per-row.
    # The returned Span is borrowed from the reader's payload view (no copy,
    # no UnsafePointer crosses the boundary — Span is the safe view type).
    # -------------------------------------------------------------------------
    @always_inline
    def read_string_span(mut self) raises -> Span[UInt8, Self.origin]:
        var n = Int(self.read_long())
        if n < 0:
            raise Error("AvroDecodeError.MALFORMED: negative string length")
        if n > len(self.data) - self.pos:
            raise Error("AvroDecodeError.TRUNCATED: string payload overrun")
        var sl = self.data[self.pos : self.pos + n]
        self.pos += n
        return sl

    # -------------------------------------------------------------------------
    # read_bytes_span — borrowed view of the next `bytes` value's raw bytes
    # WITHOUT materializing a List[UInt8]. Twin of `read_string_span`; the
    # columnar BinaryAcc copies the slice straight into its Arrow data buffer
    # (one memcpy/value), avoiding the per-value List[UInt8] heap alloc + drop
    # that `read_bytes` paid. Span is the safe view type — no UnsafePointer
    # crosses the module boundary.
    # -------------------------------------------------------------------------
    @always_inline
    def read_bytes_span(mut self) raises -> Span[UInt8, Self.origin]:
        var n = Int(self.read_long())
        if n < 0:
            raise Error("AvroDecodeError.MALFORMED: negative bytes length")
        if n > len(self.data) - self.pos:
            raise Error("AvroDecodeError.TRUNCATED: bytes payload overrun")
        var sl = self.data[self.pos : self.pos + n]
        self.pos += n
        return sl

    # -------------------------------------------------------------------------
    # read_fixed_span — borrowed view of the next `fixed[N]` value's bytes.
    # Twin of `read_bytes_span` with a caller-supplied length (no prefix).
    # -------------------------------------------------------------------------
    @always_inline
    def read_fixed_span(mut self, n: Int) raises -> Span[UInt8, Self.origin]:
        if n < 0:
            raise Error("AvroDecodeError.MALFORMED: negative fixed size")
        if n > len(self.data) - self.pos:
            raise Error("AvroDecodeError.TRUNCATED: fixed payload overrun")
        var sl = self.data[self.pos : self.pos + n]
        self.pos += n
        return sl

    # -------------------------------------------------------------------------
    # fixed[N] — exactly N raw bytes (no length prefix).
    # -------------------------------------------------------------------------
    def read_fixed(mut self, n: Int) raises -> List[UInt8]:
        if n < 0:
            raise Error("AvroDecodeError.MALFORMED: negative fixed size")
        if n > len(self.data) - self.pos:
            raise Error("AvroDecodeError.TRUNCATED: fixed payload overrun")
        var out = List[UInt8]()
        for i in range(n):
            out.append(self.data[self.pos + i])
        self.pos += n
        return out^

    # -------------------------------------------------------------------------
    # skip helpers (field-skip resolution rule + nested-skip support).
    # -------------------------------------------------------------------------
    def skip_long(mut self) raises:
        _ = self.read_long()

    def skip_n(mut self, n: Int) raises:
        if n < 0 or n > len(self.data) - self.pos:
            raise Error(
                String(
                    "AvroDecodeError.TRUNCATED: skip of "
                )
                + String(n)
                + " bytes at payload offset "
                + String(self.pos)
                + " overruns the "
                + String(len(self.data))
                + "-byte block payload"
            )
        self.pos += n


# =============================================================================
# Standalone zigzag helpers (for callers that have a Span + position and do
# not want a cursor — e.g. the union-tag peek in the interpreter).
# =============================================================================


@fieldwise_init
struct ZigzagLong(Copyable, Movable):
    """Result of a standalone zigzag long decode: value + new position."""

    var value: Int64
    var new_pos: Int


def decode_zigzag_long(bytes: Span[UInt8, _], pos: Int) raises -> ZigzagLong:
    """Decode a zigzag varint Avro `long` at `pos`. Returns value + new_pos.

    ⚠ `pos` IS VALIDATED HERE AND ONLY HERE. Unlike
    `AvroByteReader`, this free function has no cursor invariant to inherit —
    `pos` is whatever the caller passed. The loop below tests only
    `p >= len(bytes)`, which is FALSE for every negative `p`, so a negative
    `pos` would walk straight into `bytes[p]`. At ASSERT=safe the stdlib Span
    debug_assert aborts; at ASSERT=none — the configuration we ship — it is an
    out-of-bounds read at an attacker-influenced offset below the payload
    (without this check `decode_zigzag_long(span, -2**40)` SIGSEGVs).

    This is a ONE-TIME entry check, deliberately not in the byte loop: `p`
    starts at a validated non-negative `pos` and only increments, so the loop's
    existing upper-bound test is sufficient from there on and no per-byte cost
    is added.
    """
    if pos < 0 or pos > len(bytes):
        raise Error(
            String("AvroDecodeError.TRUNCATED: varint start offset ")
            + String(pos)
            + " is outside the "
            + String(len(bytes))
            + "-byte payload"
        )
    var p = pos
    var shift: UInt64 = 0
    var acc: UInt64 = 0
    while True:
        if p >= len(bytes):
            raise Error("AvroDecodeError.TRUNCATED: long varint overrun")
        var b = bytes[p]
        p += 1
        acc |= (UInt64(b & 0x7F) << shift)
        if (b & 0x80) == 0:
            break
        shift += 7
        if shift >= 64:
            raise Error("AvroDecodeError.MALFORMED_VARINT: long > 10 bytes")
    var decoded = Int64((acc >> 1) ^ (~(acc & 1) + 1))
    return ZigzagLong(decoded, p)
