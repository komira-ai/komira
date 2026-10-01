# =============================================================================
# src/komira_http/client/body_frame.mojo — BodyFrame (response-body chunk)
# =============================================================================
#
# the FRAME-shape envelope yielded by ResponseBody.
# poll_frame.:
#   "BodyFrame = Data(ByteView) | Trailers(HeaderMap) | Pending | End | Error.
#    The zero-copy ByteView-with-origin discipline is the CONTRACT
#    of this method, not a property of one struct."
#
# REPRESENTATION CHOICE.
# ----------------------------------------------------------------------------
# Field-tied origins survive ahead-of-time compilation, so
# the safer of the two candidate shapes is the
# discriminator + sentinel form: a value-typed struct with a UInt8
# `kind` tag + concrete fields per variant. The wrapping-enum form
# (Variant[Data, Trailers, ...]) is the candidate that *can* trip
# gap-O on AOT-darwin-arm64; we adopt the safer shape from
# onward.
#
# A second, ORTHOGONAL decision: for's BufferedResponseBody bridge
# conformer (the v1 slurp default), the Data variant carries an OWNED
# `List[UInt8]` chunk — NOT a borrowed ByteView. The slurp-bridge
# semantic is preserved with a single ownership transfer; no per-chunk
# alloc, no origin-parametric trait surface, no encapsulation leak from
# the conformer's private field origin to the caller's call site.
#
# When lands RecvRingBody (the zero-copy recv-ring pull stream),
# we can EITHER:
#   (a) Keep this owned-bytes BodyFrame and accept a per-chunk memcpy
#       from recv-ring → owned chunk (the simpler shape; the
#       2GB-flat-RSS gate measurement in will tell us if this is
#       acceptable);
#   (b) Or reshape BodyFrame to be `BodyFrame[buf_origin: Origin[mut=False]]`
#       parametric and lift the borrow back into the public surface
#       (the zero-copy story, more complex caller-side ergonomics).
#
# (a) is the baseline; (b) is the
# escape hatch if perf demands it.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * ZERO unsafe_from_address.
#   * BodyFrame owns its `_data_chunk: List[UInt8]` and `_trailers: HeaderMap`
#     and `_error_detail: String`. Value-typed, Movable, not Copyable.
# =============================================================================

from komira_http.client.header_map import HeaderMap


# =============================================================================
# §1 — BodyFrameKind discriminator (UInt8 sentinel namespace).
# =============================================================================

comptime BODY_FRAME_KIND_DATA: UInt8 = 0
"""A chunk of body bytes. The conformer hands ownership of `_data_chunk`
to the caller as `List[UInt8]` (one body chunk, may be the full body
for buffered conformers or one ring-sized chunk for streaming
conformers)."""

comptime BODY_FRAME_KIND_TRAILERS: UInt8 = 1
"""End-of-body trailing HEADERS block. Surfaced by chunked-encoded
responses with a trailing-headers field, OR by HTTP/2 trailers (e.g.
S3 x-amz-checksum-*). The conformer hands ownership of `_trailers` to
the caller."""

comptime BODY_FRAME_KIND_PENDING: UInt8 = 2
"""Conformer has no bytes available right now; caller should park on
the reactor and re-poll. The driver loop typically handles Pending by
calling reactor.poll_completions and retrying."""

comptime BODY_FRAME_KIND_END: UInt8 = 3
"""End-of-body. The conformer has yielded all bytes for this response.
Subsequent calls to poll_frame return End idempotently."""

comptime BODY_FRAME_KIND_ERROR: UInt8 = 4
"""A hard error occurred while reading the body (I/O error, framing
error, body-too-large, etc.). `_error_detail` carries a typed-error
detail string. The HttpError taxonomy lives in `client/error.mojo`;
this kind is a sentinel that the driver maps to the typed error."""


def _write_body_frame_kind_name[W: Writer](mut writer: W, k: UInt8):
    """WRITE what `body_frame_kind_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, and a pair bound
    CROSSED takes the process down with it."""
    if k == BODY_FRAME_KIND_DATA:
        writer.write(String("DATA"))
        return
    if k == BODY_FRAME_KIND_TRAILERS:
        writer.write(String("TRAILERS"))
        return
    if k == BODY_FRAME_KIND_PENDING:
        writer.write(String("PENDING"))
        return
    if k == BODY_FRAME_KIND_END:
        writer.write(String("END"))
        return
    if k == BODY_FRAME_KIND_ERROR:
        writer.write(String("ERROR"))
        return
    writer.write(String("UNKNOWN"))
    return


def body_frame_kind_name(k: UInt8) -> String:
    """Symbolic name for the BodyFrame discriminator — for log lines +
    test assertions."""
    var out = String()
    _write_body_frame_kind_name(out, k)
    return out^


# =============================================================================
# §2 — BodyFrame value type (discriminator + sentinel).
# =============================================================================


struct BodyFrame(Movable, Deinitable):
    """A single chunk of response body, per the ResponseBody trait
    contract.

    Representation: discriminator + sentinel. Non-parametric;
    Data variant carries an owned `List[UInt8]` chunk, NOT a borrowed
    view. The zero-copy ByteView-in-Data shape is deferred to
    's RecvRingBody work — and is an OPT-IN refactor at that time
    if the 2GB-flat-RSS measurement says we need it.

    Fields (only ONE is populated per variant per the discriminator):
      kind          — BODY_FRAME_KIND_* sentinel.
      _data_chunk   — DATA: the chunk bytes (owned). EMPTY for non-DATA.
      _trailers     — TRAILERS: the trailing HEADERS block. EMPTY for
                      non-TRAILERS.
      _error_detail — ERROR: typed-error detail string. EMPTY for
                      non-ERROR.

    Construction: use the static factories `BodyFrame.data(chunk)`,
    `BodyFrame.trailers(hdrs)`, `BodyFrame.pending()`, `BodyFrame.end()`,
    `BodyFrame.error(detail)`. Do NOT construct via fields directly —
    the factories enforce the variant invariant.

    Accessors: `is_data()`, `is_trailers()`, `is_pending()`, `is_end()`,
    `is_error()`. To take ownership of the inner payload (mandatory on
    DATA / TRAILERS — the chunk is single-use per the contract),
    callers use `take_data_chunk(mut self)` / `take_trailers(mut self)`.

    Movable, NOT Copyable — owns interior `List[UInt8]` / `HeaderMap` /
    `String` heap state.
    """

    var kind: UInt8
    var _data_chunk: List[UInt8]
    var _trailers: HeaderMap
    var _error_detail: String

    def __init__(out self):
        """End-of-body frame default ctor (no allocation)."""
        self.kind = BODY_FRAME_KIND_END
        self._data_chunk = List[UInt8]()
        self._trailers = HeaderMap()
        self._error_detail = String()

    # ----- Static factories ------------------------------------------------

    @staticmethod
    def data(var chunk: List[UInt8]) -> BodyFrame:
        """Construct a DATA frame carrying `chunk` (ownership moved in)."""
        var f = BodyFrame()
        f.kind = BODY_FRAME_KIND_DATA
        f._data_chunk = chunk^
        return f^

    @staticmethod
    def trailers(var hdrs: HeaderMap) -> BodyFrame:
        """Construct a TRAILERS frame carrying `hdrs` (ownership moved in)."""
        var f = BodyFrame()
        f.kind = BODY_FRAME_KIND_TRAILERS
        f._trailers = hdrs^
        return f^

    @staticmethod
    def pending() -> BodyFrame:
        """Construct a PENDING frame (no payload). The driver maps this
        to a reactor.poll_completions + retry."""
        var f = BodyFrame()
        f.kind = BODY_FRAME_KIND_PENDING
        return f^

    @staticmethod
    def end() -> BodyFrame:
        """Construct an END frame (no payload). Subsequent poll_frame
        calls on a completed body return END idempotently."""
        return BodyFrame()

    @staticmethod
    def error(detail: String) -> BodyFrame:
        """Construct an ERROR frame carrying a detail string. The
        ResponseBody driver maps the kind to a typed HttpError."""
        var f = BodyFrame()
        f.kind = BODY_FRAME_KIND_ERROR
        f._error_detail = detail
        return f^

    # ----- Variant queries -------------------------------------------------

    @always_inline
    def is_data(self) -> Bool:
        return self.kind == BODY_FRAME_KIND_DATA

    @always_inline
    def is_trailers(self) -> Bool:
        return self.kind == BODY_FRAME_KIND_TRAILERS

    @always_inline
    def is_pending(self) -> Bool:
        return self.kind == BODY_FRAME_KIND_PENDING

    @always_inline
    def is_end(self) -> Bool:
        return self.kind == BODY_FRAME_KIND_END

    @always_inline
    def is_error(self) -> Bool:
        return self.kind == BODY_FRAME_KIND_ERROR

    @always_inline
    def chunk_len(self) -> Int:
        """Length of the DATA chunk. Returns 0 for non-DATA kinds."""
        if self.kind == BODY_FRAME_KIND_DATA:
            return self._data_chunk.__len__()
        return 0

    # ----- Ownership transfer (single-use) ---------------------------------

    def take_data_chunk(mut self) -> List[UInt8]:
        """Move out the DATA chunk. Caller takes ownership. After this
        call, the frame's _data_chunk is empty; subsequent
        take_data_chunk yields an empty List.

        Discipline: only call on a frame where `is_data()` is True. The
        contract is single-use — the chunk transfers ownership exactly
        once."""
        var out = List[UInt8]()
        swap(out, self._data_chunk)
        return out^

    def take_trailers(mut self) -> HeaderMap:
        """Move out the TRAILERS HeaderMap. Caller takes ownership.
        After this call, the frame's _trailers is empty."""
        var out = HeaderMap()
        swap(out, self._trailers)
        return out^

    def error_detail(self) -> String:
        """Read the ERROR detail string. Safe to call on any kind; non-
        ERROR kinds return empty."""
        return self._error_detail
