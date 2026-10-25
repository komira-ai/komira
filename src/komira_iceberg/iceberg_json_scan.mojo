# =============================================================================
# iceberg_json_scan.mojo — byte-exact scanners for the metadata.json we write.
# =============================================================================
#
# Targeted scanners over the metadata.json this package emits (a fixed shape of
# flat objects, arrays and string/number values). They never build a String one
# byte at a time through `chr` (which would re-encode every byte >= 0x80 as a
# two-byte character): decoded strings are accumulated as bytes. Bytes read
# from a store are untrusted, so invalid UTF-8 becomes U+FFFD, never an invalid
# String.
# =============================================================================


@fieldwise_init
struct ParsedStr(Movable, Deinitable):
    """A decoded JSON string + the index just past its closing quote (a tiny
    return-pair struct — Mojo tuple returns of owned Strings are awkward)."""

    var text: String
    var end: Int


def read_json_string_at(s: String, start: Int) raises -> ParsedStr:
    """Read a JSON string beginning at the opening quote `start`; return the
    decoded value + the index JUST PAST the closing quote. Handles the escapes
    OUR emitter produces (\\", \\\\, \\n, \\r, \\t, \\b, \\f, \\uXXXX)."""
    var bs = s.as_bytes()
    var n = len(bs)
    var i = start
    if i >= n or bs[i] != UInt8(ord('"')):
        raise Error("read_json_string_at: expected opening quote")
    i += 1  # past opening quote
    var out = List[UInt8]()
    while i < n:
        var c = bs[i]
        if c == UInt8(ord('"')):
            i += 1  # past closing quote
            return ParsedStr(String(from_utf8_lossy=Span(out)), i)
        if c == UInt8(ord("\\")) and i + 1 < n:
            var e = bs[i + 1]
            if e == UInt8(ord("n")):
                out.append(UInt8(0x0A))
            elif e == UInt8(ord("r")):
                out.append(UInt8(0x0D))
            elif e == UInt8(ord("t")):
                out.append(UInt8(0x09))
            elif e == UInt8(ord("b")):
                out.append(UInt8(0x08))
            elif e == UInt8(ord("f")):
                out.append(UInt8(0x0C))
            elif e == UInt8(ord("u")) and i + 5 < n:
                # \uXXXX: decode the 4 hex nibbles into a code point and
                # append its UTF-8 bytes. Our emitter escapes only control
                # characters this way; a surrogate pair is not combined.
                var hi = hex_nibble(bs[i + 2]) * 16 + hex_nibble(bs[i + 3])
                var lo = hex_nibble(bs[i + 4]) * 16 + hex_nibble(bs[i + 5])
                var enc = chr(hi * 256 + lo)
                for k in range(enc.byte_length()):
                    out.append(enc.as_bytes()[k])
                i += 6
                continue
            else:
                # \" \\ \/ and any other escaped byte: the byte itself.
                out.append(e)
            i += 2
        else:
            out.append(c)
            i += 1
    raise Error("read_json_string_at: unterminated string")


@always_inline
def hex_nibble(b: UInt8) -> Int:
    var c = Int(b)
    if c >= ord("0") and c <= ord("9"):
        return c - ord("0")
    if c >= ord("a") and c <= ord("f"):
        return c - ord("a") + 10
    if c >= ord("A") and c <= ord("F"):
        return c - ord("A") + 10
    return 0


def bare_int64_field(s: String, key: String) raises -> Int64:
    """Parse a bare-number `"key":<int>` value from OUR json (mirrors the
    reader's `_json_int64_field`)."""
    var needle = '"' + key + '":'
    var at = s.find(needle)
    if at < 0:
        raise Error("bare_int64_field: key not found: " + key)
    var bs = s.as_bytes()
    var n = len(bs)
    var i = at + needle.byte_length()
    var neg = False
    if i < n and bs[i] == UInt8(ord("-")):
        neg = True
        i += 1
    var v = Int64(0)
    var any = False
    while i < n:
        var d = Int(bs[i])
        if d < ord("0") or d > ord("9"):
            break
        v = v * Int64(10) + Int64(d - ord("0"))
        any = True
        i += 1
    if not any:
        raise Error("bare_int64_field: no digits for key " + key)
    return -v if neg else v


def substr(s: String, start: Int, end: Int) -> String:
    var bs = s.as_bytes()
    var n = len(bs)
    var a = start if start >= 0 else 0
    var b = end if end <= n else n
    if a >= b:
        return String("")
    return String(from_utf8_lossy=bs[a:b])


def bytes_to_str(bytes: List[UInt8]) -> String:
    # Store bytes are untrusted: invalid UTF-8 becomes U+FFFD, never an
    # invalid String.
    return String(from_utf8_lossy=Span(bytes))


def parse_ascii_int(bytes: List[UInt8]) raises -> Int:
    var v = 0
    var any = False
    for i in range(len(bytes)):
        var d = Int(bytes[i])
        if d >= ord("0") and d <= ord("9"):
            v = v * 10 + (d - ord("0"))
            any = True
        elif any:
            break
    if not any:
        raise Error("parse_ascii_int: no digits in pointer body")
    return v


def matching_object_end(s: String, start: Int) -> Int:
    """The index just past the `}` that closes the object opening at `start`.

    Braces inside a JSON string (a summary value like `a}b`) do not count: the
    scan skips every quoted string, honouring `\\` escapes. An unterminated
    object ends at the end of `s`."""
    var bs = s.as_bytes()
    var n = len(bs)
    var depth = 0
    var i = start
    while i < n:
        var c = bs[i]
        if c == UInt8(ord('"')):
            i += 1
            while i < n and bs[i] != UInt8(ord('"')):
                if bs[i] == UInt8(ord("\\")):
                    i += 1
                i += 1
            i += 1
            continue
        if c == UInt8(ord("{")):
            depth += 1
        elif c == UInt8(ord("}")):
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def json_str_field(s: String, key: String) raises -> String:
    """The decoded value of the first `"key":"value"` in `s`."""
    var needle = '"' + key + '":'
    var at = s.find(needle)
    if at < 0:
        raise Error("json_str_field: key not found: " + key)
    var bs = s.as_bytes()
    var n = len(bs)
    var i = at + needle.byte_length()
    while i < n and bs[i] != UInt8(ord('"')):
        i += 1
    return read_json_string_at(s, i).text


def object_array_items(json: String, key: String) -> List[String]:
    """Every object of the array `"key":[...]` in `json`, in order (an empty
    list when the array is absent or empty). Braces inside a string value do not
    end an object (`matching_object_end`)."""
    var out = List[String]()
    var needle = '"' + key + '":['
    var at = json.find(needle)
    if at < 0:
        return out^
    var bs = json.as_bytes()
    var n = len(bs)
    var p = at + needle.byte_length()
    while p < n:
        var c = bs[p]
        if c == UInt8(ord("]")):
            break
        if c == UInt8(ord("{")):
            var start = p
            p = matching_object_end(json, p)
            out.append(substr(json, start, p))
        else:
            p += 1
    return out^


def snapshot_objects(json: String) -> List[String]:
    """Every object of the `snapshots` array of a metadata.json."""
    return object_array_items(json, "snapshots")
