# =============================================================================
# komira_grpc/metadata.mojo — gRPC metadata header conventions
# =============================================================================
#
#   gRPC request/response metadata is just HTTP headers (custom keys, plus
#   the `-bin` base64 convention for binary values). It maps directly onto
#   komira_http's HeaderMap — the case-insensitive multimap of the HTTP
#   client.
#
# This module is the thin layer that:
#   1. Offers the TWO wire spellings of a user metadata key and lets the
#      header builders pick: VERBATIM (gRPC/HTTP2 — the key IS the header
#      name) and `grpc-metadata-`-prefixed (Connect's "Grpc-Metadata-Foo"
#      gateway convention). ⚠ Applying the prefix on BOTH arms would mean a
#      real gRPC server never sees a custom key by its own name; see
#      `komira_grpc.headers._drain_user_metadata`.
#   2. Base64-encodes/decodes `-bin` values — standard
#      alphabet, RFC 4648 §4, NOT base64url — accepting the PADDED and the
#      UN-PADDED spelling and splitting a comma-joined Binary-Header, both
#      of which PROTOCOL-HTTP2.md requires.
#   3. VALIDATES what a caller may put on the wire: the Custom-Metadata
#      Header-Name ABNF for keys, no control bytes in values. A CR/LF in
#      either is request smuggling.
#   4. Provides a `RpcMetadata` newtype-shim over `HeaderMap` for typed
#      ergonomics at call sites (codegen consumers store request metadata
#      as `RpcMetadata`; the runtime drains into the request's HeaderMap).
#
# Encapsulation: NO UnsafePointer in any public sig; reuses HeaderMap;
# no new container.
# =============================================================================

from komira_http_client.header_map import HeaderMap


# =============================================================================
# §1 — Canonical header prefixes.
# =============================================================================

comptime GRPC_METADATA_HEADER_PREFIX: String = "grpc-metadata-"
"""Connect-RPC's convention for forwarding metadata over HTTP/1.1 — the
client adds a `grpc-metadata-` prefix to every user-supplied metadata key
so the server can distinguish gRPC metadata from generic HTTP headers.

⛔ CONNECT ONLY. This is a protocol-TRANSLATION convention and is NOT part
of gRPC-over-HTTP/2, where a Custom-Metadata key travels verbatim as the
header name. Applying it on the classic-gRPC arm makes the gRPC interop
`custom_metadata` case unreachable."""

comptime GRPC_BIN_HEADER_SUFFIX: String = "-bin"
"""Suffix marking a binary metadata value — the server expects base64
(standard alphabet, padded, RFC 4648 §4) and the client must encode."""


# =============================================================================
# §2 — RpcMetadata — typed newtype-shim over HeaderMap.
# =============================================================================


struct RpcMetadata(Movable, Deinitable):
    """A typed wrapper around HeaderMap for ergonomic gRPC metadata.

    Generated stubs accept an `opts: CallOptions` (which contains a
    RpcMetadata field) on every call; the runtime drains the metadata into
    the request's HeaderMap through ONE OF THREE drains, because the right
    spelling depends on what the entries mean and who reads them:

      * `drain_verbatim_into_request_headers` — gRPC/HTTP2 Custom-Metadata.
        `.set("user-id", "42")` → `user-id: 42`. APPEND (multi-valued).
      * `drain_into_request_headers` — Connect. Same entry →
        `grpc-metadata-user-id: 42`. APPEND (multi-valued).
      * `drain_raw_into_request_headers` — transport / routing headers
        (`authorization`, `x-goog-request-params`). Verbatim, INSERT
        (exactly one, so a retry cannot stack them).

    For binary metadata: store `.set_bin("auth-token-bin", token_bytes)` →
    base64-encoded at set time and emitted under whichever spelling the
    drain applies.

    Keys and values are VALIDATED at `set` / `set_bin`, not at drain — see
    `_validate_metadata_key` / `_validate_metadata_value`. The raw drain
    emits keys verbatim, so a check at one drain would cover only one path.

    This is NOT a separate container — it's a thin newtype over HeaderMap
    so the codegen call sites have a typed name to call. The hot path is
    `HeaderMap.append` after a tiny per-key transform; no extra alloc
    beyond the prefix string concat.
    """

    var _inner: HeaderMap
    """The backing HeaderMap. Keys are stored UNPREFIXED here — a prefix, if
    the protocol calls for one, is added by the drain; `-bin` values are
    base64-encoded at `set_bin` time."""

    def __init__(out self):
        self._inner = HeaderMap()

    @staticmethod
    def new() -> RpcMetadata:
        return RpcMetadata()

    def set(mut self, var name: String, var value: String) raises:
        """Set a text metadata value. Stored unprefixed.

        REFUSES a name or value that is not legal Custom-Metadata — see
        `_validate_metadata_key` / `_validate_metadata_value`. The refusal is
        HERE and not at drain time on purpose: the same `RpcMetadata` backs
        `CallOptions.raw_metadata`, whose drain emits keys VERBATIM, so a
        check at the prefixing drain would cover only one of the two paths.

        `raises` also propagates from HeaderMap.append.
        """
        _validate_metadata_key(name)
        _validate_metadata_value(value)
        self._inner.append(name^, value^)

    def set_bin(mut self, var name: String, value: Span[UInt8, _]) raises:
        """Set a binary metadata value. The `name` MUST end in `-bin`
        per gRPC convention; the value is base64-encoded on forward.

        The `-bin` suffix is NOT validated here (the request-encoder
        applies it as a post-step).
        The NAME is validated exactly as in `set`; the value needs no check
        because we produce it (base64 output is alphabet-only by
        construction).
        `raises` propagates from HeaderMap.append.
        """
        _validate_metadata_key(name)
        # Encode now to keep the storage homogeneous (String-valued
        # HeaderMap). The base64 cost is paid once per call; the runtime
        # writer just emits the precomputed string.
        var encoded = base64_encode_standard(value)
        self._inner.append(name^, encoded^)

    def count(imm self) -> Int:
        """Number of metadata entries stored."""
        return self._inner.len()

    def drain_into_request_headers(imm self, mut dst: HeaderMap) raises:
        """Drain all stored metadata entries into `dst` (the request's
        HeaderMap), adding the `grpc-metadata-` prefix per entry.

        ⛔ THIS IS THE **CONNECT** DRAIN. Over gRPC/HTTP2 the key travels
        verbatim — use `drain_verbatim_into_request_headers`. The header
        builders select; do not call this one unconditionally.
        `raises` propagates from HeaderMap.append.

        NOTE: simplification — every key is text-prefixed and
        re-appended to dst. Binary keys (`-bin` suffix) were already
        base64-encoded at `set_bin` time, so the value is plain ASCII
        here. No per-key bin-vs-text branch needed at drain time.

        Reads `self._inner` via the public `entries()` snapshot to keep
        the drain API ergonomic; HeaderEntry is Copyable so the snapshot
        is cheap to walk. For ~5-10 metadata entries per call (typical),
        the copy is unmeasurable.
        """
        var snapshot = self._inner.entries()
        var n = len(snapshot)
        var i = 0
        while i < n:
            var entry = snapshot[i]
            var prefixed = GRPC_METADATA_HEADER_PREFIX + entry.name
            dst.append(prefixed^, String(entry.value))
            i = i + 1

    def drain_verbatim_into_request_headers(
        imm self, mut dst: HeaderMap
    ) raises:
        """Drain every entry into `dst` with its key VERBATIM — the
        gRPC-over-HTTP/2 Custom-Metadata wire form.

        ⚠ THE `grpc-metadata-` PREFIX IS A CONNECT / gRPC-WEB GATEWAY
        CONVENTION, NOT PART OF gRPC/HTTP2. `PROTOCOL-HTTP2.md`
        ("Custom-Metadata") carries the key as the header name itself, which
        is why the gRPC interop `custom_metadata` case echoes
        `x-grpc-test-echo-initial` and a real gRPC server never looks for a
        prefixed spelling. `komira_grpc.headers` selects this drain on the
        classic-gRPC arm and the prefixing one on the Connect arm.

        ⚠ APPEND, not insert — the difference from
        `drain_raw_into_request_headers`, and it is deliberate. Custom-Metadata
        is legitimately MULTI-VALUED (two `warning` entries are two headers),
        whereas a transport header such as `authorization` must appear exactly
        once across a retry. Same storage, two drains, because the two
        collections mean different things.
        """
        var snapshot = self._inner.entries()
        var n = len(snapshot)
        var i = 0
        while i < n:
            var entry = snapshot[i]
            dst.append(String(entry.name), String(entry.value))
            i = i + 1

    def drain_raw_into_request_headers(imm self, mut dst: HeaderMap) raises:
        """Drain all stored entries into `dst` VERBATIM — WITHOUT the
        `grpc-metadata-` prefix. This is the path for transport / routing
        headers that the server reads as bare HTTP/2 headers, NOT as gRPC
        metadata: e.g. `authorization: Bearer <token>` (OAuth2) and
        `x-goog-request-params: bucket=projects/_/buckets/<b>` (the GCS gRPC
        routing header). gRPC's own metadata forwarding convention does NOT
        apply to these — Google's frontend matches them as exact header
        names — so they MUST bypass the `grpc-metadata-` prefix.

        Keys are inserted (REPLACE semantics) so a recycled CallOptions on a
        retry path stays idempotent (one `authorization` entry, not N).
        `raises` propagates from HeaderMap.insert.
        """
        var snapshot = self._inner.entries()
        var n = len(snapshot)
        var i = 0
        while i < n:
            var entry = snapshot[i]
            dst.insert(String(entry.name), String(entry.value))
            i = i + 1


# =============================================================================
# §3 — Standard base64 encoding (RFC 4648 §4 — padded).
# =============================================================================
#
# `grpc-status-details-bin` and any other `-bin`
# metadata value uses STANDARD base64 with padding — NOT base64url. We
# implement here (small, ~40 LOC) rather than importing from a system
# library to keep `komira_grpc` dependency-free of new transitive
# packages.
# =============================================================================


def base64_encode_standard(bytes: Span[UInt8, _]) -> String:
    """Encode `bytes` as standard base64 (padded) per RFC 4648 §4.

    Uses the alphabet `A-Z a-z 0-9 + /` with `=` padding. NOT base64url
    (which uses `-` and `_` instead of `+` and `/`).

    Implementation builds a `List[UInt8]` of ASCII bytes then finalizes
    via `String(unsafe_from_utf8=...)` — the output is guaranteed valid
    UTF-8 (every byte is an ASCII printable < 0x80).
    """
    var n = len(bytes)
    if n == 0:
        return String("")
    var out = List[UInt8]()
    var i = 0
    while i < n:
        var b0: Int = Int(bytes[i])
        var b1: Int = Int(bytes[i + 1]) if i + 1 < n else 0
        var b2: Int = Int(bytes[i + 2]) if i + 2 < n else 0
        var triplet: Int = (b0 << 16) | (b1 << 8) | b2
        out.append(_b64_encode_idx((triplet >> 18) & 0x3F))
        out.append(_b64_encode_idx((triplet >> 12) & 0x3F))
        if i + 1 < n:
            out.append(_b64_encode_idx((triplet >> 6) & 0x3F))
        else:
            out.append(UInt8(ord("=")))
        if i + 2 < n:
            out.append(_b64_encode_idx(triplet & 0x3F))
        else:
            out.append(UInt8(ord("=")))
        i += 3
    return String(unsafe_from_utf8=Span(out))


@always_inline
def _b64_encode_idx(v: Int) -> UInt8:
    """Map a 6-bit value (0..63) to its base64 alphabet byte (ASCII).

    Standard alphabet: A-Z (0..25), a-z (26..51), 0-9 (52..61), + (62), / (63).
    """
    if v < 26:
        return UInt8(ord("A") + v)
    if v < 52:
        return UInt8(ord("a") + (v - 26))
    if v < 62:
        return UInt8(ord("0") + (v - 52))
    if v == 62:
        return UInt8(ord("+"))
    # v == 63
    return UInt8(ord("/"))


def base64_decode_standard(s: String) raises -> List[UInt8]:
    """Decode a gRPC `-bin` metadata value to its bytes.

    Two conformance requirements the RFC-4648-shaped name does not hint at,
    both stated by `grpc/doc/PROTOCOL-HTTP2.md` under "Custom-Metadata":

      1. **PADDED AND UN-PADDED ARE BOTH LEGAL.**
         "Implementations MUST accept padded and un-padded values and should
         emit un-padded values."
         grpc-go and grpc-java EMIT UN-PADDED. A decoder that raises on
         `len % 4 != 0` fails grpc-go's own vector `Zm9vAGJhcg` (10 chars,
         `10 % 4 == 2`) outright, and EVERY `-bin` header from a Go or Java
         peer whose payload length is not a multiple of 3 is undecodable.

      2. **A BINARY HEADER IS SPLIT ON `,` BEFORE DECODING.**
         "Implementations must split Binary-Headers on commas before decoding
         the Base64-encoded values."
         HPACK and intermediaries may join duplicate header lines into one
         comma-separated value, so a joined pair arrives here as one blob. The
         segments are decoded independently and their bytes concatenated;
         optional whitespace around a separator (the `", "` an HTTP joiner
         writes) is skipped.

    What is STILL rejected, because it cannot have come from any byte
    sequence: a character outside the standard alphabet, a symbol count of
    `4k+1` in a segment, and malformed `=` padding.

    ⚠ The alphabet is STANDARD base64 (`+` and `/`), NOT base64url.
    """
    # `s` is a peer's header value and may hold any byte: it is read through
    # `as_bytes()` here and in `_b64_decode_segment_into`. (Indexing
    # `s[byte=i]` asserts on a UTF-8 continuation byte and aborts the
    # process.) A non-ASCII byte is outside the alphabet and raises.
    var out = List[UInt8]()
    var bytes = s.as_bytes()
    var n = len(bytes)
    if n == 0:
        return out^
    var seg_start = 0
    var i = 0
    while i <= n:
        if i == n or bytes[i] == UInt8(ord(",")):
            _b64_decode_segment_into(s, seg_start, i, out)
            seg_start = i + 1
        i = i + 1
    return out^


def _b64_decode_segment_into(
    s: String, start: Int, end: Int, mut out: List[UInt8]
) raises:
    """Decode ONE comma-free base64 segment `s[start:end]` onto `out`.

    Accepts the padded and the un-padded spelling of the same value and
    produces identical bytes for both. Leading/trailing spaces and tabs are
    skipped — a header joiner writes `", "`, not `","`.
    """
    # Trim optional whitespace (OWS) on both ends of the segment.
    var bytes = s.as_bytes()
    var lo = start
    var hi = end
    while lo < hi and (
        bytes[lo] == UInt8(ord(" ")) or bytes[lo] == UInt8(ord("\t"))
    ):
        lo = lo + 1
    while hi > lo and (
        bytes[hi - 1] == UInt8(ord(" ")) or bytes[hi - 1] == UInt8(ord("\t"))
    ):
        hi = hi - 1
    if lo >= hi:
        # An empty segment carries no bytes. `a,,b` and a trailing `,` are
        # tolerated rather than raised on: the joiner, not the peer, put them
        # there.
        return

    # Accumulate 6 bits per alphabet symbol, emitting a byte per 8 bits. This
    # form is padding-agnostic BY CONSTRUCTION — `=` only ever tells us the
    # symbol run has ended, which running off the end of the segment also
    # does, so the padded and un-padded spellings take the same path.
    var acc: Int = 0
    var nbits: Int = 0
    var nsym: Int = 0
    var i = lo
    var pad = 0
    while i < hi:
        var b = Int(bytes[i])
        if b == ord("="):
            pad = pad + 1
            if pad > 2:
                raise Error(
                    "komira_grpc.metadata: malformed base64 padding: more"
                    " than two '=' in one value"
                )
            i = i + 1
            continue
        if pad > 0:
            # A data symbol AFTER padding — `Zg==A`. Padding terminates the
            # value; anything past it is garbage, not a short value.
            raise Error(
                "komira_grpc.metadata: malformed base64 padding: data after"
                " '=' in one value"
            )
        var v = _b64_decode_byte(b)
        acc = (acc << 6) | v
        nbits = nbits + 6
        nsym = nsym + 1
        if nbits >= 8:
            nbits = nbits - 8
            out.append(UInt8((acc >> nbits) & 0xFF))
        i = i + 1

    # `nbits == 6` <=> `nsym % 4 == 1`: one leftover symbol encodes 6 bits,
    # which is less than one byte. No sequence of bytes base64-encodes to it,
    # so it is malformed however it is padded.
    if nbits == 6:
        raise Error(
            "komira_grpc.metadata: malformed base64 value: "
            + String(nsym)
            + " symbols (4k+1) cannot encode a whole number of bytes"
        )
    if pad > 0 and (nsym + pad) % 4 != 0:
        raise Error(
            "komira_grpc.metadata: malformed base64 padding: "
            + String(nsym)
            + " symbols + "
            + String(pad)
            + " '=' is not a whole number of quads"
        )


def _b64_decode_byte(b: Int) raises -> Int:
    """Decode one base64 alphabet byte (ASCII code) to its 6-bit value
    (0..63). Raises on invalid character."""
    if b >= ord("A") and b <= ord("Z"):
        return b - ord("A")
    if b >= ord("a") and b <= ord("z"):
        return 26 + (b - ord("a"))
    if b >= ord("0") and b <= ord("9"):
        return 52 + (b - ord("0"))
    if b == ord("+"):
        return 62
    if b == ord("/"):
        return 63
    raise Error(
        "komira_grpc.metadata: invalid base64 character: byte="
        + String(b)
    )


# =============================================================================
# §4 — Custom-Metadata validation. The refusal is at `set`, not at drain.
# =============================================================================
#
# `grpc/doc/PROTOCOL-HTTP2.md` ("Custom-Metadata"):
#
#     Custom-Metadata -> Binary-Header / ASCII-Header
#     Binary-Header   -> {Header-Name "-bin"} {base64 encoded value}
#     ASCII-Header    -> Header-Name ASCII-Value
#     Header-Name     -> 1*( %x30-39 / %x61-7A / "_" / "-" / "." )
#                        ; 0-9 a-z _ - .
#     ASCII-Value     -> 1*( %x20-%x7E ) ; space and printable ASCII
#
# ⚠ WHY THIS IS A SECURITY CHECK AND NOT TIDINESS. `HeaderMap.append` performs
# no validation of its own, so without this check any String handed to
# `RpcMetadata.set` reaches the wire. Three things would:
#
#   * A CR or LF in a caller-supplied key or value is REQUEST SMUGGLING on any
#     path that serialises these headers as HTTP/1.1 text — and this same
#     `RpcMetadata` feeds the Connect-over-HTTP/1.1 path. RFC 9113 §8.2.1 says
#     a field name or value containing CR, LF or NUL is malformed, full stop.
#   * A `:`-prefixed name is an HTTP/2 PSEUDO-header: `:authority`, `:path`,
#     `:method`. Accepting one through user metadata lets a caller-supplied
#     value RE-POINT the request.
#   * An empty key is not a header at all; the ABNF is `1*(...)`.
# =============================================================================


def _validate_metadata_key(name: String) raises:
    """Refuse a metadata key outside the Custom-Metadata Header-Name ABNF.

    ⚠ UPPERCASE IS ACCEPTED even though the ABNF is lowercase-only. HTTP/2
    field names are case-insensitive and HeaderMap canonicalises on lookup, so
    `set("X-Request-Id", ...)` is retrievable as `x-request-id`; grpc-go's
    `metadata.New` takes the same position (it lowercases rather than
    refusing). Refusing it here would break callers over a spelling that
    cannot reach the wire wrong.
    """
    # Read through `as_bytes()`: a non-ASCII byte is refused below, never an
    # abort (indexing `name[byte=i]` asserts on a UTF-8 continuation byte).
    var bytes = name.as_bytes()
    var n = len(bytes)
    if n == 0:
        raise Error(
            "komira_grpc.metadata: empty metadata key -- Header-Name is"
            " 1*( 0-9 / a-z / '_' / '-' / '.' ), one or more"
        )
    for i in range(n):
        var b = Int(bytes[i])
        var is_digit = b >= ord("0") and b <= ord("9")
        var is_lower = b >= ord("a") and b <= ord("z")
        var is_upper = b >= ord("A") and b <= ord("Z")
        var is_punct = b == ord("_") or b == ord("-") or b == ord(".")
        if not (is_digit or is_lower or is_upper or is_punct):
            raise Error(
                "komira_grpc.metadata: illegal byte "
                + String(b)
                + " at offset "
                + String(i)
                + " of metadata key -- Header-Name is 1*( 0-9 / a-z / '_' /"
                " '-' / '.' ); a ':' prefix would be an HTTP/2 pseudo-header"
            )


def _validate_metadata_value(value: String) raises:
    """Refuse a metadata value carrying a control byte.

    CR, LF, NUL and the other C0 controls (plus DEL) are what turn a metadata
    value into a second header line. RFC 9113 §8.2.1 makes a field value
    containing them malformed.

    Bytes >= 0x80 are TOLERATED rather than refused: the ABNF says such a
    value should travel as a `-bin` header, but an over-strict check here
    would reject a UTF-8 value that no framer mis-parses, and the injection
    hazard this function exists for is entirely in the control range. An
    EMPTY value is likewise allowed — HTTP/2 permits one and callers rely on
    it.
    """
    # Read through `as_bytes()`: the bytes >= 0x80 tolerated above are UTF-8
    # continuation bytes, and indexing `value[byte=i]` asserts on one.
    var bytes = value.as_bytes()
    var n = len(bytes)
    for i in range(n):
        var b = Int(bytes[i])
        if b < 0x20 or b == 0x7F:
            raise Error(
                "komira_grpc.metadata: control byte "
                + String(b)
                + " at offset "
                + String(i)
                + " of metadata value -- CR/LF/NUL in a header value is"
                " request smuggling (RFC 9113 8.2.1)"
            )
