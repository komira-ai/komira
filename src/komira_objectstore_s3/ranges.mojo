# =============================================================================
# komira_objectstore_s3/ranges.mojo -- byte ranges, between the trait and S3
# =============================================================================
#
# komira_objectstore speaks HALF-OPEN ranges: `get_range(path, start,
# length)` reads `[start, start + length)`, and `GetRange.bounded(start,
# end)` is `[start, end)`. HTTP's Range header (RFC 9110 section 14.1.2) and
# S3's Content-Range answer are CLOSED: `bytes=first-last` names the last
# byte itself. The conversion is done here, once, in `S3ByteRange`, and
# nowhere else in the package: a second spelling of `start + length - 1` is
# where an off-by-one hides.
#
# The answer is checked against the question. A 206 must carry a
# Content-Range whose first byte is the one asked for and whose last byte is
# the one asked for, or the object's last byte when the object ends first.
# A 200 is a server that ignored the Range header and sent the whole object
# (some S3-compatible servers do for a range covering all of it); the
# window asked for is then cut from that body.
# =============================================================================


@fieldwise_init
struct S3ByteRange(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """The half-open byte window `[start, end)`, `end > start >= 0`."""

    var start: Int64
    var end: Int64

    @staticmethod
    def of_length(start: Int64, length: Int64) raises -> S3ByteRange:
        """`[start, start + length)`. Refuses a negative start, a length
        below 1 (S3 has no empty range) and an end past Int64."""
        if start < 0:
            raise Error(String("S3ByteRange: negative start ") + String(start))
        if length < 1:
            raise Error(
                String("S3ByteRange: a range holds at least one byte, got length ")
                + String(length)
            )
        if start > Int64.MAX - length:
            raise Error("S3ByteRange: start + length overflows")
        return S3ByteRange(start, start + length)

    def length(self) -> Int64:
        return self.end - self.start

    def last(self) -> Int64:
        """The closed form's last byte, `end - 1`: the ONE place the
        half-open window becomes inclusive."""
        return self.end - 1

    def header(self) -> String:
        """The Range header value, `bytes=<start>-<last>`."""
        return String("bytes=") + String(self.start) + "-" + String(self.last())


def s3_suffix_range_header(n: Int64) raises -> String:
    """`bytes=-<n>`: the last `n` bytes, whatever the object's size."""
    if n < 1:
        raise Error(String("a suffix range holds at least one byte, got ") + String(n))
    return String("bytes=-") + String(n)


def s3_offset_range_header(start: Int64) raises -> String:
    """`bytes=<start>-`: from `start` to the end of the object."""
    if start < 0:
        raise Error(String("an offset range starts at a negative byte ") + String(start))
    return String("bytes=") + String(start) + "-"


@fieldwise_init
struct S3ContentRange(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """A 206's `Content-Range: bytes first-last/total`, closed as sent.
    `total` is -1 for an unknown length (`/*`)."""

    var first: Int64
    var last: Int64
    var total: Int64


def _digits(s: String, what: String, value: String) raises -> Int64:
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 18:
        raise Error("Content-Range '" + value + "': " + what + " is not a byte count")
    var n = Int64(0)
    for i in range(len(b)):
        var c = Int(b[i])
        if c < 48 or c > 57:
            raise Error("Content-Range '" + value + "': " + what + " is not a byte count")
        n = n * 10 + Int64(c - 48)
    return n


def _sub(s: String, i: Int, j: Int) -> String:
    return String(StringSlice(unsafe_from_utf8=s.as_bytes()[i:j]))


def s3_parse_content_range(value: String) raises -> S3ContentRange:
    """The range of a 206's Content-Range. Refuses any other form than
    `bytes first-last/total` (or `/*`), a last byte before the first, and a
    last byte at or past the total."""
    var v = String(value.strip())
    if not v.startswith("bytes "):
        raise Error("Content-Range '" + value + "' is not a bytes range")
    var rest = String(_sub(v, 6, v.byte_length()).strip())
    var slash = rest.find("/")
    if slash < 0:
        raise Error("Content-Range '" + value + "' has no '/length'")
    var span = _sub(rest, 0, slash)
    var total_text = _sub(rest, slash + 1, rest.byte_length())
    var dash = span.find("-")
    if dash < 0:
        raise Error("Content-Range '" + value + "' has no 'first-last'")
    var first = _digits(_sub(span, 0, dash), "the first byte", value)
    var last = _digits(_sub(span, dash + 1, span.byte_length()), "the last byte", value)
    if last < first:
        raise Error("Content-Range '" + value + "' ends before it starts")
    var total = Int64(-1)
    if total_text != "*":
        total = _digits(total_text, "the length", value)
        if last >= total:
            raise Error("Content-Range '" + value + "' ends past the object")
    return S3ContentRange(first, last, total)


def s3_check_partial(asked: S3ByteRange, got: S3ContentRange, body_len: Int) raises:
    """A 206 for `asked` answered `got` with `body_len` bytes: its first
    byte must be the one asked for, its last the one asked for or the
    object's last, and the body as long as the range it states."""
    if got.first != asked.start:
        raise Error(
            String("the 206 starts at byte ")
            + String(got.first)
            + ", not the "
            + String(asked.start)
            + " asked for"
        )
    var short = got.total >= 0 and got.last == got.total - 1
    if got.last != asked.last() and not (short and got.last < asked.last()):
        raise Error(
            String("the 206 ends at byte ")
            + String(got.last)
            + ", not the "
            + String(asked.last())
            + " asked for"
        )
    if Int64(body_len) != got.last - got.first + 1:
        raise Error(
            String("the 206 states ")
            + String(got.last - got.first + 1)
            + " bytes and carries "
            + String(body_len)
        )
