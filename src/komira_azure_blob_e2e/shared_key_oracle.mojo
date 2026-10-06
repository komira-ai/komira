# =============================================================================
# shared_key_oracle.mojo -- the fake service's own Shared Key verifier
# =============================================================================
#
# The fake Blob service recomputes every request's Shared Key signature from
# the request AS IT ARRIVED ON THE WIRE (the parsed method, path, query string
# and headers), with this canonicalizer, written from Microsoft's "Authorize
# with Shared Key" document and sharing no canonicalization code with
# komira_azure_blob's signer:
#
#   StringToSign = VERB "\n"
#                  Content-Encoding "\n" Content-Language "\n"
#                  Content-Length "\n"   (empty when it is 0)
#                  Content-MD5 "\n" Content-Type "\n"
#                  Date "\n"             (empty when x-ms-date is present)
#                  If-Modified-Since "\n" If-Match "\n" If-None-Match "\n"
#                  If-Unmodified-Since "\n" Range "\n"
#                  CanonicalizedHeaders CanonicalizedResource
#
#   CanonicalizedHeaders: every header whose name starts with `x-ms-`, the
#     name lowercased, sorted by name, each `name:value\n` with the value's
#     runs of linear whitespace collapsed to one space and the ends trimmed.
#   CanonicalizedResource: `/` account, then the request's encoded URI path;
#     then, for each query parameter name (lowercased, URL-decoded) in sorted
#     order, `\n name:v1,v2` with its URL-decoded values sorted.
#
# On a path-style (emulator) URL the path already begins with the account, so
# the account appears twice (`/devstoreaccount1/devstoreaccount1/...`), as
# the document says for the storage emulator.
#
# Only the two primitives are shared with the signer: HMAC-SHA256
# (komira_crypto) and base64 (komira_encoding), each pinned to published
# vectors by its own package. A canonicalization defect on either side (a
# header dropped, a field out of order, the query left out or not decoded)
# makes the two strings differ, and the fake answers 403. Planted on the
# signer and seen red end to end: an x-ms-* header dropped, and a query
# value signed raw instead of decoded. This file's own string-to-sign is
# pinned to a literal spelled from the document by tests/
# test_shared_key_oracle.mojo (lowercased names, whitespace folds, repeated
# and percent-encoded query parameters), so the oracle cannot drift with the
# signer unseen.
#
# One known difference from the signer: the document folds runs of linear
# whitespace inside an x-ms-* value to one space, and this oracle does;
# komira_azure_blob's canonicalize_headers only trims the ends. AzureStore
# sends no x-ms-* value with an inner run, so no test here can see it.
#
# The Azurite development account and key below are the published,
# well-known emulator credentials (Microsoft's Azurite documentation); they
# authenticate nothing outside a local emulator.
# =============================================================================

from komira_crypto import hmac_sha256_string
from komira_encoding import base64_decode, base64_encode


comptime AZURITE_ACCOUNT: StaticString = "devstoreaccount1"
comptime AZURITE_KEY_B64: StaticString = (
    "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/"
    "K1SZFPTOtr/KBHBeksoGMGw=="
)


@fieldwise_init
struct QueryParam(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """One URL-decoded `name=value` pair of a query string."""

    var name: String
    var value: String


def _lower_ascii(s: String) -> String:
    var out = String()
    for b in s.as_bytes():
        if b >= UInt8(0x41) and b <= UInt8(0x5A):
            out += chr(Int(b) + 0x20)
        else:
            out += chr(Int(b))
    return out^


def _collapse_ws(s: String) -> String:
    """Trim, and fold each run of spaces / tabs into one space."""
    var out = String()
    var pending_space = False
    for b in s.as_bytes():
        if b == UInt8(0x20) or b == UInt8(0x09):
            pending_space = out.byte_length() > 0
            continue
        if pending_space:
            out += " "
            pending_space = False
        out += chr(Int(b))
    return out^


def _hex_digit(b: UInt8) raises -> Int:
    if b >= UInt8(0x30) and b <= UInt8(0x39):
        return Int(b) - 0x30
    if b >= UInt8(0x41) and b <= UInt8(0x46):
        return Int(b) - 0x41 + 10
    if b >= UInt8(0x61) and b <= UInt8(0x66):
        return Int(b) - 0x61 + 10
    raise Error("oracle: bad hex digit in a percent-escape")


def percent_decode(s: String) raises -> String:
    """`%XX` decoded; `+` is NOT a space (RFC 3986). The fake serves ASCII
    names only, so a decoded byte above 0x7F is refused rather than guessed."""
    var bs = s.as_bytes()
    var out = String()
    var i = 0
    var n = len(bs)
    while i < n:
        var c = Int(bs[i])
        if c == 0x25:
            if i + 2 >= n:
                raise Error("oracle: truncated percent-escape")
            c = _hex_digit(bs[i + 1]) * 16 + _hex_digit(bs[i + 2])
            i += 3
        else:
            i += 1
        if c > 0x7F:
            raise Error("oracle: non-ASCII byte in a decoded component")
        out += chr(c)
    return out^


def parse_query(query: String) raises -> List[QueryParam]:
    """The URL-decoded pairs of `query` (no leading `?`), in wire order."""
    var out = List[QueryParam]()
    if query.byte_length() == 0:
        return out^
    for part in query.split("&"):
        var p = String(part)
        if p.byte_length() == 0:
            continue
        var eq = p.find("=")
        if eq < 0:
            out.append(QueryParam(percent_decode(p), String("")))
        else:
            out.append(
                QueryParam(
                    percent_decode(String(p[byte=0:eq])),
                    percent_decode(String(p[byte = eq + 1 : p.byte_length()])),
                )
            )
    return out^


def query_value(params: List[QueryParam], name: String) -> String:
    """The first value of `name` (exact match), or empty."""
    for i in range(len(params)):
        if params[i].name == name:
            return params[i].value
    return String("")


def _sort_strings(mut xs: List[String]):
    for i in range(1, len(xs)):
        var k = xs[i]
        var j = i - 1
        while j >= 0 and xs[j] > k:
            xs[j + 1] = xs[j]
            j -= 1
        xs[j + 1] = k


def _header(headers: Dict[String, String], name: String) -> String:
    """A request header by lowercase name (the server's parser lowercases
    every name), or empty."""
    var v = headers.get(name)
    if v:
        return v.value()
    return String("")


def shared_key_string_to_sign(
    verb: String,
    headers: Dict[String, String],
    path: String,
    query: String,
    account: String,
) raises -> String:
    """The string the service signs for this request (see the file header)."""
    var sts = verb + "\n"
    sts += _header(headers, "content-encoding") + "\n"
    sts += _header(headers, "content-language") + "\n"
    var content_length = _header(headers, "content-length")
    if content_length == "0":
        content_length = String("")
    sts += content_length + "\n"
    sts += _header(headers, "content-md5") + "\n"
    sts += _header(headers, "content-type") + "\n"
    if _header(headers, "x-ms-date").byte_length() > 0:
        sts += "\n"
    else:
        sts += _header(headers, "date") + "\n"
    sts += _header(headers, "if-modified-since") + "\n"
    sts += _header(headers, "if-match") + "\n"
    sts += _header(headers, "if-none-match") + "\n"
    sts += _header(headers, "if-unmodified-since") + "\n"
    sts += _header(headers, "range") + "\n"

    # CanonicalizedHeaders. The names are lowercased HERE (a caller's dict
    # may hold `X-MS-Meta-A`), so each value travels with its own name rather
    # than being looked up again by the lowercased one; two spellings of one
    # name join as `v1,v2`.
    var hdrs = List[QueryParam]()
    for kv in headers.items():
        var lname = _lower_ascii(kv.key)
        if lname.startswith("x-ms-"):
            hdrs.append(QueryParam(lname^, _collapse_ws(kv.value)))
    for i in range(1, len(hdrs)):
        var k = hdrs[i]
        var j = i - 1
        while j >= 0 and hdrs[j].name > k.name:
            hdrs[j + 1] = hdrs[j]
            j -= 1
        hdrs[j + 1] = k
    for i in range(len(hdrs)):
        if i > 0 and hdrs[i].name == hdrs[i - 1].name:
            continue
        sts += hdrs[i].name + ":" + hdrs[i].value
        var m = i + 1
        while m < len(hdrs) and hdrs[m].name == hdrs[i].name:
            sts += "," + hdrs[m].value
            m += 1
        sts += "\n"

    # CanonicalizedResource.
    sts += "/" + account + path
    var params = parse_query(query)
    var pnames = List[String]()
    for i in range(len(params)):
        var lname = _lower_ascii(params[i].name)
        var seen = False
        for j in range(len(pnames)):
            if pnames[j] == lname:
                seen = True
        if not seen:
            pnames.append(lname)
    _sort_strings(pnames)
    for i in range(len(pnames)):
        var values = List[String]()
        for j in range(len(params)):
            if _lower_ascii(params[j].name) == pnames[i]:
                values.append(params[j].value)
        _sort_strings(values)
        sts += "\n" + pnames[i] + ":"
        for j in range(len(values)):
            if j > 0:
                sts += ","
            sts += values[j]
    return sts^


def shared_key_authorization(
    account: String, key_b64: String, string_to_sign: String
) raises -> String:
    """`SharedKey <account>:<base64(HMAC-SHA256(base64-decoded key, sts))>`."""
    var key = base64_decode(key_b64)
    var mac = hmac_sha256_string(key, string_to_sign)
    var mac_bytes = List[UInt8](capacity=32)
    for i in range(32):
        mac_bytes.append(mac[i])
    return "SharedKey " + account + ":" + base64_encode(mac_bytes)
