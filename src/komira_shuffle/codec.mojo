# =============================================================================
# komira_shuffle/codec.mojo
#   Shared little-endian wire primitives for the distributed-shuffle codecs.
# =============================================================================
#
# These mirror cas_manifest's `_put_i64_le` / `_get_i64_le` byte-for-byte (same
# little-endian wire, same truncation-raise on read). We define them here rather
# than importing the underscore-private cas_manifest helpers across the module
# boundary — importing `_`-prefixed module privates is fragile coupling, and the
# wire format (8-byte LE) is the contract, not the function identity. The shuffle
# entry / seal / segment codecs all share these so their framing is uniform.
#
# Pointer discipline: ZERO UnsafePointer. Plain List[UInt8] byte buffers.
# =============================================================================


@always_inline
def put_i64_le(mut out: List[UInt8], v: Int64):
    """Append `v` as 8 little-endian bytes (byte-identical to cas_manifest's
    `_put_i64_le`)."""
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))


@always_inline
def get_i64_le(bytes: List[UInt8], off: Int) raises -> Int64:
    """Read an 8-byte little-endian i64 at `off`. Raises on truncation
    (byte-identical to cas_manifest's `_get_i64_le`)."""
    if off < 0 or off + 8 > len(bytes):
        raise Error("shuffle_codec: truncated i64 at offset " + String(off))
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)


def put_len_prefixed_str(mut out: List[UInt8], s: String):
    """Append a length-prefixed UTF-8 string: `[len: i64 LE][bytes]` (mirrors
    `encode_head`'s etag framing)."""
    var sb = s.as_bytes()
    put_i64_le(out, Int64(len(sb)))
    for i in range(len(sb)):
        out.append(sb[i])


def get_len_prefixed_str(bytes: List[UInt8], off: Int) raises -> Tuple[String, Int]:
    """Decode a length-prefixed UTF-8 string at `off`. Returns `(string,
    next_offset)`. Raises on truncation."""
    var slen = Int(get_i64_le(bytes, off))
    if slen < 0:
        raise Error("shuffle_codec: negative string length " + String(slen))
    var body_start = off + 8
    if body_start + slen > len(bytes):
        raise Error(
            "shuffle_codec: truncated string body at offset " + String(off)
        )
    # Decode the byte range DIRECTLY into a String (UTF-8 bytes verbatim). A
    # per-byte `chr(Int(b))` would map any byte 0x80-0xFF to a Unicode codepoint
    # that re-encodes as a MULTI-byte UTF-8 sequence — so the round-trip would
    # NOT be byte-identical for a non-ASCII object key, silently breaking the
    # byte-DETERMINISTIC-SEAL invariant (DECISION (b)) the moment a key carries
    # non-ASCII. We instead copy the exact `slen` bytes into a sub-buffer and
    # construct the String over that UTF-8 span (the objectstore-canonical
    # bytes->String idiom — mirrors `path.mojo`'s
    # `String(StringSlice(unsafe_from_utf8=Span[UInt8](...)))`). Encode is
    # length-prefixed UTF-8 bytes, so encode->decode->encode is byte-identical.
    var sub = List[UInt8]()
    sub.reserve(slen)
    for i in range(slen):
        sub.append(bytes[body_start + i])
    var s = String(StringSlice(unsafe_from_utf8=Span[UInt8](sub)))
    return (s^, body_start + slen)


def put_i64_list(mut out: List[UInt8], xs: List[Int64]):
    """Append a length-prefixed list of i64: `[count: i64 LE][x0..xn]`."""
    put_i64_le(out, Int64(len(xs)))
    for i in range(len(xs)):
        put_i64_le(out, xs[i])


def get_i64_list(bytes: List[UInt8], off: Int) raises -> Tuple[List[Int64], Int]:
    """Decode a length-prefixed list of i64 at `off`. Returns `(list,
    next_offset)`. Raises on truncation."""
    var count = Int(get_i64_le(bytes, off))
    if count < 0:
        raise Error("shuffle_codec: negative list count " + String(count))
    var cur = off + 8
    var xs = List[Int64]()
    for _i in range(count):
        xs.append(get_i64_le(bytes, cur))
        cur += 8
    return (xs^, cur)


def put_str_list(mut out: List[UInt8], xs: List[String]):
    """Append a length-prefixed list of length-prefixed strings."""
    put_i64_le(out, Int64(len(xs)))
    for i in range(len(xs)):
        put_len_prefixed_str(out, xs[i])


def get_str_list(bytes: List[UInt8], off: Int) raises -> Tuple[List[String], Int]:
    """Decode a length-prefixed list of length-prefixed strings at `off`.
    Returns `(list, next_offset)`. Raises on truncation."""
    var count = Int(get_i64_le(bytes, off))
    if count < 0:
        raise Error("shuffle_codec: negative str-list count " + String(count))
    var cur = off + 8
    var xs = List[String]()
    for _i in range(count):
        var pair = get_len_prefixed_str(bytes, cur)
        xs.append(pair[0].copy())
        cur = pair[1]
    return (xs^, cur)
