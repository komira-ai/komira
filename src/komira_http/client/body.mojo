# =============================================================================
# src/komira_http/client/body.mojo — RequestBody trait + BytesBody + EmptyBody
# =============================================================================
#
# The WRITE-direction body trait is `RequestBody`. The READ-direction
# `ResponseBody` trait (FRAME-shaped
# `poll_frame -> BodyFrame`) lives in `response_body.mojo`. One unified
# Body for both directions would serve only a
# forwarding-proxy optimization this library does not need; the
# WRITE-direction (request) and READ-direction (response) seams have
# genuinely different shapes.
#
# Conformers (write-direction request bodies):
#   * `EmptyBody`  — zero-byte body. Used by GET/HEAD/DELETE.
#   * `BytesBody`  — fully in-memory request body. The default for small
#                    POST/PUT/PATCH where the caller has the entire body
#                    in a `List[UInt8]`. Drains to wire as one
#                    Content-Length-framed block.
#
# Reserved for future milestones:
#   * `StreamingBody`  — caller-supplied generator for
#                                       large PUT uploads (chunked-encoded
#                                       on the wire if Content-Length is
#                                       unknown). Conforms to RequestBody.
#
# Response bodies live in `response_body.mojo`:
#   * `BufferedResponseBody`  — v1-bridge default; slurps the
#                                       List[UInt8] body and yields it
#                                       as one Data frame + End.
#   * `RecvRingBody`  — recv-ring pull-stream; conforms
#                                       to ResponseBody (poll_frame ->
#                                       BodyFrame).
#
# Trait minimal surface:
#   * `content_length()` -> Int
#       Returns the known byte length, or -1 if unknown (a streaming
#       body that uses chunked-encoding). Used by `request_writer` to
#       decide between `Content-Length: N` and `Transfer-Encoding:
#       chunked`. EmptyBody returns 0; BytesBody returns its buffer
#       length.
#   * `read_chunk(dst: Span[UInt8, mut=True]) -> Int`
#       Drain up to `dst.len()` bytes into `dst`. Returns the number of
#       bytes written. 0 means "no more bytes (end of body)".
#       The request writer drives `read_chunk` until 0 is returned.
#
# Mojo 1.0.0b1 trait surface notes:
#   * Bodies are trait-typed at request build time. (with
#     `StreamingBody`) widens `ClientRequest` to `ClientRequest[B:
#     RequestBody]` parametric; for the existing `ClientRequest`
#     stays non-parametric (carries pre-serialized `request_bytes`).
#     Each concrete conformer monomorphizes — ZERO fn-ptr table.
#   * `Span[UInt8, o]` with explicit `o: Origin[mut=True]` method-level
#     parameter — same idiom as `try_read`.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * BytesBody owns a `List[UInt8]`; no borrowed-Span fields. The
#     read cursor is an Int — value-typed.
# =============================================================================

from std.memory import unsafe_memcpy


# =============================================================================
# §1 — RequestBody trait.
# =============================================================================


trait RequestBody(Movable, Deinitable):
    """WRITE-direction (outbound request) body
    abstraction. Conformers drain bytes into a caller-supplied `dst`
    buffer; the request writer keeps calling `read_chunk` until 0 is
    returned.

    `content_length()` -> Int      : known byte length, or -1 if unknown
                                     (chunked-encoded on the wire).
    `read_chunk(dst)`  -> Int      : up to dst.len() bytes drained.
                                     Returns the count written. 0 means
                                     end-of-body.
    `replayable()`     -> Bool     : True iff this body can be rewound
                                     and re-drained for retry.
                                     hook for RetryLayer.
    `rewind()`                     : reset the body's read cursor to
                                     position 0. Raises if not
                                     replayable. hook.

    The state of the body is owned by the conformer — `read_chunk` is
    a mutating method (`mut self`).

    NOTE: previously named `Body`. The unified-Body claim was
    walked back at; the READ-direction
    response-body trait lives separately as `ResponseBody` in
    `response_body.mojo` with the FRAME-shaped `poll_frame` method.

    NOTE: `replayable` + `rewind` were added to support
    B-parametric RetryLayer. EmptyBody / BytesBody / StreamingBody all
    conform; consumer code that wraps an HttpService with RetryLayer
    must use a B whose replayable() returns True (the layer asserts).
    """

    def content_length(self) -> Int:
        ...

    def read_chunk[o: Origin[mut=True]](
        mut self, dst: Span[UInt8, o],
    ) -> Int:
        ...

    def replayable(self) -> Bool:
        """True iff this body can be `rewind`'d and re-drained.
        Conformers: EmptyBody=True, BytesBody=True, StreamingBody=False.
        Implementations:
          * EmptyBody overrides to True (no state).
          * BytesBody overrides to True (cursor reset via reset()).
          * StreamingBody overrides to False (producer state consumed
            by reading; the chunk-source has no rewind seam in v1).
        """
        ...

    def rewind(mut self) raises:
        """Reset the body's read cursor to 0. Raises if not replayable.
        Implementations:
          * EmptyBody: no-op (zero bytes).
          * BytesBody: delegate to existing reset() — clears _cursor.
          * StreamingBody: raises HttpError[BODY_NOT_REPLAYABLE].
        """
        ...


# =============================================================================
# §2 — EmptyBody (zero-byte conformer).
# =============================================================================


@fieldwise_init
struct EmptyBody(RequestBody, Movable, Deinitable):
    """Zero-byte body. Used by GET / HEAD / DELETE where no body is
    sent. The request writer emits `Content-Length: 0` for these (a
    server is entitled to expect it for a CL-known body of length 0).
    """

    var _placeholder: UInt8

    @staticmethod
    def new() -> EmptyBody:
        return EmptyBody(_placeholder=UInt8(0))

    @always_inline
    def content_length(self) -> Int:
        return 0

    @always_inline
    def read_chunk[o: Origin[mut=True]](
        mut self, dst: Span[UInt8, o],
    ) -> Int:
        # No bytes ever — always returns 0.
        return 0

    @always_inline
    def replayable(self) -> Bool:
        """EmptyBody is trivially replayable: zero bytes, no state."""
        return True

    @always_inline
    def rewind(mut self) raises:
        """EmptyBody rewind is a no-op (no cursor state)."""
        pass


# =============================================================================
# §3 — BytesBody (in-memory conformer).
# =============================================================================


struct BytesBody(RequestBody, Movable, Deinitable):
    """In-memory body backed by a `List[UInt8]`. Drains chunk by chunk
    via `read_chunk` until exhausted.

    Construction:
      * `BytesBody.empty()`         — equivalent to EmptyBody.
      * `BytesBody.from_bytes(bs)`  — take ownership of `bs`.
      * `BytesBody.from_str(s)`     — owned copy of `s`'s bytes.

    Movable, NOT Copyable — owns the buffer.
    """

    var _buf: List[UInt8]
    var _cursor: Int

    def __init__(out self):
        self._buf = List[UInt8]()
        self._cursor = 0

    @staticmethod
    def empty() -> BytesBody:
        return BytesBody()

    @staticmethod
    def from_bytes(var bs: List[UInt8]) -> BytesBody:
        var b = BytesBody()
        b._buf = bs^
        return b^

    @staticmethod
    def from_str(s: String) -> BytesBody:
        """Construct from a String. The String's bytes are copied into
        an owned `List[UInt8]`."""
        var b = BytesBody()
        var bytes_ref = s.as_bytes()
        var n = len(bytes_ref)
        var i = 0
        while i < n:
            b._buf.append(bytes_ref[i])
            i = i + 1
        return b^

    @always_inline
    def content_length(self) -> Int:
        """Known body size — the buffer length."""
        return self._buf.__len__()

    def read_chunk[o: Origin[mut=True]](
        mut self, dst: Span[UInt8, o],
    ) -> Int:
        """Drain up to dst.len() bytes from the buffer at the current
        cursor. Advances cursor. Returns the number drained, or 0 at
        EOF."""
        var remaining = self._buf.__len__() - self._cursor
        if remaining <= 0:
            return 0
        var n_to_copy = remaining
        if dst.__len__() < n_to_copy:
            n_to_copy = dst.__len__()
        # SAFETY: dst is a caller-frame-rooted Span[UInt8, o:mut=True];
        # its `unsafe_ptr()` points into the caller's buffer storage.
        # The source bytes live in self._buf (List[UInt8]) at offsets
        # [_cursor, _cursor + n_to_copy). Both pointers are valid for
        # the duration of this method frame, never stored. Internal
        # UnsafePointer use is allowed (not in a public signature) per
        # pointer-hierarchy item 4. The bounds checks above
        # ensure n_to_copy <= min(dst.len, buf-remaining).
        var dst_ptr = dst.unsafe_ptr()
        var src_ptr = self._buf.unsafe_ptr() + self._cursor
        unsafe_memcpy(dest=dst_ptr, src=src_ptr, count=n_to_copy)
        self._cursor = self._cursor + n_to_copy
        return n_to_copy

    @always_inline
    def bytes_remaining(self) -> Int:
        """Bytes still un-drained. For tests and instrumentation."""
        return self._buf.__len__() - self._cursor

    def reset(mut self):
        """Rewind to the beginning of the buffer. Used for retry: the
        body can be re-drained from cursor 0 after a connection failure
        (only viable for fully-buffered bodies — a streaming body
        cannot retry). RetryLayer checks `content_length >= 0`
        to know it can replay."""
        self._cursor = 0

    @always_inline
    def replayable(self) -> Bool:
        """BytesBody owns its bytes; rewind via reset() is trivial."""
        return True

    def rewind(mut self) raises:
        """Delegate to reset() — clears _cursor."""
        self.reset()


# =============================================================================
# §4 — StreamingBody — flat-RSS pattern producer.
# =============================================================================
#
# Caller-supplied for large PUT — a body whose bytes are produced
# on-demand without ever holding the full payload in RAM. RSS stays
# flat at scratch-buffer size regardless of body size.
#
# Mojo 1.0.0b1 idiom: without proper closures, the chunk-producer is
# expressed as a stateful conformer whose `read_chunk` produces bytes
# from cheap, deterministic state. The v1 production shape is a
# "pattern repeat": emit `total_bytes` bytes of the same `byte_value`.
# This is sufficient for a 100MB streaming test and for
# any object-store PUT use case where the caller wants to send a known
# repeating pattern (the typical real-world streaming PUT body is
# itself produced from a typed iterator — a later version may add a
# trait-based ChunkSource that lets callers plug their own iterator).
#
# Pointer audit:
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * Internal storage: 3 Ints (cursor + total + byte_value). No heap
#     allocation; RSS stays flat.
# =============================================================================


struct StreamingBody(RequestBody, Movable, Deinitable):
    """A flat-RSS streaming body conformer. Produces `total_bytes` of
    the configured `byte_value` byte on demand via successive
    read_chunk calls; never holds the full body in RAM.

    Construction:
      * `StreamingBody.from_pattern(byte_value, total_bytes)` — produce
         `total_bytes` of `byte_value`. RSS cost: ZERO. Used for the
         100MB streaming test and for callers wanting a deterministic
         pattern payload.

    For object-store PUT with arbitrary byte content, callers can use
    BytesBody for small bodies; a later version adds a callback/iterator-based
    ChunkSource. The trait-shape (read_chunk in a loop) is the seam.

    Movable, NOT Copyable — owns its cursor state."""

    var _byte_value: UInt8
    var _total_bytes: Int
    var _cursor: Int

    def __init__(out self):
        self._byte_value = UInt8(0)
        self._total_bytes = 0
        self._cursor = 0

    @staticmethod
    def from_pattern(byte_value: UInt8, total_bytes: Int) -> StreamingBody:
        """Construct a pattern-repeating streaming body. `total_bytes`
        is the content-length advertised on the wire."""
        var b = StreamingBody()
        b._byte_value = byte_value
        b._total_bytes = total_bytes
        b._cursor = 0
        return b^

    @always_inline
    def content_length(self) -> Int:
        """Known body size. The state machine uses this to emit a
        Content-Length: N header; flowing all `total_bytes` produced
        through read_chunk matches the advertised size."""
        return self._total_bytes

    def read_chunk[o: Origin[mut=True]](
        mut self, dst: Span[UInt8, o],
    ) -> Int:
        """Fill up to dst.len() bytes with the pattern. Advances cursor.
        Returns the count filled. Returns 0 once total_bytes have been
        produced (end-of-body).
        """
        var remaining = self._total_bytes - self._cursor
        if remaining <= 0:
            return 0
        var n_to_fill = remaining
        if dst.__len__() < n_to_fill:
            n_to_fill = dst.__len__()
        var i = 0
        while i < n_to_fill:
            dst[i] = self._byte_value
            i = i + 1
        self._cursor = self._cursor + n_to_fill
        return n_to_fill

    @always_inline
    def bytes_remaining(self) -> Int:
        """Bytes still un-emitted. For tests + instrumentation."""
        return self._total_bytes - self._cursor

    @always_inline
    def replayable(self) -> Bool:
        """StreamingBody's pattern-repeating conformer COULD theoretically
        replay by resetting _cursor — but the trait contract is for
        replayability across arbitrary StreamingBody conformers (later
        callback/iterator-based ChunkSource will NOT be replayable; the
        producer state is consumed by reading). conservatively
        returns False so the RetryLayer fails-loud rather than guessing
        which conformer variant we have."""
        return False

    def rewind(mut self) raises:
        """StreamingBody is not replayable per the v1 contract;
        rewind raises HTTP_ERROR_BODY_NOT_REPLAYABLE."""
        raise Error(
            "HttpError[BODY_NOT_REPLAYABLE]: StreamingBody cannot be"
            " rewound for retry; use BytesBody for retry-eligible"
            " requests"
        )
