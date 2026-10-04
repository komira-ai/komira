# =============================================================================
# komira_cloud_metrics/metric_json.mojo — the two scanning primitives a METRIC
#   parse needs that a LOG parse does not, plus the percent-encoder both query
#   builders use.
# =============================================================================
#
# ⛔ EVERYTHING ELSE IS IMPORTED FROM `kci_logs.json_scan`, NOT
# RE-DERIVED. That module owns `json_skip_space` / `json_scan_string` /
# `json_scan_number` / `json_skip_value`, and `json_skip_value` in particular is
# what makes an allow-list actually hold — a second depth-tracking skipper is a
# second thing to get wrong, in the one place where getting it wrong leaks
# structure the parser never intended to read.
#
# ⚠ WHY THIS FILE EXISTS AT ALL: a metric VALUE is not an integer. GCP sends
# `int64Value` as a JSON **string** (the proto3-JSON int64 mapping) and
# `doubleValue` as a bare number; CloudWatch sends `Values` as bare numbers and
# `Timestamps` as bare numbers too. `json_scan_number` reads a bare INTEGER and
# stops at a `.`, which would silently truncate every fractional value it met.
#
# def-based, Mojo 1.0.0b2. No UnsafePointer, no wildcard origin, no FFI.
# =============================================================================

from kci_logs.json_scan import json_scan_string, json_skip_space


def json_scan_scalar_text(
    b: Span[UInt8, _], i: Int, mut out: String
) -> Int:
    """Read ONE scalar at `i` — a quoted STRING or a bare NUMBER — and write its
    text into `out`. Returns the index just after it, or -1.

    ★ ONE FUNCTION FOR BOTH SHAPES, AND THAT IS THE POINT. The same logical
    field arrives quoted on one cloud and bare on the other (GCP's `int64Value`
    is a JSON string; CloudWatch's `Values` entries are bare numbers), and a
    parser with two branches at every call site is a parser whose two branches
    drift. A quoted value comes back UNQUOTED and UNESCAPED; a bare number comes
    back as its LITERAL TEXT.

    ⛔ THE NUMBER IS KEPT AS TEXT, NOT CONVERTED HERE. `MetricPoint.end_time`
    promises the provider's own spelling verbatim, and a timestamp that this
    layer re-rendered could disagree with the provider's console. The VALUE is
    converted by `parse_f64`, one step later and where a failure can be
    reported."""
    var j = json_skip_space(b, i)
    if j >= len(b):
        return -1
    if b[j] == UInt8(ord('"')):
        return json_scan_string(b, j, out)
    var start = j
    # A bare JSON number: an optional sign, digits, an optional fraction, an
    # optional exponent. ⚠ `e`/`E`/`+`/`-` are accepted INSIDE the token because
    # `1.7e+09` is a legal CloudWatch timestamp and stopping at the `e` would
    # truncate it to a value nine orders of magnitude wrong.
    while j < len(b):
        var c = b[j]
        var is_digit = c >= UInt8(0x30) and c <= UInt8(0x39)
        var is_num_punct = (
            c == UInt8(ord("-"))
            or c == UInt8(ord("+"))
            or c == UInt8(ord("."))
            or c == UInt8(ord("e"))
            or c == UInt8(ord("E"))
        )
        if not (is_digit or is_num_punct):
            break
        j += 1
    if j == start:
        return -1
    var buf = List[UInt8]()
    for k in range(start, j):
        buf.append(b[k])
    out = String(unsafe_from_utf8=Span(buf))
    return j


def parse_f64(text: String, mut out: Float64) -> Bool:
    """Parse `text` as a Float64. Returns False — leaving `out` UNTOUCHED — when
    it is not a number.

    ⛔ A BOOL RATHER THAN A SENTINEL VALUE. `0.0` is a perfectly ordinary metric
    reading (a service that served zero requests in a bucket), so a parse
    failure that returned 0.0 would be indistinguishable from the most common
    real answer this package will ever carry — and the direction of that
    confusion is the dangerous one: an unreadable body would report a healthy
    "zero errors".

    ⛔ AND IT DOES NOT RAISE. The stdlib conversion does; catching it here is
    what lets every parser in this package keep the `CloudLogPage` contract of
    never raising on provider data."""
    if text.byte_length() == 0:
        return False
    var ok = True
    var v = Float64(0)
    try:
        v = Float64(text)
    except:
        ok = False
    if not ok:
        return False
    out = v
    return True


def urlencode_query_component(s: String) -> String:
    """Percent-encode `s` as a URL query component per RFC 3986.

    ⚠ IT LIVES IN THE PURE PACKAGE, WHICH IS THE WHOLE REASON THE QUERY BUILDERS
    ARE FALSIFIABLE. Aggregation parameters assembled inside a live transport
    conformer sit in the one layer a hermetic falsifier replaces with a
    double, i.e. the one place a wrong request shape could not be caught by
    any test."""
    var out = String("")
    var bs = s.as_bytes()
    var hex_chars = String("0123456789ABCDEF")
    for i in range(len(bs)):
        var b = bs[i]
        var is_alpha = (b >= UInt8(0x41) and b <= UInt8(0x5A)) or (
            b >= UInt8(0x61) and b <= UInt8(0x7A)
        )
        var is_digit = b >= UInt8(0x30) and b <= UInt8(0x39)
        var is_unreserved = (
            b == UInt8(0x2D)
            or b == UInt8(0x5F)
            or b == UInt8(0x2E)
            or b == UInt8(0x7E)
        )
        if is_alpha or is_digit or is_unreserved:
            out += chr(Int(b))
        else:
            out += "%"
            out += chr(Int(ord(hex_chars[byte = Int(b >> 4)])))
            out += chr(Int(ord(hex_chars[byte = Int(b & 0x0F)])))
    return out^
