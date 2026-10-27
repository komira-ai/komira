# =============================================================================
# request_path.mojo: the pure helpers that read an untrusted request target
# =============================================================================
#
# The request target and the body length come from a client. These helpers are
# value functions over a String and an Int: one pass over the bytes, no
# allocation beyond the result, and a hard cap on what they accept.
#
#   * `strip_query` cuts the target at the first '?'.
#   * `split_path` splits `/seg/seg` (one optional trailing '/') into its
#     segments, and answers an empty list, meaning no route, for anything else:
#     a missing leading '/', an empty segment, more than `MAX_PATH_SEGMENTS`
#     segments or a path over `MAX_PATH_BYTES` bytes.
#   * `is_valid_index_name` accepts 1 to `MAX_INDEX_NAME_BYTES` bytes of a-z,
#     0-9, '.', '_' and '-', starting with a letter or digit.
#   * `unsupported_query_param` is true when the query string names a parameter
#     other than the few that cannot change an answer (`refresh`, `pretty`,
#     `human`, `error_trace`). The official clients send `size`, `from`, `q`,
#     `sort` and `_source` as URL parameters; this dispatcher reads them from
#     the body only, so it refuses a request that sets one rather than answer
#     as if it had not.
#   * `body_too_large` is true when a body is longer than the limit.
#   * `count_ndjson_lines` counts the non-empty lines of a body, one pass.
#
# Nothing is percent-decoded. An escape such as `%2e%2e` stays three bytes of
# the target, so it is never a `..` segment: as an index name it fails
# `is_valid_index_name` ('%' is not in the set), and as a part of another
# segment it makes that segment match no route.
# =============================================================================

comptime MAX_PATH_BYTES: Int = 4096
"""The longest request path `split_path` reads."""

comptime MAX_PATH_SEGMENTS: Int = 8
"""The most segments `split_path` returns."""

comptime MAX_INDEX_NAME_BYTES: Int = 255
"""The longest index name."""


def strip_query(path: String) -> String:
    """The part of `path` before the first '?' (all of it when there is none).
    A test may put the whole target in `req.path`; a server that has split the
    target already passes the path alone."""
    var pb = path.as_bytes()
    var n = len(pb)
    for i in range(n):
        if pb[i] == UInt8(63):  # '?'
            return String(path[byte = 0 : i])
    return path.copy()


def split_path(path: String) -> List[String]:
    """The segments of `/seg/seg/...`, or an empty list when `path` is not of
    that shape or is over the limits (see the module header). One trailing '/'
    is allowed. The cut points are ASCII '/', so each segment is valid UTF-8."""
    var out = List[String]()
    var pb = path.as_bytes()
    var n = len(pb)
    if n == 0 or n > MAX_PATH_BYTES or pb[0] != UInt8(47):  # '/'
        return out^
    var end = n
    if n > 1 and pb[n - 1] == UInt8(47):
        end = n - 1
    var start = 1
    for i in range(1, end + 1):
        if i == end or pb[i] == UInt8(47):
            if i == start or len(out) == MAX_PATH_SEGMENTS:
                return List[String]()  # an empty segment, or too many
            out.append(String(path[byte = start : i]))
            start = i + 1
    return out^


def is_valid_index_name(name: String) -> Bool:
    """True iff `name` is 1 to 255 bytes of a-z, 0-9, '.', '_' and '-' whose
    first byte is a letter or digit. The set keeps every character that has a
    meaning in an object key, a URL or a glob out of the name, so an index name
    can be placed in a key as it is."""
    var b = name.as_bytes()
    var n = len(b)
    if n == 0 or n > MAX_INDEX_NAME_BYTES:
        return False
    for i in range(n):
        var c = b[i]
        var alnum = (c >= UInt8(97) and c <= UInt8(122)) or (
            c >= UInt8(48) and c <= UInt8(57)
        )
        if alnum:
            continue
        if i > 0 and (c == UInt8(46) or c == UInt8(95) or c == UInt8(45)):
            continue  # '.', '_', '-' after the first byte
        return False
    return True


def body_too_large(body_len: Int, max_bytes: Int) -> Bool:
    """True iff a body of `body_len` bytes is longer than `max_bytes`."""
    return body_len > max_bytes


def _name_is(b: Span[UInt8, _], start: Int, end: Int, name: String) -> Bool:
    var nb = name.as_bytes()
    if end - start != len(nb):
        return False
    for i in range(len(nb)):
        if b[start + i] != nb[i]:
            return False
    return True


def unsupported_query_param(target: String) -> Bool:
    """True iff the query string of `target` (the part after the first '?')
    has a parameter whose name is not `refresh`, `pretty`, `human` or
    `error_trace`. Empty pieces between '&' are skipped. A name is compared as
    it arrives, with no percent-decoding, so an escaped spelling is unsupported.
    One pass; no allocation."""
    var b = target.as_bytes()
    var n = len(b)
    var q = -1
    for i in range(n):
        if b[i] == UInt8(63):  # '?'
            q = i
            break
    if q < 0:
        return False
    var start = q + 1
    for i in range(q + 1, n + 1):
        if i == n or b[i] == UInt8(38):  # '&'
            if i > start:
                var name_end = i
                for j in range(start, i):
                    if b[j] == UInt8(61):  # '='
                        name_end = j
                        break
                if not (
                    _name_is(b, start, name_end, String("refresh"))
                    or _name_is(b, start, name_end, String("pretty"))
                    or _name_is(b, start, name_end, String("human"))
                    or _name_is(b, start, name_end, String("error_trace"))
                ):
                    return True
            start = i + 1
    return False


def count_ndjson_lines(body: Span[UInt8, _]) -> Int:
    """The number of non-empty lines of `body`: maximal runs of bytes other than
    '\n'. Each line of a `_bulk` body can become an item, so this bounds the
    items a body can create."""
    var lines = 0
    var in_line = False
    for i in range(len(body)):
        if body[i] == UInt8(10):
            in_line = False
        elif not in_line:
            in_line = True
            lines += 1
    return lines
