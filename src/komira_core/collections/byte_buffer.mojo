# =============================================================================
# ByteBuffer -- owns bytes and provides a read cursor
# =============================================================================
#
# Single struct that OWNS a contiguous byte buffer and provides sequential
# read cursor methods (read_byte, read_u32_le, read_uleb128, etc.).
# ByteBuffer always owns its data via List[UInt8].
#
# PUBLIC API BOUNDARY:
#   NO UnsafePointer in any constructor, method parameter, or return type.
#   Internal hot-path methods use `self._data.unsafe_ptr()` for zero-overhead
#   byte access, but this is encapsulated -- callers never see raw pointers.
#
# SAFETY: The internal `self._data.unsafe_ptr()` pointer is valid as long as
# `self._data` is alive (i.e., as long as the ByteBuffer exists) and `_data`
# is not mutated in a way that triggers reallocation. All read methods only
# advance `_pos` -- they never resize `_data` -- so the pointer remains stable
# for the lifetime of the ByteBuffer.
#
# Performance: All small read methods are @always_inline so the compiler
# inlines them into the decode hot path -- zero overhead vs raw pointer math.
# =============================================================================


from std.memory import unsafe_memcpy

from .byte_view import ByteView


struct ByteBuffer(Movable):
    """Owns bytes and provides a read cursor.

    ByteBuffer always OWNS its data. There is no borrowing mode.
    Construct via `ByteBuffer(data^)` where data is a `List[UInt8]`.

    Fields:
        _data: The owned byte buffer.
        _pos: Current read position (0-based offset from start).
    """

    var _data: List[UInt8]
    var _pos: Int

    def __init__(out self, var data: List[UInt8]):
        """Construct a ByteBuffer that owns the byte data.

        Args:
            data: Byte buffer to take ownership of. Consumed by this call.
        """
        self._data = data^
        self._pos = 0

    def __init__(out self, var data: List[UInt8], start_offset: Int):
        """Construct a ByteBuffer with an initial read offset.

        Args:
            data: Byte buffer to take ownership of. Consumed by this call.
            start_offset: Initial read position within the buffer.
        """
        self._data = data^
        self._pos = start_offset

    # =========================================================================
    # Position management
    # =========================================================================

    @always_inline
    def remaining(self) -> Int:
        """Return the number of unread bytes remaining."""
        return len(self._data) - self._pos

    @always_inline
    def position(self) -> Int:
        """Return the current read position (offset from start)."""
        return self._pos

    @always_inline
    def is_empty(self) -> Bool:
        """Return True if there are no more bytes to read."""
        return self._pos >= len(self._data)

    @always_inline
    def length(self) -> Int:
        """Return the total length of the buffer."""
        return len(self._data)

    @always_inline
    def advance(mut self, n: Int) raises:
        """Advance the read position by n bytes.

        Args:
            n: Number of bytes to skip forward.

        Raises:
            Error if advancing would exceed the buffer bounds.
        """
        if self._pos + n > len(self._data):
            raise Error(
                "ByteBuffer: advance("
                + String(n)
                + ") at pos "
                + String(self._pos)
                + " exceeds length "
                + String(len(self._data))
            )
        self._pos += n

    @always_inline
    def set_position(mut self, pos: Int) raises:
        """Set the read position to an absolute offset.

        Args:
            pos: The new read position.

        Raises:
            Error if pos is negative or exceeds the buffer length.
        """
        if pos < 0 or pos > len(self._data):
            raise Error(
                "ByteBuffer: set_position("
                + String(pos)
                + ") out of range [0, "
                + String(len(self._data))
                + "]"
            )
        self._pos = pos

    # =========================================================================
    # Core single-value reads
    # =========================================================================

    @always_inline
    def peek(self) raises -> UInt8:
        """Peek at the next byte without advancing the position.

        Returns:
            The byte at the current position.

        Raises:
            Error if the buffer is exhausted.
        """
        if self._pos >= len(self._data):
            raise Error("ByteBuffer: peek past end of buffer")
        # SAFETY: bounds-checked above; _data is alive and not resized.
        return (self._data.unsafe_ptr() + self._pos)[]

    @always_inline
    def read_byte(mut self) raises -> UInt8:
        """Read a single byte and advance the position by 1.

        Returns:
            The byte at the current position.

        Raises:
            Error if the buffer is exhausted.
        """
        if self._pos >= len(self._data):
            raise Error("ByteBuffer: read_byte past end of buffer")
        # SAFETY: bounds-checked above; _data is alive and not resized.
        var b = (self._data.unsafe_ptr() + self._pos)[]
        self._pos += 1
        return b

    @always_inline
    def read_byte_int(mut self) raises -> Int:
        """Read a single byte as Int and advance. Convenience for decode loops
        where the caller immediately widens to Int for bit manipulation.

        Returns:
            The byte value widened to Int.

        Raises:
            Error if the buffer is exhausted.
        """
        if self._pos >= len(self._data):
            raise Error("ByteBuffer: read_byte_int past end of buffer")
        # SAFETY: bounds-checked above; _data is alive and not resized.
        var b = Int((self._data.unsafe_ptr() + self._pos)[])
        self._pos += 1
        return b

    # =========================================================================
    # Multi-byte little-endian reads
    # =========================================================================

    @always_inline
    def read_u32_le(mut self) raises -> UInt32:
        """Read a 4-byte little-endian UInt32 and advance by 4.

        Returns:
            The decoded UInt32 value.

        Raises:
            Error if fewer than 4 bytes remain.
        """
        if self._pos + 4 > len(self._data):
            raise Error("ByteBuffer: read_u32_le needs 4 bytes")
        # SAFETY: bounds-checked above; _data is alive and not resized.
        var ptr = self._data.unsafe_ptr() + self._pos
        var val = ptr.bitcast[UInt32]()[]
        self._pos += 4
        return val

    @always_inline
    def read_i32_le(mut self) raises -> Int32:
        """Read a 4-byte little-endian Int32 and advance by 4.

        Returns:
            The decoded Int32 value.

        Raises:
            Error if fewer than 4 bytes remain.
        """
        if self._pos + 4 > len(self._data):
            raise Error("ByteBuffer: read_i32_le needs 4 bytes")
        # SAFETY: bounds-checked above; _data is alive and not resized.
        var ptr = self._data.unsafe_ptr() + self._pos
        var val = ptr.bitcast[Int32]()[]
        self._pos += 4
        return val

    @always_inline
    def read_u64_le(mut self) raises -> UInt64:
        """Read an 8-byte little-endian UInt64 and advance by 8.

        Returns:
            The decoded UInt64 value.

        Raises:
            Error if fewer than 8 bytes remain.
        """
        if self._pos + 8 > len(self._data):
            raise Error("ByteBuffer: read_u64_le needs 8 bytes")
        # SAFETY: bounds-checked above; _data is alive and not resized.
        var ptr = self._data.unsafe_ptr() + self._pos
        var val = ptr.bitcast[UInt64]()[]
        self._pos += 8
        return val

    @always_inline
    def read_i64_le(mut self) raises -> Int64:
        """Read an 8-byte little-endian Int64 and advance by 8.

        Returns:
            The decoded Int64 value.

        Raises:
            Error if fewer than 8 bytes remain.
        """
        if self._pos + 8 > len(self._data):
            raise Error("ByteBuffer: read_i64_le needs 8 bytes")
        # SAFETY: bounds-checked above; _data is alive and not resized.
        var ptr = self._data.unsafe_ptr() + self._pos
        var val = ptr.bitcast[Int64]()[]
        self._pos += 8
        return val

    # =========================================================================
    # Varint reads (Parquet/Thrift formats)
    # =========================================================================

    @always_inline
    def read_uleb128(mut self) raises -> Int:
        """Read an unsigned LEB128 (ULEB128) varint and advance past it.

        This is the exact encoding used by Parquet RLE headers, delta block
        headers, and Thrift Compact Protocol integer fields.

        Returns:
            The decoded unsigned integer value.

        Raises:
            Error if the buffer is exhausted before the varint terminates,
            or if the varint exceeds 10 bytes (64-bit overflow protection).
        """
        var result = 0
        var shift = 0
        # SAFETY: bounds-checked per-byte below; _data alive and not resized.
        var base = self._data.unsafe_ptr()
        var buf_len = len(self._data)
        while True:
            if self._pos >= buf_len:
                raise Error("ByteBuffer: read_uleb128 past end of buffer")
            var byte = Int((base + self._pos)[])
            self._pos += 1
            result = result | ((byte & 0x7F) << shift)
            if byte & 0x80 == 0:
                break
            shift += 7
            if shift >= 64:
                break
        return result

    @always_inline
    def read_zigzag_varint(mut self) raises -> Int:
        """Read a zigzag-encoded varint and advance past it.

        Zigzag encoding maps signed integers to unsigned:
          0 -> 0, -1 -> 1, 1 -> 2, -2 -> 3, ...

        Used by Parquet delta encoding (min_delta, first_value) and Thrift
        Compact Protocol signed integer fields.

        Returns:
            The decoded signed integer value.

        Raises:
            Error if the buffer is exhausted before the varint terminates.
        """
        var encoded = self.read_uleb128()
        return (encoded >> 1) ^ (-(encoded & 1))

    # =========================================================================
    # Safe bulk read (public API)
    # =========================================================================

    @always_inline
    def read_slice_pos(mut self, n: Int) raises -> Tuple[Int, Int]:
        """Consume n bytes and return their (start_offset, length) in the buffer.

        Args:
            n: Number of bytes to consume.

        Returns:
            Tuple of (start_offset, length) within the backing buffer.

        Raises:
            Error if fewer than n bytes remain.
        """
        if self._pos + n > len(self._data):
            raise Error(
                "ByteBuffer: read_slice_pos("
                + String(n)
                + ") at pos "
                + String(self._pos)
                + " exceeds length "
                + String(len(self._data))
            )
        var start = self._pos
        self._pos += n
        return (start, n)

    # =========================================================================
    # Safe bulk read -- copying data out
    # =========================================================================

    @always_inline
    def read_into_list(mut self, mut dest: List[UInt8], n: Int) raises:
        """Copy n bytes from current position into dest and advance.

        Appends n bytes to dest (caller should pre-reserve if performance
        matters).

        Args:
            dest: Destination list to append bytes to.
            n: Number of bytes to copy.

        Raises:
            Error if fewer than n bytes remain.
        """
        if self._pos + n > len(self._data):
            raise Error(
                "ByteBuffer: read_into_list("
                + String(n)
                + ") at pos "
                + String(self._pos)
                + " exceeds length "
                + String(len(self._data))
            )
        dest.reserve(len(dest) + n)
        # SAFETY: bounds-checked above; _data alive and not resized.
        var base = self._data.unsafe_ptr()
        for i in range(n):
            dest.append((base + self._pos + i)[])
        self._pos += n

    # =========================================================================
    # Public view API
    # =========================================================================
    # Each method returns a `ByteView[origin]` whose `origin` is an explicit
    # (inferred) method parameter tying the view's liveness to `self`, so
    # the compiler catches use-after-destroy at compile time.
    # =========================================================================

    @always_inline
    def read_view[
        origin: Origin[mut=True], //,
    ](ref [origin] self, n: Int) raises -> ByteView[origin]:
        """Consume n bytes and return an origin-tied view of them.

        Advances the read position by n. The returned view's origin is
        tied to `self` -- the compiler enforces that callers do not use
        the view past `self`'s lifetime.

        Requires a mutable `self` because advancing `_pos` is an in-place
        write. For non-advancing sub-views over any (mut or immut)
        receiver, use `view_at(start, length)` instead.

        Args:
            n: Number of bytes to consume.

        Returns:
            Mutable view over the n consumed bytes.

        Raises:
            Error if fewer than n bytes remain.
        """
        if self._pos + n > len(self._data):
            raise Error(
                "ByteBuffer: read_view("
                + String(n)
                + ") at pos "
                + String(self._pos)
                + " exceeds length "
                + String(len(self._data))
            )
        # SAFETY: bounds-checked above; _data alive and not resized.
        # Widen List[UInt8]'s internal origin to the explicit origin
        # parameter, preserving the caller's liveness tracking.
        var ptr = (self._data.unsafe_ptr() + self._pos).unsafe_origin_cast[origin]()
        self._pos += n
        return ByteView[origin](ptr, n)

    @always_inline
    def view_at[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self, start: Int, length: Int) raises -> ByteView[
        origin
    ]:
        """Return an origin-tied sub-view over [start, start+length).

        Does NOT advance the read position.

        Args:
            start: Absolute offset within the buffer (0-based).
            length: Number of bytes in the view.

        Returns:
            Immutable or mutable view over the requested range.

        Raises:
            Error if start+length exceeds the buffer length or start < 0.
        """
        if start < 0 or start + length > len(self._data):
            raise Error(
                "ByteBuffer: view_at("
                + String(start)
                + ", "
                + String(length)
                + ") out of range [0, "
                + String(len(self._data))
                + "]"
            )
        # SAFETY: bounds-checked above; _data alive and not resized.
        var ptr = (self._data.unsafe_ptr() + start).unsafe_mut_cast[
            _mut
        ]().unsafe_origin_cast[origin]()
        return ByteView[origin](ptr, length)

    @always_inline
    def current_view[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self) -> ByteView[origin]:
        """Return an origin-tied view over the unread bytes.

        Does NOT advance the read position. The returned view covers
        `[position(), length())` -- i.e., every unread byte. Useful for
        callers that need to peek at the remaining buffer.

        Returns:
            View over the unread bytes.
        """
        var remaining = len(self._data) - self._pos
        # SAFETY: pos is always in [0, len(_data)] by invariant.
        var ptr = (self._data.unsafe_ptr() + self._pos).unsafe_mut_cast[
            _mut
        ]().unsafe_origin_cast[origin]()
        return ByteView[origin](ptr, remaining)

    def copy_into_view(
        mut self, dest: ByteView[mut=True, _], n: Int
    ) raises:
        """Copy n bytes from the current position into `dest` and advance.

        The
        destination is a mutable view whose origin is independent of
        `self`, which preserves the caller's borrow-checker invariants.

        Args:
            dest: Mutable destination view (must have at least n bytes).
            n: Number of bytes to copy.

        Raises:
            Error if fewer than n bytes remain in self, or if dest is
            smaller than n.
        """
        if self._pos + n > len(self._data):
            raise Error(
                "ByteBuffer: copy_into_view("
                + String(n)
                + ") at pos "
                + String(self._pos)
                + " exceeds length "
                + String(len(self._data))
            )
        if dest.len() < n:
            raise Error(
                "ByteBuffer: copy_into_view dest too small for "
                + String(n)
                + " bytes (dest len="
                + String(dest.len())
                + ")"
            )
        # SAFETY: bounds-checked above on both sides; _data alive.
        # `dest._unsafe_ptr()` is a module-internal escape within
        # core/collections (byte_view is in the same package).
        unsafe_memcpy(
            dest=dest._unsafe_ptr(),
            src=self._data.unsafe_ptr() + self._pos,
            count=n,
        )
        self._pos += n



# =============================================================================
# Free function: write_uleb128 — the symmetric encoder for read_uleb128.
# =============================================================================
#
# `ByteBuffer.read_uleb128` (above) is the PUBLIC unsigned-LEB128 decoder;
# this free `def` is the symmetric public unsigned encoder, co-located with
# the decoder so the encode/decode pair is discoverable. It is NOT zigzag: a
# zigzag encoder would double small values and break round-trip with
# read_uleb128. Used for length prefixes such as front-coded term
# dictionaries.
# =============================================================================


def write_uleb128(value: Int, mut out: List[UInt8]):
    """Append the unsigned LEB128 (ULEB128) encoding of `value` (>= 0) to `out`.

    The symmetric encoder for `ByteBuffer.read_uleb128` — a value written by
    `write_uleb128` and read back by `read_uleb128` round-trips byte-for-byte.
    This is UNSIGNED ULEB128 (NOT zigzag): callers pass only non-negative
    lengths. Negative `value` would loop on the arithmetic shift; callers must
    not pass one (term/length fields are always >= 0 by construction).

    Args:
        value: The non-negative integer to encode.
        out:   The byte list to append the encoding to (grown in place).
    """
    var v = value
    while True:
        var byte = UInt8(v & 0x7F)
        v = v >> 7
        if v != 0:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            break
